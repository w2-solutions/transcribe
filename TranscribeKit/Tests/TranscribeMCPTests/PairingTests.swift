import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import TranscribeMCP

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

    /// Commit, then reveal, against a registry: the reveal's answer and the transcript; nil when the commit was refused.
    func pair(_ r: PairingRegistry, name: String = "Claude Code", now: Date) -> (answer: PairingRegistry.RevealAnswer, pairing: String)? {
        guard case .reveal(let appNonce) = r.commit(clientID: id, name: name, publicKey: publicKey, commitment: commitment,
                                                    now: now) else { return nil }
        let answer = r.reveal(clientID: id, publicKey: publicKey, clientNonce: nonce, now: now)
        return (answer, pairing(appPublicKey: r.appPublicKey, appNonce: appNonce))
    }

    /// Paired and allowed in `r`: the credentials it signs with.
    func allowed(in r: PairingRegistry, now: Date) -> ClientCredentials {
        let (_, pairing) = pair(r, now: now)!
        r.allow(clientID: id, now: now)
        return credentials(appPublicKey: r.appPublicKey, pairing: pairing)
    }
}

/// HMAC keys compare by their bytes.
func bytes(_ key: SymmetricKey?) -> Data? { key?.withUnsafeBytes { Data($0) } }

@Suite("MCP: pairing crypto")
struct PairingCryptoTests {
    let app = PairingCrypto.newPrivateKey()
    var appPublic: String { PairingCrypto.publicKey(ofPrivate: app)! }

    func appKey(_ c: TestClient, pairing: String) -> SymmetricKey? {
        PairingCrypto.sharedKey(privateKey: app, peerPublicKey: c.publicKey, clientID: c.id, clientPublicKey: c.publicKey,
                                appPublicKey: appPublic, pairing: pairing)
    }

    @Test func bothSidesDeriveTheSameKeyAndCode() throws {
        let client = TestClient()
        let appNonce = PairingCrypto.newNonce()
        let pairing = client.pairing(appPublicKey: appPublic, appNonce: appNonce)
        #expect(PairingCrypto.isDigest(pairing))
        let clientSide = client.key(appPublicKey: appPublic, pairing: pairing)
        #expect(clientSide != nil && bytes(clientSide) == bytes(appKey(client, pairing: pairing)))
        #expect(bytes(clientSide)?.count == 32)
        // The app computes the transcript from what it holds; the code is the same on both sides.
        let appTranscript = PairingCrypto.transcript(clientID: client.id, clientPublicKey: client.publicKey, appPublicKey: appPublic,
                                                     appNonce: appNonce, clientNonce: client.nonce)
        #expect(appTranscript == pairing)
        let code = PairingCrypto.code(pairing: pairing)
        #expect(code.count == 7 && code.dropFirst(3).first == " " && code.filter(\.isNumber).count == 6)
    }

