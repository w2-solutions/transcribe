import CryptoKit
import Darwin
import Foundation
import SwiftData
import Testing
@testable import TranscribeKit
@testable import TranscribeMCP
@testable import TranscribeMCPHost

/// The switch, the app's pairing key pair, Allow / Don't Allow / Remove and the server behind Settings → Claude, over
/// real loopback sockets. Each test has its own temp root and its own ports (port 0, or ports it found free); nothing
/// touches the real library or the well-known ports.
@Suite("MCP: Claude access", .serialized)
@MainActor
final class ClaudeAccessTests {
    static let helper = "/Applications/Transcribe.app/Contents/Helpers/transcribe-mcp"
    static let call = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_recordings","arguments":{}}}"#.utf8)

    let container: ModelContainer
    let root: URL
    var accesses: [ClaudeAccess] = []

    init() throws {
        container = try ModelContainerFactory.make(inMemory: true, url: nil)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-access-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func make(_ options: ClaudeAccessOptions = ClaudeAccessOptions(ephemeralPort: true), ports: [UInt16] = [],
              otherCopy: Bool = false) -> ClaudeAccess {
        let a = ClaudeAccess(container: container, root: root, serverVersion: "9.9", options: options,
                             ports: ports.isEmpty ? [1] : ports, otherCopyRunning: { otherCopy })
        accesses.append(a)
        return a
    }

    func cleanUp() async {
        for a in accesses where a.isEnabled { await a.setEnabled(false) }
    }

    var fileURL: URL { ClaudeAccessFile.url(root: root) }
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    static func port(_ a: ClaudeAccess) -> UInt16? {
        if case .ready(let p) = a.status { return p }
        return nil
    }

    /// What a client signs with once the app took its commitment.
    struct Paired { let appKey: String; let pairing: String }

    /// A pairing request to the app, commit then reveal, as the helper sends it: the reveal's reply (or the commit's,
    /// when the app did not take it), and the pairing.
    func pair(_ client: TestClient, port: UInt16, name: String = "Claude Code") async -> (reply: PairReply, paired: Paired?) {
        let transport = URLSessionAppTransport(timeout: 5)
        let commit = await transport.pair(PairingRequest(clientID: client.id, clientName: name, publicKey: client.publicKey,
                                                         commitment: client.commitment), port: port)
        guard case .reveal(let appKey, let appNonce) = commit else { return (commit, nil) }
        let reply = await transport.reveal(PairingReveal(clientID: client.id, publicKey: client.publicKey, clientNonce: client.nonce),
                                           port: port)
        return (reply, Paired(appKey: appKey, pairing: client.pairing(appPublicKey: appKey, appNonce: appNonce)))
    }

    func post(_ client: TestClient, _ paired: Paired, port: UInt16) async -> AppReply {
        await URLSessionAppTransport(timeout: 5).post(Self.call, protocolVersion: "2025-11-25", port: port,
                                                      credentials: client.credentials(appPublicKey: paired.appKey, pairing: paired.pairing))
    }

    /// Pairs a client and waits for the request to show in Settings.
    func request(_ client: TestClient, on a: ClaudeAccess) async throws -> (PendingRequest, Paired) {
        let port = try #require(Self.port(a))
        let (reply, paired) = await pair(client, port: port)
        guard reply == .status(.pending), let paired else { Issue.record("not pending: \(reply)"); throw CancellationError() }
        let request = try await waitFor { a.pendingRequests.first { $0.id == client.id } }
        return (request, paired)
    }

    /// Polls the main actor (registry changes arrive there in a Task).
    func waitFor<T>(_ value: () -> T?) async throws -> T {
        for _ in 0..<200 {
            if let v = value() { return v }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
        throw CancellationError()
    }

    static func text(_ reply: AppReply) -> String? {
        guard case .message(let data) = reply,
              case .array(let content)? = (try? JSONValue.decode(data))?["result"]?["content"] else { return nil }
        return content.first?["text"]?.string
    }

    /// Ports nothing listens on.
    static func freePorts(_ n: Int) async throws -> [UInt16] {
        var servers: [LoopbackHTTPServer] = []
        var ports: [UInt16] = []
        for _ in 0..<n {
            let s = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 500) }
            ports.append(try await s.start())
            servers.append(s)
        }
        servers.forEach { $0.stop() }
        try await Task.sleep(for: .milliseconds(100))
        return ports
    }

