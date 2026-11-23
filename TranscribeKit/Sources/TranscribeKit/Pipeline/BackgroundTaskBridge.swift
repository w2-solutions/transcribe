import Foundation

public struct BackgroundToken: Sendable, Hashable { public let id: UUID; public init(id: UUID = UUID()) { self.id = id } }
public protocol BackgroundTaskBridge: Sendable {
    /// Called when a job starts. `onExpire` is called (any thread) if the system ends the time.
    func begin(recordingID: UUID, title: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken?
    func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async
    func end(_ token: BackgroundToken, success: Bool) async
}
public struct NoopBackgroundTaskBridge: BackgroundTaskBridge {
    public init() {}
    public func begin(recordingID: UUID, title: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? { nil }
    public func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async {}
    public func end(_ token: BackgroundToken, success: Bool) async {}
}