    /// Changing either nonce, either key or the client id changes the transcript, so the code and the key change too.
    @Test func everyPartOfTheExchangeChangesTheCodeAndKey() throws {
        let client = TestClient()
        let appNonce = PairingCrypto.newNonce()
        let base = client.pairing(appPublicKey: appPublic, appNonce: appNonce)
        let otherApp = try #require(PairingCrypto.publicKey(ofPrivate: PairingCrypto.newPrivateKey()))
        let otherClientKey = try #require(PairingCrypto.publicKey(ofPrivate: PairingCrypto.newPrivateKey()))
        let variants = [
            PairingCrypto.transcript(clientID: client.id, clientPublicKey: client.publicKey, appPublicKey: appPublic,
                                     appNonce: PairingCrypto.newNonce(), clientNonce: client.nonce),
            PairingCrypto.transcript(clientID: client.id, clientPublicKey: client.publicKey, appPublicKey: appPublic,
                                     appNonce: appNonce, clientNonce: PairingCrypto.newNonce()),
            PairingCrypto.transcript(clientID: client.id, clientPublicKey: client.publicKey, appPublicKey: otherApp,
                                     appNonce: appNonce, clientNonce: client.nonce),
            PairingCrypto.transcript(clientID: client.id, clientPublicKey: otherClientKey, appPublicKey: appPublic,
                                     appNonce: appNonce, clientNonce: client.nonce),
            PairingCrypto.transcript(clientID: PairingCrypto.newClientID(), clientPublicKey: client.publicKey,
                                     appPublicKey: appPublic, appNonce: appNonce, clientNonce: client.nonce),
            // The two nonces are not interchangeable.
            PairingCrypto.transcript(clientID: client.id, clientPublicKey: client.publicKey, appPublicKey: appPublic,
                                     appNonce: client.nonce, clientNonce: appNonce),
        ]
        let right = bytes(client.key(appPublicKey: appPublic, pairing: base))
        for (i, v) in variants.enumerated() {
            #expect(v != base, "variant \(i)")
            #expect(bytes(client.key(appPublicKey: appPublic, pairing: v)) != right, "variant \(i)")
        }
        // Codes are six digits of a hash: across many variants almost all differ from the base code.
        let code = PairingCrypto.code(pairing: base)
        let others = (0..<200).map { _ in
            PairingCrypto.code(pairing: PairingCrypto.transcript(clientID: client.id, clientPublicKey: client.publicKey,
                                                                 appPublicKey: appPublic, appNonce: PairingCrypto.newNonce(),
                                                                 clientNonce: client.nonce))
        }
        #expect(others.filter { $0 == code }.count <= 1)
        #expect(Set(others).count >= 198)
    }

    @Test func commitmentBindsTheNonceKeyAndID() throws {
        let c = TestClient()
        let commitment = c.commitment
        #expect(PairingCrypto.isDigest(commitment))
        #expect(PairingCrypto.commitment(clientID: c.id, clientPublicKey: c.publicKey, clientNonce: c.nonce) == commitment)
        #expect(PairingCrypto.commitment(clientID: c.id, clientPublicKey: c.publicKey, clientNonce: PairingCrypto.newNonce()) != commitment)
        #expect(PairingCrypto.commitment(clientID: PairingCrypto.newClientID(), clientPublicKey: c.publicKey, clientNonce: c.nonce) != commitment)
        #expect(PairingCrypto.commitment(clientID: c.id, clientPublicKey: TestClient().publicKey, clientNonce: c.nonce) != commitment)
    }

    @Test func malformedKeysAreRejected() throws {
        let client = TestClient()
        let pairing = client.pairing(appPublicKey: appPublic, appNonce: PairingCrypto.newNonce())
        #expect(PairingCrypto.isPublicKey(client.publicKey))
        for bad in ["", "short", String(repeating: "A", count: 42), client.publicKey + "A", String(client.publicKey.dropLast()) + "+"] {
            #expect(!PairingCrypto.isPublicKey(bad), "\(bad)")
            #expect(PairingCrypto.sharedKey(privateKey: app, peerPublicKey: bad, clientID: client.id, clientPublicKey: bad,
                                            appPublicKey: appPublic, pairing: pairing) == nil)
        }
        for bad in ["", "short", String(pairing.dropLast()), String(pairing.dropLast()) + "+"] {
            #expect(!PairingCrypto.isDigest(bad), "\(bad)")
            #expect(appKey(client, pairing: bad) == nil)
        }
        // The all-zero point gives an all-zero secret: refused.
        let zero = Base64URL.encode(Data(count: 32))
        #expect(PairingCrypto.sharedKey(privateKey: app, peerPublicKey: zero, clientID: client.id, clientPublicKey: zero,
                                        appPublicKey: appPublic, pairing: pairing) == nil)
        #expect(PairingCrypto.privateKey("nope") == nil)
        #expect(!PairingCrypto.isClientID("too-short") && PairingCrypto.isClientID(PairingCrypto.newClientID()))
        #expect(PairingCrypto.isNonce(PairingCrypto.newNonce()) && !PairingCrypto.isNonce("short"))
    }
}