    @Test func offByDefault() async {
        let a = make()
        await a.start()
        #expect(!a.isEnabled && !a.wasSetUp && a.status == .off)
        #expect(a.setup(helperPath: Self.helper) == nil && a.allowedApps.isEmpty && a.pendingRequests.isEmpty)
        #expect(!fileExists)
    }

    @Test func firstEnableWritesFile0600() async throws {
        let a = make()
        await a.start()
        await a.setEnabled(true)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let file = try #require(ClaudeAccessFile.load(root: root))
        #expect(file.enabled && file.version == 3 && file.allowed.isEmpty)
        #expect(PairingCrypto.publicKey(ofPrivate: file.appKey) != nil)
        #expect(Self.port(a).map { $0 != 0 } == true && a.wasSetUp)
        // No temporary file is left behind, and nothing about a key or port for Claude's config.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [ClaudeAccessFile.name])
        let json = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!json.contains("\"port\"") && !json.contains("\"key\""))
        await cleanUp()
    }

    @Test func oldVersionFileIsFresh() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":1,"enabled":true,"key":"Ab3_-Ab3_-Ab3_-Ab3_-Ab3_-Ab3_-Ab3_-Ab3_-xyz","port":41234,"setupGeneration":2}"#.utf8)
            .write(to: fileURL)
        let a = make()
        #expect(!a.isEnabled && !a.wasSetUp)
        await a.start()
        #expect(a.status == .off)
        await a.setEnabled(true)
        #expect(ClaudeAccessFile.load(root: root)?.version == 3)
        await cleanUp()
    }

    /// A file from before commit and reveal (version 2, allowed apps without a pairing) reads as none.
    @Test func version2FileIsFresh() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let c = TestClient()
        let v2 = #"{"version":2,"enabled":true,"app_key":"\#(PairingCrypto.newPrivateKey())","allowed":[{"id":"\#(c.id)","name":"Claude Code","public_key":"\#(c.publicKey)","allowed_at":"2026-11-25T00:00:00Z"}]}"#
        try Data(v2.utf8).write(to: fileURL)
        let a = make()
        #expect(!a.isEnabled && !a.wasSetUp && a.allowedApps.isEmpty)
    }

    /// One bad allowed app (or a repeated id) is left out; the key, the switch and the other apps survive.
    @Test func oneBadAllowedAppDoesNotLoseTheFile() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let good = TestClient()
        let pairing = good.pairing(appPublicKey: "x", appNonce: PairingCrypto.newNonce())
        let file = ClaudeAccessFile(enabled: true, appKey: PairingCrypto.newPrivateKey(), allowed: [
            AllowedClient(id: good.id, name: "Claude Code", publicKey: good.publicKey, pairing: pairing, allowedAt: Date()),
            AllowedClient(id: good.id, name: "Again", publicKey: good.publicKey, pairing: pairing, allowedAt: Date()),
            AllowedClient(id: "bad", name: "Bad", publicKey: good.publicKey, pairing: pairing, allowedAt: Date()),
            AllowedClient(id: TestClient().id, name: "Bad", publicKey: good.publicKey, pairing: "short", allowedAt: Date()),
        ])
        try file.save(root: root)
        let loaded = try #require(ClaudeAccessFile.load(root: root))
        #expect(loaded.enabled && loaded.appKey == file.appKey && loaded.allowed.map(\.name) == ["Claude Code"])
        let a = make()
        #expect(a.isEnabled && a.allowedApps.map(\.id) == [good.id])
    }

    /// A commitment alone shows nothing in Settings and asks for no attention; only the reveal does.
    @Test func unrevealedNeverShows() async throws {
        let a = make()
        await a.setEnabled(true)
        let port = try #require(Self.port(a))
        var attention = 0
        a.onNewRequest = { attention += 1 }
        let client = TestClient()
        let commit = await URLSessionAppTransport(timeout: 5).pair(
            PairingRequest(clientID: client.id, clientName: "Claude Code", publicKey: client.publicKey, commitment: client.commitment),
            port: port)
        guard case .reveal = commit else { Issue.record("commit not taken: \(commit)"); return }
        try await Task.sleep(for: .milliseconds(100))
        #expect(a.pendingRequests.isEmpty && attention == 0)
        // A wrong nonce: still nothing.
        let wrong = await URLSessionAppTransport(timeout: 5).reveal(
            PairingReveal(clientID: client.id, publicKey: client.publicKey, clientNonce: PairingCrypto.newNonce()), port: port)
        #expect(wrong == .invalid)
        try await Task.sleep(for: .milliseconds(100))
        #expect(a.pendingRequests.isEmpty && attention == 0)
        await cleanUp()
    }

    @Test func pairAllowThenRead() async throws {
        let a = make()
        await a.setEnabled(true)
        let port = try #require(Self.port(a))
        let client = TestClient()
        var attention = 0
        a.onNewRequest = { attention += 1 }
        let (request, paired) = try await request(client, on: a)
        #expect(request.name == "Claude Code" && request.code == PairingCrypto.code(pairing: paired.pairing))
        #expect(attention == 1)
        // Until allowed, no data.
        #expect(await post(client, paired, port: port) == .pairing(.pending))
        // Asking again joins the same request, without asking for attention again.
        #expect(await pair(client, port: port).reply == .status(.pending))
        try await Task.sleep(for: .milliseconds(50))
        #expect(a.pendingRequests.count == 1 && attention == 1)

        #expect(a.allow(request))
        #expect(a.pendingRequests.isEmpty && a.allowedApps.map(\.id) == [client.id])
        #expect(Self.text(await post(client, paired, port: port))?.contains("recordings") == true)
        // Saved at once.
        #expect(ClaudeAccessFile.load(root: root)?.allowed.map(\.id) == [client.id])
        await cleanUp()
    }

    @Test func allowedAppsSurviveANewInstance() async throws {
        let a = make()
        await a.setEnabled(true)
        let client = TestClient()
        let (request, paired) = try await request(client, on: a)
        a.allow(request)
        await a.setEnabled(false)
        let b = make()
        #expect(b.isEnabled == false && b.wasSetUp)
        #expect(b.allowedApps.map(\.id) == [client.id] && b.allowedApps.first?.name == "Claude Code")
        await b.setEnabled(true)
        let port = try #require(Self.port(b))
        #expect(Self.text(await post(client, paired, port: port)) != nil)
        await cleanUp()
    }

    @Test func denyIsNotSavedAndRefuses() async throws {
        let a = make()
        await a.setEnabled(true)
        let port = try #require(Self.port(a))
        let client = TestClient()
        let (request, paired) = try await request(client, on: a)
        a.deny(request)
        #expect(a.pendingRequests.isEmpty && a.allowedApps.isEmpty)
        #expect(await post(client, paired, port: port) == .pairing(.denied))
        #expect(await pair(client, port: port).reply == .status(.denied))
        #expect(ClaudeAccessFile.load(root: root)?.allowed.isEmpty == true)
        // Allowing an answered request does nothing.
        #expect(!a.allow(request))
        await cleanUp()
    }

    @Test func removeTakesEffectAndIsSaved() async throws {
        let a = make()
        await a.setEnabled(true)
        let port = try #require(Self.port(a))
        let client = TestClient()
        let (request, paired) = try await request(client, on: a)
        a.allow(request)
        let app = try #require(a.allowedApps.first)
        a.remove(app)
        #expect(a.allowedApps.isEmpty && ClaudeAccessFile.load(root: root)?.allowed.isEmpty == true)
        #expect(await post(client, paired, port: port) == .pairing(.unknown))
        await cleanUp()
    }

    @Test func perClientKeysAreIsolated() async throws {
        let a = make()
        await a.setEnabled(true)
        let port = try #require(Self.port(a))
        let allowed = TestClient(), other = TestClient()
        let (request, paired) = try await request(allowed, on: a)
        a.allow(request)
        // Another client claiming the allowed client's id, with its own key pair (so its MAC is valid), gets nothing.
        // (It even names the allowed pairing's transcript, which it could have seen on a port it held.)
        let appKey = paired.appKey
        let claimedKey = try #require(PairingCrypto.sharedKey(privateKey: other.privateKey, peerPublicKey: appKey, clientID: allowed.id,
                                                              clientPublicKey: other.publicKey, appPublicKey: appKey,
                                                              pairing: paired.pairing))
        let claimed = ClientCredentials(clientID: allowed.id, publicKey: other.publicKey, pairing: paired.pairing, key: claimedKey)
        let reply = await URLSessionAppTransport(timeout: 5).post(Self.call, protocolVersion: "2025-11-25", port: port,
                                                                  credentials: claimed)
        #expect(reply == .pairing(.unknown))
        // Its own key under the allowed client's id does not verify at all.
        let mixed = ClientCredentials(clientID: allowed.id, publicKey: other.publicKey, pairing: paired.pairing,
                                      key: other.key(appPublicKey: appKey, pairing: paired.pairing)!)
        #expect(await URLSessionAppTransport(timeout: 5).post(Self.call, protocolVersion: "2025-11-25", port: port,
                                                              credentials: mixed) == .unauthorized)
        // And one signing with the allowed client's public key but its own key fails the MAC.
        let forged = ClientCredentials(clientID: allowed.id, publicKey: allowed.publicKey, pairing: paired.pairing,
                                       key: SymmetricKey(size: .bits256))
        #expect(await URLSessionAppTransport(timeout: 5).post(Self.call, protocolVersion: "2025-11-25", port: port,
                                                              credentials: forged) == .unauthorized)
        await cleanUp()
    }

    @Test func pendingRequestsExpire() async throws {
        var limits = PairingRegistry.Limits()
        limits.pendingLifetime = 0.3
        let a = ClaudeAccess(container: container, root: root, serverVersion: "9.9", options: ClaudeAccessOptions(ephemeralPort: true),
                             limits: limits, otherCopyRunning: { false })
        accesses.append(a)
        await a.setEnabled(true)
        let (request, _) = try await request(TestClient(), on: a)
        #expect(a.pendingRequests.count == 1)
        // Settings drops it by itself when it expires.
        _ = try await waitFor { a.pendingRequests.isEmpty ? true : nil }
        #expect(!a.allow(request))
        await cleanUp()
    }

    @Test func switchOffRefusesAndDropsRequests() async throws {
        let a = make()
        await a.setEnabled(true)
        let port = try #require(Self.port(a))
        _ = try await request(TestClient(), on: a)
        await a.setEnabled(false)
        #expect(a.status == .off && a.pendingRequests.isEmpty)
        #expect(await pair(TestClient(), port: port).reply == .refused)
        #expect(ClaudeAccessFile.load(root: root)?.enabled == false)
        #expect(a.wasSetUp)
    }

    /// A request still arriving when the switch goes off: the connection closes (or answers 503), never 200.
    @Test func disableMidRequestGets503OrClose() async throws {
        let a = make()
        await a.setEnabled(true)
        let port = try #require(Self.port(a))
        let client = try #require(RawClient(port: port))
        client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{")
        try await Task.sleep(for: .milliseconds(100))
        await a.setEnabled(false)
        let (data, closed) = client.readAll(timeout: 2)
        #expect(closed)
        let reply = String(decoding: data, as: UTF8.self)
        #expect(reply.isEmpty || reply.hasPrefix("HTTP/1.1 503 "), "\(reply)")
        #expect(RawClient(port: port) == nil)
    }

    /// Something that is not Transcribe holds the first port: this copy moves on to the next.
    @Test func foreignHolderMovesToTheNextPort() async throws {
        let squatter = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 500) }
        let taken = try await squatter.start()
        defer { squatter.stop() }
        let free = try await Self.freePorts(1)
        let a = make(ClaudeAccessOptions(), ports: [taken, free[0]])
        await a.setEnabled(true)
        #expect(a.status == .ready(port: free[0]))
        #expect(a.endpointPort == free[0])
        await cleanUp()
    }

    /// Another copy of Transcribe holds the first port: it is the one sharing, so this copy does not move on.
    @Test func otherCopyStopsAtTheFirstPort() async throws {
        let squatter = LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 500) }
        let taken = try await squatter.start()
        defer { squatter.stop() }
        let free = try await Self.freePorts(1)
        let a = make(ClaudeAccessOptions(), ports: [taken, free[0]], otherCopy: true)
        await a.setEnabled(true)
        #expect(a.status == .otherCopy(taken))
        #expect(await pair(TestClient(), port: free[0]).reply == .refused)
        #expect(a.isEnabled)
        await cleanUp()
    }

    @Test func everyPortTakenGivesPortsInUse() async throws {
        let squatters = [LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 500) },
                         LoopbackHTTPServer(port: 0) { _ in HTTPResponse(status: 500) }]
        var taken: [UInt16] = []
        for s in squatters { taken.append(try await s.start()) }
        defer { squatters.forEach { $0.stop() } }
        let a = make(ClaudeAccessOptions(), ports: taken)
        await a.setEnabled(true)
        #expect(a.status == .portsInUse(taken))
        #expect(a.isEnabled)
        await cleanUp()
    }

    /// The test hooks: a session started on, with a test port or with auto-allow, is never saved.
    @Test func sessionHooksAreNotSaved() async throws {
        let port = try await Self.freePorts(1)[0]
        let a = make(ClaudeAccessOptions(startOn: true, autoAllow: true, fixedPort: port))
        await a.start()
        #expect(a.isEnabled && a.status == .ready(port: port))
        let client = TestClient()
        let (reply, pairing) = await pair(client, port: port)
        guard reply == .status(.allowed), let paired = pairing else { Issue.record("not allowed: \(reply)"); return }
        #expect(Self.text(await post(client, paired, port: port)) != nil)
        _ = try await waitFor { a.allowedApps.isEmpty ? nil : true }
        if let app = a.allowedApps.first { a.remove(app) }
        await a.setEnabled(false)
        #expect(!fileExists)
        // A later normal session starts with nothing allowed.
        let b = make()
        #expect(b.allowedApps.isEmpty && !b.isEnabled)
        await cleanUp()
    }

    /// The listener serves as soon as it is ready, which at launch can be a second or more before the busy main actor
    /// resumes `start()`. The endpoint must already check Host and the MAC against the real port by then.
    @Test func endpointKnowsThePortBeforeTheListenerIsReady() async throws {
        let port = try await Self.freePorts(1)[0]
        let a = make(ClaudeAccessOptions(startOn: true, autoAllow: true, fixedPort: port))
        let starting = Task { await a.start() }
        // start() sets .starting, then waits for the listener; it cannot resume while this test holds the main actor.
        while a.status != .starting { await Task.yield() }
        #expect(a.endpointPort == port)
        await starting.value
        #expect(a.status == .ready(port: port))
        await cleanUp()
    }

    @Test func setupNilWhileOffAndHasNoSecret() async throws {
        let a = make()
        await a.start()
        #expect(a.setup(helperPath: Self.helper) == nil)
        await a.setEnabled(true)
        let setup = try #require(a.setup(helperPath: Self.helper))
        #expect(setup.helperPath == Self.helper && setup.version == "9.9.0")
        let appKey = try #require(ClaudeAccessFile.load(root: root)?.appKey)
        #expect(!setup.claudeCodeCommand.contains(appKey) && !setup.desktopConfigEntry.contains(appKey))
        await a.setEnabled(false)
        #expect(a.setup(helperPath: Self.helper) == nil)
    }

    @Test func onEnabledChangeFires() async {
        let a = make()
        var seen: [Bool] = []
        a.onEnabledChange = { seen.append($0) }
        await a.start()
        await a.setEnabled(true)
        await a.setEnabled(false)
        #expect(seen == [false, true, false])
    }
}

