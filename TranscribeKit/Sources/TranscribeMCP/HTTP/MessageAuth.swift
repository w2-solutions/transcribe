import CryptoKit
import Foundation
import Synchronization

/// The private HMAC scheme between the helper and the app (§3.2, D10). Each Claude app's helper signs with its own
/// key, derived at pairing (`PairingCrypto.sharedKey`); the `Authorization` value names the client id, public key and
/// pairing transcript so the app can derive the same key. Requests are signed over method, path, port, client id, key
/// and transcript, timestamp, nonce and the body's hash; replies are signed back over the nonce, status and body hash. The key never crosses
/// the socket, so a process holding the port cannot forge a reply, though it does see the arguments of requests sent
/// to it. The endpoint rejects a request signed before its listener began serving, so such a request cannot be
/// relayed to the app later.
public enum MessageAuth {
    public static let scheme = "TranscribeHMAC"
    public static let responseHeader = "X-Transcribe-MAC"
    /// On an unsigned 401: "unknown" when the app has no record of the client id (it may have lost its own key).
    public static let pairingHeader = "X-Transcribe-Pairing"
    /// How far a request's timestamp may be from the app's clock, in seconds.
    public static let window: TimeInterval = 60

    /// Why a request failed the check (logged as the `reason`; the replay case is the `ReplayGuard`'s).
    public enum Failure: String, Error, Sendable, Equatable { case format, time, mac }

    /// The parts of an `Authorization` value, each well-formed.
    public struct Fields: Sendable, Equatable {
        public var client: String
        public var publicKey: String
        /// The pairing transcript the key was derived from.
        public var pairing: String
        public var ts: String
        public var nonce: String
        public var mac: String
    }

    /// 16 random bytes as base64url with no padding (22 characters).
    public static func newNonce() -> String { Base64URL.random(bytes: 16) }

    /// The whole `Authorization` header value:
    /// `TranscribeHMAC client=<id>, pub=<public key>, pairing=<transcript>, ts=<unix seconds>, nonce=<nonce>, mac=<mac>`.
    public static func signRequest(body: Data, credentials c: ClientCredentials, port: UInt16, now: Date,
                                   nonce: String) -> String {
        let ts = String(Int64(now.timeIntervalSince1970.rounded(.down)))
        let mac = Base64URL.encode(Data(HMAC<SHA256>.authenticationCode(
            for: requestMessage(port: port, client: c.clientID, publicKey: c.publicKey, pairing: c.pairing, ts: ts,
                                nonce: nonce, body: body),
            using: c.key)))
        return "\(scheme) client=\(c.clientID), pub=\(c.publicKey), pairing=\(c.pairing), ts=\(ts), nonce=\(nonce), mac=\(mac)"
    }

