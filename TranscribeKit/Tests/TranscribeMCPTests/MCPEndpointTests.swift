import CryptoKit
import Foundation
import Testing
@testable import TranscribeMCP

/// The endpoint's checks in order (§3.1), `/pair` and the per-client signed path, with no sockets and a fixed clock.
@Suite("MCP: endpoint")
struct MCPEndpointTests {
    static let port: UInt16 = 41_234
    static let now = Date(timeIntervalSince1970: 1_794_972_660)
    let state = EndpointState(serving: true)
    let registry = PairingRegistry(privateKey: PairingCrypto.newPrivateKey(), allowed: [])!
    let client = TestClient()
    let endpoint: MCPEndpoint
    /// `client`, paired and allowed.
    let creds: ClientCredentials

    init() {
        endpoint = MCPEndpoint(port: { Self.port }, state: state, pairing: registry, replay: ReplayGuard(),
                               server: MCPServer(version: "1.0", library: FakeLibrary(), timeZone: { Fixture.sydney }),
                               now: { Self.now })
        creds = client.allowed(in: registry, now: Self.now)
    }

    /// Credentials for a client the registry has never seen (any pairing transcript will do).
    func stranger(appPublicKey: String? = nil) -> ClientCredentials {
        TestClient().credentials(appPublicKey: appPublicKey ?? registry.appPublicKey, pairing: randomDigest())
    }