@Suite("MCP: client names")
struct ClientNameTests {
    @Test func knownClientsUseProductNames() {
        #expect(ClientName.display(clientInfo: ["name": "claude-code", "version": "2.1"]) == "Claude Code")
        #expect(ClientName.display(clientInfo: ["name": "claude-ai", "version": "0.1"]) == "Claude Desktop")
        #expect(ClientName.display(clientInfo: ["name": "other", "title": "Other App"]) == "Other App")
        #expect(ClientName.display(clientInfo: ["name": "other"]) == "other")
        #expect(ClientName.display(clientInfo: nil) == "Claude")
        #expect(ClientName.display(clientInfo: ["name": "\u{202E}\u{0007}"]) == "Claude")
    }

    @Test func sanitisedToPrintableText() {
        #expect(ClientName.sanitized("  Claude \n\t Code  ") == "Claude Code")
        #expect(ClientName.sanitized("Evil\u{202E}txt.app") == "Eviltxt.app")
        #expect(ClientName.sanitized("a\u{0000}b\u{001B}c") == "abc")
        #expect(ClientName.sanitized(String(repeating: "x", count: 200))?.count == 64)
        #expect(ClientName.sanitized(String(repeating: "x", count: 2_000)) == nil)
        #expect(ClientName.sanitized("   ") == nil && ClientName.sanitized(nil) == nil)
        #expect(ClientName.sanitized("Claude Code") == "Claude Code")
    }

    @Test func fileStemsAreSafeAndDistinct() {
        let code = ClientName.fileStem("Claude Code")
        #expect(code.hasPrefix("claude-code-") && code.count == "claude-code-".count + 8)
        #expect(ClientName.fileStem("Claude Code") == code)
        #expect(ClientName.fileStem("Claude Desktop") != code)
        #expect(ClientName.fileStem("../../etc") .allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        #expect(ClientName.fileStem("クロード").hasPrefix("client-"))
        #expect(ClientName.fileStem("クロード") != ClientName.fileStem("クラウド"))
    }
}

@Suite("MCP: pairing registry")
struct PairingRegistryTests {
    static let t0 = Date(timeIntervalSince1970: 1_794_972_660)

    final class Changes: Sendable {
        let list = Mutex<[PairingRegistry.Change]>([])
        var all: [PairingRegistry.Change] { list.withLock { $0 } }
    }

    func make(_ limits: PairingRegistry.Limits = .init(), allowed: [AllowedClient] = []) -> (PairingRegistry, Changes) {
        let registry = PairingRegistry(privateKey: PairingCrypto.newPrivateKey(), allowed: allowed, limits: limits)!
        let changes = Changes()
        registry.setOnChange { c in changes.list.withLock { $0.append(c) } }
        return (registry, changes)
    }

    func commit(_ r: PairingRegistry, _ c: TestClient, commitment: String? = nil, at t: TimeInterval = 0) -> PairingRegistry.CommitAnswer {
        r.commit(clientID: c.id, name: "C", publicKey: c.publicKey, commitment: commitment ?? c.commitment,
                 now: Self.t0.addingTimeInterval(t))
    }

    func appNonce(_ a: PairingRegistry.CommitAnswer) -> String? {
        if case .reveal(let n) = a { return n }
        return nil
    }

