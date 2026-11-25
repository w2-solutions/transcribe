import Foundation

/// The helper's stdio side (§6, D4). The handshake, ping, tools/list, notifications and unknown methods are answered
/// here by the same `MCPServer` the app runs, without a library, so opening Claude never launches Transcribe. Only a
/// tools/call goes to the app, on the first well-known port that gives a signed answer.
///
/// Pairing: the helper keeps one identity per Claude app (named from `clientInfo` in initialize). Unpaired, a
/// tools/call sends a pairing request instead (commit, then reveal) and tells Claude the code to check in Transcribe;
/// it never waits for the user. Paired, it signs each call with the key derived at pairing and trusts only replies
/// that verify against it (the app's public key is pinned), trying the next port when one does not. When the app says,
/// signed, that it does not know this client (removed, denied a while ago, or the request expired), the helper forgets
/// the pairing and asks again with a new identity. An unsigned "unknown" never makes it drop or replace a pairing that
/// has ever had a verified 200 or 202 (`HelperIdentity.verified`). One that never has (it was pinned to whatever answered
/// the pairing request first, which may have been something else on an earlier port, such as another macOS user's
/// Transcribe) is replaced when every port that answers says, unsigned, that it does not know the client and none
/// verifies or says otherwise.
///
/// When every port refuses the connection, the helper may start the app once (`refusedFlow`).
public actor StdioBridge {
    /// How a refused call ended.
    private enum Outcome: Sendable {
        case answer(Data?)
        case notSharing, notOpen, didNotStart
    }

    /// One pass over the ports for one call.
    private enum Step: Sendable {
        case answer(Data?)
        case allRefused
    }

    /// A signed call across the ports.
    private enum CallResult: Sendable {
        case verified(AppReply)
        case allRefused
        case failed(String)
        /// Nothing verified, and everything that answered said, unsigned, that it has no record of this client: nothing
        /// listening knows this pairing (the text is for a pairing that has been verified, which is kept).
        case unknownEverywhere(String)
    }

    private let transport: any AppTransport
    private let launcher: any AppLaunching
    private let identities: HelperIdentityStore
    private let ports: [UInt16]
    private let local: MCPServer
    private let launchWait: Duration
    private let switchOffGrace: Duration
    private let poll: Duration
    /// The pause (plus up to 100 ms of jitter) before a call whose connection was lost is sent again, once.
    private let lostRetryDelay: Duration
    /// Sent as `MCP-Protocol-Version`; set by the client's initialize.
    private var protocolVersion = MCPVersion.latest
    /// Who this helper speaks for, from initialize's `clientInfo`.
    private var clientName = ClientName.fallback
    /// The port that last gave a signed answer: tried first next time.
    private var lastGoodPort: UInt16?
    /// At most one launch per helper process (D16).
    private var launchUsed = false
    /// The launch in progress, which concurrent refused calls wait for instead of launching again.
    private var launching: Task<Outcome, Never>?

    public init(transport: any AppTransport, launcher: any AppLaunching, identities: HelperIdentityStore,
                ports: [UInt16] = WellKnownPorts.all, serverVersion: String, launchWait: Duration = .seconds(12),
                switchOffGrace: Duration = .seconds(5), poll: Duration = .milliseconds(250),
                lostRetryDelay: Duration = .milliseconds(150)) {
        self.transport = transport; self.launcher = launcher; self.identities = identities
        self.ports = ports.isEmpty ? WellKnownPorts.all : ports
        self.local = MCPServer(version: serverVersion, library: nil)
        self.launchWait = launchWait; self.switchOffGrace = switchOffGrace; self.poll = poll
        self.lostRetryDelay = lostRetryDelay
    }

    /// The reply to one line from the client (one line of JSON, no LF), or nil when none is due.
    public func handle(line: Data) async -> Data? {
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return nil }
        let message: RPCMessage
        switch RPCMessage.parse(line) {
        case .failure(let error): return RPCEncode.error(nil, error)
        case .success(let m): message = m
        }
        if case .request(let id, "tools/call", _) = message {
            return await forward(line, id: id)
        }
        if case .request(_, "initialize", let params) = message {
            protocolVersion = MCPVersion.negotiate(params?["protocolVersion"]?.string)
            clientName = ClientName.display(clientInfo: params?["clientInfo"])
        }
        switch await local.handle(line) {
        case .message(let d), .badRequest(let d): return d
        case .accepted: return nil
        }
    }

    private func forward(_ line: Data, id: RPCID) async -> Data? {
        if case .answer(let d) = await step(line, id: id) { return d }
        switch await refusedFlow(line, id: id) {
        case .answer(let d): return d
        case .notSharing: return Self.error(id, BridgeMessages.notSharing)
        case .notOpen: return Self.error(id, BridgeMessages.notOpen)
        case .didNotStart: return Self.error(id, BridgeMessages.didNotStart)
        }
    }

    // MARK: - One pass

    /// Pairs, or sends the call, across the ports.
    private func step(_ line: Data, id: RPCID) async -> Step {
        let identity: HelperIdentity
        do { identity = try identities.loadOrCreate(name: clientName) } catch {
            Self.note("couldn't save its state")
            return .answer(Self.error(id, BridgeMessages.stateUnavailable))
        }
        guard let credentials = identity.credentials else { return await pair(line, id: id, identity: identity, again: false) }
        switch await call(line, credentials: credentials) {
        case .verified(.pairing(.unknown)): return await pairAgain(line, id: id, identity: identity)
        case .verified(let reply): return .answer(render(reply, id: id, identity: noteVerified(reply, identity)))
        case .allRefused: return .allRefused
        case .failed(let text): return .answer(Self.error(id, text))
        case .unknownEverywhere(let text):
            guard !identity.verified else { return .answer(Self.error(id, text)) }
            return await pairUnconfirmed(line, id: id, identity: identity)
        }
    }

    /// A pairing that never had a verified 200 or 202, and that nothing listening knows: it was most likely pinned to
    /// something other than the user's Transcribe (an earlier port's holder), or to a request that is gone. Nothing the
    /// user allowed is lost by replacing it, so ask again with a new identity, as for a first call.
    private func pairUnconfirmed(_ line: Data, id: RPCID, identity: HelperIdentity) async -> Step {
        // Another helper process for this Claude app may have had a verified answer under it meanwhile: then keep it.
        if let saved = identities.load(name: identity.name), saved.clientID == identity.clientID, saved.verified {
            return .answer(Self.error(id, BridgeMessages.notRecognised))
        }
        Self.note("no app knows this unconfirmed pairing; asking again")
        identities.forget(identity)
        let fresh: HelperIdentity
        do { fresh = try identities.loadOrCreate(name: clientName) } catch {
            return .answer(Self.error(id, BridgeMessages.stateUnavailable))
        }
        return await pair(line, id: id, identity: fresh, again: false)
    }

    /// Records the first verified 200 or 202 under a pairing; from then on it is never replaced automatically.
    private func noteVerified(_ reply: AppReply, _ identity: HelperIdentity) -> HelperIdentity {
        switch reply {
        case .message, .accepted:
            guard !identity.verified else { return identity }
            return (try? identities.markVerified(identity)) ?? identity
        default:
            return identity
        }
    }

    /// The app this helper paired with says, signed with the pairing's key, that it does not know this identity any
    /// more (removed in Settings, never allowed, or the request expired): forget it and ask with a new one. An
    /// unsigned "unknown" never gets here (`call`): anything on a port could send one.
    private func pairAgain(_ line: Data, id: RPCID, identity: HelperIdentity) async -> Step {
        Self.note("Transcribe doesn't know this client; asking again")
        identities.forget(identity)
        let fresh: HelperIdentity
        do { fresh = try identities.loadOrCreate(name: clientName) } catch {
            return .answer(Self.error(id, BridgeMessages.stateUnavailable))
        }
        return await pair(line, id: id, identity: fresh, again: true)
    }

    /// Pairs, commit then reveal (`PairingCrypto`): sends a commitment to a fresh nonce to the first port that answers
    /// like Transcribe, pins that app's key and nonce together with its own nonce, reveals its nonce there, and tells
    /// Claude the code. If the app allows the client at once (a test hook), the call goes through now.
    private func pair(_ line: Data, id: RPCID, identity: HelperIdentity, again: Bool) async -> Step {
        let nonce = PairingCrypto.newNonce()
        let request = PairingRequest(clientID: identity.clientID, clientName: identity.name, publicKey: identity.publicKey,
                                     commitment: PairingCrypto.commitment(clientID: identity.clientID,
                                                                          clientPublicKey: identity.publicKey,
                                                                          clientNonce: nonce))
        var refused = 0, notServing = false, timedOut = false
        for port in orderedPorts() {
            switch await transport.pair(request, port: port) {
            case .reveal(let appKey, let appNonce):
                let pinned: HelperIdentity
                do { pinned = try identities.pin(identity, appPublicKey: appKey, appNonce: appNonce, clientNonce: nonce) } catch {
                    return .answer(Self.error(id, BridgeMessages.stateUnavailable))
                }
                lastGoodPort = port
                return .answer(await revealed(line, id: id, pinned: pinned, port: port, again: again))
            case .status(.denied):
                Self.note("asked Transcribe for permission: denied")
                return .answer(Self.error(id, BridgeMessages.denied))
            case .refused: refused += 1
            case .busy: return .answer(Self.error(id, BridgeMessages.pairingBusy))
            case .conflict: return .answer(Self.error(id, BridgeMessages.unauthorized))
            // Something that accepts and never answers may hold this port: keep looking (see `call`).
            case .timedOut: timedOut = true
            case .notServing: notServing = true
            case .status, .connectionLost, .invalid: continue
            }
        }
        if refused == ports.count { return .allRefused }
        if notServing { return .answer(Self.error(id, BridgeMessages.notSharing)) }
        return .answer(Self.error(id, timedOut ? BridgeMessages.timedOut : BridgeMessages.impostor))
    }

    /// Reveals the nonce on the port that took the commitment, then answers the call: the code to check, the call's
    /// result when the app allowed the client at once, or why not.
    private func revealed(_ line: Data, id: RPCID, pinned: HelperIdentity, port: UInt16, again: Bool) async -> Data? {
        guard let clientNonce = pinned.clientNonce, let code = pinned.code, let credentials = pinned.credentials else {
            return Self.error(id, BridgeMessages.impostor)
        }
        let reply = await transport.reveal(PairingReveal(clientID: pinned.clientID, publicKey: pinned.publicKey,
                                                         clientNonce: clientNonce), port: port)
        if case .status(let status) = reply { Self.note("asked Transcribe for permission: \(status.rawValue)") }
        switch reply {
        case .status(.pending):
            return Self.error(id, again ? BridgeMessages.askingAgain(code: code) : BridgeMessages.permissionNeeded(code: code))
        case .status(.denied):
            return Self.error(id, BridgeMessages.denied)
        case .status(.allowed):
            switch await call(line, credentials: credentials) {
            case .verified(.pairing(.unknown)): return Self.error(id, BridgeMessages.unauthorized)
            case .verified(let reply): return render(reply, id: id, identity: noteVerified(reply, pinned))
            case .allRefused: return Self.error(id, BridgeMessages.notOpen)
            case .failed(let text), .unknownEverywhere(let text): return Self.error(id, text)
            }
        case .timedOut: return Self.error(id, BridgeMessages.timedOut)
        case .notServing: return Self.error(id, BridgeMessages.notSharing)
        case .connectionLost: return Self.error(id, BridgeMessages.connectionLost)
        // The exchange expired, was restarted by another helper for this Claude app, or did not match: the next call
        // gets a signed "unknown" and asks again.
        case .reveal, .busy, .conflict, .refused, .invalid: return Self.error(id, BridgeMessages.unauthorized)
        }
    }

    /// Sends one signed call to each port in turn until one gives an answer that verifies. A dropped connection is
    /// sent once more on the same port (the app drops a just-accepted connection when a burst from several helpers
    /// passes its 16-connection cap; both tools are read-only and each post is signed afresh), and never launches the
    /// app. A timeout does not end the search: anything listening on an earlier port could accept and never answer, and
    /// would otherwise keep every allowed Claude app from reading. "Took too long" is reported only when no port verified.
    private func call(_ line: Data, credentials: ClientCredentials) async -> CallResult {
        var refused = 0, unknown = false, notServing = false, lost = false, impostor = false, unauthorized = false
        var timedOut = false
        var httpError: Int?
        for port in orderedPorts() {
            var reply = await transport.post(line, protocolVersion: protocolVersion, port: port, credentials: credentials)
            if reply == .connectionLost {
                let jitter = Duration.milliseconds(Int.random(in: 0...100))
                try? await Task.sleep(for: lostRetryDelay + jitter)
                reply = await transport.post(line, protocolVersion: protocolVersion, port: port, credentials: credentials)
            }
            switch reply {
            case .message, .accepted, .pairing:
                lastGoodPort = port
                return .verified(reply)
            case .refused: refused += 1
            case .timedOut: timedOut = true
            case .unknownClient: unknown = true
            case .notServing: notServing = true
            case .connectionLost: lost = true
            case .impostor: impostor = true
            case .unauthorized: unauthorized = true
            case .httpError(let code): httpError = code
            }
        }
        if refused == ports.count { return .allRefused }
        if notServing { return .failed(BridgeMessages.notSharing) }
        if timedOut { return .failed(BridgeMessages.timedOut) }
        // Unsigned, so it may come from anything on a port: never a reason to drop a verified pairing. Only when nothing
        // else answered in a way that could be the paired app (a plain 401 means an app knows this client id, and an
        // HTTP error or a dropped connection may be the app itself) may a never-verified pairing be replaced (`step`).
        if unknown, !unauthorized, !lost, httpError == nil { return .unknownEverywhere(BridgeMessages.notRecognised) }
        if unknown { return .failed(BridgeMessages.notRecognised) }
        if lost { return .failed(BridgeMessages.connectionLost) }
        if impostor { return .failed(BridgeMessages.impostor) }
        if unauthorized { return .failed(BridgeMessages.unauthorized) }
        return .failed(BridgeMessages.httpError(httpError ?? 0))
    }

    /// A verified reply as the line for Claude.
    private func render(_ reply: AppReply, id: RPCID, identity: HelperIdentity) -> Data? {
        switch reply {
        case .message(let d):
            guard d.contains(0x0A) else { return d }
            // Signed, but framing must hold: re-encode as one line.
            guard let object = try? JSONSerialization.jsonObject(with: d),
                  let flat = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
                  !flat.contains(0x0A) else { return Self.error(id, BridgeMessages.httpError(200)) }
            return flat
        case .accepted: return nil
        case .pairing(.pending): return Self.error(id, BridgeMessages.stillWaiting(code: identity.code ?? ""))
        case .pairing(.denied): return Self.error(id, BridgeMessages.denied)
        default: return Self.error(id, BridgeMessages.unauthorized)
        }
    }

    /// The ports in order, the one that last answered first.
    private func orderedPorts() -> [UInt16] {
        guard let lastGoodPort, ports.contains(lastGoodPort) else { return ports }
        return [lastGoodPort] + ports.filter { $0 != lastGoodPort }
    }

    // MARK: - Starting the app

    /// Every port refused the connection (§6 `refusedFlow`).
    private func refusedFlow(_ line: Data, id: RPCID) async -> Outcome {
        // Another call is already launching the app: wait for it, then send this call once. Checked again after the
        // running-app check, which suspends, so a launch started meanwhile is joined rather than refused.
        if let launching { return await join(launching, line, id: id) }
        let running = await launcher.anyCopyRunning()
        if let launching { return await join(launching, line, id: id) }
        if running {
            // A copy is up but refusing: the switch is off (or it is still starting). Never launch another copy.
            for _ in 0..<2 {
                try? await Task.sleep(for: poll * 2)
                if case .answer(let d) = await step(line, id: id) { return .answer(d) }
            }
            return .notSharing
        }
        guard !launchUsed, launcher.canLaunch else { return .notOpen }
        launchUsed = true
        let task = Task { await self.launchAndWait(line, id: id) }
        launching = task
        let outcome = await Self.value(of: task)
        launching = nil
        return outcome
    }

    private func join(_ launch: Task<Outcome, Never>, _ line: Data, id: RPCID) async -> Outcome {
        let outcome = await Self.value(of: launch)
        guard case .answer = outcome else { return outcome }
        if case .answer(let d) = await step(line, id: id) { return .answer(d) }
        return .notSharing
    }

    private func launchAndWait(_ line: Data, id: RPCID) async -> Outcome {
        guard await launcher.launch() else { return .didNotStart }
        let clock = ContinuousClock()
        let deadline = clock.now + launchWait
        var runningSince: ContinuousClock.Instant?
        while clock.now < deadline {
            try? await Task.sleep(for: poll)
            if Task.isCancelled { return .didNotStart }
            if case .answer(let d) = await step(line, id: id) { return .answer(d) }
            if await launcher.anyCopyRunning() {
                let since = runningSince ?? clock.now
                runningSince = since
                if clock.now - since >= switchOffGrace { return .notSharing }
            }
        }
        return .didNotStart
    }

    /// Waits for the shared launch. The launch runs in its own task, so a waiter cancelled at stdin EOF (`run`) passes
    /// the cancellation on; otherwise `run` would wait out the whole launch instead of its 5 s.
    private static func value(of launch: Task<Outcome, Never>) async -> Outcome {
        await withTaskCancellationHandler { await launch.value } onCancel: { launch.cancel() }
    }

    private static func error(_ id: RPCID, _ text: String) -> Data {
        RPCEncode.result(id, MCPServer.toolResult(text, isError: true))
    }

    /// One short line on stderr (Claude Desktop keeps it in its log). Never a key, code, name or argument.
    private static func note(_ event: String) {
        FileHandle.standardError.write(Data("transcribe-mcp: \(event)\n".utf8))
    }

    // MARK: - Running over stdio

    /// Reads newline-delimited JSON from `input` until EOF and writes each reply as one line to `output`. Each line is
    /// handled in its own task, so a slow call never holds up a ping, except `initialize`, which is answered in order
    /// before the next line is read: it names the Claude app, and so the pairing, of every later call. At EOF,
    /// in-flight calls get up to 5 s. If a write fails (the client has gone), `onOutputClosed` runs; the helper exits
    /// there.
    public static func run(_ bridge: StdioBridge, input: FileHandle, output: FileHandle,
                           onOutputClosed: @escaping @Sendable () -> Void = {}) async {
        let writer = LineWriter(output, onClosed: onOutputClosed)
        await withTaskGroup(of: Bool.self) { group in
            var pending = 0
            func dispatch(_ line: LineSplitter.Line) async {
                if case .line(let data) = line, case .success(.request(_, "initialize", _)) = RPCMessage.parse(data) {
                    if let reply = await bridge.handle(line: data) { await writer.write(reply) }
                    return
                }
                pending += 1
                group.addTask {
                    switch line {
                    case .tooLong: await writer.write(RPCEncode.error(nil, .invalidRequest))
                    case .line(let data): if let reply = await bridge.handle(line: data) { await writer.write(reply) }
                    }
                    return true
                }
            }
            var splitter = LineSplitter()
            do {
                for try await byte in input.bytes {
                    if let line = splitter.feed(byte) { await dispatch(line) }
                }
            } catch {}
            if let line = splitter.finish() { await dispatch(line) }
            guard pending > 0 else { return }

            // EOF: wait for in-flight calls, at most 5 s.
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            while let isLine = await group.next() {
                if isLine { pending -= 1 }
                if !isLine || pending == 0 { group.cancelAll(); break }
            }
        }
    }
}

/// Writes one message per line, in order.
actor LineWriter {
    private let handle: FileHandle
    private let onClosed: @Sendable () -> Void
    private var closed = false

    init(_ handle: FileHandle, onClosed: @escaping @Sendable () -> Void) { self.handle = handle; self.onClosed = onClosed }

    func write(_ message: Data) {
        guard !closed else { return }
        do {
            try handle.write(contentsOf: message + Data([0x0A]))
        } catch {
            closed = true
            onClosed()
        }
    }
}