    /// A signed request from `client` (or `from`).
    func signed(_ body: Data = request(1, "ping"), from c: ClientCredentials? = nil, nonce: String = MessageAuth.newNonce(),
                headers extra: [String: String] = [:], method: String = "POST", path: String = "/mcp") -> HTTPRequest {
        var headers = ["host": "127.0.0.1:\(Self.port)", "content-type": "application/json",
                       "authorization": MessageAuth.signRequest(body: body, credentials: c ?? creds, port: Self.port,
                                                                now: Self.now, nonce: nonce)]
        headers.merge(extra) { _, new in new }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    func verified(_ r: HTTPResponse, nonce: String, key: SymmetricKey? = nil) -> Bool {
        MessageAuth.verifyResponse(r.header(MessageAuth.responseHeader), status: r.status, body: r.body, nonce: nonce,
                                   key: key ?? creds.key)
    }

    func pairRequest(_ body: Data, contentType: String = "application/json", headers extra: [String: String] = [:]) -> HTTPRequest {
        var headers = ["host": "127.0.0.1:\(Self.port)", "content-type": contentType]
        headers.merge(extra) { _, new in new }
        return HTTPRequest(method: "POST", path: "/pair", headers: headers, body: body)
    }

    /// The commit step for `c`.
    func pairBody(_ c: TestClient, name: String = "Claude Code") -> Data {
        PairingRequest(clientID: c.id, clientName: name, publicKey: c.publicKey, commitment: c.commitment).body
    }

    /// The reveal step for `c` (or another nonce).
    func revealBody(_ c: TestClient, nonce: String? = nil) -> Data {
        PairingReveal(clientID: c.id, publicKey: c.publicKey, clientNonce: nonce ?? c.nonce).body
    }

    // MARK: - Common checks

    @Test func wrongPath404() async {
        #expect(await endpoint.handle(signed(path: "/")).status == 404)
        #expect(await endpoint.handle(signed(path: "/mcp/")).status == 404)
        #expect(await endpoint.handle(signed(path: "/MCP")).status == 404)
        #expect(await endpoint.handle(signed(path: "/pair/")).status == 404)
    }

    @Test func getIs405WithAllow() async {
        let r = await endpoint.handle(signed(method: "GET"))
        #expect(r.status == 405 && r.header("Allow") == "POST" && r.body.isEmpty)
        #expect(await endpoint.handle(signed(method: "GET", path: "/pair")).status == 405)
    }

    @Test func deleteIs405() async {
        #expect(await endpoint.handle(signed(method: "DELETE")).status == 405)
    }

    @Test func anyOriginIs403() async {
        for origin in ["https://example.com", "http://127.0.0.1:\(Self.port)", "null", ""] {
            #expect(await endpoint.handle(signed(headers: ["origin": origin])).status == 403, "\(origin)")
            #expect(await endpoint.handle(pairRequest(pairBody(TestClient()), headers: ["origin": origin])).status == 403)
        }
    }

    @Test func foreignHostIs403() async {
        for host in ["evil.example", "127.0.0.1:1", "localhost:80", "192.168.0.2:\(Self.port)", "[::1]:\(Self.port)"] {
            #expect(await endpoint.handle(signed(headers: ["host": host])).status == 403, "\(host)")
            #expect(await endpoint.handle(pairRequest(pairBody(TestClient()), headers: ["host": host])).status == 403)
        }
        var r = signed()
        r.headers["host"] = nil
        #expect(await endpoint.handle(r).status == 403)
    }

    @Test func localhostHostAccepted() async {
        for host in ["localhost:\(Self.port)", "LOCALHOST:\(Self.port)", "127.0.0.1", "localhost"] {
            #expect(await endpoint.handle(signed(headers: ["host": host])).status == 200, "\(host)")
        }
    }

    @Test func notServing503() async {
        state.set(serving: false)
        let r = await endpoint.handle(signed())
        #expect(r.status == 503 && r.body.isEmpty && r.header(MessageAuth.responseHeader) == nil)
        // Pairing only while the switch is on.
        let other = TestClient()
        #expect(await endpoint.handle(pairRequest(pairBody(other))).status == 503)
        #expect(registry.pendingRequests(now: Self.now).isEmpty)
    }

    // MARK: - POST /pair

    /// Commit, then reveal: the commit's reply holds only the app's key and its nonce, nothing shows until the reveal,
    /// and the code the user sees is the one the client computes.
    @Test func commitThenRevealShowsTheRequest() async throws {
        let other = TestClient()
        let r = await endpoint.handle(pairRequest(pairBody(other, name: "  Claude\u{202E} Desktop ")))
        #expect(r.status == 200 && r.header(MessageAuth.responseHeader) == nil)
        let json = r.body.json
        let appNonce = try #require(json["app_nonce"]?.string)
        #expect(json == ["v": 2, "status": "reveal", "app_key": .string(registry.appPublicKey), "app_nonce": .string(appNonce)])
        #expect(registry.pendingRequests(now: Self.now).isEmpty)
        // The same commitment again gets the same nonce, and still nothing shows.
        #expect(await endpoint.handle(pairRequest(pairBody(other))).body.json["app_nonce"]?.string == appNonce)
        #expect(registry.pendingRequests(now: Self.now).isEmpty)
        let revealed = await endpoint.handle(pairRequest(revealBody(other)))
        #expect(revealed.status == 200 && revealed.body.json == ["v": 2, "status": "pending"])
        let pending = try #require(registry.pendingRequests(now: Self.now).first)
        #expect(pending.id == other.id && pending.name == "Claude Desktop")
        #expect(pending.code == PairingCrypto.code(pairing: other.pairing(appPublicKey: registry.appPublicKey, appNonce: appNonce)))
        // An allowed client cannot start again under the same id.
        #expect(await endpoint.handle(pairRequest(pairBody(client))).status == 409)
    }

    @Test func wrongRevealIs400AndShowsNothing() async {
        let other = TestClient()
        #expect(await endpoint.handle(pairRequest(pairBody(other))).status == 200)
        #expect(await endpoint.handle(pairRequest(revealBody(other, nonce: PairingCrypto.newNonce()))).status == 400)
        #expect(registry.pendingRequests(now: Self.now).isEmpty)
        // The exchange is gone.
        #expect(await endpoint.handle(pairRequest(revealBody(other))).status == 409)
        // A reveal with no commit before it.
        #expect(await endpoint.handle(pairRequest(revealBody(TestClient()))).status == 409)
        #expect(registry.pendingRequests(now: Self.now).isEmpty)
    }

    @Test func pairValidatesStrictly() async {
        let c = TestClient()
        func body(_ o: [String: JSONValue]) -> Data { JSONValue.object(o).encoded() }
        let good: [String: JSONValue] = ["v": 2, "client_id": .string(c.id), "client_name": "Claude", "client_key": .string(c.publicKey),
                                         "commit": .string(c.commitment)]
        let reveal: [String: JSONValue] = ["v": 2, "client_id": .string(c.id), "client_key": .string(c.publicKey),
                                           "reveal": .string(c.nonce)]
        var bad: [Data] = [Data("{not json".utf8), Data("[]".utf8), body([:])]
        bad.append(body(good.merging(["extra": 1]) { $1 }))
        bad.append(body(good.merging(["v": 1]) { $1 }))
        bad.append(body(good.merging(["client_id": "short"]) { $1 }))
        bad.append(body(good.merging(["client_key": "AAAA"]) { $1 }))
        bad.append(body(good.merging(["client_name": "   "]) { $1 }))
        bad.append(body(good.merging(["client_name": 5]) { $1 }))
        bad.append(body(good.merging(["commit": "short"]) { $1 }))
        bad.append(body(good.filter { $0.key != "client_name" }))
        bad.append(body(good.filter { $0.key != "commit" }))
        // The old one-step request (no commitment).
        bad.append(body(good.filter { $0.key != "commit" }.merging(["v": 1]) { $1 }))
        bad.append(body(reveal.merging(["reveal": "short"]) { $1 }))
        bad.append(body(reveal.merging(["commit": .string(c.commitment)]) { $1 }))
        bad.append(body(reveal.merging(["client_name": "Claude"]) { $1 }))
        for b in bad {
            #expect(await endpoint.handle(pairRequest(b)).status == 400, "\(String(decoding: b, as: UTF8.self))")
        }
        #expect(await endpoint.handle(pairRequest(body(good), contentType: "text/plain")).status == 415)
        let padded = body(good.merging(["client_name": .string(String(repeating: "x", count: 1_000))]) { $1 })
        #expect(await endpoint.handle(pairRequest(padded)).status == 413)
        #expect(registry.pendingRequests(now: Self.now).isEmpty)
        #expect(await endpoint.handle(pairRequest(body(good))).status == 200)
        #expect(await endpoint.handle(pairRequest(body(reveal))).status == 200)
        #expect(registry.pendingRequests(now: Self.now).count == 1)
    }

    @Test func pairBusyIs429AndConflictIs409() async {
        for _ in 0..<3 { _ = await endpoint.handle(pairRequest(pairBody(TestClient()))) }
        // Three unrevealed exchanges fill the cap without showing anything.
        #expect(registry.pendingRequests(now: Self.now).isEmpty)
        #expect(await endpoint.handle(pairRequest(pairBody(TestClient()))).status == 429)
        // The allowed client's id with another key.
        let impostor = PairingRequest(clientID: client.id, clientName: "Claude Code", publicKey: TestClient().publicKey,
                                      commitment: TestClient().commitment)
        #expect(await endpoint.handle(pairRequest(impostor.body)).status == 409)
    }

    // MARK: - POST /mcp

    @Test func missingAuth401HasNoWWWAuthenticate() async {
        var r = signed()
        r.headers["authorization"] = nil
        let response = await endpoint.handle(r)
        #expect(response.status == 401 && response.body.isEmpty)
        #expect(response.header("WWW-Authenticate") == nil && response.header(MessageAuth.responseHeader) == nil)
        r.headers["authorization"] = "Bearer x"
        #expect(await endpoint.handle(r).status == 401)
    }

    @Test func wrongKey401() async {
        // The allowed client's id and public key, but a key that was not derived from them.
        let forged = ClientCredentials(clientID: client.id, publicKey: client.publicKey, pairing: creds.pairing,
                                       key: SymmetricKey(size: .bits256))
        let r = await endpoint.handle(signed(from: forged))
        #expect(r.status == 401 && r.header(MessageAuth.pairingHeader) == nil && r.header(MessageAuth.responseHeader) == nil)
    }

    /// A client the app has no record of whose MAC does not verify (a helper paired with a key this app no longer has):
    /// an unsigned 401 marked "unknown".
    @Test func unknownClientWithBadMACIsMarkedUnknown() async throws {
        let elsewhere = try #require(PairingCrypto.publicKey(ofPrivate: PairingCrypto.newPrivateKey()))
        let r = await endpoint.handle(signed(from: stranger(appPublicKey: elsewhere)))
        #expect(r.status == 401 && r.header(MessageAuth.pairingHeader) == "unknown" && r.body.isEmpty)
        #expect(r.header(MessageAuth.responseHeader) == nil)
    }

    @Test func pendingDeniedAndUnknownGetSigned403WithoutData() async throws {
        let waiting = TestClient()
        let (_, waitingPairing) = try #require(waiting.pair(registry, now: Self.now))
        let denied = TestClient()
        let (_, deniedPairing) = try #require(denied.pair(registry, now: Self.now))
        registry.deny(clientID: denied.id, now: Self.now)
        // Committed but not revealed: unknown, never pending.
        let unrevealed = TestClient()
        guard case .reveal(let unrevealedNonce) = registry.commit(clientID: unrevealed.id, name: "U", publicKey: unrevealed.publicKey,
                                                                  commitment: unrevealed.commitment, now: Self.now) else {
            Issue.record("commit refused"); return
        }
        let list = request(3, "tools/call", ["name": "list_recordings", "arguments": [:]])
        let cases: [(ClientCredentials, String)] = [
            (waiting.credentials(appPublicKey: registry.appPublicKey, pairing: waitingPairing), "pending"),
            (denied.credentials(appPublicKey: registry.appPublicKey, pairing: deniedPairing), "denied"),
            (stranger(), "unknown"),
            (unrevealed.credentials(appPublicKey: registry.appPublicKey,
                                    pairing: unrevealed.pairing(appPublicKey: registry.appPublicKey, appNonce: unrevealedNonce)), "unknown"),
            // The allowed client naming another pairing transcript.
            (client.credentials(appPublicKey: registry.appPublicKey, pairing: randomDigest()), "unknown"),
        ]
        for (creds, state) in cases {
            let nonce = MessageAuth.newNonce()
            let r = await endpoint.handle(signed(list, from: creds, nonce: nonce))
            #expect(r.status == 403 && verified(r, nonce: nonce, key: creds.key), "\(state)")
            #expect(r.body.json == ["pairing": .string(state)], "\(state)")
            #expect(!String(decoding: r.body, as: UTF8.self).contains("recordings"))
        }
    }

    @Test func allowedClientGetsData() async {
        let nonce = MessageAuth.newNonce()
        let r = await endpoint.handle(signed(request(3, "tools/list"), nonce: nonce))
        #expect(r.status == 200 && r.header("Content-Type") == "application/json")
        #expect(verified(r, nonce: nonce))
        #expect(!verified(r, nonce: MessageAuth.newNonce()))
        #expect(r.body.json["id"] == .int(3) && !r.body.contains(0x0A))
        let text = String(decoding: r.serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: \(r.body.count)\r\n") && text.contains("Cache-Control: no-store\r\n"))
        #expect(text.contains("Connection: close\r\n") && !text.lowercased().contains("access-control"))
    }

    @Test func removalTakesEffectImmediately() async {
        #expect(await endpoint.handle(signed()).status == 200)
        registry.remove(clientID: client.id)
        let nonce = MessageAuth.newNonce()
        let r = await endpoint.handle(signed(nonce: nonce))
        #expect(r.status == 403 && r.body.json["pairing"] == "unknown" && verified(r, nonce: nonce))
    }

    @Test func replayedRequest401() async {
        let r = signed()
        #expect(await endpoint.handle(r).status == 200)
        #expect(await endpoint.handle(r).status == 401)
    }

    @Test func wrongContentType415() async {
        let nonce = MessageAuth.newNonce()
        let r = await endpoint.handle(signed(nonce: nonce, headers: ["content-type": "text/plain"]))
        #expect(r.status == 415 && verified(r, nonce: nonce))
        #expect(await endpoint.handle(signed(headers: ["content-type": "application/json; charset=utf-8"])).status == 200)
        var missing = signed()
        missing.headers["content-type"] = nil
        #expect(await endpoint.handle(missing).status == 415)
    }

    @Test func unsupportedProtocolHeader400HasEmptyBody() async {
        let nonce = MessageAuth.newNonce()
        let r = await endpoint.handle(signed(nonce: nonce, headers: ["mcp-protocol-version": "2025-03-26"]))
        #expect(r.status == 400 && r.body.isEmpty && verified(r, nonce: nonce))
        #expect(await endpoint.handle(signed(headers: ["mcp-protocol-version": "2025-06-18"])).status == 200)
        #expect(await endpoint.handle(signed(headers: ["mcp-protocol-version": "2025-11-25"])).status == 200)
    }

    @Test func missingProtocolHeaderAccepted() async {
        #expect(await endpoint.handle(signed()).status == 200)
    }

    @Test func invalidBodies400Signed() async {
        let nonce = MessageAuth.newNonce()
        let parse = await endpoint.handle(signed(Data("{not json".utf8), nonce: nonce))
        #expect(parse.status == 400 && verified(parse, nonce: nonce))
        #expect(parse.body.json["error"]?["code"] == -32700 && parse.body.json["id"] == .null)
        let batch = await endpoint.handle(signed(Data("[\(String(decoding: request(1, "ping"), as: UTF8.self))]".utf8)))
        #expect(batch.status == 400 && batch.body.json["error"]?["code"] == -32600)
    }

    @Test func notification202SignedEmpty() async {
        let nonce = MessageAuth.newNonce()
        let r = await endpoint.handle(signed(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), nonce: nonce))
        #expect(r.status == 202 && r.body.isEmpty && verified(r, nonce: nonce))
        let response = await endpoint.handle(signed(Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8)))
        #expect(response.status == 202)
    }

