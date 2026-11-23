import AppKit
import Foundation
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

    /// While sync is on, iCloud pushes tell `CKSyncEngine` to fetch (§8.4 item 9). The engine handles the pushes itself;
    /// the app only registers.
    static func registerForRemoteNotifications() {
        NSApplication.shared.registerForRemoteNotifications()
    }

    private static var activationSync: Task<Void, Never>?

    /// The Mac syncs each time the app becomes active (§8.4 item 9), after the launch's own sync start, and never
    /// twice at once.
    static func syncOnActivation(_ env: AppEnvironment) {
        guard env.isLaunched, env.settings.syncEnabled, let sync = env.sync, activationSync == nil else { return }
        let launch = env.syncLaunch
        activationSync = Task {
            await launch?.value
            await sync.syncNow()
            activationSync = nil
        }
    }
}
