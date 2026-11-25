import Foundation

/// The helper's environment (§6). Claude's config sets none of these: the helper finds the app on the well-known
/// ports and keeps its pairing in its own folder. `TRANSCRIBE_MCP_PORT` (one port instead of the well-known ones) and
/// `TRANSCRIBE_MCP_STATE_DIR` (another state folder; an absolute path) are for tests and the smoke script;
/// `TRANSCRIBE_MCP_DEBUG_LAUNCH=fake` matters only to a DEBUG helper. Malformed values read as unset.
public struct HelperEnvironment: Sendable {
    public static let portKey = "TRANSCRIBE_MCP_PORT"
    public static let stateDirectoryKey = "TRANSCRIBE_MCP_STATE_DIR"
    public static let debugLaunchKey = "TRANSCRIBE_MCP_DEBUG_LAUNCH"

    public let port: UInt16?
    public let stateDirectory: String?
    public let debugLaunch: Bool

    public init(_ env: [String: String]) {
        let digits = env[Self.portKey].flatMap { $0.utf8.count <= 5 && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } ? $0 : nil }
        port = digits.flatMap { UInt16($0) }.flatMap { $0 >= 1 ? $0 : nil }
        stateDirectory = env[Self.stateDirectoryKey].flatMap { $0.hasPrefix("/") && !$0.contains("\0") ? $0 : nil }
        debugLaunch = env[Self.debugLaunchKey] == "fake"
    }

    /// The ports to try, in order.
    public var ports: [UInt16] { port.map { [$0] } ?? WellKnownPorts.all }
}

/// The app the helper sits in: `…/X.app/Contents/Helpers/transcribe-mcp` maps to `…/X.app`, anything else to nil.
public enum EnclosingApp {
    public static func url(forHelper exe: URL) -> URL? {
        let parts = exe.standardizedFileURL.pathComponents
        guard parts.count >= 5, parts[parts.count - 1] == "transcribe-mcp", parts[parts.count - 2] == "Helpers",
              parts[parts.count - 3] == "Contents", parts[parts.count - 4].hasSuffix(".app"),
              parts[parts.count - 4].count > 4 else { return nil }
        return exe.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
