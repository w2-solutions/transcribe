import Foundation
import Observation
import Synchronization
import TranscribeKit

/// Keeps the Mac awake while a recording is processed, or while the speech models prepare (`beginShortTask`): holds
/// a user-initiated `ProcessInfo` activity (idle system sleep disabled) from `begin` to `end`. The Mac never takes the
/// time away, so `onExpire` is never called.
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

    func beginShortTask(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? {
        let token = BackgroundToken()
        let activity = Activity(object: ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: name))
        activities.withLock { $0[token] = activity }
        return token
    }

    func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async {}

    func end(_ token: BackgroundToken, success: Bool) async {
        let activity = activities.withLock { $0.removeValue(forKey: token) }
        if let activity { ProcessInfo.processInfo.endActivity(activity.object) }
    }
}

/// Keeps the Mac awake while a recording is being captured (the processing activity above covers the rest). Owned by
/// the app, not a window: closing the main window during a recording must not let the Mac sleep.
@MainActor final class CaptureActivity {
    private var activity: NSObjectProtocol?
    private var following = false

    /// Follows `isActive` for the life of the app, whichever windows are open. Calling it again does nothing.
    func follow(_ isActive: @escaping @MainActor @Sendable () -> Bool) {
        guard !following else { return }
        following = true
        observe(isActive)
    }

    private func observe(_ isActive: @escaping @MainActor @Sendable () -> Bool) {
        let active = withObservationTracking { isActive() } onChange: { [weak self] in
            Task { @MainActor in self?.observe(isActive) }
        }
        set(active: active)
    }

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
