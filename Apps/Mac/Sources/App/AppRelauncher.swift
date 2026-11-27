import AppKit
import os

/// Quits Transcribe and opens it again: the guided Accessibility setup's Relaunch Transcribe, for when macOS applies a
/// new grant only to a fresh process.
///
/// The new copy is opened first (a sandboxed app cannot start anything after it has quit), with
/// `-relaunchedAfter <pid>`. That copy waits for this one to exit (`waitForPreviousCopy`) before it registers
/// shortcuts, starts Claude access and runs launch, so it never sees "another copy is running" and never meets the
/// old copy's ports or hot keys. The launch arguments and `TRANSCRIBE_*` environment are passed on, so a test session
/// stays the same kind of session.
enum AppRelauncher {
    static let waitArgument = "-relaunchedAfter"
    /// How long the new copy waits for the old one before carrying on anyway.
    static let waitLimit: Duration = .seconds(10)
    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "shortcuts")

    @MainActor static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = forwardedArguments() + [waitArgument, String(ProcessInfo.processInfo.processIdentifier)]
        configuration.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("TRANSCRIBE_") }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    log.error("Relaunch failed: \(String(describing: type(of: error)), privacy: .public)")
                    return
                }
                log.info("Relaunching")
                NSApp.terminate(nil)
            }
        }
    }

    /// In the new copy: returns once the copy that relaunched it has exited (at most `waitLimit`). Returns at once
    /// for a normal launch.
    static func waitForPreviousCopy() async {
        guard let pid = previousPID() else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + waitLimit
        while NSRunningApplication(processIdentifier: pid) != nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func previousPID() -> pid_t? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: waitArgument), index + 1 < arguments.count else { return nil }
        return pid_t(arguments[index + 1])
    }

    /// This launch's arguments without the program path and without an earlier relaunch's pair.
    private static func forwardedArguments() -> [String] {
        var result: [String] = []
        var skipNext = false
        for argument in ProcessInfo.processInfo.arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if argument == waitArgument { skipNext = true; continue }
            result.append(argument)
        }
        return result
    }
}