    @Test func revealedRequestIsPendingWithTheClientsCode() throws {
        let (r, changes) = make()
        let c = TestClient()
        let nonce = try #require(appNonce(r.commit(clientID: c.id, name: "Claude Code", publicKey: c.publicKey,
                                                   commitment: c.commitment, now: Self.t0)))
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: c.nonce, now: Self.t0) == .pending)
        let pairing = c.pairing(appPublicKey: r.appPublicKey, appNonce: nonce)
        let pending = r.pendingRequests(now: Self.t0)
        #expect(pending.count == 1 && pending[0].name == "Claude Code" && pending[0].pairing == pairing)
        #expect(pending[0].code == PairingCrypto.code(pairing: pairing))
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0) == .pending)
        #expect(changes.all == [.newRequest])
    }

    /// Before the reveal nothing shows: no pending request, no change, no access, unknown to the endpoint.
    @Test func invisibleBeforeReveal() throws {
        let (r, changes) = make()
        let c = TestClient()
        let nonce = try #require(appNonce(commit(r, c)))
        #expect(r.pendingRequests(now: Self.t0).isEmpty && r.nextExpiry(now: Self.t0) == nil)
        #expect(changes.all.isEmpty)
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: c.pairing(appPublicKey: r.appPublicKey, appNonce: nonce),
                         now: Self.t0) == .unknown)
        #expect(!r.knows(clientID: c.id, now: Self.t0))
        #expect(!r.allow(clientID: c.id, now: Self.t0) && !r.deny(clientID: c.id, now: Self.t0))
        #expect(r.allowedClients.isEmpty)
    }

    /// A nonce that does not match the commitment is refused, drops the exchange, and the request never shows.
    @Test func wrongRevealIsRejectedAndNeverShown() throws {
        let (r, changes) = make()
        let c = TestClient()
        _ = try #require(appNonce(commit(r, c)))
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: PairingCrypto.newNonce(), now: Self.t0) == .rejected)
        #expect(r.pendingRequests(now: Self.t0).isEmpty && changes.all.isEmpty)
        // The exchange is gone: the right nonce now finds nothing.
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: c.nonce, now: Self.t0) == .unknown)
        // Another key under the same id cannot reveal it either.
        let d = TestClient()
        _ = commit(r, d)
        #expect(r.reveal(clientID: d.id, publicKey: TestClient().publicKey, clientNonce: d.nonce, now: Self.t0) == .unknown)
        #expect(r.pendingRequests(now: Self.t0).isEmpty)
    }

    /// The same commitment again gets the same nonce; a new commitment restarts with a fresh one (never the old nonce
    /// with another commitment), and counts against the nonce limit.
    @Test func repeatsAndRestarts() throws {
        let (r, _) = make()
        let c = TestClient()
        let first = try #require(appNonce(commit(r, c)))
        #expect(appNonce(commit(r, c, at: 1)) == first)
        let restart = TestClient()   // only its nonce: same client id and key, another commitment
        let otherCommitment = PairingCrypto.commitment(clientID: c.id, clientPublicKey: c.publicKey, clientNonce: restart.nonce)
        let second = try #require(appNonce(commit(r, c, commitment: otherCommitment, at: 2)))
        #expect(second != first)
        // The same id with another key is not the same client.
        #expect(r.commit(clientID: c.id, name: "C", publicKey: TestClient().publicKey, commitment: c.commitment, now: Self.t0) == .conflict)
        // The first commitment's nonce no longer reveals (and the attempt ends the exchange).
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: c.nonce, now: Self.t0.addingTimeInterval(3)) == .rejected)
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: restart.nonce, now: Self.t0.addingTimeInterval(3)) == .unknown)
    }

    @Test func aPendingRequestKeepsItsNonce() throws {
        let (r, _) = make()
        let c = TestClient()
        let (answer, _) = try #require(c.pair(r, now: Self.t0))
        #expect(answer == .pending)
        let nonce = appNonce(commit(r, c))
        #expect(nonce != nil)
        // Revealing again is harmless; a new commitment is refused (no new nonce for a request the user can see).
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: c.nonce, now: Self.t0) == .pending)
        #expect(commit(r, c, commitment: TestClient().commitment) == .conflict)
        #expect(r.pendingRequests(now: Self.t0).count == 1)
    }

    @Test func unrevealedExpiresAfter30s() throws {
        let (r, _) = make()
        let c = TestClient()
        _ = try #require(appNonce(commit(r, c)))
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: c.nonce, now: Self.t0.addingTimeInterval(30)) == .unknown)
        #expect(r.pendingRequests(now: Self.t0.addingTimeInterval(30)).isEmpty)
        // Within 30 s it reveals.
        let d = TestClient()
        _ = commit(r, d)
        #expect(r.reveal(clientID: d.id, publicKey: d.publicKey, clientNonce: d.nonce, now: Self.t0.addingTimeInterval(29)) == .pending)
    }

    /// Unrevealed and pending requests share the cap of 3; a flood is refused and never displaces one already there.
    @Test func capCoversUnrevealedAndNeverDisplaces() throws {
        let (r, _) = make()
        let real = TestClient()
        #expect(real.pair(r, now: Self.t0)?.answer == .pending)
        for _ in 0..<2 { #expect(appNonce(commit(r, TestClient())) != nil) }
        let flood = TestClient()
        #expect(commit(r, flood) == .busy)
        #expect(r.pendingRequests(now: Self.t0).map(\.id) == [real.id])
        // The unrevealed ones expire after 30 s and free their places; the real request is still there.
        #expect(appNonce(commit(r, flood, at: 31)) != nil)
        #expect(r.pendingRequests(now: Self.t0.addingTimeInterval(31)).map(\.id) == [real.id])
    }

    /// At most 5 app nonces per 10 minutes, restarts included: this also bounds tries at a chosen code.
    @Test func nonceRateLimit() throws {
        var limits = PairingRegistry.Limits()
        limits.maxPending = 10
        let (r, _) = make(limits)
        let c = TestClient()
        _ = try #require(appNonce(commit(r, c)))
        for i in 0..<4 {
            let restart = PairingCrypto.commitment(clientID: c.id, clientPublicKey: c.publicKey, clientNonce: PairingCrypto.newNonce())
            #expect(appNonce(commit(r, c, commitment: restart, at: Double(i + 1))) != nil, "restart \(i)")
        }
        let restart = PairingCrypto.commitment(clientID: c.id, clientPublicKey: c.publicKey, clientNonce: PairingCrypto.newNonce())
        #expect(commit(r, c, commitment: restart, at: 10) == .busy)
        #expect(commit(r, TestClient(), at: 60) == .busy)
        // Once the window has passed, a new exchange is taken.
        #expect(appNonce(commit(r, TestClient(), at: 601)) != nil)
    }

    @Test func pendingExpires() throws {
        let (r, _) = make()
        let c = TestClient()
        let (_, pairing) = try #require(c.pair(r, now: Self.t0))
        #expect(r.nextExpiry(now: Self.t0) == Self.t0.addingTimeInterval(600))
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0.addingTimeInterval(599)) == .pending)
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0.addingTimeInterval(600)) == .unknown)
        #expect(r.pendingRequests(now: Self.t0.addingTimeInterval(600)).isEmpty)
        #expect(!r.allow(clientID: c.id, now: Self.t0.addingTimeInterval(601)))
        #expect(appNonce(commit(r, c, at: 601)) != nil)
    }

    @Test func allowMakesThatPairingAllowed() throws {
        let (r, changes) = make()
        let c = TestClient()
        let (_, pairing) = try #require(c.pair(r, now: Self.t0))
        #expect(r.allow(clientID: c.id, now: Self.t0.addingTimeInterval(5)))
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0) == .allowed)
        #expect(r.allowedClients == [AllowedClient(id: c.id, name: "Claude Code", publicKey: c.publicKey, pairing: pairing,
                                                   allowedAt: Self.t0.addingTimeInterval(5))])
        #expect(r.pendingRequests(now: Self.t0).isEmpty)
        #expect(changes.all == [.newRequest, .updated])
        // Allowed never lasts for another key or another pairing under the same id, and the id cannot pair again.
        #expect(r.access(clientID: c.id, publicKey: TestClient().publicKey, pairing: pairing, now: Self.t0) == .unknown)
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: randomDigest(), now: Self.t0) == .unknown)
        #expect(commit(r, c) == .conflict)
    }

    @Test func denyHoldsThenForgets() throws {
        let (r, _) = make()
        let c = TestClient()
        let (_, pairing) = try #require(c.pair(r, now: Self.t0))
        #expect(r.deny(clientID: c.id, now: Self.t0))
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0.addingTimeInterval(299)) == .denied)
        // Asking again during the hold changes nothing and shows no new prompt.
        #expect(commit(r, c, at: 10) == .denied)
        #expect(r.reveal(clientID: c.id, publicKey: c.publicKey, clientNonce: c.nonce, now: Self.t0.addingTimeInterval(10)) == .denied)
        #expect(r.pendingRequests(now: Self.t0.addingTimeInterval(10)).isEmpty)
        #expect(r.knows(clientID: c.id, now: Self.t0.addingTimeInterval(10)))
        // After the hold the client is unknown, and a request asks the user again.
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0.addingTimeInterval(300)) == .unknown)
        #expect(!r.knows(clientID: c.id, now: Self.t0.addingTimeInterval(300)))
        #expect(c.pair(r, now: Self.t0.addingTimeInterval(700))?.answer == .pending)
    }

    @Test func removeMakesItUnknown() {
        let c = TestClient()
        let pairing = randomDigest()
        let (r, changes) = make(allowed: [AllowedClient(id: c.id, name: "Claude", publicKey: c.publicKey, pairing: pairing,
                                                        allowedAt: Self.t0)])
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0) == .allowed)
        #expect(r.remove(clientID: c.id))
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0) == .unknown)
        #expect(!r.knows(clientID: c.id, now: Self.t0))
        #expect(!r.remove(clientID: c.id))
        #expect(changes.all == [.updated])
    }

    @Test func keysArePerPairing() throws {
        let (r, _) = make()
        let a = TestClient(), b = TestClient()
        let pa = randomDigest(), pb = randomDigest()
        let appA = try #require(r.key(clientID: a.id, clientPublicKey: a.publicKey, pairing: pa))
        let appB = try #require(r.key(clientID: b.id, clientPublicKey: b.publicKey, pairing: pb))
        #expect(bytes(appA) == bytes(a.key(appPublicKey: r.appPublicKey, pairing: pa)))
        #expect(bytes(appB) == bytes(b.key(appPublicKey: r.appPublicKey, pairing: pb)))
        #expect(bytes(appA) != bytes(appB))
        #expect(bytes(r.key(clientID: a.id, clientPublicKey: a.publicKey, pairing: pb)) != bytes(appA))
        // A request signed by A does not verify as B.
        let body = Data("{}".utf8)
        let header = MessageAuth.signRequest(body: body, credentials: a.credentials(appPublicKey: r.appPublicKey, pairing: pa),
                                             port: 1, now: Self.t0, nonce: MessageAuth.newNonce())
        #expect(MessageAuth.checkRequest(header, body: body, key: appB, port: 1, now: Self.t0) == .failure(.mac))
        #expect(MessageAuth.checkRequest(header, body: body, key: appA, port: 1, now: Self.t0).map { _ in true } == .success(true))
    }

    @Test func autoAllowAllowsAtReveal() throws {
        let (r, changes) = make()
        r.setAutoAllow(true)
        let c = TestClient()
        #expect(changes.all.isEmpty)
        let (answer, pairing) = try #require(c.pair(r, name: "Smoke", now: Self.t0))
        #expect(answer == .allowed)
        #expect(r.access(clientID: c.id, publicKey: c.publicKey, pairing: pairing, now: Self.t0) == .allowed)
        #expect(r.pendingRequests(now: Self.t0).isEmpty && changes.all == [.updated])
    }

    @Test func invalidSavedClientsAreDropped() {
        let good = TestClient()
        let r = PairingRegistry(privateKey: PairingCrypto.newPrivateKey(), allowed: [
            AllowedClient(id: good.id, name: "Good", publicKey: good.publicKey, pairing: randomDigest(), allowedAt: Self.t0),
            AllowedClient(id: "bad", name: "Bad", publicKey: good.publicKey, pairing: randomDigest(), allowedAt: Self.t0),
            AllowedClient(id: PairingCrypto.newClientID(), name: "Bad", publicKey: "nope", pairing: randomDigest(), allowedAt: Self.t0),
            AllowedClient(id: PairingCrypto.newClientID(), name: "Bad", publicKey: good.publicKey, pairing: "nope", allowedAt: Self.t0),
        ])
        #expect(r?.allowedClients.map(\.name) == ["Good"])
        #expect(PairingRegistry(privateKey: "nope", allowed: []) == nil)
    }

    @Test func dropPendingKeepsAllowedAndClearsUnrevealed() throws {
        let c = TestClient(), d = TestClient(), e = TestClient()
        let (r, _) = make(allowed: [AllowedClient(id: c.id, name: "C", publicKey: c.publicKey, pairing: randomDigest(), allowedAt: Self.t0)])
        _ = d.pair(r, now: Self.t0)
        _ = try #require(appNonce(commit(r, e)))
        r.dropPending()
        #expect(r.pendingRequests(now: Self.t0).isEmpty && r.allowedClients.count == 1)
        #expect(r.reveal(clientID: e.id, publicKey: e.publicKey, clientNonce: e.nonce, now: Self.t0) == .unknown)
    }
}

