import Foundation
import Synchronization

/// Whether the endpoint serves, changed at once by the app: turning the switch off clears `serving`, so in-flight
/// requests get 503 (§5).
public final class EndpointState: Sendable {
    private struct Values { var serving: Bool; var since: Date? }
    private let state: Mutex<Values>

    /// `serving` true here sets no `servingSince` (tests that serve from the start, with a fixed clock).
    public init(serving: Bool) { state = Mutex(Values(serving: serving, since: nil)) }

    public var serving: Bool { state.withLock { $0.serving } }
    /// When serving last started (set before the listener can accept anything). A request signed earlier can only
    /// have gone to whatever held the port then, so the endpoint rejects it (a squatter relaying a captured request).
    public var servingSince: Date? { state.withLock { $0.since } }
    public func set(serving: Bool, at now: Date = Date()) {
        state.withLock { $0.serving = serving; $0.since = serving ? now : nil }
    }
}

/// base64url with no padding (RFC 4648 §5).
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        guard s.utf8.allSatisfy(isAlphabet) else { return nil }
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.utf8.count % 4) % 4)
        return Data(base64Encoded: b64)
    }

    /// `^[A-Za-z0-9_-]{count}$`
    static func isToken(_ s: String, count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy(isAlphabet)
    }

    static func isAlphabet(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: true
        default: false
        }
    }

    static func random(bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return encode(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
    }
}
