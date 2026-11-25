import Foundation

/// Starting the app from the helper (D16). The helper implements it with NSWorkspace (`WorkspaceLauncher`); tests
/// use a fake.
public protocol AppLaunching: Sendable {
    /// False for a DEBUG helper without the fake launch, or when the enclosing app is unknown.
    var canLaunch: Bool { get }
    /// Whether any copy of Transcribe (this bundle id) is running.
    func anyCopyRunning() async -> Bool
    /// Launches the enclosing app in the background; false if that failed.
    func launch() async -> Bool
}
