import CryptoKit
import Foundation
import Testing
@testable import TranscribeMCP

/// Credentials with a random key (the MAC tests need no key agreement).
func randomCredentials() -> ClientCredentials {
    ClientCredentials(clientID: PairingCrypto.newClientID(),
                      publicKey: PairingCrypto.publicKey(ofPrivate: PairingCrypto.newPrivateKey())!,
                      pairing: randomDigest(), key: SymmetricKey(size: .bits256))
}

/// A well-formed transcript or commitment that belongs to nothing.
func randomDigest() -> String {
    PairingCrypto.transcript(clientID: PairingCrypto.newClientID(), clientPublicKey: "a", appPublicKey: "b",
                             appNonce: PairingCrypto.newNonce(), clientNonce: PairingCrypto.newNonce())
}

@Suite("MCP: HMAC message auth")
struct MessageAuthTests {
    let creds = randomCredentials()
    let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
    let now = Date(timeIntervalSince1970: 1_794_972_660)

    func sign(_ c: ClientCredentials? = nil, port: UInt16 = 41_000, nonce: String = MessageAuth.newNonce()) -> String {
        MessageAuth.signRequest(body: body, credentials: c ?? creds, port: port, now: now, nonce: nonce)
    }

    @Test func signThenVerifyRequest() {
        let nonce = MessageAuth.newNonce()
        let header = sign(nonce: nonce)
        #expect(header.hasPrefix("TranscribeHMAC client=\(creds.clientID), pub=\(creds.publicKey), pairing=\(creds.pairing), ts=1794972660, nonce=\(nonce), mac="))
        let fields = MessageAuth.parse(header)
        #expect(fields?.client == creds.clientID && fields?.publicKey == creds.publicKey && fields?.nonce == nonce)
        #expect(MessageAuth.checkRequest(header, body: body, key: creds.key, port: 41_000, now: now) == .success(nonce))
        #expect(MessageAuth.checkRequest(header, body: body, key: creds.key, port: 41_000, now: now.addingTimeInterval(60)) == .success(nonce))
        #expect(MessageAuth.checkRequest(header, body: body, key: creds.key, port: 41_000, now: now.addingTimeInterval(-60)) == .success(nonce))
        #expect(MessageAuth.checkRequest(header, body: body, key: SymmetricKey(size: .bits256), port: 41_000, now: now) == .failure(.mac))
    }

    @Test func bodyTamperFails() {
        var tampered = body
        tampered[tampered.count - 3] = 0x71
        #expect(MessageAuth.checkRequest(sign(), body: tampered, key: creds.key, port: 41_000, now: now) == .failure(.mac))
    }

    @Test func portMismatchFails() {
        #expect(MessageAuth.checkRequest(sign(), body: body, key: creds.key, port: 41_001, now: now) == .failure(.mac))
    }

    /// The client id and key are covered by the MAC: naming another client in the header breaks it.
    @Test func clientFieldsAreSigned() {
        let other = randomCredentials()
        let header = sign()
        let swappedID = header.replacingOccurrences(of: "client=\(creds.clientID)", with: "client=\(other.clientID)")
        let swappedKey = header.replacingOccurrences(of: "pub=\(creds.publicKey)", with: "pub=\(other.publicKey)")
        #expect(MessageAuth.checkRequest(swappedID, body: body, key: creds.key, port: 41_000, now: now) == .failure(.mac))
        #expect(MessageAuth.checkRequest(swappedKey, body: body, key: creds.key, port: 41_000, now: now) == .failure(.mac))
        let swappedPairing = header.replacingOccurrences(of: "pairing=\(creds.pairing)", with: "pairing=\(other.pairing)")
        #expect(swappedPairing != header)
        #expect(MessageAuth.checkRequest(swappedPairing, body: body, key: creds.key, port: 41_000, now: now) == .failure(.mac))
    }

    @Test func staleTimestampFails() {
        let header = sign()
        #expect(MessageAuth.checkRequest(header, body: body, key: creds.key, port: 41_000, now: now.addingTimeInterval(61)) == .failure(.time))
        #expect(MessageAuth.checkRequest(header, body: body, key: creds.key, port: 41_000, now: now.addingTimeInterval(-61)) == .failure(.time))
    }

