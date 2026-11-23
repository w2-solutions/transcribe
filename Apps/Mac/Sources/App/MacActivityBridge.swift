import Foundation
import Synchronization
import TranscribeKit

/// Keeps the Mac awake while a recording is processed: holds a user-initiated `ProcessInfo` activity (idle system
/// sleep disabled) from `begin` to `end`. The Mac never takes the time away, so `onExpire` is never called.
nonisolated final class MacActivityBridge: BackgroundTaskBridge {
    /// `beginActivity`'s opaque token, which is only handed back to `endActivity`.
    private struct Activity: @unchecked Sendable { let object: NSObjectProtocol }
    private let activities = Mutex<[BackgroundToken: Activity]>([:])

    init() {}

    func begin(recordingID: UUID, title: String,
               onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? {
        let token = BackgroundToken()
        let activity = Activity(object: ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Processing \(title)"))
        activities.withLock { $0[token] = activity }
        return token
    }

    func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async {}

    func end(_ token: BackgroundToken, success: Bool) async {
        let activity = activities.withLock { $0.removeValue(forKey: token) }
        if let activity { ProcessInfo.processInfo.endActivity(activity.object) }
    }
}

/// Keeps the Mac awake while a recording is being captured (the processing activity above covers the rest).
@MainActor final class CaptureActivity {
    private var activity: NSObjectProtocol?

    func set(active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Recording a conversation")
        } else if !active, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
