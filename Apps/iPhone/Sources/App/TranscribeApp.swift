import SwiftUI
import UIKit
import TranscribeCore
import TranscribeKit

@main struct TranscribeApp: App {
    @State private var env = Composition.makeEnvironment()
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // UI tests run without UIKit animations (glass still renders).
        if LaunchConfig.current.uiTesting { UIView.setAnimationsEnabled(false) }
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .modelContainer(env.container)
        }
        .onChange(of: scenePhase) { _, p in Task { await env.onPhase(Self.appPhase(p)) } }
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
