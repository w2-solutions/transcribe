import AppKit
import Foundation
import OSLog
import TranscribeCore
import TranscribeKit

/// The Mac app's platform-specific services, used by the shared `Composition`.
/// Same API as the iPhone app's `PlatformServices`.
@MainActor enum PlatformServices {
    static func backgroundBridge(uiTesting: Bool) -> any BackgroundTaskBridge {
        uiTesting ? NoopBackgroundTaskBridge() : MacActivityBridge()
    }

    /// The install id lives in a file in the app's container (no Keychain prompts on a Developer ID build).
    static func deviceIdentity(uiTesting: Bool) -> any DeviceIdentity {
        if uiTesting { return FixedDeviceIdentity("test-device") }
        return FileDeviceIdentity(root: AppPaths(config: LaunchConfig.current).root)
    }

    static let platform: DevicePlatform = .mac

    /// None: a Mac app is never suspended, so `AppActivity` always reads as in front (SwiftUI reports `.background`
    /// when the windows close, and the app keeps running).
    static var activityPhase: (@MainActor () -> AppPhase)? { nil }

    /// While sync is on, iCloud pushes tell `CKSyncEngine` to fetch (§8.4 item 9). The engine handles the pushes itself;
    /// the app only registers.
    static func registerForRemoteNotifications() {
        pushLog.notice("Registering for remote notifications")
        NSApplication.shared.registerForRemoteNotifications()
    }

    /// The Mac syncs each time the app becomes active and every 60 s while it stays active, never behind other apps
    /// (§8.4 item 9; `SyncCoordinator.setForeground`), so a missed push only delays a change. A launch's own sync start
    /// is never doubled: the coordinator skips a refresh while it starts.
    static func syncOnActivation(_ env: AppEnvironment, active: Bool) {
        env.syncForeground(active)
    }
}

let pushLog = Logger(subsystem: "ai.w2solutions.transcribe", category: "push")

/// Logs whether push registration worked and every push that arrives, and syncs on a push. Without it a failed
/// registration is silent. Never logs the token or a push's contents.
@MainActor final class PushDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once its environment exists.
    static var onPush: (@MainActor () async -> Void)?

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        pushLog.notice("Registered for remote notifications (token of \(deviceToken.count, privacy: .public) bytes)")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        let e = error as NSError
        pushLog.error("Registering for remote notifications failed: \(e.domain, privacy: .public) \(e.code, privacy: .public)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        pushLog.notice("Remote notification received (iCloud: \(userInfo["ck"] != nil, privacy: .public))")
        Task { await Self.onPush?() }
    }
}
