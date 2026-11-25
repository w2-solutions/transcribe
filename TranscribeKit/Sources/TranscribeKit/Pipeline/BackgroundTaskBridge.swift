import Foundation

public struct BackgroundToken: Sendable, Hashable { public let id: UUID; public init(id: UUID = UUID()) { self.id = id } }
public protocol BackgroundTaskBridge: Sendable {
    /// Called when a job starts. `onExpire` is called (any thread) if the system ends the time.
    func begin(recordingID: UUID, title: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken?
    func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async
    func end(_ token: BackgroundToken, success: Bool) async
    /// A short system grace period with no progress UI and no continued-processing request (the speech-model
    /// prepare): on iPhone `UIApplication.beginBackgroundTask` (about 30 s once the app leaves the screen), on the Mac
    /// a user-initiated activity. Returns nil when the system grants none. `onExpire` is called (any thread) when the
    /// system ends the time; the bridge then releases it itself. End it with `end(_:success:)`.
    func beginShortTask(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken?
}
public extension BackgroundTaskBridge {
    func beginShortTask(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? { nil }
}
public struct NoopBackgroundTaskBridge: BackgroundTaskBridge {
    public init() {}
    public func begin(recordingID: UUID, title: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? { nil }
    public func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async {}
    public func end(_ token: BackgroundToken, success: Bool) async {}
}
