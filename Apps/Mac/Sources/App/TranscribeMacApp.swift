import AppKit
import SwiftUI
import TranscribeCloudKit
import TranscribeCore
import TranscribeDesign
import TranscribeKit
import TranscribeMCPHost

@main struct TranscribeMacApp: App {
    @State private var env: AppEnvironment
    /// "Let Claude read transcripts": created and started here, before any window, so a background launch by the
    /// Claude helper serves straight away.
    @State private var claude: ClaudeAccess
    /// In-app updates (Sparkle): created here, started the first time the app is active with the main window, or from
    /// Settings or Check for Updates…. A background launch by the Claude helper opens the main window behind other
    /// apps but does not start it. Off in Debug, fake-engine and UI-test runs. A scheduled update never opens a window:
    /// it shows as a quiet reminder (sidebar, app menu, Settings), hidden during a recording; the updater follows the
    /// recorder itself, whichever windows are open (D23).
    @State private var updater: AppUpdater
    @State private var router: Router
    @State private var selection: MacSelection
    /// Global shortcuts and dictation (Mac only): created here, so they work with every window closed. Shortcuts are
    /// refused until `env.isLaunched`, which this init's task also starts.
    @State private var shortcuts: MacShortcuts
    /// Keeps the Mac awake while a meeting or a dictation captures audio. Started once here, not from a window.
    @State private var captureActivity: CaptureActivity
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

    init() {
        if LaunchConfig.current.uiTesting {
            // UI tests run without window and view animations (glass still renders).
            NSAnimationContext.current.duration = 0
            NSWindow.allowsAutomaticWindowTabbing = false
            UserDefaults.standard.set(false, forKey: "NSAutomaticWindowAnimationsEnabled")
        }
        let env = Composition.makeEnvironment()
        #if DEBUG
        // Session-only (never saved): UI tests bind port 0 (or a test port); the smoke script and the helper's fake
        // launch pass TRANSCRIBE_MCP=on with a throwaway port, and TRANSCRIBE_MCP_AUTO_ALLOW=on to allow every
        // pairing request at once. Release builds ignore all of these (D19).
        let options = ClaudeAccessOptions(ephemeralPort: env.config.uiTesting, startOn: env.config.mcpOn,
                                          autoAllow: env.config.mcpAutoAllow, fixedPort: env.config.mcpTestPort)
        #else
        let options = ClaudeAccessOptions()
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let claude = ClaudeAccess(container: env.container, root: env.paths.root, serverVersion: version, options: options,
            otherCopyRunning: {
                NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            })
        claude.onEnabledChange = { [env] on in env.claudeAccessOn = on }
        // A Claude app asked to read transcripts: bounce the Dock icon once (nothing happens while Transcribe is in
        // front), without bringing Transcribe forward. The request shows on the main window and in Settings → Claude.
        claude.onNewRequest = { _ = NSApplication.shared.requestUserAttention(.informationalRequest) }
        let availability = UpdateAvailability.resolve(isDebugBuild: Self.isDebugBuild,
            uiTesting: env.config.uiTesting, useFakeEngine: env.config.useFakeEngine,
            feedURL: Bundle.main.infoDictionary?["SUFeedURL"] as? String,
            publicKey: Bundle.main.infoDictionary?["SUPublicEDKey"] as? String)
        let router = Router()
        let selection = MacSelection()
        let shortcuts = MacShortcuts(env: env, router: router, selection: selection)
        let dictation = shortcuts.dictation
        // The reminder follows the recorder only; the permission prompt and a postponed install wait for a dictation
        // too.
        let updater = AppUpdater(availability: availability, isRecording: { [env] in env.recorder.isActive },
                                 isBusy: { [env] in env.recorder.isActive || dictation.isBusy })
        #if DEBUG
        // Session-only: UI tests show the "Update available" reminder with TRANSCRIBE_UPDATE_AVAILABLE=<version>
        // (fake engine and UI tests only). Never starts Sparkle or touches the network; Release builds ignore it.
        if let version = env.config.updateAvailable { updater.showReminderForTesting(version: version) }
        #endif
        env.updatesAvailable = availability == .on
        _env = State(initialValue: env)
        _claude = State(initialValue: claude)
        _updater = State(initialValue: updater)
        _router = State(initialValue: router)
        _selection = State(initialValue: selection)
        _shortcuts = State(initialValue: shortcuts)
        let captureActivity = CaptureActivity()
        captureActivity.follow { [env] in env.recorder.isActive || dictation.isBusy }
        _captureActivity = State(initialValue: captureActivity)
        Task { @MainActor in
            // After Relaunch Transcribe (the Accessibility setup): wait for the old copy to quit first, so this one
            // registers shortcuts and binds Claude's ports without meeting it.
            await AppRelauncher.waitForPreviousCopy()
            shortcuts.start()
            await claude.start()
            // Launch does not wait for a window: a shortcut works with every window closed, and the seed of the smoke
            // script and the helper's fake launch must not depend on one appearing (a background launch opens the main
            // window behind other apps, and state restoration may open none). It runs once; the main window's task
            // waits for the same run.
            await env.onLaunch()
        }
    }

