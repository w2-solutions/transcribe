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
@MainActor @Observable
final class AppUpdater {
    let availability: UpdateAvailability
    private(set) var isStarted = false
    /// Sparkle's own `canCheckForUpdates` (false while a check or an update runs).
    private(set) var canCheckForUpdates = false
    /// Sparkle's `automaticallyChecksForUpdates`, mirrored so the switch follows the permission prompt.
    private(set) var automaticallyChecks = false

    /// The menu item and the Settings controls. Before the updater starts they stay enabled: choosing one starts it.
    var controlsEnabled: Bool { availability == .on && (!isStarted || canCheckForUpdates) }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private var wasBusy = false

    init(availability: UpdateAvailability, isBusy: @escaping @MainActor () -> Bool) {
        self.availability = availability
        self.isBusy = isBusy
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
        followBusy()
    }

    /// Calls `busyEnded()` whenever a recording stops, for the life of the app and whichever windows are open (the main
    /// window can be closed during a recording, as for `CaptureActivity`).
    private func followBusy() {
        let busy = withObservationTracking { isBusy() } onChange: { [weak self] in
            Task { @MainActor in self?.followBusy() }
        }
        if wasBusy, !busy { busyEnded() }
        wasBusy = busy
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

    /// Check for Updates… (menu and Settings). User-initiated checks are never deferred.
    func checkForUpdates() {
        guard let controller else { return }
        startIfNeeded()
        controller.checkForUpdates(nil)
    }

    /// The recording stopped: shows a scheduled update that was held back while it ran (once).
    func busyEnded() {
        guard let controller, delegate.deferral.busyEnded() else { return }
        updatesLog.info("Showing the update held back during a recording")
        controller.checkForUpdates(nil)
    }
}

/// Public fields only: availability, version strings, error domain and code.
private let updatesLog = Logger(subsystem: "ai.w2solutions.transcribe", category: "updates")

/// Sparkle's delegate: the bundled feed URL only, no permission prompt and no scheduled update alert while a recording
/// runs (D23), and an install that waits for the recording to stop.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let isBusy: @MainActor () -> Bool
    /// A scheduled update held back while recording.
    var deferral = UpdateDeferral()

    init(isBusy: @escaping @MainActor () -> Bool) {
        self.isBusy = isBusy
    }

    // MARK: SPUUpdaterDelegate

    /// The Info.plist `SUFeedURL`, the value `UpdateAvailability` checked; never one from the user defaults.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    /// Sparkle asks on the second launch that starts the updater; never in the middle of a recording (it asks at a
    /// later launch). Implementing this method replaces Sparkle's own second-launch rule, so it is repeated here:
    /// Sparkle sets `SUHasLaunchedBefore` only after asking.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore") && !isBusy()
    }

    /// Install and Relaunch during a recording: the update installs, and the app reopens, once the recording stops.
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

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updatesLog.info("No update found")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        updatesLog.error("Update stopped: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update found while recording is not shown now (Sparkle may show it "in immediate and utmost focus").
    /// No side effects here, as Sparkle asks; the deferral is recorded when Sparkle reports who shows it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        !isBusy()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        if !deferral.scheduledUpdateFound(busy: !handleShowingUpdate) {
            updatesLog.info("Update \(update.displayVersionString, privacy: .public) held back during a recording")
        }
    }

    /// The user has seen the update (a manual check brought it forward, or they chose Install, Skip or Remind Me Later):
    /// it is no longer held back, so stopping the recording does not bring it up again.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        deferral = UpdateDeferral()
    }

    /// The update session ended (installed, skipped or put off by the user): nothing is left to show.
    func standardUserDriverWillFinishUpdateSession() {
        deferral = UpdateDeferral()
    }
}
