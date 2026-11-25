import Foundation
import Synchronization
import Testing
@testable import TranscribeMCP

/// A pretend Mac: whether Transcribe runs and shares, on which port, which clients it allowed, and what launching it
/// does. Every other port refuses, unless `squatters` names something else answering there.
actor FakeMac {
    nonisolated let appPrivateKey = PairingCrypto.newPrivateKey()
    nonisolated var appPublicKey: String { PairingCrypto.publicKey(ofPrivate: appPrivateKey)! }
    var port: UInt16 = 41_000
    var running = false
    var sharing = false
    var launches = 0
    /// "pair <port>" or "post <port>", in order.
    var attempts: [String] = []
    var posted: [Data] = []
    var protocolVersions: [String] = []
    var pairRequests: [PairingRequest] = []
    /// New pairing requests are allowed at once (the app's test hook), or left pending for the test to answer.
    var autoAllow = true
    var clients: [String: PairStatus] = [:]
    /// Each client's exchange (commitment and the app's nonce), and its pairing transcript once revealed.
    var exchanges: [String: (commitment: String, appNonce: String)] = [:]
    var pairings: [String: String] = [:]
    /// Answers every pairing commit with this instead.
    var pairOverride: PairReply?
    /// Answers every reveal with this instead.
    var revealOverride: PairReply?
    /// Other ports with something else on them: what a signed call there gets (pairing requests get `.invalid`).
    var squatters: [UInt16: AppReply] = [:]
    var launchSucceeds = true
    /// After a launch: whether a process appears, and when the listener comes up (nil: the switch is off).
    var appearsAfterLaunch = true
    var sharesAfterLaunch: Duration? = .milliseconds(30)
    /// Answers every signed call to the app's port with this instead (an error, or a reply from another process).
    var fixedReply: AppReply?
    /// How long a call takes while sharing.
    var postDelay: Duration = .zero
    /// The app's reply body; by default a tool result that echoes the request id.
    var replyBody: ((Data) -> Data)?
    /// The next this-many calls lose their connection (the app dropped them at its connection cap).
    var dropNext = 0

    func set(running: Bool = false, sharing: Bool = false) { self.running = running; self.sharing = sharing }
    func set(port: UInt16) { self.port = port }
    func set(autoAllow: Bool) { self.autoAllow = autoAllow }
    func set(client id: String, _ status: PairStatus?) { clients[id] = status }
    func set(pairOverride: PairReply?) { self.pairOverride = pairOverride }
    func set(revealOverride: PairReply?) { self.revealOverride = revealOverride }
    func set(squatter port: UInt16, _ reply: AppReply) { squatters[port] = reply }
    func set(dropNext: Int) { self.dropNext = dropNext }
    func set(fixedReply: AppReply?) { self.fixedReply = fixedReply }
    func set(launchSucceeds: Bool) { self.launchSucceeds = launchSucceeds }
    func set(appearsAfterLaunch: Bool, sharesAfterLaunch: Duration?) {
        self.appearsAfterLaunch = appearsAfterLaunch; self.sharesAfterLaunch = sharesAfterLaunch
    }
    func set(postDelay: Duration) { self.postDelay = postDelay }
    func set(replyBody: @escaping @Sendable (Data) -> Data) { self.replyBody = replyBody }

    /// The commit step, as the app answers it: a fresh nonce (or the same one for the same commitment).
    func pair(_ request: PairingRequest, port: UInt16) -> PairReply {
        attempts.append("pair \(port)")
        // A squatter that never answers times out here too; any other squatter answers something that is not Transcribe.
        if let squatter = squatters[port] { return squatter == .timedOut ? .timedOut : .invalid }
        guard port == self.port, sharing else { return .refused }
        pairRequests.append(request)
        if let pairOverride { return pairOverride }
        if clients[request.clientID] == .denied { return .status(.denied) }
        if let e = exchanges[request.clientID], e.commitment == request.commitment {
            return .reveal(appPublicKey: appPublicKey, appNonce: e.appNonce)
        }
        let nonce = PairingCrypto.newNonce()
        exchanges[request.clientID] = (request.commitment, nonce)
        return .reveal(appPublicKey: appPublicKey, appNonce: nonce)
    }

    /// The reveal step: the nonce must match the commitment; then the request is pending (or allowed at once).
    func reveal(_ reveal: PairingReveal, port: UInt16) -> PairReply {
        attempts.append("reveal \(port)")
        guard port == self.port, sharing else { return .refused }
        if let revealOverride { return revealOverride }
        guard let e = exchanges[reveal.clientID],
              PairingCrypto.commitment(clientID: reveal.clientID, clientPublicKey: reveal.publicKey,
                                       clientNonce: reveal.clientNonce) == e.commitment else { return .invalid }
        pairings[reveal.clientID] = PairingCrypto.transcript(clientID: reveal.clientID, clientPublicKey: reveal.publicKey,
                                                             appPublicKey: appPublicKey, appNonce: e.appNonce,
                                                             clientNonce: reveal.clientNonce)
        if clients[reveal.clientID] == nil { clients[reveal.clientID] = autoAllow ? .allowed : .pending }
        return .status(clients[reveal.clientID]!)
    }

    func post(_ body: Data, protocolVersion: String, port: UInt16, credentials: ClientCredentials) async -> AppReply {
        attempts.append("post \(port)")
        if let squatter = squatters[port] { return squatter }
        posted.append(body)
        protocolVersions.append(protocolVersion)
        if dropNext > 0 { dropNext -= 1; return .connectionLost }
        if let fixedReply { return fixedReply }
        guard port == self.port, sharing else { return .refused }
        // A pairing the app never completed (or another one) is unknown to it.
        guard pairings[credentials.clientID] == credentials.pairing else { return .pairing(.unknown) }
        switch clients[credentials.clientID] {
        case .pending: return .pairing(.pending)
        case .denied: return .pairing(.denied)
        case nil: return .pairing(.unknown)
        case .allowed: break
        }
        if postDelay > .zero { try? await Task.sleep(for: postDelay) }
        if let replyBody { return .message(replyBody(body)) }
        let id = body.json["id"] ?? .null
        return .message(JSONValue.object(["jsonrpc": "2.0", "id": id,
                                          "result": ["content": [["type": "text", "text": "from the app"]]]]).encoded())
    }

    func launch() -> Bool {
        launches += 1
        guard launchSucceeds else { return false }
        if appearsAfterLaunch { running = true }
        if let delay = sharesAfterLaunch {
            Task { try? await Task.sleep(for: delay); self.sharing = true }
        }
        return true
    }
}

