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

/// Holds back a scheduled update alert while a recording runs (D23). Sparkle asks before showing a scheduled update;
/// while busy the answer is "not now", and the alert is shown once the recording stops. User-initiated checks never
/// come through here.
public struct UpdateDeferral: Sendable, Equatable {
    public private(set) var pending: Bool = false

    public init() {}

    /// true: let Sparkle show the scheduled update now; false: deferred until busyEnded().
    public mutating func scheduledUpdateFound(busy: Bool) -> Bool {
        if busy { pending = true }
        return !busy
    }

    /// true exactly once after a deferral: present it now.
    public mutating func busyEnded() -> Bool {
        defer { pending = false }
        return pending
    }
}

/// Wording for Settings → Updates and the postponed-install alert (Mac only).
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

    /// The alert when the user installs an update while a recording runs.
    public static let postponeTitle = "Update after this recording"
    public static let postponeText = "Transcribe will install the update and reopen when you stop recording."
}
