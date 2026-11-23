import AppKit
import SwiftUI
import TranscribeCore
import TranscribeDesign
import TranscribeKit

@main struct TranscribeMacApp: App {
    @State private var env = Composition.makeEnvironment()
    @State private var router = Router()
    @State private var selection = MacSelection()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if LaunchConfig.current.uiTesting {
            // UI tests run without window and view animations (glass still renders).
            NSAnimationContext.current.duration = 0
            NSWindow.allowsAutomaticWindowTabbing = false
            UserDefaults.standard.set(false, forKey: "NSAutomaticWindowAnimationsEnabled")
        }
    }

    var body: some Scene {
        Window("Transcribe", id: "main") {
            MacRootView()
                .frame(minWidth: 960, minHeight: 600)
                .modifier(SceneEnvironment(env: env, router: router, selection: selection))
                .onChange(of: env.settings.syncEnabled, initial: true) { _, on in
                    if on, env.sync != nil, !env.config.uiTesting { PlatformServices.registerForRemoteNotifications() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    PlatformServices.syncOnActivation(env)
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands { MacCommands(env: env, router: router, selection: selection) }
        .onChange(of: scenePhase) { _, p in Task { await env.onPhase(Self.appPhase(p)) } }

        Window("Recording", id: "recording") {
            MacRecordingWindow()
                .modifier(SceneEnvironment(env: env, router: router, selection: selection))
        }
        .defaultSize(width: 560, height: 720)
        .windowResizability(.contentSize)
        // Never reopened at launch: the window only makes sense while a recording runs.
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsRoot()
                .frame(width: 520, height: 640)
                .modifier(SceneEnvironment(env: env, router: router, selection: selection))
        }
    }

    private static func appPhase(_ p: ScenePhase) -> AppPhase {
        switch p {
        case .active: .active
        case .background: .background
        default: .inactive
        }
    }
}

/// What every scene gets: the app environment, the router, the Mac selection, the SwiftData container, tint and
/// appearance, and (UI tests) no animations.
private struct SceneEnvironment: ViewModifier {
    let env: AppEnvironment
    let router: Router
    let selection: MacSelection

    func body(content: Content) -> some View {
        content
            .environment(env)
            .environment(router)
            .environment(selection)
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
        .environment(router)
    }
}