struct FakeTransport: AppTransport {
    let mac: FakeMac
    func post(_ body: Data, protocolVersion: String, port: UInt16, credentials: ClientCredentials) async -> AppReply {
        await mac.post(body, protocolVersion: protocolVersion, port: port, credentials: credentials)
    }
    func pair(_ request: PairingRequest, port: UInt16) async -> PairReply { await mac.pair(request, port: port) }
    func reveal(_ reveal: PairingReveal, port: UInt16) async -> PairReply { await mac.reveal(reveal, port: port) }
}

struct FakeLauncher: AppLaunching {
    let mac: FakeMac
    var canLaunch = true
    func anyCopyRunning() async -> Bool { await mac.running }
    func launch() async -> Bool { await mac.launch() }
}

/// A folder for one test's helper state, removed when the test's suite instance goes.
final class StateFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-helper-\(UUID().uuidString)", isDirectory: true)
    var store: HelperIdentityStore { HelperIdentityStore(directory: url) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

func makeBridge(_ mac: FakeMac, state: StateFolder, ports: [UInt16] = [41_000], canLaunch: Bool = true) -> StdioBridge {
    StdioBridge(transport: FakeTransport(mac: mac), launcher: FakeLauncher(mac: mac, canLaunch: canLaunch),
                identities: state.store, ports: ports, serverVersion: "9.9", launchWait: .milliseconds(400),
                switchOffGrace: .milliseconds(120), poll: .milliseconds(10))
}

let listCall = request(7, "tools/call", ["name": "list_recordings", "arguments": [:]])

extension Optional where Wrapped == Data {
    /// The text of a tool result, and whether it is an error.
    var toolText: (text: String, isError: Bool)? {
        guard let json = self?.json, let text = json["result"]?["content"]?[0]?["text"]?.string else { return nil }
        return (text, json["result"]?["isError"] == true)
    }
}

extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }
}

@Suite("MCP: stdio bridge")
final class StdioBridgeTests {
    let state = StateFolder()

    func bridge(_ mac: FakeMac, ports: [UInt16] = [41_000], canLaunch: Bool = true) -> StdioBridge {
        makeBridge(mac, state: state, ports: ports, canLaunch: canLaunch)
    }

    /// The code the helper shows for its saved identity, checked against the one the app computes from its side.
    func code(_ mac: FakeMac, name: String = "Claude") async -> String? {
        guard let identity = state.store.load(name: name), let code = identity.code else { return nil }
        let appSide = await mac.pairings[identity.clientID].map(PairingCrypto.code(pairing:))
        #expect(appSide == code, "the app and the helper show different codes")
        return code
    }

    // MARK: - Answered by the helper

