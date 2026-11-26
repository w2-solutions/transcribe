import AppKit
import Observation
import SwiftUI
import TranscribeCore
import TranscribeKit

/// Global shortcuts and dictation, wired together once in `App.init` so they work before any window appears and with
/// every window closed (a background launch by the Claude helper runs `App.init` too). Holds the services the scenes
/// read from the environment, and the app-wide followers that are not a window's business: the Esc source following
/// the dictation, the HUD, the Dock badge during a recording, and sleep and lock.
@MainActor @Observable
final class MacShortcuts {
    let availability: ShortcutAvailability
    let settings: ShortcutSettings
    let permissions: ShortcutPermissions
    let dictation: DictationController
    let hud: HUDPresenter
    let opener: MacWindowOpener
    let center: ShortcutCenter
    /// Only in a simulated run: what the last dictation delivered (DEBUG's hidden accessibility element).
    let simulatedOutput: SimulatedOutput?
    /// Where dictation text goes: `PasteService`, or `SimulatedOutput` in a simulated run. Copy Last Dictation uses it
    /// too.
    @ObservationIgnored let output: any DictationOutput
    @ObservationIgnored private let meeting: MeetingShortcut
    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var started = false

    /// Set when something asks for Settings → Shortcuts (the HUD's "allow Accessibility" click, the sidebar note, the
    /// Shortcuts… menu item); the section scrolls itself into view and clears it.
    var revealSettingsSection = false

    /// A meeting recording or a dictation is capturing: Relaunch Transcribe waits for it to finish.
    var isCapturing: Bool { env.recorder.isActive || dictation.isBusy }

    /// The sidebar's quiet note (`ShortcutPermissionNote` has the rule).
    var showsPermissionNote: Bool {
        ShortcutPermissionNote.shows(availability: availability, introSeen: settings.introSeen,
                                     statuses: Array(center.status.values), bindings: settings.bindings,
                                     postEventAllowed: permissions.postEventAllowed)
    }

    init(env: AppEnvironment, router: Router, selection: MacSelection) {
        self.env = env
        #if DEBUG
        let simulation = env.config.shortcutSimulation
        #else
        // Release builds never simulate (the menu and the test pasteboard are DEBUG hooks).
        let simulation = false
        #endif
        let availability = ShortcutAvailability.resolve(uiTesting: env.config.uiTesting,
                                                        useFakeEngine: env.config.useFakeEngine, simulation: simulation)
        self.availability = availability
        let settings = ShortcutSettings(defaults: env.settings.userDefaults)
        self.settings = settings
        let permissions = ShortcutPermissions(fixed: availability != .live)
        self.permissions = permissions
        let simulated = availability == .simulated ? SimulatedOutput() : nil
        simulatedOutput = simulated
        let output: any DictationOutput = simulated ?? PasteService(permissions: permissions)
        self.output = output
        let dictation = DictationController(engine: env.engine, coordinator: env.coordinator, models: env.models,
                                            settings: env.settings, paths: env.paths, gate: env.captureGate,
                                            output: output, isMeetingActive: { [env] in env.recorder.isActive })
        self.dictation = dictation
        let hud = HUDPresenter()
        self.hud = hud
        let opener = MacWindowOpener()
        self.opener = opener
        let meeting = MeetingShortcut(env: env, router: router, selection: selection, opener: opener,
                                      dictation: dictation, hud: hud, settings: settings)
        self.meeting = meeting
        let otherCopyRunning: @MainActor () -> Bool = {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        }
        // Launch keeps recent dictation files while another copy runs: it shares the container and may be dictating.
        env.otherCopyRunning = otherCopyRunning
        center = ShortcutCenter(
            settings: settings, permissions: permissions, availability: availability,
            isLaunched: { [env] in env.isLaunched },
            otherCopyRunning: otherCopyRunning,
            onCommand: { command in
                switch command {
                case .toggleMeeting: meeting.toggle()
                case .holdBegan: dictation.handle(.holdPressed)
                case .holdEnded: dictation.handle(.holdReleased)
                case .toggleDictation: dictation.handle(.togglePressed)
                case .cancelDictation: dictation.handle(.escape)
                }
            },
            onNotReady: { hud.show(DictationHUD.notReady) })

        hud.bindings = { settings.bindings }
        hud.setContent { [env] in
            AnyView(HUDView(presenter: hud, dictation: dictation, models: env.models, settings: settings))
        }
        hud.onAction = { [weak self] action in
            switch action {
            case .openMicSettings: permissions.openPane(.microphone)
            case .openApp: opener.showApp()
            case .openShortcutSettings: self?.showShortcutSettings()
            }
        }
    }

    /// Brings Transcribe forward with Settings open at Shortcuts. With no window's action yet, the main window opens
    /// instead (`MacWindowOpener.showSettings`).
    func showShortcutSettings() {
        revealSettingsSection = true
        opener.showSettings()
    }

    /// Registers the shortcuts and starts the followers. Once, from `App.init`'s task.
    func start() {
        guard !started else { return }
        started = true
        center.start()
        hud.followDictation(dictation)
        followEscape()
        followDockBadge()
        observeSleepAndLock()
    }

    /// The one Esc source is armed only while a dictation can be cancelled.
    private func followEscape() {
        let accepts = withObservationTracking { dictation.acceptsEscape } onChange: { [weak self] in
            Task { @MainActor in self?.followEscape() }
        }
        center.setEscapeArmed(accepts)
    }

    /// "●" on the Dock icon while a meeting records: a recording started from another app has no window, and the HUD
    /// only lasts a moment.
    private func followDockBadge() {
        let active = withObservationTracking { env.recorder.isActive } onChange: { [weak self] in
            Task { @MainActor in self?.followDockBadge() }
        }
        let label = active ? "●" : ""
        if NSApplication.shared.dockTile.badgeLabel ?? "" != label { NSApplication.shared.dockTile.badgeLabel = label }
    }

    /// The Mac going to sleep, the screen locking, or the user switching to another account: a dictation in progress
    /// stops and its text is only copied (pasting into a locked screen or another session is never right), and keys
    /// held now are forgotten. Sleep and session changes come from the workspace's notification centre, the screen
    /// lock from the distributed one.
    private func observeSleepAndLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        observers.append((distributed, token))
    }

    private func systemWillSleep() {
        dictation.handle(.systemSleep)
        center.systemWillSleep()
    }

    /// Edit → Copy Last Dictation: the same markers as a dictation's own copy (this Mac only, transient).
    func copyLastDictation() {
        guard let text = dictation.lastText else { return }
        _ = output.copy(text, reason: .notPasting)
    }
}