    @Test func requestSignedBeforeServingIs401() async {
        // A squatter held the port at T and caught a signed request; the app began serving at T+5 and the squatter
        // relays the request at T+6. It is inside ±60 s and its nonce is new, but it predates this listener.
        let signedAt = Self.now
        let state = EndpointState(serving: false)
        state.set(serving: true, at: signedAt.addingTimeInterval(5))
        let endpoint = MCPEndpoint(port: { Self.port }, state: state, pairing: registry, replay: ReplayGuard(),
                                   server: MCPServer(version: "1.0", library: nil), now: { signedAt.addingTimeInterval(6) })
        let creds = creds
        func signed(at t: Date) -> HTTPRequest {
            let body = request(1, "ping")
            return HTTPRequest(method: "POST", path: "/mcp", headers: [
                "host": "127.0.0.1:\(Self.port)", "content-type": "application/json",
                "authorization": MessageAuth.signRequest(body: body, credentials: creds, port: Self.port, now: t,
                                                         nonce: MessageAuth.newNonce())], body: body)
        }
        let relayed = await endpoint.handle(signed(at: signedAt))
        #expect(relayed.status == 401 && relayed.header(MessageAuth.responseHeader) == nil)
        // Signed once the app serves (and up to 1 s before, for a second boundary): accepted.
        #expect(await endpoint.handle(signed(at: signedAt.addingTimeInterval(5))).status == 200)
        #expect(await endpoint.handle(signed(at: signedAt.addingTimeInterval(4))).status == 200)
        #expect(await endpoint.handle(signed(at: signedAt.addingTimeInterval(3))).status == 401)
        // Serving again (the switch off and on) moves the floor.
        state.set(serving: false)
        #expect(state.servingSince == nil)
        state.set(serving: true, at: signedAt.addingTimeInterval(6))
        #expect(await endpoint.handle(signed(at: signedAt.addingTimeInterval(4))).status == 401)
    }

    @Test func replayGuardFullIs503() async {
        let endpoint = MCPEndpoint(port: { Self.port }, state: state, pairing: registry, replay: ReplayGuard(window: 120, capacity: 1),
                                   server: MCPServer(version: "1.0", library: nil), now: { Self.now })
        #expect(await endpoint.handle(signed()).status == 200)
        #expect(await endpoint.handle(signed()).status == 503)
    }

    /// Anyone who has the app's public key can sign as a client of their own making. Such calls get a signed 403 and
    /// never use up the replay guard, so they cannot lock out an allowed client.
    @Test func strangersCannotFillTheReplayGuard() async {
        let endpoint = MCPEndpoint(port: { Self.port }, state: state, pairing: registry, replay: ReplayGuard(window: 120, capacity: 2),
                                   server: MCPServer(version: "1.0", library: nil), now: { Self.now })
        for _ in 0..<5 {
            let other = stranger()
            let r = await endpoint.handle(signed(from: other))
            #expect(r.status == 403 && r.body.json["pairing"] == "unknown")
        }
        let r = signed()
        #expect(await endpoint.handle(r).status == 200)
        #expect(await endpoint.handle(r).status == 401)
    }
}
