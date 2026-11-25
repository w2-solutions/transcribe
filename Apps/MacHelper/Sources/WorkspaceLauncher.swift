import AppKit
import TranscribeMCP

/// Starts the app this helper sits in (D16): by its path, never by bundle id (spike C), in the background without
/// taking focus. A DEBUG helper never launches, except with `TRANSCRIBE_MCP_DEBUG_LAUNCH=fake`, which starts the
/// fake engine with Claude access on for that session, on the helper's test port if it has one, and every pairing
/// request allowed at once, so a Debug copy never opens the real library and no one has to click Allow.
struct WorkspaceLauncher: AppLaunching {
    let appURL: URL?
    let bundleID: String
    let env: HelperEnvironment

    init(appURL: URL?, bundleID: String, env: HelperEnvironment) {
        self.appURL = appURL; self.bundleID = bundleID; self.env = env
    }

    var canLaunch: Bool {
        #if DEBUG
        appURL != nil && env.debugLaunch
        #else
        appURL != nil
        #endif
    }

    func anyCopyRunning() async -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func launch() async -> Bool {
        guard let appURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        #if DEBUG
        if env.debugLaunch {
            configuration.arguments = ["-useFakeEngine"]
            var environment = ["TRANSCRIBE_MCP": "on", "TRANSCRIBE_MCP_AUTO_ALLOW": "on"]
            if let port = env.port { environment["TRANSCRIBE_MCP_TEST_PORT"] = String(port) }
            configuration.environment = environment
        }
        #endif
        FileHandle.standardError.write(Data("transcribe-mcp: launching Transcribe\n".utf8))
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            FileHandle.standardError.write(Data("transcribe-mcp: launch failed\n".utf8))
            return false
        }
    }
}
