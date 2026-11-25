import Foundation
import OSLog
import TranscribeKit
import UIKit

/// The iPhone app's platform-specific services, used by the shared `Composition`.
/// The Mac app defines its own `PlatformServices` with the same API.
@MainActor enum PlatformServices {
    static func backgroundBridge(uiTesting: Bool) -> any BackgroundTaskBridge {
        uiTesting ? NoopBackgroundTaskBridge() : ContinuedProcessingBridge()
    }

    static func deviceIdentity(uiTesting: Bool) -> any DeviceIdentity {
        uiTesting ? FixedDeviceIdentity("test-device") : KeychainDeviceIdentity()
    }

    static let platform: DevicePlatform = .iPhone

    /// The app's state now, for `AppActivity` (§ background prepare): the iPhone app is suspended in the background,
    /// so the speech-model prepare follows it. Read at launch, when `UIApplication` exists.
    static var activityPhase: (@MainActor () -> AppPhase)? {
        { UIApplication.shared.applicationState == .background ? .background : .active }
    }

    /// While sync is on, iCloud pushes tell `CKSyncEngine` to fetch (§8.4 item 9; `remote-notification` background
    /// mode). The engine handles the pushes itself; the app only registers.
    static func registerForRemoteNotifications() {
        pushLog.notice("Registering for remote notifications")
        UIApplication.shared.registerForRemoteNotifications()
    }
}

let pushLog = Logger(subsystem: "ai.w2solutions.transcribe", category: "push")

/// Logs whether push registration worked and every push that arrives, and syncs on a push. Without it a failed
/// registration is silent. Never logs the token or a push's contents.
@MainActor final class PushDelegate: NSObject, UIApplicationDelegate {
    /// Set by the app once its environment exists.
    static var onPush: (@MainActor () async -> Void)?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        pushLog.notice("Registered for remote notifications (token of \(deviceToken.count, privacy: .public) bytes)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        let e = error as NSError
        pushLog.error("Registering for remote notifications failed: \(e.domain, privacy: .public) \(e.code, privacy: .public)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        pushLog.notice("Remote notification received (iCloud: \(userInfo["ck"] != nil, privacy: .public))")
        await Self.onPush?()
        return .newData
    }
}
