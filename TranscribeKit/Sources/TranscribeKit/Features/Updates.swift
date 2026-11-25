import Foundation

/// Whether this copy of the Mac app runs the Sparkle updater (D10). Pure: the Mac app passes in what it knows, and
/// only `.on` creates the updater. Debug, fake-engine and UI-test runs never touch the network, Release included (the
/// same rule as `Composition.syncTransport`).
public enum UpdateAvailability: Sendable, Equatable {
    case on, offDebugBuild, offTestRun, offNotConfigured

    /// Debug wins, then a test run, then the configuration: `SUFeedURL` must be an http or https URL with a host, and
    /// `SUPublicEDKey` base64 of exactly 32 bytes (an Ed25519 public key).
    public static func resolve(isDebugBuild: Bool, uiTesting: Bool, useFakeEngine: Bool,
                               feedURL: String?, publicKey: String?) -> UpdateAvailability {
        if isDebugBuild { return .offDebugBuild }
        if uiTesting || useFakeEngine { return .offTestRun }
        guard let feedURL, let url = URL(string: feedURL), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host(), !host.isEmpty else { return .offNotConfigured }
        guard let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return .offNotConfigured }
        return .on
    }
}

/// The quiet "Update available" reminder (D23). Sparkle never opens its update window by itself: a scheduled check that
/// finds an update only sets `version`, and the Mac app shows it as a small control in the sidebar, "Update
/// Available…" in the app menu and on Settings → Updates. Choosing any of them brings Sparkle's window up. Nothing shows
/// during a recording. In memory only, driven by Sparkle's delegate callbacks, so it cannot outlive what Sparkle knows
/// by more than the current run.
public struct UpdateReminder: Sendable, Equatable {
    /// The user's answer in Sparkle's update window.
    public enum Choice: Sendable, Equatable {
        case install
        case skip
        /// Remind Me Later, or the window closed.
        case later
    }

    public enum Event: Sendable, Equatable {
        /// Sparkle has an update to show: from a scheduled check (only this reminder shows it) or from Check for
        /// Updates… (Sparkle's window is already up).
        case found(version: String)
        case chose(Choice)
        /// A check found nothing newer (or only a skipped version).
        case notFound
        /// Sparkle's update session finished: after a choice, an error, or "You're up to date".
        case sessionEnded
        case recordingChanged(isRecording: Bool)
    }

    /// The version of the update the user has not yet installed or skipped.
    public private(set) var version: String?
    public private(set) var isRecording = false
    /// The user chose Remind Me Later in this session: the update is still there when the session ends.
    private var keepsAfterSession = false

    public init() {}

    /// What the sidebar, the menu and Settings show: nil while there is no update, and during a recording.
    public var visibleVersion: String? { isRecording ? nil : version }

    public mutating func apply(_ event: Event) {
        switch event {
        case .found(let found):
            version = found
            keepsAfterSession = false
        case .chose(.later):
            keepsAfterSession = true
        case .chose(.install), .chose(.skip), .notFound:
            // Installing: Sparkle's own progress window takes over. Skipped: it is not offered again.
            version = nil
            keepsAfterSession = false
        case .sessionEnded:
            if !keepsAfterSession { version = nil }
            keepsAfterSession = false
        case .recordingChanged(let recording):
            isRecording = recording
        }
    }
}

/// Wording for Settings → Updates, the app menu, the sidebar reminder and the postponed-install alert (Mac only).
public enum UpdateCopy {
    /// The note under the Updates card.
    public static func note(for availability: UpdateAvailability) -> String {
        switch availability {
        case .on:
            "Transcribe asks w2solutions.ai whether a newer version exists: once a day if automatic checks are on, and whenever you choose Check for Updates. It sends no recordings, transcripts or names, only which version you have and what any web request carries, such as your Mac's internet address and language. Updates are large because the speech models are inside. One installs only when you choose, and only if it comes from W2 Solutions."
        case .offDebugBuild:
            "Updates are off in Debug builds."
        case .offTestRun:
            "Updates are off while testing."
        case .offNotConfigured:
            "This copy of Transcribe can't check for updates. Download the latest version from w2solutions.ai/transcribe."
        }
    }

    /// The app menu item and the Settings button: "Update Available…" while an update waits, else "Check for Updates…".
    /// Both bring up Sparkle's window: the waiting update, or a new check.
    public static func checkTitle(pendingVersion: String?) -> String {
        pendingVersion == nil ? "Check for Updates…" : "Update Available…"
    }

    /// The sidebar reminder, its tooltip and its accessibility label.
    public static func reminderTitle(version: String) -> String { "Update available · \(version)" }
    public static func reminderHelp(version: String) -> String {
        "Transcribe \(version) is ready to download. Click to see what's new."
    }
    public static func reminderAccessibilityLabel(version: String) -> String { "Update available: Transcribe \(version)" }
    public static let reminderAccessibilityHint = "Shows what's new and lets you install it"

    /// The alert when the user installs an update while a recording runs.
    public static let postponeTitle = "Update after this recording"
    public static let postponeText = "Transcribe will install the update and reopen when you stop recording."
}