    @Test func malformedHeaderFails() {
        let nonce = MessageAuth.newNonce()
        let good = sign(nonce: nonce)
        let mac = String(good.split(separator: "mac=").last!)
        let id = creds.clientID, pub = creds.publicKey, pr = creds.pairing
        let bad: [String?] = [
            nil, "", "Bearer x", "transcribehmac client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac), extra=1",
            "TranscribeHMAC client=\(id), client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id)x, pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub.dropLast())+, pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr), ts=-1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660000000, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce)x, mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac.dropLast())+",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr), ts=1794972660, nonce=\(nonce), mac=\(mac)=",
            "TranscribeHMAC client=\(id), pub=\(pub), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr.dropLast()), ts=1794972660, nonce=\(nonce), mac=\(mac)",
            "TranscribeHMAC client=\(id), pub=\(pub), pairing=\(pr.dropLast())+, ts=1794972660, nonce=\(nonce), mac=\(mac)",
        ]
        for header in bad {
            #expect(MessageAuth.parse(header) == nil, "\(header ?? "nil")")
            #expect(MessageAuth.checkRequest(header, body: body, key: creds.key, port: 41_000, now: now) == .failure(.format))
        }
        // Order of the fields and spacing after commas do not matter.
        let reordered = "TranscribeHMAC mac=\(mac),nonce=\(nonce),   ts=1794972660,pub=\(pub), client=\(id),pairing=\(pr)"
        #expect(MessageAuth.checkRequest(reordered, body: body, key: creds.key, port: 41_000, now: now) == .success(nonce))
    }

    @Test func responseRoundTrip() {
        let nonce = MessageAuth.newNonce()
        let reply = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        let mac = MessageAuth.signResponse(status: 200, body: reply, nonce: nonce, key: creds.key)
        #expect(mac.count == 43)
        #expect(MessageAuth.verifyResponse(mac, status: 200, body: reply, nonce: nonce, key: creds.key))
        #expect(!MessageAuth.verifyResponse(mac, status: 202, body: reply, nonce: nonce, key: creds.key))
        #expect(!MessageAuth.verifyResponse(mac, status: 200, body: reply + Data(" ".utf8), nonce: nonce, key: creds.key))
        #expect(!MessageAuth.verifyResponse(mac, status: 200, body: reply, nonce: nonce, key: SymmetricKey(size: .bits256)))
        #expect(!MessageAuth.verifyResponse(nil, status: 200, body: reply, nonce: nonce, key: creds.key))
        #expect(!MessageAuth.verifyResponse("", status: 200, body: reply, nonce: nonce, key: creds.key))
    }

    @Test func responseWrongNonceFails() {
        let reply = Data("{}".utf8)
        let mac = MessageAuth.signResponse(status: 200, body: reply, nonce: MessageAuth.newNonce(), key: creds.key)
        #expect(!MessageAuth.verifyResponse(mac, status: 200, body: reply, nonce: MessageAuth.newNonce(), key: creds.key))
    }

    @Test func replayGuardRejectsSecondUseAndForgetsAfterWindow() {
        let guardian = ReplayGuard()
        #expect(guardian.check("n1", at: now) == .admitted)
        #expect(guardian.check("n1", at: now.addingTimeInterval(119)) == .replayed)
        #expect(!guardian.admit("n1", at: now.addingTimeInterval(60)))
        #expect(guardian.admit("n2", at: now))
        #expect(guardian.admit("n1", at: now.addingTimeInterval(121)))
    }

    @Test func replayGuardCapacity() {
        let guardian = ReplayGuard(window: 120, capacity: 3)
        for i in 0..<3 { #expect(guardian.admit("n\(i)", at: now)) }
        #expect(guardian.check("n3", at: now.addingTimeInterval(1)) == .full)
        // Once the old ones expire there is room again.
        #expect(guardian.check("n3", at: now.addingTimeInterval(121)) == .admitted)
    }

    @Test func nonceIs22CharBase64URL() {
        let nonce = MessageAuth.newNonce()
        #expect(nonce.count == 22 && nonce.utf8.allSatisfy(Base64URL.isAlphabet))
    }

    @Test func endpointStateChangesAtOnce() {
        let state = EndpointState(serving: false)
        #expect(state.servingSince == nil)
        state.set(serving: true, at: now)
        #expect(state.serving && state.servingSince == now)
        state.set(serving: false)
        #expect(!state.serving && state.servingSince == nil)
    }
}