/// A plain TCP client, to hold a request half-sent.
final class RawClient {
    let fd: Int32

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    func send(_ s: String) { _ = Data(s.utf8).withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }

    /// Reads until the server closes or `timeout` passes. `closed` is true when the server ended the connection.
    func readAll(timeout: TimeInterval) -> (data: Data, closed: Bool) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { data.append(contentsOf: buffer[0..<n]); continue }
            if n == 0 { return (data, true) }
            if errno == EAGAIN || errno == EWOULDBLOCK { return (data, false) }
            return (data, true)
        }
        return (data, false)
    }
}

/// A client's side of a pairing, made the way the helper makes one: its own id, key pair and nonce.
struct TestClient {
    let id = PairingCrypto.newClientID()
    let privateKey = PairingCrypto.newPrivateKey()
    let nonce = PairingCrypto.newNonce()
    var publicKey: String { PairingCrypto.publicKey(ofPrivate: privateKey)! }
    var commitment: String { PairingCrypto.commitment(clientID: id, clientPublicKey: publicKey, clientNonce: nonce) }

    func pairing(appPublicKey: String, appNonce: String) -> String {
        PairingCrypto.transcript(clientID: id, clientPublicKey: publicKey, appPublicKey: appPublicKey, appNonce: appNonce,
                                 clientNonce: nonce)
    }

    func key(appPublicKey: String, pairing: String) -> SymmetricKey? {
        PairingCrypto.sharedKey(privateKey: privateKey, peerPublicKey: appPublicKey, clientID: id, clientPublicKey: publicKey,
                                appPublicKey: appPublicKey, pairing: pairing)
    }

    func credentials(appPublicKey: String, pairing: String) -> ClientCredentials {
        ClientCredentials(clientID: id, publicKey: publicKey, pairing: pairing, key: key(appPublicKey: appPublicKey, pairing: pairing)!)
    }
}
