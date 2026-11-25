import CryptoKit
import Foundation

/// The name a Claude app goes by in the Allow prompt and the Allowed apps list, and the helper's file for it. It
/// comes from the client's own initialize request (`clientInfo`), so it is only what the client claims; the code is
/// what the user checks.
public enum ClientName {
    public static let fallback = "Claude"
    public static let maxLength = 64
    /// `clientInfo.name` values of Anthropic's own clients, shown by product name.
    static let known = ["claude-code": "Claude Code", "claude-ai": "Claude Desktop"]

    /// A known product name, else `clientInfo.title`, else `clientInfo.name`, sanitised; "Claude" when none is usable.
    public static func display(clientInfo: JSONValue?) -> String {
        let name = clientInfo?["name"]?.string
        if let name, let product = known[name.lowercased()] { return product }
        for raw in [clientInfo?["title"]?.string, name] {
            if let clean = sanitized(raw) { return clean }
        }
        return fallback
    }

    /// Printable text only: control, format (bidirectional overrides among them), private-use and unassigned
    /// characters are dropped, every run of spaces and line breaks becomes one space, and the result is trimmed and
    /// cut to 64 characters. nil when nothing is left, or for raw text over 1,024 bytes.
    public static func sanitized(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 1_024 else { return nil }
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where scalar == "\t" || scalar == "\n" || scalar == "\r",
                 .spaceSeparator, .lineSeparator, .paragraphSeparator:
                pendingSpace = !out.isEmpty
            case .control, .format, .surrogate, .privateUse, .unassigned:
                continue
            default:
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(scalar)
            }
        }
        let text = String(String(out).prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The helper's file name for a client (without ".json"): the name in lowercase ASCII letters, digits and hyphens,
    /// then 8 hex digits of its hash, so names that differ only in other characters still get their own file
    /// ("Claude Code" → "claude-code-1a2b3c4d").
    public static func fileStem(_ name: String) -> String {
        var slug = ""
        for ch in name.lowercased().unicodeScalars {
            if ch.isASCII, ch.properties.isAlphabetic || ("0"..."9").contains(ch) {
                slug.unicodeScalars.append(ch)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        let hash = SHA256.hash(data: Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(slug.isEmpty ? "client" : slug)-\(hash)"
    }
}
