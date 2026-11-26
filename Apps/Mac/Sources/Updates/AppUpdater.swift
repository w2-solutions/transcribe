import AppKit
import Observation
import os
import Sparkle
import TranscribeKit

/// In-app updates (Sparkle; the only file that imports it). The updater exists only when `UpdateAvailability` is `.on`
/// (never in Debug, fake-engine or UI-test runs), and starts only when something in the foreground needs it: the app
/// becoming active with the main window, the Settings window, or Check for Updates… (D11). A background launch by the
/// Claude helper opens the main window behind other apps, but the app is not active then, so no permission prompt or
/// scheduled check appears until the user brings Transcribe to the front.
///
/// Sparkle never opens its update window by itself (D23): an update found by a scheduled check becomes a quiet reminder
/// (`UpdateReminder`: the sidebar control, "Update Available…" in the app menu and Settings), and choosing it brings
/// Sparkle's window up. Check for Updates… opens the window at once, as before.
@MainActor @Observable
final class AppUpdater {
    let availability: UpdateAvailability
    private(set) var isStarted = false
    /// Sparkle's own `canCheckForUpdates` (false while a check or an update runs).
    private(set) var canCheckForUpdates = false
    /// Sparkle's `automaticallyChecksForUpdates`, mirrored so the switch follows the permission prompt.
    private(set) var automaticallyChecks = false
    /// The update waiting for the user, from Sparkle's delegate callbacks (and the recorder).
    private(set) var reminder = UpdateReminder()

    /// The version the sidebar, the app menu and Settings show as waiting; nil when none, and during a recording.
    var pendingVersion: String? { reminder.visibleVersion }

    /// The menu item and the Settings controls. Before the updater starts they stay enabled: choosing one starts it.
    var controlsEnabled: Bool { availability == .on && (!isStarted || canCheckForUpdates) }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let isRecording: @MainActor () -> Bool

