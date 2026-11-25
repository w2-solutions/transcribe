import Foundation
import Synchronization
import Testing
@testable import TranscribeMCP

/// Something that holds the port the helper tries first, while the real Transcribe (its pairing registry here) runs
/// elsewhere. Toward the helper it plays Transcribe with a key of its own; toward Transcribe it plays a Claude app with
/// a key of its own, and tries to make Transcribe show the code the helper shows.
final class ManInTheMiddle: AppTransport, Sendable {
    let app: PairingRegistry
    let now: Date
    let fakeAppPrivateKey = PairingCrypto.newPrivateKey()
    var fakeAppPublicKey: String { PairingCrypto.publicKey(ofPrivate: fakeAppPrivateKey)! }
    /// The nonce it gives the helper: it must answer the commitment before it learns the helper's nonce.
    let fakeAppNonce = PairingCrypto.newNonce()
    private struct State {
        var helperCommit: PairingRequest?
        var helperCode: String?
        var appCodes: [String] = []
        var refusedAt: Int?
    }
    private let state = Mutex(State())

    init(app: PairingRegistry, now: Date) { self.app = app; self.now = now }

    var helperCode: String? { state.withLock { $0.helperCode } }
    var appCodes: [String] { state.withLock { $0.appCodes } }
    var refusedAt: Int? { state.withLock { $0.refusedAt } }

    func pair(_ request: PairingRequest, port: UInt16) async -> PairReply {
        state.withLock { $0.helperCommit = request }
        return .reveal(appPublicKey: fakeAppPublicKey, appNonce: fakeAppNonce)
    }

    /// The helper reveals: its code is now fixed. The attacker then tries, as many times as Transcribe lets it, for an
    /// exchange whose code matches, abandoning each one that does not before it reveals (so the user never sees it).
    func reveal(_ reveal: PairingReveal, port: UInt16) async -> PairReply {
        guard let commit = state.withLock({ $0.helperCommit }) else { return .invalid }
        let helperPairing = PairingCrypto.transcript(clientID: reveal.clientID, clientPublicKey: reveal.publicKey,
                                                     appPublicKey: fakeAppPublicKey, appNonce: fakeAppNonce,
                                                     clientNonce: reveal.clientNonce)
        let target = PairingCrypto.code(pairing: helperPairing)
        state.withLock { $0.helperCode = target }
        // Its own client toward Transcribe, under the helper's claimed name.
        let attacker = TestClient()
        for attempt in 0..<100 {
            let nonce = PairingCrypto.newNonce()
            let commitment = PairingCrypto.commitment(clientID: attacker.id, clientPublicKey: attacker.publicKey, clientNonce: nonce)
            guard case .reveal(let appNonce) = app.commit(clientID: attacker.id, name: commit.clientName, publicKey: attacker.publicKey,
                                                          commitment: commitment, now: now) else {
                state.withLock { $0.refusedAt = attempt }
                break
            }
            let code = PairingCrypto.code(pairing: PairingCrypto.transcript(
                clientID: attacker.id, clientPublicKey: attacker.publicKey, appPublicKey: app.appPublicKey, appNonce: appNonce,
                clientNonce: nonce))
            state.withLock { $0.appCodes.append(code) }
            if code == target {
                _ = app.reveal(clientID: attacker.id, publicKey: attacker.publicKey, clientNonce: nonce, now: now)
                break
            }
        }
        return .status(.pending)
    }

    func post(_ body: Data, protocolVersion: String, port: UInt16, credentials: ClientCredentials) async -> AppReply { .impostor }
}

@Suite("MCP: man in the middle")
struct ManInTheMiddleTests {
    let state = StateFolder()

    /// The attacker substitutes keys both ways. The helper's code is fixed before the attacker sees Transcribe's
    /// nonce, and Transcribe hands out at most 5 nonces per 10 minutes, so the codes on the two sides differ and the
    /// user is never shown a request whose code matches Claude's.
    @Test func substitutedKeysGiveDifferentCodes() async throws {
        let now = Date(timeIntervalSince1970: 1_794_972_660)
        let app = try #require(PairingRegistry(privateKey: PairingCrypto.newPrivateKey(), allowed: []))
        let mitm = ManInTheMiddle(app: app, now: now)
        let bridge = StdioBridge(transport: mitm, launcher: FakeLauncher(mac: FakeMac(), canLaunch: false),
                                 identities: state.store, ports: [41_000], serverVersion: "9.9")
        let reply = await bridge.handle(line: listCall)
        let helperCode = try #require(state.store.load(name: "Claude")?.code)
        #expect(reply.toolText?.text == BridgeMessages.permissionNeeded(code: helperCode))
        #expect(mitm.helperCode == helperCode)
        // Transcribe gave out five nonces and then refused; none of the five codes matched Claude's.
        #expect(mitm.appCodes.count == 5 && mitm.refusedAt == 5)
        #expect(!mitm.appCodes.contains(helperCode))
        // Nothing the attacker started is shown to the user, so there is nothing to Allow.
        #expect(app.pendingRequests(now: now).isEmpty)
    }
}
