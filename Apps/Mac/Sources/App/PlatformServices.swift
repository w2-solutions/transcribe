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
}