    var body: some Scene {
        Window("Transcribe", id: "main") {
            MacRootView()
                .frame(minWidth: 960, minHeight: 600)
                .modifier(ClaudePairingAlert())
                .modifier(SceneEnvironment(env: env, claude: claude, updater: updater, router: router, selection: selection,
                                           shortcuts: shortcuts))
                // Only once Transcribe is in front: a background launch by the Claude helper also opens this window
                // (behind other apps), and must not show Sparkle's prompt or start a scheduled check (D11). The
                // activation below starts it otherwise.
                .task { if NSApp.isActive { updater.startIfNeeded() } }
                #if DEBUG
                // `-seedCloudSchema`: complete the Development iCloud schema before a deploy (CloudSchemaSeeder).
                .task {
                    if ProcessInfo.processInfo.arguments.contains("-seedCloudSchema") { await CloudSchemaSeeder.seed() }
                }
                #endif
                .onChange(of: env.settings.syncEnabled, initial: true) { _, on in
                    PushDelegate.onPush = { [env] in await env.sync?.remoteChangeNotified() }
                    if on, env.sync != nil, !env.config.uiTesting { PlatformServices.registerForRemoteNotifications() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    PlatformServices.syncOnActivation(env, active: true)
                    updater.startIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    PlatformServices.syncOnActivation(env, active: false)
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            MacCommands(env: env, router: router, selection: selection, updater: updater, shortcuts: shortcuts)
            #if DEBUG
            if shortcuts.availability == .simulated { ShortcutSimulationCommands(center: shortcuts.center) }
            #endif
        }
        .onChange(of: scenePhase) { _, p in Task { await env.onPhase(Self.appPhase(p)) } }

        Window("Recording", id: "recording") {
            MacRecordingWindow()
                .modifier(SceneEnvironment(env: env, claude: claude, updater: updater, router: router, selection: selection,
                                           shortcuts: shortcuts))
                #if DEBUG
                // `-seedCloudSchema`: complete the Development iCloud schema before a deploy (CloudSchemaSeeder).
                .task {
                    if ProcessInfo.processInfo.arguments.contains("-seedCloudSchema") { await CloudSchemaSeeder.seed() }
                }
                #endif
        }
        .defaultSize(width: 560, height: 720)
        .windowResizability(.contentSize)
        // Never reopened at launch: the window only makes sense while a recording runs.
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsRoot()
                .frame(width: 520, height: 640)
                .modifier(SceneEnvironment(env: env, claude: claude, updater: updater, router: router, selection: selection,
                                           shortcuts: shortcuts))
                .task { updater.startIfNeeded() }
        }
    }

    /// Debug builds never run the updater, whatever their Info.plist says (D10).
    private static let isDebugBuild: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    private static func appPhase(_ p: ScenePhase) -> AppPhase {
        switch p {
        case .active: .active
        case .background: .background
        default: .inactive
        }
    }
}

/// What every scene gets: the app environment, Claude access, the updater, the router, the Mac selection, the
/// shortcuts and dictation services, the SwiftData container, tint and appearance, and (UI tests) no animations.
private struct SceneEnvironment: ViewModifier {
    let env: AppEnvironment
    let claude: ClaudeAccess
    let updater: AppUpdater
    let router: Router
    let selection: MacSelection
    let shortcuts: MacShortcuts

    func body(content: Content) -> some View {
        content
            .environment(env)
            .environment(claude)
            .environment(updater)
            .environment(router)
            .environment(selection)
            .environment(shortcuts)
            .environment(shortcuts.center)
            .environment(shortcuts.settings)
            .environment(shortcuts.permissions)
            .environment(shortcuts.dictation)
            .environment(shortcuts.opener)
            .modelContainer(env.container)
            .tint(DS.Colour.accent)
            .preferredColorScheme(env.settings.appearance == .light ? .light : env.settings.appearance == .dark ? .dark : nil)
            .transaction { if env.config.uiTesting { $0.disablesAnimations = true } }
    }
}

/// The Settings window (⌘,): the shared Settings screen in its own navigation stack, with its own router so its
/// pushes (Speech models, Language, Acknowledgements) never move the main window.
private struct MacSettingsRoot: View {
    @State private var router = Router()

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            SettingsView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .transcript(let id): TranscriptView(recordingID: id)
                    case .voices: VoicesView()
                    case .voice(let id): VoiceDetailView(profileID: id)
                    case .settings: SettingsView()
                    case .modelSettings: ModelSettingsView()
                    case .language: LanguagePickerView()
                    case .attributions: AttributionsView()
                    }
                }
        }
        // Voices and transcripts reached from here name speakers through this router's sheet.
        .sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .nameSpeaker(let ctx):
                NameSpeakerSheet(context: ctx).sheetSizing(minWidth: 480, minHeight: 560)
            }
        }
        // The root is Settings: "Speaker settings" in Voices goes back to it instead of stacking a second one.
        .onChange(of: router.path) { _, path in
            if path.last == .settings { router.path = [] }
        }
        .environment(router)
    }
}
