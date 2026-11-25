import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import TranscribeMCP

/// Everything but the Mac app and SwiftData: the stdio bridge with its identity store, the signed URLSession
/// transport, real loopback servers on free ports, the endpoint with its pairing registry, and the MCP server over a
/// fake library.
@Suite("MCP: bridge end to end", .serialized)
final class BridgeEndToEndTests {
    final class PortBox: Sendable {
        let value = Mutex<UInt16>(0)
        func get() -> UInt16 { value.withLock { $0 } }
        func set(_ p: UInt16) { value.withLock { $0 = p } }
    }

    /// Every raw request a server received, as text (head and body).
    final class Recorder: Sendable {
        let requests = Mutex<[String]>([])
        func add(_ r: HTTPRequest) {
            let head = r.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            requests.withLock { $0.append("\(r.method) \(r.path)\n\(head)\n\n" + String(decoding: r.body, as: UTF8.self)) }
        }
        var all: [String] { requests.withLock { $0 } }
    }

    /// The app side: a real endpoint on a free port.
    struct App {
        let server: LoopbackHTTPServer
        let port: UInt16
        let registry: PairingRegistry
    }

    static let library: FakeLibrary = {
        let t = Fixture.transcript([Fixture.turn(0, "S1", 0.5, 4.0, "Hello there"), Fixture.turn(1, "S2", 4.2, 8, "Hi Liam")])
        return FakeLibrary(page: MCPRecordingPage(items: [t.summary], total: 1), transcripts: [Fixture.id: t])
    }()

    let state = StateFolder()
    var apps: [App] = []

    deinit { apps.forEach { $0.server.stop() } }

    func startApp(autoAllow: Bool = false) async throws -> App {
        let box = PortBox()
        let registry = try #require(PairingRegistry(privateKey: PairingCrypto.newPrivateKey(), allowed: []))
        registry.setAutoAllow(autoAllow)
        let endpoint = MCPEndpoint(port: { box.get() }, state: EndpointState(serving: true), pairing: registry,
                                   replay: ReplayGuard(),
                                   server: MCPServer(version: "2.0", library: Self.library, timeZone: { Fixture.sydney }))
        let server = LoopbackHTTPServer(port: 0) { await endpoint.handle($0) }
        let port = try await server.start()
        box.set(port)
        let app = App(server: server, port: port, registry: registry)
        apps.append(app)
        return app
    }

