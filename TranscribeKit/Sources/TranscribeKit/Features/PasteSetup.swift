import Foundation

/// The guided setup for pasting dictation (Settings → Shortcuts on the Mac): what the guide shows while the user turns
/// Transcribe on under System Settings › Privacy & Security › Accessibility.
///
/// macOS often does not pass a new Accessibility grant to a process that is already running (Apple DTS: "accept the
/// quit and relaunch"), so a user can switch Transcribe on and still see "not allowed". The guide therefore watches for
/// the grant by itself (`pollInterval`), and once the user has come back to Transcribe from System Settings and the
/// grant still has not shown for `relaunchHintDelay`, it offers Relaunch Transcribe as well as opening the pane again.
public struct PasteSetup: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Not allowed and the guide has not been started: the three steps with Open Accessibility Settings.
        case notStarted
        /// System Settings was opened from the guide; waiting for the switch ("Waiting for Accessibility…").
        case waiting
        /// The user came back and macOS still says no: they may have turned it on already, so offer a relaunch.
        case offerRelaunch
        /// Pasting works.
        case allowed
    }

    /// How often the grant is read while the guide waits (cheap; only while waiting, and stops once allowed).
    public static let pollInterval: Duration = .seconds(1)
    /// How long after the user comes back before Relaunch is offered: a grant that reaches the running process shows
    /// within a poll or two.
    public static let relaunchHintDelay: TimeInterval = 2
    /// The guide stops polling after this long without a grant (the steps stay; opening the pane again restarts it).
    public static let pollLimit: TimeInterval = 300

    public private(set) var openedAt: Date?
    public private(set) var returnedAt: Date?

    public init() {}

    /// The user opened System Settings from the guide (again): wait afresh.
    public mutating func openedSettings(now: Date) {
        openedAt = now
        returnedAt = nil
    }

    /// Transcribe became the active app. Counts only after the guide opened System Settings.
    public mutating func appBecameActive(now: Date) {
        guard let openedAt, now >= openedAt, returnedAt == nil else { return }
        returnedAt = now
    }

    public func stage(allowed: Bool, now: Date) -> Stage {
        if allowed { return .allowed }
        guard openedAt != nil else { return .notStarted }
        if let returnedAt, now.timeIntervalSince(returnedAt) >= Self.relaunchHintDelay { return .offerRelaunch }
        return .waiting
    }

    /// Whether the grant should still be polled: only while the guide waits, and not for ever.
    public func shouldPoll(allowed: Bool, now: Date) -> Bool {
        guard !allowed, let openedAt else { return false }
        return now.timeIntervalSince(openedAt) < Self.pollLimit
    }
}

/// The guide's wording (Settings → Shortcuts).
public enum PasteSetupCopy {
    public static let title = "Turn on pasting"
    public static let intro = "So dictation can paste where you're typing, macOS needs you to allow Transcribe under Accessibility. It's one switch."
    public static let step1 = "Open Accessibility settings."
    public static let step2 = "Turn on Transcribe in the list. If it isn't there, click +, or drag Transcribe into the list."
    public static let step3 = "Come back here. This page updates by itself."
    public static let openSettings = "Open Accessibility Settings"
    public static let openSettingsAgain = "Open Settings Again"
    public static let showInFinder = "Show Transcribe in Finder"
    public static let waiting = "Waiting for you to turn on Transcribe…"
    public static let relaunchHint = "Turned it on already? macOS sometimes applies it only after Transcribe restarts."
    public static let relaunch = "Relaunch Transcribe"
    public static let relaunchBusy = "Finish the recording or dictation first, then relaunch."

    /// Shown once pasting works, naming the hold shortcut when it is on.
    public static func done(holdShortcut: String?) -> String {
        if let holdShortcut { return "Pasting is on. Try it: in any text field, hold \(holdShortcut), speak, and let go." }
        return "Pasting is on."
    }
}
