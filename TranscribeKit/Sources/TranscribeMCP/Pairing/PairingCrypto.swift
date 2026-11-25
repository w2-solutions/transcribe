import CryptoKit
import Foundation

/// Pairing keys (Curve25519 key agreement, CryptoKit). The helper makes one key pair and a random client id per Claude
/// app; the app has one key pair of its own.
///
/// Pairing is commit, then reveal, so a man in the middle cannot choose the code: the helper sends its public key and a
/// commitment to a fresh nonce (`commitment`); the app answers with its public key and a fresh nonce of its own; only
/// then does the helper reveal its nonce, which the app checks against the commitment. The pairing transcript
/// (`transcript`: client id, both public keys, both nonces) decides both the 6-digit code the user compares in Claude
/// and in Transcribe, and the HMAC key (X25519, then HKDF-SHA256 bound to the transcript). Whoever learns the code
/// first has already fixed everything it chose, so a substituted key gives the two sides different codes, except by a
/// one-in-a-million chance per attempt (and the app limits attempts).
///
/// Keys travel as base64url with no padding (43 characters for 32 bytes); client ids and nonces are 16 random bytes
/// (22 characters); commitments and transcripts are SHA-256 digests (43 characters).
public enum PairingCrypto {
    private static let label = "TRANSCRIBE-MCP-PAIR-2"

    public static func newClientID() -> String { Base64URL.random(bytes: 16) }

    public static func isClientID(_ s: String) -> Bool { Base64URL.isToken(s, count: 22) }

    /// A fresh pairing nonce (the helper's or the app's).
    public static func newNonce() -> String { Base64URL.random(bytes: 16) }

    public static func isNonce(_ s: String) -> Bool { Base64URL.isToken(s, count: 22) }

    /// A commitment or a transcript: a canonical SHA-256 digest in base64url.
    public static func isDigest(_ s: String) -> Bool {
        guard Base64URL.isToken(s, count: 43), let raw = Base64URL.decode(s), raw.count == 32 else { return false }
        return Base64URL.encode(raw) == s
    }

    public static func newPrivateKey() -> String { encode(Curve25519.KeyAgreement.PrivateKey()) }

    /// A private key in its stored form (raw 32 bytes, base64url), or nil.
    public static func privateKey(_ s: String) -> Curve25519.KeyAgreement.PrivateKey? {
        guard Base64URL.isToken(s, count: 43), let raw = Base64URL.decode(s), raw.count == 32 else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    /// The public key of a stored private key, or nil.
    public static func publicKey(ofPrivate s: String) -> String? { privateKey(s).map { encode($0.publicKey) } }

    /// True for a canonical public key: 43 base64url characters that decode to 32 bytes and encode back the same.
    public static func isPublicKey(_ s: String) -> Bool { publicKey(s) != nil }

    static func publicKey(_ s: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard Base64URL.isToken(s, count: 43), let raw = Base64URL.decode(s), raw.count == 32,
              Base64URL.encode(raw) == s else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    static func encode(_ key: Curve25519.KeyAgreement.PublicKey) -> String { Base64URL.encode(key.rawRepresentation) }
    static func encode(_ key: Curve25519.KeyAgreement.PrivateKey) -> String { Base64URL.encode(key.rawRepresentation) }

    /// What the helper sends first: a hash of its client id, public key and fresh nonce. The nonce stays secret until
    /// the app has answered with its own.
    public static func commitment(clientID: String, clientPublicKey: String, clientNonce: String) -> String {
        digest("\(label) commit\n\(clientID)\n\(clientPublicKey)\n\(clientNonce)")
    }

    /// The pairing transcript, once both nonces are known: the code and the HMAC key both come from it.
    public static func transcript(clientID: String, clientPublicKey: String, appPublicKey: String, appNonce: String,
                                  clientNonce: String) -> String {
        digest("\(label) transcript\n\(clientID)\n\(clientPublicKey)\n\(appPublicKey)\n\(appNonce)\n\(clientNonce)")
    }

    /// The HMAC key for one pairing. The helper passes its own private key and the app's public key; the app passes
    /// its private key and the client's public key. nil for a malformed value or a degenerate (all-zero) secret.
    public static func sharedKey(privateKey: String, peerPublicKey: String, clientID: String, clientPublicKey: String,
                                 appPublicKey: String, pairing: String) -> SymmetricKey? {
        guard let own = Self.privateKey(privateKey), let peer = publicKey(peerPublicKey), isClientID(clientID),
              isPublicKey(clientPublicKey), isPublicKey(appPublicKey), isDigest(pairing),
              let secret = try? own.sharedSecretFromKeyAgreement(with: peer),
              secret.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { return nil }
        let info = "\(label) key\n\(clientID)\n\(clientPublicKey)\n\(appPublicKey)\n\(pairing)"
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(label.utf8), sharedInfo: Data(info.utf8),
                                              outputByteCount: 32)
    }

    /// The code both sides show, as "482 913": six digits from a hash of the pairing transcript.
    public static func code(pairing: String) -> String {
        let digest = SHA256.hash(data: Data("\(label) code\n\(pairing)".utf8))
        let n = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let digits = String(n)
        let padded = String(repeating: "0", count: 6 - digits.count) + digits
        return "\(padded.prefix(3)) \(padded.suffix(3))"
    }

    private static func digest(_ text: String) -> String { Base64URL.encode(Data(SHA256.hash(data: Data(text.utf8)))) }
}

/// What the helper signs a call with: its client id, public key and pairing transcript (sent in the `Authorization`
/// value, so the app can pick the key) and the derived HMAC key (never sent).
public struct ClientCredentials: Sendable {
    public let clientID: String
    public let publicKey: String
    public let pairing: String
    public let key: SymmetricKey

    public init(clientID: String, publicKey: String, pairing: String, key: SymmetricKey) {
        self.clientID = clientID; self.publicKey = publicKey; self.pairing = pairing; self.key = key
    }
}
