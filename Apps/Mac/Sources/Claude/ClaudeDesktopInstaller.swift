import AppKit
import TranscribeMCP
import UniformTypeIdentifiers

/// "Add to Claude Desktop…" (§2.3): saves a `.mcpb` where the user picks (the save panel hands back a real path, which
/// `files.user-selected.read-write` lets the sandboxed app write) and opens it with Claude, which shows its Install
/// dialog. The file holds no key and no port, so nothing is copied and the file is never deleted.
@MainActor enum ClaudeDesktopInstaller {
    enum InstallError: Error { case noClaude }

    static let bundleID = "com.anthropic.claudefordesktop"

    static var claudeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// `~/Downloads` of the real home, not the container's.
    static var realDownloads: URL { URL(fileURLWithPath: HelperLocation.realHome, isDirectory: true).appending(path: "Downloads") }

    /// True when the file was saved and opened in Claude; false when the user cancelled the save panel.
    @discardableResult
    static func install(_ setup: ClientSetup) async throws -> Bool {
        guard let claudeURL else { throw InstallError.noClaude }
        let panel = NSSavePanel()
        panel.directoryURL = realDownloads
        panel.nameFieldStringValue = "Transcribe for Claude.mcpb"
        panel.allowedContentTypes = [UTType(filenameExtension: "mcpb") ?? .data]
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return false }
        try setup.mcpbArchive().write(to: url, options: .atomic)
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: claudeURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