    /// A port nothing listens on.
    static func freePort() async throws -> UInt16 {
        let probe = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 200) }
        let port = try await probe.start()
        probe.stop()
        try await Task.sleep(for: .milliseconds(100))
        return port
    }

    func bridge(ports: [UInt16], canLaunch: Bool = false) -> StdioBridge {
        let mac = FakeMac()
        return StdioBridge(transport: URLSessionAppTransport(timeout: 5), launcher: FakeLauncher(mac: mac, canLaunch: canLaunch),
                           identities: state.store, ports: ports, serverVersion: "2.0", launchWait: .milliseconds(200),
                           switchOffGrace: .milliseconds(100), poll: .milliseconds(10))
    }

    static let getTranscript = request(4, "tools/call", ["name": "get_transcript",
                                                         "arguments": ["recording_id": .string(Fixture.id.uuidString)]])

    /// Runs the helper over pipes with these lines; the replies by id.
    func run(_ bridge: StdioBridge, _ lines: [Data]) async -> [Int64: JSONValue] {
        let input = Pipe(), output = Pipe()
        input.fileHandleForWriting.write(lines.reduce(Data()) { $0 + $1 + Data([0x0A]) })
        try? input.fileHandleForWriting.close()
        await StdioBridge.run(bridge, input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try? output.fileHandleForWriting.close()
        return Dictionary(uniqueKeysWithValues: StdioBridgeTests.replies(output.fileHandleForReading.readDataToEndOfFile())
            .compactMap { r in r["id"]?.int.map { ($0, r) } })
    }

    @Test func pairThenReadOverLoopback() async throws {
        let app = try await startApp()
        let initialize = request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:],
                                                   "clientInfo": ["name": "claude-code", "version": "1"]])
        let first = await run(bridge(ports: [app.port]), [
            initialize, Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), request(2, "tools/list"), listCall,
        ])
        #expect(first.count == 3)
        #expect(first[1]?["result"]?["protocolVersion"] == "2025-11-25")
        #expect(first[2]?["result"]?["tools"]?[1] != nil)
        // Not allowed yet: the permission message, with the code the app shows for this request.
        let pending = try #require(app.registry.pendingRequests(now: Date()).first)
        #expect(pending.name == "Claude Code")
        #expect(first[7]?["result"]?["content"]?[0]?["text"] == .string(BridgeMessages.permissionNeeded(code: pending.code)))
        #expect(first[7]?["result"]?["isError"] == true)
        #expect(state.store.load(name: "Claude Code")?.code == pending.code)

        // The user clicks Allow; a new helper process (Claude's next session) reads.
        #expect(app.registry.allow(clientID: pending.id, now: Date()))
        let second = await run(bridge(ports: [app.port]), [initialize, listCall, Self.getTranscript])
        let list = second[7]?["result"]?["content"]?[0]?["text"]?.string ?? ""
        #expect(list.contains("Team sync") && list.contains(Fixture.id.uuidString) && second[7]?["result"]?["isError"] == nil)
        let transcript = second[4]?["result"]?["content"]?[0]?["text"]?.string ?? ""
        #expect(transcript.contains("[0:00–0:04] Liam: Hello there"))
        #expect(transcript.contains("Karan (auto): Hi Liam"))
        #expect(transcript.contains("End of transcript."))
    }

    @Test func pendingAndDeniedNeverGetData() async throws {
        let app = try await startApp()
        let bridge = bridge(ports: [app.port])
        _ = await bridge.handle(line: listCall)
        let pending = try #require(app.registry.pendingRequests(now: Date()).first)
        let waiting = await bridge.handle(line: listCall)
        #expect(waiting.toolText?.text == BridgeMessages.stillWaiting(code: pending.code))
        #expect(app.registry.deny(clientID: pending.id, now: Date()))
        let denied = await bridge.handle(line: listCall)
        #expect(denied.toolText?.text == BridgeMessages.denied && denied.toolText?.isError == true)
        for reply in [waiting, denied] { #expect(!(reply?.json.encodedString.contains("Team sync") ?? true)) }
        // Asking again while denied shows the user nothing new.
        _ = await bridge.handle(line: listCall)
        #expect(app.registry.pendingRequests(now: Date()).isEmpty)
    }

    @Test func removedClientIsAskedAgain() async throws {
        let app = try await startApp(autoAllow: true)
        let bridge = bridge(ports: [app.port])
        #expect(await bridge.handle(line: listCall).toolText?.text.contains("Team sync") == true)
        let old = try #require(app.registry.allowedClients.first)
        app.registry.setAutoAllow(false)
        #expect(app.registry.remove(clientID: old.id))
        let reply = await bridge.handle(line: listCall)
        let pending = try #require(app.registry.pendingRequests(now: Date()).first)
        #expect(pending.id != old.id)
        #expect(reply.toolText?.text == BridgeMessages.askingAgain(code: pending.code))
    }

    /// Another Transcribe with another key (the app lost its key, or something posing as it) answers on the only port
    /// left: the helper's MAC does not verify there and it says "unknown", unsigned. The helper keeps its pairing, asks
    /// nothing of the other app, and tells the user what to do; once the paired app answers again, it reads.
    @Test func unsignedUnknownFromAnotherAppKeepsThePairing() async throws {
        let first = try await startApp(autoAllow: true)
        let second = try await startApp()
        let bridge = bridge(ports: [first.port, second.port])
        #expect(await bridge.handle(line: listCall).toolText?.text.contains("Team sync") == true)
        let old = try #require(state.store.load(name: "Claude"))
        #expect(old.appPublicKey == first.registry.appPublicKey && old.verified)
        first.server.stop()
        let reply = await bridge.handle(line: listCall)
        #expect(reply.toolText?.text == BridgeMessages.notRecognised && reply.toolText?.isError == true)
        #expect(second.registry.pendingRequests(now: Date()).isEmpty)
        #expect(state.store.load(name: "Claude") == old)
    }

    /// Another Transcribe (another macOS user's, say) holds the first port and takes the helper's first pairing request,
    /// so the user's own Transcribe on the next port sees nothing. While that app answers signed, nothing changes. Once
    /// it goes away, the pairing (never verified with a 200) is known to nothing that answers, so the helper asks again
    /// and the user's own Transcribe shows the request.
    @Test func unconfirmedPairingWithAnEarlierPortsAppMovesToTheUsersApp() async throws {
        let other = try await startApp()
        let mine = try await startApp()
        let ports = [other.port, mine.port]
        _ = await bridge(ports: ports).handle(line: listCall)
        let captured = try #require(state.store.load(name: "Claude"))
        #expect(captured.appPublicKey == other.registry.appPublicKey && !captured.verified)
        #expect(other.registry.pendingRequests(now: Date()).count == 1 && mine.registry.pendingRequests(now: Date()).isEmpty)
        let waiting = await bridge(ports: ports).handle(line: listCall)
        #expect(waiting.toolText?.text == BridgeMessages.stillWaiting(code: try #require(captured.code)))
        #expect(state.store.load(name: "Claude") == captured)

        other.server.stop()
        let reply = await bridge(ports: ports).handle(line: listCall)
        let request = try #require(mine.registry.pendingRequests(now: Date()).first)
        #expect(reply.toolText?.text == BridgeMessages.permissionNeeded(code: request.code))
        let moved = try #require(state.store.load(name: "Claude"))
        #expect(moved.appPublicKey == mine.registry.appPublicKey && moved.clientID == request.id && moved.code == request.code)
        // Allowed there, it reads, and is now confirmed.
        #expect(mine.registry.allow(clientID: request.id, now: Date()))
        #expect(await bridge(ports: ports).handle(line: listCall).toolText?.text.contains("Team sync") == true)
        #expect(state.store.load(name: "Claude")?.verified == true)
    }

    /// Something else holds the first port and answers like an MCP server, unsigned. It learns only public values
    /// (client id and public key, the signed request), cannot relay that request to the app, and the helper reaches
    /// the real app on the next port: before pairing (the squatter does not pair) and after.
    @Test func squatterOnFirstPortNeverObtainsAnythingUsable() async throws {
        let recorder = Recorder()
        let squatter = LoopbackHTTPServer(port: 0) { r in
            recorder.add(r)
            let id = r.body.json["id"] ?? .null
            let body = JSONValue.object(["jsonrpc": "2.0", "id": id,
                                         "result": ["content": [["type": "text", "text": "injected"]]]]).encoded()
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: body)
        }
        let squatted = try await squatter.start()
        defer { squatter.stop() }
        let app = try await startApp()
        let bridge = bridge(ports: [squatted, app.port])

        // Unpaired: the pairing request goes past the squatter to the app.
        let asked = await bridge.handle(line: listCall)
        let pending = try #require(app.registry.pendingRequests(now: Date()).first)
        #expect(asked.toolText?.text == BridgeMessages.permissionNeeded(code: pending.code))
        #expect(state.store.load(name: "Claude")?.appPublicKey == app.registry.appPublicKey)
        app.registry.allow(clientID: pending.id, now: Date())

        // Paired: a fresh helper process tries the squatter first, rejects its unsigned reply, and reads from the app.
        let reply = await self.bridge(ports: [squatted, app.port]).handle(line: listCall)
        #expect(reply.toolText?.text.contains("Team sync") == true && reply.toolText?.isError == false)
        #expect(!(reply?.json.encodedString.contains("injected") ?? true))

        // What the squatter saw holds no secret: neither private key, nor the derived key.
        let identity = try #require(state.store.load(name: "Claude"))
        let derived = try #require(identity.credentials?.key.withUnsafeBytes { Base64URL.encode(Data($0)) })
        let seen = recorder.all
        #expect(seen.count >= 2)
        #expect(seen.contains { $0.hasPrefix("POST /pair") } && seen.contains { $0.hasPrefix("POST /mcp") })
        for secret in [identity.privateKey, derived] {
            #expect(seen.allSatisfy { !$0.contains(secret) })
        }
        #expect(seen.allSatisfy { !$0.lowercased().contains("origin:") })

        // The signed request it caught was signed for its own port, so relaying it to the app fails.
        let caught = try #require(seen.first { $0.hasPrefix("POST /mcp") })
        let authorization = try #require(caught.split(separator: "\n").first { $0.hasPrefix("authorization: ") })
            .dropFirst("authorization: ".count)
        let relayed = await MCPEndpoint(port: { app.port }, state: EndpointState(serving: true), pairing: app.registry,
                                        replay: ReplayGuard(), server: MCPServer(version: "2.0", library: Self.library))
            .handle(HTTPRequest(method: "POST", path: "/mcp",
                                headers: ["host": "127.0.0.1:\(app.port)", "content-type": "application/json",
                                          "authorization": String(authorization)], body: listCall))
        #expect(relayed.status == 401)
    }

    @Test func forgedResponseRejected() async throws {
        let app = try await startApp(autoAllow: true)
        let bridge = bridge(ports: [app.port])
        _ = await bridge.handle(line: listCall)
        let creds = try #require(state.store.load(name: "Claude")?.credentials)
        // A genuine signed reply, captured from the real endpoint for an earlier request.
        let endpoint = MCPEndpoint(port: { 1 }, state: EndpointState(serving: true), pairing: app.registry, replay: ReplayGuard(),
                                   server: MCPServer(version: "2.0", library: Self.library))
        let nonce = MessageAuth.newNonce()
        let captured = await endpoint.handle(HTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["host": "127.0.0.1:1", "content-type": "application/json",
                      "authorization": MessageAuth.signRequest(body: listCall, credentials: creds, port: 1, now: Date(), nonce: nonce)],
            body: listCall))
        #expect(captured.status == 200)

        // Replayed to a later request (another nonce), and signed with a wrong key: both are rejected.
        for forged in [captured.header(MessageAuth.responseHeader) ?? "",
                       MessageAuth.signResponse(status: 200, body: captured.body, nonce: nonce, key: SymmetricKey(size: .bits256))] {
            let squatter = LoopbackHTTPServer(port: 0) { _ in
                HTTPResponse(status: 200, headers: [("Content-Type", "application/json"), (MessageAuth.responseHeader, forged)],
                             body: captured.body)
            }
            let port = try await squatter.start()
            #expect(await URLSessionAppTransport().post(listCall, protocolVersion: "2025-11-25", port: port, credentials: creds) == .impostor)
            squatter.stop()
        }

        // An oversize reply is not Transcribe's either.
        let big = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 200, body: Data(count: 3_000_000)) }
        let port = try await big.start()
        defer { big.stop() }
        #expect(await URLSessionAppTransport().post(listCall, protocolVersion: "2025-11-25", port: port, credentials: creds) == .impostor)
    }

    @Test func transportMapsStatusesAndRefusal() async throws {
        let creds = randomCredentials()
        let client = TestClient()
        let pairing = PairingRequest(clientID: client.id, clientName: "Claude", publicKey: client.publicKey,
                                     commitment: client.commitment)
        let reveal = PairingReveal(clientID: client.id, publicKey: client.publicKey, clientNonce: client.nonce)
        let appKey = try #require(PairingCrypto.publicKey(ofPrivate: PairingCrypto.newPrivateKey()))
        let appNonce = PairingCrypto.newNonce()
        for (status, expected, pairExpected) in [(401, AppReply.unauthorized, PairReply.invalid), (503, .notServing, .notServing),
                                                 (500, .httpError(500), .invalid), (404, .httpError(404), .invalid),
                                                 (429, .httpError(429), .busy), (409, .httpError(409), .conflict),
                                                 (400, .httpError(400), .invalid)] {
            let server = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: status) }
            let port = try await server.start()
            #expect(await URLSessionAppTransport().post(listCall, protocolVersion: "2025-11-25", port: port, credentials: creds) == expected)
            #expect(await URLSessionAppTransport().pair(pairing, port: port) == pairExpected, "\(status)")
            #expect(await URLSessionAppTransport().reveal(reveal, port: port) == pairExpected, "\(status)")
            server.stop()
        }
        // The unsigned "unknown" marker on a 401.
        let marked = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 401, headers: [(MessageAuth.pairingHeader, "unknown")]) }
        let markedPort = try await marked.start()
        #expect(await URLSessionAppTransport().post(listCall, protocolVersion: "2025-11-25", port: markedPort, credentials: creds) == .unknownClient)
        marked.stop()
        // Commit answers: well-formed, or not Transcribe's.
        for (body, expected) in [
            (JSONValue.object(["v": 2, "status": "reveal", "app_key": .string(appKey), "app_nonce": .string(appNonce)]),
             PairReply.reveal(appPublicKey: appKey, appNonce: appNonce)),
            (["v": 2, "status": "denied", "app_key": .string(appKey)], .status(.denied)),
            (["v": 2, "status": "pending", "app_key": .string(appKey)], .invalid),
            (["v": 2, "status": "reveal", "app_key": .string(appKey)], .invalid),
            (["v": 2, "status": "reveal", "app_key": "short", "app_nonce": .string(appNonce)], .invalid),
            (["v": 2, "status": "reveal", "app_key": .string(appKey), "app_nonce": "short"], .invalid),
            (["v": 2, "status": "reveal", "app_key": .string(appKey), "app_nonce": .string(appNonce), "extra": 1], .invalid),
            (["v": 1, "status": "pending", "app_key": .string(appKey)], .invalid),
        ] {
            let server = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 200, body: body.encoded()) }
            let port = try await server.start()
            #expect(await URLSessionAppTransport().pair(pairing, port: port) == expected)
            server.stop()
        }
        // Reveal answers.
        for (body, expected) in [
            (JSONValue.object(["v": 2, "status": "pending"]), PairReply.status(.pending)),
            (["v": 2, "status": "allowed"], .status(.allowed)),
            (["v": 2, "status": "denied"], .status(.denied)),
            (["v": 2, "status": "maybe"], .invalid),
            (["v": 2, "status": "pending", "app_key": .string(appKey)], .invalid),
        ] {
            let server = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 200, body: body.encoded()) }
            let port = try await server.start()
            #expect(await URLSessionAppTransport().reveal(reveal, port: port) == expected)
            server.stop()
        }
        // A redirect is never followed: the request goes nowhere else.
        let recorder = Recorder()
        let elsewhere = LoopbackHTTPServer(port: 0) { r in recorder.add(r); return HTTPResponse(status: 200) }
        let target = try await elsewhere.start()
        defer { elsewhere.stop() }
        let redirecting = LoopbackHTTPServer(port: 0) { _ in
            HTTPResponse(status: 307, headers: [("Location", "http://127.0.0.1:\(target)/mcp")])
        }
        let port = try await redirecting.start()
        #expect(await URLSessionAppTransport().post(listCall, protocolVersion: "2025-11-25", port: port, credentials: creds) == .httpError(307))
        #expect(await URLSessionAppTransport().pair(pairing, port: port) == .invalid)
        redirecting.stop()
        #expect(recorder.all.isEmpty)

        // Nothing listening: refused.
        let free = try await Self.freePort()
        #expect(await URLSessionAppTransport().post(listCall, protocolVersion: "2025-11-25", port: free, credentials: creds) == .refused)
        #expect(await URLSessionAppTransport().pair(pairing, port: free) == .refused)
    }

    @Test func refusedWithoutLaunchSaysNotOpen() async throws {
        let free = try await Self.freePort()
        let reply = await bridge(ports: [free], canLaunch: false).handle(line: listCall)
        #expect(reply.toolText?.text == BridgeMessages.notOpen)
    }
}

extension JSONValue {
    var encodedString: String { String(decoding: encoded(), as: UTF8.self) }
}