    /// Exactly the scheme, then exactly the keys `client`, `pub`, `pairing`, `ts`, `nonce` and `mac` (any order), each
    /// once and well-formed; otherwise nil.
    public static func parse(_ header: String?) -> Fields? {
        guard let header, header.hasPrefix(scheme + " "), header.utf8.count <= 512 else { return nil }
        var fields: [String: String] = [:]
        for part in header.dropFirst(scheme.count + 1).split(separator: ",", omittingEmptySubsequences: false) {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1,
                                                                       omittingEmptySubsequences: false)
            guard pair.count == 2, fields[String(pair[0])] == nil else { return nil }
            fields[String(pair[0])] = String(pair[1])
        }
        guard fields.count == 6, let client = fields["client"], let pub = fields["pub"], let pairing = fields["pairing"],
              let ts = fields["ts"], let nonce = fields["nonce"], let mac = fields["mac"],
              PairingCrypto.isClientID(client), PairingCrypto.isPublicKey(pub), PairingCrypto.isDigest(pairing),
              (1...12).contains(ts.utf8.count), ts.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              Base64URL.isToken(nonce, count: 22), Base64URL.isToken(mac, count: 43) else { return nil }
        return Fields(client: client, publicKey: pub, pairing: pairing, ts: ts, nonce: nonce, mac: mac)
    }

    /// The nonce of a valid request, or why not. Checks the time window, then the MAC (in constant time). With
    /// `notBefore` (when the listener began serving), a request signed more than 1 s before it is also `.time`: it was
    /// signed while something else held the port, and is being relayed now.
    public static func checkRequest(_ f: Fields, body: Data, key: SymmetricKey, port: UInt16, now: Date,
                                    notBefore: Date? = nil) -> Result<String, Failure> {
        guard let ts = Int64(f.ts), let mac = Base64URL.decode(f.mac) else { return .failure(.format) }
        guard abs(now.timeIntervalSince1970 - TimeInterval(ts)) <= window else { return .failure(.time) }
        if let notBefore, TimeInterval(ts) < notBefore.timeIntervalSince1970.rounded(.down) - 1 { return .failure(.time) }
        let message = requestMessage(port: port, client: f.client, publicKey: f.publicKey, pairing: f.pairing, ts: f.ts,
                                     nonce: f.nonce, body: body)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: key) else { return .failure(.mac) }
        return .success(f.nonce)
    }

    /// `parse` then `checkRequest`.
    public static func checkRequest(_ authorization: String?, body: Data, key: SymmetricKey, port: UInt16, now: Date,
                                    notBefore: Date? = nil) -> Result<String, Failure> {
        guard let fields = parse(authorization) else { return .failure(.format) }
        return checkRequest(fields, body: body, key: key, port: port, now: now, notBefore: notBefore)
    }

    /// The `X-Transcribe-MAC` value for a reply to the request that carried `nonce`.
    public static func signResponse(status: Int, body: Data, nonce: String, key: SymmetricKey) -> String {
        Base64URL.encode(Data(HMAC<SHA256>.authenticationCode(
            for: responseMessage(status: status, body: body, nonce: nonce), using: key)))
    }

    public static func verifyResponse(_ mac: String?, status: Int, body: Data, nonce: String, key: SymmetricKey) -> Bool {
        guard let mac, Base64URL.isToken(mac, count: 43), let code = Base64URL.decode(mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: responseMessage(status: status, body: body, nonce: nonce),
                                                      using: key)
    }

    // MARK: - Messages

    private static func requestMessage(port: UInt16, client: String, publicKey: String, pairing: String, ts: String,
                                       nonce: String, body: Data) -> Data {
        Data("TRANSCRIBE-MCP-3 request\nPOST\n/mcp\n\(port)\n\(client)\n\(publicKey)\n\(pairing)\n\(ts)\n\(nonce)\n\(hexSHA256(body))".utf8)
    }

    private static func responseMessage(status: Int, body: Data, nonce: String) -> Data {
        Data("TRANSCRIBE-MCP-3 response\n\(nonce)\n\(status)\n\(hexSHA256(body))".utf8)
    }

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Accepts each request nonce once (§3.2). A nonce is kept for `window` seconds, which covers the ±60 s timestamp
/// window, and expired ones are pruned on every call. When `capacity` nonces are live, nothing more is admitted.
public final class ReplayGuard: Sendable {
    public enum Admission: Sendable, Equatable { case admitted, replayed, full }

    private let window: TimeInterval
    private let capacity: Int
    private let seen = Mutex<[String: Date]>([:])

    public init(window: TimeInterval = 120, capacity: Int = 10_000) {
        self.window = window; self.capacity = capacity
    }

    public func admit(_ nonce: String, at now: Date) -> Bool { check(nonce, at: now) == .admitted }

    public func check(_ nonce: String, at now: Date) -> Admission {
        seen.withLock { seen in
            let cutoff = now.addingTimeInterval(-window)
            seen = seen.filter { $0.value > cutoff }
            if seen[nonce] != nil { return .replayed }
            if seen.count >= capacity { return .full }
            seen[nonce] = now
            return .admitted
        }
    }
}
