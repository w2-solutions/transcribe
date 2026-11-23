import BackgroundTasks
import Foundation
import os
import Synchronization
import TranscribeKit
import UIKit

/// Keeps post-recording processing alive when the app leaves the screen (§5.8).
///
/// Each job submits a `BGContinuedProcessingTaskRequest` ("ai.w2solutions.transcribe.process.<uuid>") with the
/// `.fail` strategy, so the system either starts it now or refuses. The launch handler does not start any
/// work: it attaches to the job the `ProcessingCoordinator` is already running, mirrors its progress into
/// `task.progress` and the system UI, and reports expiry back through `onExpire` (the coordinator then
/// parks the job at its checkpoint). If the request is refused, it falls back to
/// `UIApplication.beginBackgroundTask`.
///
/// Info.plist needs `BGTaskSchedulerPermittedIdentifiers` = ["ai.w2solutions.transcribe.process.*"].
/// Each job registers its own concrete identifier right before submitting it (registering the wildcard
/// string itself is rejected by the system on iOS 27).
nonisolated final class ContinuedProcessingBridge: BackgroundTaskBridge, Sendable {
    static let identifierPrefix = "ai.w2solutions.transcribe.process."
    static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "background")

    init() {}

    func begin(recordingID: UUID, title: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? {
        let token = BackgroundToken()
        let identifier = Self.identifierPrefix + token.id.uuidString
        await ContinuedProcessingRegistry.shared.add(token: token, identifier: identifier, onExpire: onExpire)
        let submitted = await Self.submit(identifier: identifier, title: title)
        if !submitted {
            await ContinuedProcessingRegistry.shared.beginFallback(token: token, name: title)
        }
        return token
    }

    func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async {
        await ContinuedProcessingRegistry.shared.update(token: token, fraction: fraction, subtitle: subtitle)
    }

    func end(_ token: BackgroundToken, success: Bool) async {
        await ContinuedProcessingRegistry.shared.end(token: token, success: success)
    }

    // MARK: - Scheduler (nonisolated: the launch handler runs on the scheduler's queue)

    /// Identifiers registered in this process (each may be registered only once).
    private static let registered = Mutex<Set<String>>([])

    /// Registers a launch handler for one concrete identifier just before it is submitted. The system
    /// rejects registering the literal wildcard; a concrete identifier is accepted when it matches the
    /// `ai.w2solutions.transcribe.process.*` entry in Info.plist. Continued-processing registrations are
    /// exempt from the "before launch finishes" rule.
    private static func register(_ identifier: String) -> Bool {
        registered.withLock { done in
            if done.contains(identifier) { return true }
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                handleLaunch(task)
            }
            if ok { done.insert(identifier) } else { log.error("register \(identifier, privacy: .public) rejected") }
            return ok
        }
    }

    private static func handleLaunch(_ task: BGTask) {
        log.info("launched \(task.identifier, privacy: .public)")
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        let box = TaskBox(task)
        Task { @MainActor in ContinuedProcessingRegistry.shared.attach(box) }
    }

    private static func submit(identifier: String, title: String) async -> Bool {
        guard register(identifier) else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title,
                                                       subtitle: ProcessingStepCopy.starting)
        request.strategy = .fail
        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            log.info("submitted \(identifier, privacy: .public)")
            return true
        } catch {
            // Simulator, Background App Refresh off, or no room right now: fall back.
            log.info("submit refused (\(String(describing: error), privacy: .public)); using beginBackgroundTask")
            return false
        }
    }
}

nonisolated private enum ProcessingStepCopy {
    static let starting = "Starting"
}

/// Carries a system task object across to the main actor. The system's task objects are documented as safe
/// to use from any thread; this box only exists to make that explicit to the compiler.
nonisolated struct TaskBox: @unchecked Sendable {
    let task: BGContinuedProcessingTask
    init(_ task: BGContinuedProcessingTask) { self.task = task }
}

/// Live jobs by token, on the main actor.
@MainActor
final class ContinuedProcessingRegistry {
    static let shared = ContinuedProcessingRegistry()

    private final class Entry {
        let token: BackgroundToken
        let identifier: String
        let onExpire: @Sendable () -> Void
        var task: BGContinuedProcessingTask?
        var fallbackID: UIBackgroundTaskIdentifier = .invalid
        var fraction = 0.0
        var title = ""
        var subtitle = "Starting"
        init(token: BackgroundToken, identifier: String, onExpire: @escaping @Sendable () -> Void) {
            self.token = token; self.identifier = identifier; self.onExpire = onExpire
        }
    }

    private var entries: [BackgroundToken: Entry] = [:]
    private static let progressUnits: Int64 = 1000

    func add(token: BackgroundToken, identifier: String, onExpire: @escaping @Sendable () -> Void) {
        entries[token] = Entry(token: token, identifier: identifier, onExpire: onExpire)
    }

    /// The system started our request: attach it to the running job.
    func attach(_ box: TaskBox) {
        let task = box.task
        guard let entry = entries.values.first(where: { $0.identifier == task.identifier }) else {
            task.setTaskCompleted(success: true)          // the job already ended
            return
        }
        entry.task = task
        entry.title = task.title
        task.progress.totalUnitCount = Self.progressUnits
        task.progress.completedUnitCount = Int64(entry.fraction * Double(Self.progressUnits))
        let onExpire = entry.onExpire
        task.expirationHandler = Self.expirationHandler(onExpire)
    }

    /// Built outside the main actor so the closure carries no actor isolation (it runs on a system queue).
    nonisolated private static func expirationHandler(_ onExpire: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        { onExpire() }
    }

    func beginFallback(token: BackgroundToken, name: String) {
        guard let entry = entries[token] else { return }
        let onExpire = entry.onExpire
        entry.fallbackID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            onExpire()
            self?.endFallback(token)
        }
    }

    func update(token: BackgroundToken, fraction: Double, subtitle: String) {
        guard let entry = entries[token] else { return }
        entry.fraction = Swift.min(1, Swift.max(0, fraction))
        if let task = entry.task {
            task.progress.completedUnitCount = Int64(entry.fraction * Double(Self.progressUnits))
            if subtitle != entry.subtitle { task.updateTitle(entry.title, subtitle: subtitle) }
        }
        entry.subtitle = subtitle
    }

    func end(token: BackgroundToken, success: Bool) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        if let task = entry.task {
            if success { task.progress.completedUnitCount = Self.progressUnits }
            task.setTaskCompleted(success: success)
        } else {
            // Not launched yet (or never will be): withdraw the request.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: entry.identifier)
        }
        if entry.fallbackID != .invalid {
            UIApplication.shared.endBackgroundTask(entry.fallbackID)
        }
    }

    private func endFallback(_ token: BackgroundToken) {
        guard let entry = entries[token], entry.fallbackID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(entry.fallbackID)
        entry.fallbackID = .invalid
    }
}