    /// `isRecording` (a meeting recording) hides the reminder; `isBusy` (a recording or a dictation) holds back
    /// Sparkle's permission prompt and a postponed install. A dictation is short and happens over other apps, so the
    /// reminder must not flicker with every one.
    init(availability: UpdateAvailability, isRecording: @escaping @MainActor () -> Bool,
         isBusy: @escaping @MainActor () -> Bool) {
        self.availability = availability
        self.isRecording = isRecording
        let delegate = UpdaterDelegate(isBusy: isBusy)
        self.delegate = delegate
        #if !DEBUG
        controller = availability == .on
            ? SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
            : nil
        #else
        controller = nil
        #endif
        updatesLog.info("Updates: \(String(describing: availability), privacy: .public)")
        delegate.onReminderEvent = { [weak self] event in self?.reminder.apply(event) }
        followRecording()
        guard let updater = controller?.updater else { return }
        // Sparkle's updater is main-actor bound, and so are its KVO notifications.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecks = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    /// Hides the reminder while a recording runs and shows it again when it stops, for the life of the app and
    /// whichever windows are open (the main window can be closed during a recording, as for `CaptureActivity`).
    private func followRecording() {
        let recording = withObservationTracking { isRecording() } onChange: { [weak self] in
            Task { @MainActor in self?.followRecording() }
        }
        if recording != reminder.isRecording { reminder.apply(.recordingChanged(isRecording: recording)) }
    }

    /// Starts the updater once (a no-op unless updates are on). A feed URL an older build may have saved in the user
    /// defaults is cleared, so the bundled one is the only feed (D12).
    func startIfNeeded() {
        guard let controller, !isStarted else { return }
        isStarted = true
        controller.startUpdater()
        controller.updater.clearFeedURLFromUserDefaults()
    }

    /// The Settings switch: written only when the user flips it, never mirrored into our own settings.
    func setAutomaticallyChecks(_ on: Bool) {
        guard let controller else { return }
        startIfNeeded()
        controller.updater.automaticallyChecksForUpdates = on
    }

    /// Check for Updates… and Update Available… (menu, Settings and the sidebar reminder). While Sparkle holds a
    /// scheduled update back as a reminder, `-[SPUUpdater checkForUpdates]` brings that update's window into focus
    /// (`showUpdateInFocus`) instead of checking again; otherwise it is a user-initiated check, whose window Sparkle shows
    /// at once, recording or not.
    func checkForUpdates() {
        guard let controller else { return }
        startIfNeeded()
        controller.checkForUpdates(nil)
    }

    #if DEBUG
    /// UI tests (`TRANSCRIBE_UPDATE_AVAILABLE`): the reminder as if a scheduled check had found `version`. Debug builds
    /// have no Sparkle controller, so nothing is checked or downloaded and choosing the reminder does nothing.
    func showReminderForTesting(version: String) {
        reminder.apply(.found(version: version))
    }
    #endif
}

/// Public fields only: availability, version strings, error domain and code.
private let updatesLog = Logger(subsystem: "ai.w2solutions.transcribe", category: "updates")

/// Sparkle's delegate: the bundled feed URL only, no permission prompt while a recording runs, never a scheduled update
/// window (gentle reminders: the app shows `UpdateReminder` instead, D23), and an install that waits for the recording
/// to stop. It only reports Sparkle's callbacks as `UpdateReminder.Event`s; the decisions are in `UpdateReminder`.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let isBusy: @MainActor () -> Bool
    /// Set by `AppUpdater`.
    var onReminderEvent: (@MainActor (UpdateReminder.Event) -> Void)?

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
    }

    // MARK: SPUUpdaterDelegate

    /// The Info.plist `SUFeedURL`, the value `UpdateAvailability` checked; never one from the user defaults.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    /// Sparkle asks on the second launch that starts the updater; never in the middle of a recording or a dictation (it
    /// asks at a later launch). Implementing this method replaces Sparkle's own second-launch rule, so it is repeated here:
    /// Sparkle sets `SUHasLaunchedBefore` only after asking.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore") && !isBusy()
    }

    /// Install and Relaunch during a recording (or a dictation): the update installs, and the app reopens, once it
    /// stops.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        updatesLog.info("Install postponed until the recording stops")
        Task { @MainActor [isBusy] in
            let alert = NSAlert()
            alert.messageText = UpdateCopy.postponeTitle
            alert.informativeText = UpdateCopy.postponeText
            alert.addButton(withTitle: "OK")
            alert.runModal()
            while isBusy() {
                try? await Task.sleep(for: .seconds(2))
            }
            updatesLog.info("Recording stopped: installing the update")
            installHandler()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updatesLog.info("Update found: \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    /// Also after a scheduled check, which shows nothing then: an earlier reminder is cleared (the version was skipped,
    /// or withdrawn from the feed).
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updatesLog.info("No update found")
        onReminderEvent?(.notFound)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        updatesLog.error("Update stopped: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
    }

    /// Install Update, Skip This Version, or Remind Me Later (closing the window counts as that). Sparkle calls this
    /// before it ends the session, so a Remind Me Later keeps the reminder through `standardUserDriverWillFinishUpdateSession`.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        let mapped: UpdateReminder.Choice
        switch choice {
        case .install: mapped = .install
        case .skip: mapped = .skip
        case .dismiss: mapped = .later
        @unknown default: mapped = .later
        }
        updatesLog.info("Update \(updateItem.displayVersionString, privacy: .public): \(String(describing: mapped), privacy: .public)")
        onReminderEvent?(.chose(mapped))
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never: the app shows a scheduled update as a quiet reminder instead of Sparkle's window, even when Sparkle would
    /// show it "in immediate and utmost focus" (just after launch, or after the Mac sat idle), and during a recording.
    /// Sparkle keeps the update's window ready but hidden until `checkForUpdates()` brings it into focus. No side
    /// effects here, as Sparkle asks; the reminder is set in `standardUserDriverWillHandleShowingUpdate`.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    /// Every update Sparkle is about to show: scheduled (only the reminder shows it, `handleShowingUpdate` false) or
    /// user-initiated (Sparkle's window is up; the reminder stays if the user chooses Remind Me Later). Not called when
    /// an update already shown is brought back into focus.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        let version = update.displayVersionString
        updatesLog.info("Update \(version, privacy: .public) found (\(state.userInitiated ? "user-initiated" : "scheduled", privacy: .public); window shown by Sparkle: \(handleShowingUpdate, privacy: .public))")
        onReminderEvent?(.found(version: version))
    }

    /// The user brought the update's window into focus or answered it. The reminder stays until the answer
    /// (`updater(_:userDidMake:forUpdate:state:)`): the window may be closed again without one.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updatesLog.info("Update \(update.displayVersionString, privacy: .public) seen")
    }

    /// The update session is ending (after a choice, an error, or "You're up to date"): the reminder goes, unless the
    /// user chose Remind Me Later in it.
    func standardUserDriverWillFinishUpdateSession() {
        onReminderEvent?(.sessionEnded)
    }
}
