import Foundation

/// What Settings → Claude hands to Claude Code and Claude Desktop (§2.3): the one-line `claude mcp add` command, the
/// inner `"transcribe"` entry for `claude_desktop_config.json`, and the `.mcpb` bundle. None of them holds a key, a
/// port or any environment: the helper finds the app on its well-known ports, and each Claude app is allowed once in
/// Transcribe.
public struct ClientSetup: Sendable, Equatable {
    public static let serverName = "transcribe"
    public static let readme = "Connects Claude to the Transcribe app. The server is the transcribe-mcp helper inside Transcribe.app; this bundle contains no code or keys."

    public let helperPath: String
    /// The `.mcpb` version: the app's version when it reads as x.y.z, else 1.0.0.
    public let version: String

    public init(helperPath: String, appVersion: String) {
        self.helperPath = helperPath
        version = Self.semver(appVersion) ?? "1.0.0"
    }

    /// One line, no trailing newline. It removes any earlier user-scope entry first, so pasting it again (after the
    /// app moved, say) replaces the old setup.
    public var claudeCodeCommand: String {
        "claude mcp remove --scope user \(Self.serverName) >/dev/null 2>&1; claude mcp add --scope user --transport stdio \(Self.serverName) -- \(Self.shellQuoted(helperPath))"
    }

    /// The inner entry only, to paste inside `"mcpServers": { … }`.
    public var desktopConfigEntry: String {
        """
        "\(Self.serverName)": {
          "command": \(Self.json(helperPath)),
          "args": []
        }
        """
    }

    /// The `.mcpb` manifest (manifest_version 0.3): the helper by absolute path, no `env` and no `user_config`.
    public var mcpbManifest: JSONValue {
        [
            "manifest_version": "0.3",
            "name": .string(Self.serverName),
            "display_name": "Transcribe",
            "version": .string(version),
            "description": "Read your Transcribe recordings: transcripts with times and speaker names. Read-only.",
            "author": ["name": "W2 Solutions"],
            "server": [
                "type": "binary",
                "entry_point": "README.md",
                "mcp_config": [
                    "command": .string(helperPath),
                    "args": [],
                ],
            ],
            "tools": .array(ToolCatalog.manifestEntries.map { ["name": .string($0.name), "description": .string($0.description)] }),
            "compatibility": ["platforms": ["darwin"]],
        ]
    }

    /// The `.mcpb` file: a ZIP of `manifest.json` and `README.md`, stored uncompressed. No code, no key.
    public func mcpbArchive(date: Date = Date()) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = (try? encoder.encode(mcpbManifest)) ?? mcpbManifest.encoded()
        return ZipWriter.stored([("manifest.json", manifest), ("README.md", Data((Self.readme + "\n").utf8))], date: date)
    }

    /// Single-quoted for zsh and bash, with `'` written as `'\''`.
    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// A JSON string literal, quotes included.
    static func json(_ s: String) -> String { String(decoding: JSONValue.string(s).encoded(), as: UTF8.self) }

    /// "0.1" → "0.1.0", "0.1.1" → "0.1.1"; anything else → nil.
    static func semver(_ s: String) -> String? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return (parts.map(String.init) + Array(repeating: "0", count: 3 - parts.count)).joined(separator: ".")
    }
}

/// Why this copy of the app cannot be set up for Claude (§2.1).
public enum HelperProblem: Sendable, Equatable {
    /// `Contents/Helpers/transcribe-mcp` is missing or not executable.
    case missing
    /// The app runs from somewhere that moves or vanishes (a disk image, App Translocation, DerivedData), so a
    /// setup pointing at its helper would break.
    case notInApplications

    /// Fine only under `/Applications/` or `<home>/Applications/`. `homeDirectory` is the real home (from
    /// `getpwuid`), never the sandbox container.
    public static func helperProblem(path: String, isExecutable: Bool, homeDirectory: String) -> HelperProblem? {
        guard isExecutable else { return .missing }
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if path.hasPrefix("/Applications/") || (!home.isEmpty && path.hasPrefix(home + "/Applications/")) { return nil }
        return .notInApplications
    }
}