    @Test func initializeAnsweredLocallyWithoutApp() async {
        let mac = FakeMac()
        let bridge = bridge(mac)
        let reply = await bridge.handle(line: request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                         "clientInfo": ["name": "claude-code", "version": "1"]]))
        #expect(reply?.json["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply?.json["result"]?["serverInfo"]?["version"] == "9.9")
        #expect(await mac.attempts.isEmpty)
        #expect(await mac.launches == 0)
        // The negotiated version goes with later forwarded calls, and the client's name names its pairing.
        await mac.set(running: true, sharing: true)
        _ = await bridge.handle(line: listCall)
        #expect(await mac.protocolVersions == ["2025-06-18"])
        #expect(await mac.pairRequests.map(\.clientName) == ["Claude Code"])
        #expect(state.store.load(name: "Claude Code") != nil && state.store.load(name: "Claude") == nil)
    }

    @Test func toolsListAnsweredLocally() async {
        let mac = FakeMac()
        let reply = await bridge(mac).handle(line: request(2, "tools/list"))
        if case .array(let tools) = reply?.json["result"]?["tools"] { #expect(tools.count == 2) } else { Issue.record("no tools") }
        let ping = await bridge(mac).handle(line: request(3, "ping"))
        #expect(ping?.json["result"] == .object([:]))
        let discover = await bridge(mac).handle(line: request(4, "server/discover"))
        #expect(discover?.json["error"]?["code"] == -32601)
        #expect(await mac.attempts.isEmpty)
        #expect(await mac.launches == 0)
    }

    // MARK: - Pairing

    @Test func unpairedCallAsksPermissionWithCode() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(autoAllow: false)
        let reply = await bridge(mac).handle(line: listCall)
        let code = try #require(await code(mac))
        #expect(reply.toolText?.text == BridgeMessages.permissionNeeded(code: code) && reply.toolText?.isError == true)
        #expect(reply?.json["id"] == .int(7))
        #expect(code.range(of: #"^\d{3} \d{3}$"#, options: .regularExpression) != nil)
        // Nothing was sent to the app but the pairing request, and the app's key is pinned.
        #expect(await mac.posted.isEmpty)
        #expect(await mac.attempts == ["pair 41000", "reveal 41000"])
        #expect(state.store.load(name: "Claude")?.appPublicKey == mac.appPublicKey)
        let sent = try #require(await mac.pairRequests.first)
        #expect(sent.clientName == "Claude" && sent.publicKey == state.store.load(name: "Claude")?.publicKey)
    }

    @Test func pendingSaysStillWaitingThenAllowedReads() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(autoAllow: false)
        let bridge = bridge(mac)
        _ = await bridge.handle(line: listCall)
        let code = try #require(await code(mac))
        let waiting = await bridge.handle(line: listCall)
        #expect(waiting.toolText?.text == BridgeMessages.stillWaiting(code: code) && waiting.toolText?.isError == true)
        // The user clicks Allow.
        let id = try #require(state.store.load(name: "Claude")?.clientID)
        await mac.set(client: id, .allowed)
        let reply = await bridge.handle(line: listCall)
        #expect(reply.toolText?.text == "from the app" && reply.toolText?.isError == false)
        #expect(await mac.pairRequests.count == 1)
    }

    @Test func deniedSaysSo() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(autoAllow: false)
        let bridge = bridge(mac)
        _ = await bridge.handle(line: listCall)
        let id = try #require(state.store.load(name: "Claude")?.clientID)
        await mac.set(client: id, .denied)
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.denied)
        // A pairing request answered "denied" says the same.
        let fresh = FakeMac()
        await fresh.set(running: true, sharing: true)
        await fresh.set(pairOverride: .status(.denied))
        #expect(await makeBridge(fresh, state: StateFolder()).handle(line: listCall).toolText?.text == BridgeMessages.denied)
    }

    @Test func removedForgetsAndAsksAgain() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        let bridge = bridge(mac)
        #expect(await bridge.handle(line: listCall).toolText?.text == "from the app")
        let old = try #require(state.store.load(name: "Claude"))
        // Removed in Transcribe: the app answers (signed) that it does not know this client.
        await mac.set(client: old.clientID, nil)
        await mac.set(autoAllow: false)
        let reply = await bridge.handle(line: listCall)
        let new = try #require(state.store.load(name: "Claude"))
        #expect(new.clientID != old.clientID && new.publicKey != old.publicKey)
        let newCode = try #require(await code(mac))
        #expect(reply.toolText?.text == BridgeMessages.askingAgain(code: newCode))
        #expect(await mac.pairRequests.map(\.clientID) == [old.clientID, new.clientID])
    }

    /// A pairing that never had a verified 200 or 202 (still pending, or pinned to something else on an earlier port)
    /// and that nothing listening knows (every answer is an unsigned "unknown") is replaced by a new one, asked for
    /// like a first call.
    @Test func unconfirmedPairingNobodyKnowsIsReplaced() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(autoAllow: false)
        let bridge = bridge(mac)
        _ = await bridge.handle(line: listCall)
        let old = try #require(state.store.load(name: "Claude"))
        #expect(!old.verified && old.credentials != nil)
        await mac.set(fixedReply: .unknownClient)
        let reply = await bridge.handle(line: listCall)
        let new = try #require(state.store.load(name: "Claude"))
        #expect(new.clientID != old.clientID && new.publicKey != old.publicKey && !new.verified)
        #expect(await mac.pairRequests.map(\.clientID) == [old.clientID, new.clientID])
        let newCode = try #require(await code(mac))
        #expect(reply.toolText?.text == BridgeMessages.permissionNeeded(code: newCode))
    }

    /// A never-verified pairing is kept while anything answers in a way that could be the paired app itself: a plain
    /// 401 (an app that knows this client id), an HTTP error, a dropped connection, a timeout or "not sharing".
    @Test func unconfirmedPairingKeptWhenAnAppMightKnowIt() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(autoAllow: false)
        let bridge = bridge(mac, ports: [41_000, 2])
        _ = await bridge.handle(line: listCall)
        let old = try #require(state.store.load(name: "Claude"))
        await mac.set(squatter: 2, .unknownClient)
        for (reply, text) in [(AppReply.unauthorized, BridgeMessages.notRecognised), (.httpError(400), BridgeMessages.notRecognised),
                              (.connectionLost, BridgeMessages.notRecognised), (.timedOut, BridgeMessages.timedOut),
                              (.notServing, BridgeMessages.notSharing)] {
            await mac.set(fixedReply: reply)
            #expect(await bridge.handle(line: listCall).toolText?.text == text, "\(reply)")
            #expect(state.store.load(name: "Claude") == old, "\(reply)")
        }
        #expect(await mac.pairRequests.count == 1)
    }

    /// The first verified reply marks the pairing; from then on an unsigned "unknown" everywhere never replaces it.
    @Test func verifiedPairingIsNeverReplaced() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(autoAllow: false)
        let bridge = bridge(mac)
        _ = await bridge.handle(line: listCall)
        let id = try #require(state.store.load(name: "Claude")?.clientID)
        #expect(state.store.load(name: "Claude")?.verified == false)
        // Signed "pending" is verified, but not a 200 or 202: not yet confirmed.
        _ = await bridge.handle(line: listCall)
        #expect(state.store.load(name: "Claude")?.verified == false)
        await mac.set(client: id, .allowed)
        #expect(await bridge.handle(line: listCall).toolText?.text == "from the app")
        let confirmed = try #require(state.store.load(name: "Claude"))
        #expect(confirmed.verified && confirmed.clientID == id)
        await mac.set(fixedReply: .unknownClient)
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.notRecognised)
        #expect(await makeBridge(mac, state: state).handle(line: listCall).toolText?.text == BridgeMessages.notRecognised)
        #expect(state.store.load(name: "Claude") == confirmed)
        #expect(await mac.pairRequests.count == 1)
    }

    /// An unsigned "unknown" (what the app sends when it lost its key, but anything on a port can send it) never makes
    /// the helper drop its pairing or pair again: it says so, and the pairing still works once the app answers signed.
    @Test func unsignedUnknownKeepsThePairing() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(port: 2)
        let bridge = bridge(mac, ports: [1, 2])
        #expect(await bridge.handle(line: listCall).toolText?.text == "from the app")
        let old = try #require(state.store.load(name: "Claude"))
        // Transcribe quits; something else on port 1 claims not to know the client.
        await mac.set(running: false, sharing: false)
        await mac.set(squatter: 1, .unknownClient)
        let pairsBefore = await mac.pairRequests.count
        let reply = await makeBridge(mac, state: state, ports: [1, 2], canLaunch: false).handle(line: listCall)
        #expect(reply.toolText?.text == BridgeMessages.notRecognised && reply.toolText?.isError == true)
        #expect(state.store.load(name: "Claude") == old)
        #expect(await mac.pairRequests.count == pairsBefore)
        // The same when the app itself answers unsigned "unknown" on every port.
        await mac.set(running: true, sharing: true)
        await mac.set(fixedReply: .unknownClient)
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.notRecognised)
        #expect(state.store.load(name: "Claude") == old)
        // Transcribe answers signed again: the old pairing still reads.
        await mac.set(fixedReply: nil)
        #expect(await bridge.handle(line: listCall).toolText?.text == "from the app")
    }

    /// A reveal that does not go through (the exchange expired, or another helper restarted it) says try again; the
    /// next call finds the app does not know that pairing (signed) and asks again with a new identity.
    @Test func failedRevealAsksToTryAgain() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(autoAllow: false)
        await mac.set(revealOverride: .conflict)
        let bridge = bridge(mac)
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.unauthorized)
        let first = try #require(state.store.load(name: "Claude"))
        await mac.set(revealOverride: nil)
        let reply = await bridge.handle(line: listCall)
        let second = try #require(state.store.load(name: "Claude"))
        #expect(second.clientID != first.clientID)
        let code = try #require(await code(mac))
        #expect(reply.toolText?.text == BridgeMessages.askingAgain(code: code))
    }

    @Test func busySaysAnswerTheOthers() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(pairOverride: .busy)
        #expect(await bridge(mac).handle(line: listCall).toolText?.text == BridgeMessages.pairingBusy)
    }

    @Test func unwritableStateSaysSo() async throws {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        // The state folder's parent is a file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let bridge = StdioBridge(transport: FakeTransport(mac: mac), launcher: FakeLauncher(mac: mac),
                                 identities: HelperIdentityStore(directory: file.appendingPathComponent("state")),
                                 ports: [41_000], serverVersion: "9.9")
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.stateUnavailable)
        #expect(await mac.attempts.isEmpty)
    }

    // MARK: - Ports

    @Test func portsTriedInOrderThenTheGoodOneFirst() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(port: 2)
        let bridge = bridge(mac, ports: [1, 2, 3])
        #expect(await bridge.handle(line: listCall).toolText?.text == "from the app")
        #expect(await mac.attempts == ["pair 1", "pair 2", "reveal 2", "post 2"])
        _ = await bridge.handle(line: listCall)
        #expect(await mac.attempts.suffix(1) == ["post 2"])
    }

    @Test func badMACOnOnePortFallsThroughToTheNext() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(port: 2)
        let bridge = bridge(mac, ports: [1, 2, 3])
        _ = await bridge.handle(line: listCall)
        // Something else takes port 1 (and the helper starts again from the first port).
        await mac.set(squatter: 1, .impostor)
        let fresh = makeBridge(mac, state: state, ports: [1, 2, 3])
        let reply = await fresh.handle(line: listCall)
        #expect(reply.toolText?.text == "from the app" && reply.toolText?.isError == false)
        #expect(await mac.attempts.suffix(2) == ["post 1", "post 2"])
    }

    /// Something on an earlier port accepts the connection and never answers: the helper waits out the timeout there,
    /// then still reaches the app on the next port, to pair and to read. A timeout must not end the search, or any
    /// local process listening on the first port could stop every allowed Claude app from reading.
    @Test func timeoutOnOnePortFallsThroughToTheNext() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(port: 2)
        await mac.set(squatter: 1, .timedOut)
        let bridge = bridge(mac, ports: [1, 2, 3])
        #expect(await bridge.handle(line: listCall).toolText?.text == "from the app")
        #expect(await mac.attempts == ["pair 1", "pair 2", "reveal 2", "post 2"])
        // A fresh helper process starts again from the first port.
        let fresh = makeBridge(mac, state: state, ports: [1, 2, 3])
        #expect(await fresh.handle(line: listCall).toolText?.text == "from the app")
        #expect(await mac.attempts.suffix(2) == ["post 1", "post 2"])
        // Nothing else answering: still "took too long".
        await mac.set(running: false, sharing: false)
        #expect(await makeBridge(mac, state: state, ports: [1, 2, 3], canLaunch: false).handle(line: listCall).toolText?.text
                == BridgeMessages.timedOut)
    }

    @Test func impostorEverywhereSaysImpostor() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        let bridge = bridge(mac, ports: [41_000, 2])
        _ = await bridge.handle(line: listCall)
        await mac.set(fixedReply: .impostor)
        await mac.set(squatter: 2, .unauthorized)
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.impostor)
        // An unpaired helper that finds nothing that pairs says the same.
        let lonely = FakeMac()
        await lonely.set(squatter: 41_000, .impostor)
        #expect(await makeBridge(lonely, state: StateFolder()).handle(line: listCall).toolText?.text == BridgeMessages.impostor)
    }

    // MARK: - Forwarding

    @Test func toolsCallForwardedVerbatim() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        let line = Data(#"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"get_transcript","arguments":{"recording_id":"x"}}}"#.utf8)
        let reply = await bridge(mac).handle(line: line)
        #expect(await mac.posted == [line])
        #expect(reply?.json["id"] == "abc" && reply.toolText?.text == "from the app")
        #expect(await mac.protocolVersions == ["2025-11-25"])
    }

    @Test func refusedNoCopyLaunchesThenSucceeds() async {
        let mac = FakeMac()
        let reply = await bridge(mac).handle(line: listCall)
        #expect(reply.toolText?.text == "from the app" && reply.toolText?.isError == false)
        #expect(await mac.launches == 1)
    }

    @Test func refusedNoCopyLaunchFailsIsDidNotStart() async {
        let mac = FakeMac()
        await mac.set(launchSucceeds: false)
        #expect(await bridge(mac).handle(line: listCall).toolText?.text == BridgeMessages.didNotStart)
        // Launched, but no process ever appears within the wait.
        let quiet = FakeMac()
        await quiet.set(appearsAfterLaunch: false, sharesAfterLaunch: nil)
        let started = ContinuousClock.now
        let reply = await bridge(quiet).handle(line: listCall)
        #expect(reply.toolText?.text == BridgeMessages.didNotStart && reply.toolText?.isError == true)
        #expect(ContinuousClock.now - started >= .milliseconds(400))
    }

    @Test func refusedWhileAnyCopyRunningSaysTurnOnAndDoesNotLaunch() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: false)
        let reply = await bridge(mac).handle(line: listCall)
        #expect(reply.toolText?.text == BridgeMessages.notSharing && reply.toolText?.isError == true)
        #expect(await mac.launches == 0)
        #expect(await mac.attempts.count == 3)   // the call and two retries
    }

    @Test func launchedButSwitchOffSaysTurnOnAfterGrace() async {
        let mac = FakeMac()
        await mac.set(appearsAfterLaunch: true, sharesAfterLaunch: nil)
        let started = ContinuousClock.now
        let reply = await bridge(mac).handle(line: listCall)
        let elapsed = ContinuousClock.now - started
        #expect(reply.toolText?.text == BridgeMessages.notSharing)
        #expect(elapsed >= .milliseconds(120))
        #expect(await mac.launches == 1)
    }

    @Test func noSecondLaunchInOneProcess() async {
        let mac = FakeMac()
        await mac.set(launchSucceeds: false)
        let bridge = bridge(mac)
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.didNotStart)
        await mac.set(launchSucceeds: true)
        #expect(await bridge.handle(line: listCall).toolText?.text == BridgeMessages.notOpen)
        #expect(await mac.launches == 1)
    }

    @Test func cannotLaunchSaysNotOpen() async {
        let mac = FakeMac()
        let started = ContinuousClock.now
        let reply = await bridge(mac, canLaunch: false).handle(line: listCall)
        #expect(reply.toolText?.text == BridgeMessages.notOpen && reply.toolText?.isError == true)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await mac.launches == 0)
    }

    @Test func concurrentCallsShareOneLaunch() async {
        let mac = FakeMac()
        await mac.set(appearsAfterLaunch: true, sharesAfterLaunch: .milliseconds(60))
        let bridge = bridge(mac)
        async let a = bridge.handle(line: listCall)
        async let b = bridge.handle(line: request(8, "tools/call", ["name": "list_recordings"]))
        async let c = bridge.handle(line: request(9, "tools/call", ["name": "get_transcript"]))
        let replies = await [a, b, c]
        #expect(replies.map { $0.toolText?.text } == Array(repeating: "from the app", count: 3))
        #expect(replies.map { $0?.json["id"] } == [.int(7), .int(8), .int(9)])
        #expect(await mac.launches == 1)
        // All three used the one identity.
        #expect(Set(await mac.pairRequests.map(\.clientID)).count == 1)
    }

    @Test func connectionLostDoesNotLaunch() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(fixedReply: .connectionLost)
        #expect(await bridge(mac).handle(line: listCall).toolText?.text == BridgeMessages.connectionLost)
        #expect(await mac.launches == 0)
        #expect(await mac.posted.count == 2)   // the call and one retry
    }

    @Test func connectionLostOnceIsRetried() async {
        // The app dropped the connection at its cap (a burst from several helpers): the call is sent once more.
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(dropNext: 1)
        let reply = await bridge(mac).handle(line: listCall)
        #expect(reply.toolText?.text == "from the app" && reply.toolText?.isError == false)
        #expect(reply?.json["id"] == .int(7))
        #expect(await mac.posted == [listCall, listCall])
        #expect(await mac.launches == 0)
    }

    @Test func unauthorizedSaysRemoveAndAskAgain() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(fixedReply: .unauthorized)
        let reply = await bridge(mac).handle(line: listCall)
        #expect(reply.toolText?.text == BridgeMessages.unauthorized && reply.toolText?.isError == true)
        #expect(reply?.json["id"] == .int(7))
    }

    @Test func otherFailuresMapToTheirMessages() async {
        for (fixed, text) in [(AppReply.notServing, BridgeMessages.notSharing), (.timedOut, BridgeMessages.timedOut),
                              (.httpError(500), BridgeMessages.httpError(500)), (.impostor, BridgeMessages.impostor)] {
            let mac = FakeMac()
            await mac.set(running: true, sharing: true)
            await mac.set(fixedReply: fixed)
            #expect(await makeBridge(mac, state: StateFolder()).handle(line: listCall).toolText?.text == text, "\(fixed)")
            #expect(await mac.launches == 0)
        }
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(fixedReply: .accepted)
        #expect(await bridge(mac).handle(line: listCall) == nil)
    }

    @Test func enclosingAppFromHelperPath() {
        let helper = URL(fileURLWithPath: "/Applications/Transcribe.app/Contents/Helpers/transcribe-mcp")
        #expect(EnclosingApp.url(forHelper: helper)?.path == "/Applications/Transcribe.app")
        let spaced = URL(fileURLWithPath: "/Users/x/My Apps/Tran'scribe.app/Contents/Helpers/transcribe-mcp")
        #expect(EnclosingApp.url(forHelper: spaced)?.path == "/Users/x/My Apps/Tran'scribe.app")
        #expect(EnclosingApp.url(forHelper: URL(fileURLWithPath: "/usr/local/bin/transcribe-mcp")) == nil)
        #expect(EnclosingApp.url(forHelper: URL(fileURLWithPath: "/A.app/Contents/MacOS/transcribe-mcp")) == nil)
        #expect(EnclosingApp.url(forHelper: URL(fileURLWithPath: "/A.app/Contents/Helpers/other")) == nil)
    }

    @Test func invalidLineGetsParseError() async {
        let bridge = bridge(FakeMac())
        let parse = await bridge.handle(line: Data("{nope".utf8))
        #expect(parse?.json["error"]?["code"] == -32700 && parse?.json["id"] == .null)
        let batch = await bridge.handle(line: Data("[\(String(decoding: listCall, as: UTF8.self))]".utf8))
        #expect(batch?.json["error"]?["code"] == -32600)
        let nullID = await bridge.handle(line: Data(#"{"jsonrpc":"2.0","id":null,"method":"tools/call"}"#.utf8))
        #expect(nullID?.json["error"]?["code"] == -32600)
    }

    @Test func notificationWritesNothing() async {
        let mac = FakeMac()
        let bridge = bridge(mac)
        #expect(await bridge.handle(line: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
        #expect(await bridge.handle(line: Data(#"{"jsonrpc":"2.0","id":5,"result":{}}"#.utf8)) == nil)
        #expect(await bridge.handle(line: Data()) == nil)
        #expect(await bridge.handle(line: Data("  \t\r".utf8)) == nil)
        #expect(await mac.attempts.isEmpty)
    }

    @Test func responsesAreSingleLines() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(replyBody: { body in
            let id = body.json["id"] ?? .null
            let pretty = JSONEncoder()
            pretty.outputFormatting = [.prettyPrinted]
            let value = JSONValue.object(["jsonrpc": "2.0", "id": id,
                                          "result": ["content": [["type": "text", "text": "line one\nline two\u{2028}"]]]])
            return try! pretty.encode(value)
        })
        let reply = await bridge(mac).handle(line: listCall)
        #expect(reply?.contains(0x0A) == false)
        #expect(reply.toolText?.text == "line one\nline two\u{2028}")
        #expect(reply?.json["id"] == .int(7))
    }

    @Test func concurrentCallsDoNotBlockPing() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(postDelay: .seconds(2))
        let bridge = bridge(mac)
        let slow = Task { await bridge.handle(line: listCall) }
        try? await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        let ping = await bridge.handle(line: request(2, "ping"))
        #expect(ping?.json["result"] == .object([:]))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await slow.value.toolText?.text == "from the app")
    }

    // MARK: - run over real file descriptors

    /// The lines written to `output` (split on LF).
    static func replies(_ data: Data) -> [JSONValue] {
        data.split(separator: 0x0A).map { Data($0).json }
    }

    @Test func runReturnsOnEOF() async {
        let mac = FakeMac()
        await mac.set(running: true, sharing: true)
        await mac.set(postDelay: .milliseconds(200))
        let input = Pipe(), output = Pipe()
        let lines = [request(1, "initialize", ["protocolVersion": "2025-11-25"]),
                     Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8),
                     request(2, "tools/list"), listCall, Data("{broken".utf8)]
        input.fileHandleForWriting.write(lines.reduce(Data()) { $0 + $1 + Data([0x0A]) })
        // The last line has no LF and still counts.
        input.fileHandleForWriting.write(request(3, "ping"))
        try? input.fileHandleForWriting.close()

        let started = ContinuousClock.now
        await StdioBridge.run(bridge(mac), input: input.fileHandleForReading, output: output.fileHandleForWriting)
        #expect(ContinuousClock.now - started < .seconds(3))
        try? output.fileHandleForWriting.close()
        let replies = Self.replies(output.fileHandleForReading.readDataToEndOfFile())
        #expect(replies.count == 5)
        #expect(Set(replies.map { $0["id"]?.int ?? -1 }) == [1, 2, 7, 3, -1])
        // The slow tools/call finished after EOF and still got written.
        #expect(replies.contains { $0["id"] == .int(7) && $0["result"]?["content"]?[0]?["text"] == "from the app" })
    }

    /// A client that sends a tools/call right behind initialize (without waiting for its reply) still pairs under the
    /// name initialize gave: initialize is answered in order. Several runs, as the order used to depend on scheduling.
    @Test func initializeNamesTheCallThatFollowsIt() async throws {
        for _ in 0..<20 {
            let state = StateFolder()
            let mac = FakeMac()
            await mac.set(running: true, sharing: true)
            let input = Pipe(), output = Pipe()
            let lines = [request(1, "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code", "version": "1"]]),
                         listCall]
            input.fileHandleForWriting.write(lines.reduce(Data()) { $0 + $1 + Data([0x0A]) })
            try? input.fileHandleForWriting.close()
            await StdioBridge.run(makeBridge(mac, state: state), input: input.fileHandleForReading, output: output.fileHandleForWriting)
            try? output.fileHandleForWriting.close()
            let replies = Self.replies(output.fileHandleForReading.readDataToEndOfFile())
            #expect(replies.first?["id"] == .int(1), "initialize is answered first")
            #expect(await mac.pairRequests.map(\.clientName) == ["Claude Code"])
            #expect(state.store.load(name: "Claude") == nil && state.store.load(name: "Claude Code") != nil)
        }
    }

    @Test func runDoesNotWaitOutALaunchAfterEOF() async {
        // A launch whose app never appears would take the whole (here 30 s) wait; at EOF run gives it 5 s.
        let mac = FakeMac()
        await mac.set(appearsAfterLaunch: false, sharesAfterLaunch: nil)
        let bridge = StdioBridge(transport: FakeTransport(mac: mac), launcher: FakeLauncher(mac: mac), identities: state.store,
                                 ports: [41_000], serverVersion: "9.9", launchWait: .seconds(30), switchOffGrace: .seconds(30),
                                 poll: .milliseconds(10))
        let input = Pipe(), output = Pipe()
        input.fileHandleForWriting.write(listCall + Data([0x0A]))
        try? input.fileHandleForWriting.close()
        let started = ContinuousClock.now
        await StdioBridge.run(bridge, input: input.fileHandleForReading, output: output.fileHandleForWriting)
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(5) && elapsed < .seconds(7))
        #expect(await mac.launches == 1)
    }

    @Test func runWorksOverSocketpair() async throws {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let ours = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let theirs = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        ours.write(request(1, "initialize") + Data([0x0A]) + request(2, "tools/list") + Data("\r\n".utf8))
        shutdown(fds[0], SHUT_WR)

        let mac = FakeMac()
        await StdioBridge.run(bridge(mac), input: theirs, output: theirs)
        shutdown(fds[1], SHUT_WR)
        let replies = Self.replies(ours.readDataToEndOfFile())
        #expect(replies.map { $0["id"] } == [.int(1), .int(2)] || replies.map { $0["id"] } == [.int(2), .int(1)])
        #expect(await mac.attempts.isEmpty)
    }

    @Test func writeFailureCallsOnOutputClosed() async throws {
        // Output is a socket whose peer has gone (SO_NOSIGPIPE, so the test process gets EPIPE, not SIGPIPE).
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        var one: Int32 = 1
        setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        close(fds[0])
        let output = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        let input = Pipe()
        input.fileHandleForWriting.write(request(1, "ping") + Data([0x0A]))
        try? input.fileHandleForWriting.close()
        let closed = Flag()
        await StdioBridge.run(bridge(FakeMac()), input: input.fileHandleForReading, output: output,
                              onOutputClosed: { closed.set() })
        #expect(closed.value)
    }
}

final class Flag: Sendable {
    private let state = Mutex(false)
    func set() { state.withLock { $0 = true } }
    var value: Bool { state.withLock { $0 } }
}
