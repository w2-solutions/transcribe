import Foundation

/// MCP protocol versions (D2). 2025-03-26 is not offered: it requires JSON-RPC batches, which are rejected here.
public enum MCPVersion {
    public static let latest = "2025-11-25"
    public static let supported: Set<String> = ["2025-11-25", "2025-06-18"]

    /// The requested version when it is supported, otherwise the latest.
    public static func negotiate(_ requested: String?) -> String {
        guard let requested, supported.contains(requested) else { return latest }
        return requested
    }

    /// The `MCP-Protocol-Version` header check: missing is allowed, anything unsupported is not.
    public static func headerAllowed(_ v: String?) -> Bool {
        guard let v else { return true }
        return supported.contains(v)
    }
}
