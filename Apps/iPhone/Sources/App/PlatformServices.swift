import Foundation
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

    /// While sync is on, iCloud pushes tell `CKSyncEngine` to fetch (§8.4 item 9; `remote-notification` background
    /// mode). The engine handles the pushes itself; the app only registers.
    static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
