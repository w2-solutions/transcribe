import SwiftUI
import UIKit
import TranscribeCore
import TranscribeKit

@main struct TranscribeApp: App {
    @State private var env = Composition.makeEnvironment()
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    init() {
        // UI tests run without UIKit animations (glass still renders).
        if LaunchConfig.current.uiTesting { UIView.setAnimationsEnabled(false) }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .modelContainer(env.container)
                .onChange(of: env.settings.syncEnabled, initial: true) { _, on in
                    PushDelegate.onPush = { [env] in await env.sync?.remoteChangeNotified() }
                    if on, env.sync != nil, !env.config.uiTesting { PlatformServices.registerForRemoteNotifications() }
                }
        }
        .onChange(of: scenePhase) { _, p in
            // The activity moves now, not a main-actor hop later, so a prepare stage judged in between sees it.
            let phase = Self.appPhase(p)
            env.followActivity(phase)
            Task { await env.onPhase(phase) }
        }
    }
    /// Split out of the `.onChange` closure: the inline nested ternary exceeds the type-checker's time limit.
    private static func appPhase(_ p: ScenePhase) -> AppPhase {
        switch p {
        case .active: .active
        case .background: .background
        default: .inactive
        }
    }
}
