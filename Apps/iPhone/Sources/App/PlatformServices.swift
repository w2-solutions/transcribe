import Foundation
import TranscribeKit

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
}