@Suite("MCP: helper identity store")
struct HelperIdentityStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-state-\(UUID().uuidString)/Transcribe MCP",
                                                                             isDirectory: true)
    var store: HelperIdentityStore { HelperIdentityStore(directory: dir) }

    func mode(_ url: URL) throws -> Int {
        try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
    }

    func appKey() throws -> String { try #require(PairingCrypto.publicKey(ofPrivate: PairingCrypto.newPrivateKey())) }

    @Test func createsFolder0700AndFile0600() throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let identity = try store.loadOrCreate(name: "Claude Code")
        #expect(try mode(dir) == 0o700)
        #expect(try mode(store.url(forName: "Claude Code")) == 0o600)
        #expect(identity.appPublicKey == nil && identity.credentials == nil && identity.code == nil && identity.pairing == nil)
        #expect(PairingCrypto.isClientID(identity.clientID) && PairingCrypto.isPublicKey(identity.publicKey))
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [store.url(forName: "Claude Code").lastPathComponent])
        // The private key is in the file; nothing else secret is.
        let text = try String(contentsOf: store.url(forName: "Claude Code"), encoding: .utf8)
        #expect(text.contains(identity.privateKey) && text.contains("\"client_name\" : \"Claude Code\""))
    }

    @Test func reloadsTheSameIdentityAndPinPersists() throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let first = try store.loadOrCreate(name: "Claude Code")
        #expect(try store.loadOrCreate(name: "Claude Code") == first)
        let app = try appKey()
        let appNonce = PairingCrypto.newNonce(), clientNonce = PairingCrypto.newNonce()
        let pinned = try store.pin(first, appPublicKey: app, appNonce: appNonce, clientNonce: clientNonce)
        #expect(pinned.appPublicKey == app && pinned.credentials != nil)
        #expect(pinned.pairing == PairingCrypto.transcript(clientID: first.clientID, clientPublicKey: first.publicKey,
                                                           appPublicKey: app, appNonce: appNonce, clientNonce: clientNonce))
        #expect(pinned.code == pinned.pairing.map(PairingCrypto.code(pairing:)))
        #expect(store.load(name: "Claude Code") == pinned)
        #expect(try mode(store.url(forName: "Claude Code")) == 0o600)
        #expect(throws: (any Error).self) { try store.pin(first, appPublicKey: app, appNonce: "short", clientNonce: clientNonce) }
    }

    @Test func verifiedIsSavedForThatPairingOnly() throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let first = try store.loadOrCreate(name: "Claude")
        #expect(!first.verified)
        let pinned = try store.pin(first, appPublicKey: try appKey(), appNonce: PairingCrypto.newNonce(),
                                   clientNonce: PairingCrypto.newNonce())
        #expect(!pinned.verified && store.load(name: "Claude")?.verified == false)
        // Another pairing under the same identity (another helper pinned again meanwhile) is not marked.
        let other = try #require(first.pinned(appPublicKey: try appKey(), appNonce: PairingCrypto.newNonce(),
                                              clientNonce: PairingCrypto.newNonce()))
        _ = try store.markVerified(other)
        #expect(store.load(name: "Claude")?.verified == false)
        let marked = try store.markVerified(pinned)
        #expect(marked.verified && store.load(name: "Claude") == marked)
        #expect(try mode(store.url(forName: "Claude")) == 0o600)
        // An unpaired identity cannot be marked; a new pairing starts unmarked.
        #expect(throws: (any Error).self) { try store.markVerified(first) }
        store.forget(marked)
        #expect(try store.loadOrCreate(name: "Claude").verified == false)
    }

    @Test func oneFilePerClient() throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let code = try store.loadOrCreate(name: "Claude Code")
        let desktop = try store.loadOrCreate(name: "Claude Desktop")
        #expect(code.clientID != desktop.clientID && code.publicKey != desktop.publicKey)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)).count == 2)
    }

    @Test func forgetDeletesOnlyThatIdentity() throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let old = try store.loadOrCreate(name: "Claude")
        store.forget(old)
        #expect(store.load(name: "Claude") == nil)
        let new = try store.loadOrCreate(name: "Claude")
        #expect(new.clientID != old.clientID)
        // A stale helper forgetting the old identity leaves the new one alone, and cannot pin over it.
        store.forget(old)
        #expect(store.load(name: "Claude") == new)
        _ = try store.pin(old, appPublicKey: try appKey(), appNonce: PairingCrypto.newNonce(), clientNonce: PairingCrypto.newNonce())
        #expect(store.load(name: "Claude") == new)
    }

    @Test func malformedOrOlderFileIsReplaced() throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let first = try store.loadOrCreate(name: "Claude")
        try Data("{not json".utf8).write(to: store.url(forName: "Claude"))
        #expect(store.load(name: "Claude") == nil)
        let replaced = try store.loadOrCreate(name: "Claude")
        #expect(store.load(name: "Claude") == replaced)
        // A version 1 file (pairing before commit and reveal) is not used.
        let v1 = #"{"version":1,"client_id":"\#(first.clientID)","client_name":"Claude","private_key":"\#(first.privateKey)","app_key":"\#(try appKey())"}"#
        try Data(v1.utf8).write(to: store.url(forName: "Claude"))
        #expect(store.load(name: "Claude") == nil)
        #expect(try store.loadOrCreate(name: "Claude").appPublicKey == nil)
    }

    @Test func concurrentCreatesAgreeOnOneIdentity() async throws {
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = store
        let ids = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 { group.addTask { try? store.loadOrCreate(name: "Claude Code").clientID } }
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(ids.count == 8 && Set(ids).count == 1 && ids.first! != nil)
    }

    @Test func stateDirectoryFromEnvironment() {
        let env = HelperEnvironment(["TRANSCRIBE_MCP_STATE_DIR": "/tmp/x y"])
        #expect(HelperIdentityStore.directory(environment: env).path == "/tmp/x y")
        let relative = HelperEnvironment(["TRANSCRIBE_MCP_STATE_DIR": "relative/path"])
        #expect(relative.stateDirectory == nil)
        let defaultDir = HelperIdentityStore.directory(environment: HelperEnvironment([:])).path
        #expect(defaultDir == HelperIdentityStore.realHome + "/Library/Application Support/Transcribe MCP")
        #expect(!defaultDir.contains("/Containers/"))
    }

    @Test func environmentPorts() {
        #expect(HelperEnvironment([:]).ports == WellKnownPorts.all)
        #expect(HelperEnvironment(["TRANSCRIBE_MCP_PORT": "39123"]).ports == [39_123])
        for bad in ["0", "-1", "70000", "abc", ""] {
            #expect(HelperEnvironment(["TRANSCRIBE_MCP_PORT": bad]).ports == WellKnownPorts.all, "\(bad)")
        }
        #expect(HelperEnvironment(["TRANSCRIBE_MCP_DEBUG_LAUNCH": "fake"]).debugLaunch)
        #expect(!HelperEnvironment(["TRANSCRIBE_MCP_DEBUG_LAUNCH": "real"]).debugLaunch)
    }

    @Test func wellKnownPortsAreThreeInRange() {
        #expect(WellKnownPorts.all.count == 3 && Set(WellKnownPorts.all).count == 3)
        #expect(WellKnownPorts.all.allSatisfy { (40_000...48_999).contains($0) })
    }
}
