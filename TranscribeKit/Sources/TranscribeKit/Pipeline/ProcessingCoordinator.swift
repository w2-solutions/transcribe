import Foundation
import os
import TranscribeCore

/// Runs post-recording processing (§5.6): a FIFO queue, one job at a time, never while capture is active.
///
/// Concurrency rules this actor keeps:
/// - At most one job runs, and its engine calls are strictly sequential, so the engine sees at most one
///   model call in flight. A cancelled job keeps the "running" slot until its task has really finished.
/// - Every store access goes through one serial lane (`lane`), in the order the actor issued it, so a
///   queued-state write can never land after the job that follows it.
/// - Monitor snapshots go through one ordered stream to the main actor.
public actor ProcessingCoordinator {
    let engine: any SpeechEngine
    let store: any LibraryStoring
    let monitor: ProcessingMonitor
    let settings: AppSettings
    let paths: AppPaths
    let background: any BackgroundTaskBridge
    let policy: MatchPolicy
    let alignment: AlignmentConfig

    public static let maxAttempts = RecoveryPlanner.maxAttempts
    public static let failureMessage = RecoveryPlanner.gaveUpMessage
    public static let backgroundTitle = "Working out who said what"
    static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "pipeline")
    /// Minimum spacing of progress-only snapshots (about 10 per second).
    static let progressInterval: Duration = .milliseconds(100)

    enum CancelReason: Sendable { case capture, backgroundExpiry, removed, modelRemoval }

    // Queue state
    private var queue: [UUID] = []
    private var queueReasons: [UUID: QueueReason] = [:]
    private var running: (id: UUID, task: Task<Void, Never>)?
    private var cancelReasons: [UUID: CancelReason] = [:]
    private var captureActive = false
    private var waitingForModels = false
    private var modelsGeneration = 0
    private var parkedByExpiry = false
    private var observingActivation = false

    // Job state
    var jobs: [UUID: JobProgress] = [:]
    private var tokens: [UUID: BackgroundToken] = [:]
    private var lastProgressPublish: [UUID: ContinuousClock.Instant] = [:]
    private var trailingFlush: Set<UUID> = []

    // Ordering
    private var laneTail: Task<Void, Never>?
    private let events: AsyncStream<MonitorEvent>.Continuation
    private var publishObserver: (@Sendable (ProcessingSnapshot) -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    enum MonitorEvent: Sendable {
        case update(ProcessingSnapshot, BackgroundToken?)
        case clear(UUID)
        case endBackground(BackgroundToken, success: Bool)
    }

    public init(engine: any SpeechEngine, store: any LibraryStoring, monitor: ProcessingMonitor,
                settings: AppSettings, paths: AppPaths, background: any BackgroundTaskBridge,
                policy: MatchPolicy = .default, alignment: AlignmentConfig = .default) {
        self.engine = engine; self.store = store; self.monitor = monitor; self.settings = settings
        self.paths = paths; self.background = background; self.policy = policy; self.alignment = alignment
        let (stream, continuation) = AsyncStream.makeStream(of: MonitorEvent.self)
        self.events = continuation
        Task { @MainActor in
            for await event in stream {
                switch event {
                case .update(let snapshot, let token):
                    monitor.update(snapshot)
                    if let token { await background.update(token, fraction: snapshot.overall, subtitle: Self.backgroundSubtitle(snapshot)) }
                case .clear(let id):
                    monitor.clear(id)
                case .endBackground(let token, let success):
                    await background.end(token, success: success)
                }
            }
        }
    }

    deinit { events.finish() }

    // MARK: - Public API

    /// FIFO; one job at a time; never while capture is active.
    public func enqueue(_ recordingID: UUID) {
        guard !queue.contains(recordingID), running?.id != recordingID else { return }
        parkedByExpiry = false
        queue.append(recordingID)
        markQueued(recordingID, currentReason())
        pump()
    }

    /// resetForRetry + enqueue
    public func retry(_ recordingID: UUID) {
        guard !queue.contains(recordingID), running?.id != recordingID else { return }
        let store = self.store
        laneRun { try? store.resetForRetry(id: recordingID) }
        enqueue(recordingID)
    }

    /// Before delete: drops the job; a running job stops at once and writes nothing more.
    public func cancel(_ recordingID: UUID) {
        if let i = queue.firstIndex(of: recordingID) { queue.remove(at: i) }
        queueReasons[recordingID] = nil
        if running?.id == recordingID {
            cancelReasons[recordingID] = .removed
            running?.task.cancel()
        }
        events.yield(.clear(recordingID))
        notifyIdleIfNeeded()
    }

    /// Cancels the running step; job stays queued at its checkpoint.
    public func suspendForCapture() async {
        captureActive = true
        if let job = running {
            if cancelReasons[job.id] == nil { cancelReasons[job.id] = .capture }
            job.task.cancel()
            await job.task.value
        }
        for id in queue where queueReasons[id] != .modelsNotReady { markQueued(id, .pausedForRecording) }
    }

    /// Before speech models are removed: stops the running job (it stays queued at its checkpoint, without
    /// using an attempt) and holds the queue until `modelsBecameReady()`, so no engine call overlaps the removal.
    public func suspendForModelRemoval() async {
        waitingForModels = true
        if let job = running {
            if cancelReasons[job.id] == nil { cancelReasons[job.id] = .modelRemoval }
            job.task.cancel()
            await job.task.value
        }
        refreshQueuedReasons()
    }

    public func resumeAfterCapture() {
        guard captureActive else { return }
        captureActive = false
        parkedByExpiry = false
        refreshQueuedReasons()
        pump()
    }

    /// Starts jobs queued as .modelsNotReady.
    public func modelsBecameReady() {
        modelsGeneration += 1
        guard waitingForModels else { pump(); return }
        waitingForModels = false
        refreshQueuedReasons()
        pump()
    }

    /// RecoveryPlanner (§5.7).
    public func recoverOnLaunch() async {
        observeActivation()
        let store = self.store
        guard let candidates = try? await lane({ try store.recoveryCandidates() }) else { return }
        for action in RecoveryPlanner.plan(candidates) {
            switch action {
            case .requeue(let id):
                Self.log.info("recovery: requeue \(id, privacy: .public)")
                enqueue(id)
            case .discard(let id):
                Self.log.info("recovery: discard \(id, privacy: .public)")
                _ = try? await lane { try store.discardRecording(id: id) }
            case .fail(let id, let message):
                Self.log.info("recovery: fail \(id, privacy: .public): \(message, privacy: .public)")
                _ = try? await lane { try store.markFailed(id: id, message: message) }
            case .repairAndQueue(let id):
                Self.log.info("recovery: repair \(id, privacy: .public)")
                await repairAndQueue(id, candidates: candidates)
            }
        }
    }

    /// A capture whose `stop()` failed: repair the WAV header and queue it now, as launch recovery would
    /// (a recording with no usable audio is removed).
    public func recoverInterruptedCapture(_ id: UUID) async {
        let store = self.store
        guard let candidates = try? await lane({ try store.recoveryCandidates() }),
              let snap = candidates.first(where: { $0.id == id }), snap.stage == .capturing else { return }
        switch RecoveryPlanner.action(for: snap) {
        case .repairAndQueue?: await repairAndQueue(id, candidates: candidates)
        case .discard?: _ = try? await lane { try store.discardRecording(id: id) }
        default: break
        }
    }

    // MARK: - Test and diagnostics hooks (internal)

    /// Called synchronously, in order, for every snapshot the coordinator publishes.
    func setPublishObserver(_ observer: (@Sendable (ProcessingSnapshot) -> Void)?) { publishObserver = observer }

    /// Returns once no job is running and nothing queued can start (queue empty or blocked),
    /// and every store write issued so far has landed.
    func waitUntilIdle() async {
        if !isIdle { await withCheckedContinuation { idleWaiters.append($0) } }
        await laneTail?.value
    }

    var queuedIDs: [UUID] { queue }
    var runningID: UUID? { running?.id }

    // MARK: - Queue

    private var isIdle: Bool {
        running == nil && (queue.isEmpty || captureActive || waitingForModels || parkedByExpiry)
    }

    private func notifyIdleIfNeeded() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    private func currentReason() -> QueueReason {
        if waitingForModels { return .modelsNotReady }
        if captureActive { return .pausedForRecording }
        if parkedByExpiry { return .pausedByBackgroundExpiry }
        return .waitingForTurn
    }

    private func refreshQueuedReasons() {
        let reason = currentReason()
        for id in queue where queueReasons[id] != reason { markQueued(id, reason) }
    }

    private func pump() {
        guard running == nil, !captureActive, !waitingForModels, !parkedByExpiry, !queue.isEmpty else {
            notifyIdleIfNeeded()
            return
        }
        let id = queue.removeFirst()
        queueReasons[id] = nil
        running = (id, Task { await self.runJob(id) })
    }

    private func finishRunning(_ id: UUID) {
        if running?.id == id { running = nil }
        cancelReasons[id] = nil
        jobs[id] = nil
        lastProgressPublish[id] = nil
        trailingFlush.remove(id)
        pump()
        notifyIdleIfNeeded()
    }

    /// Persists the checkpoint stage with its queue reason and publishes a queued snapshot.
    private func markQueued(_ id: UUID, _ reason: QueueReason) {
        queueReasons[id] = reason
        let store = self.store
        let task = laneRun { () -> RecordingSnapshot? in
            guard let snap = try? store.snapshot(of: id), snap.stage >= .queued, snap.stage < .ready else { return nil }
            try? store.setStage(ProcessingPipeline.checkpointStage(snap), queueReason: reason, for: id)
            return snap
        }
        Task {
            guard let snap = await task.value else { return }
            self.publishQueued(id, snap, reason)
        }
    }

    private func publishQueued(_ id: UUID, _ snap: RecordingSnapshot, _ reason: QueueReason) {
        // Only if the job is still waiting for this reason: a stale queued snapshot must never
        // overwrite a running one.
        guard queue.contains(id), running?.id != id, queueReasons[id] == reason else { return }
        var job = JobProgress(states: ProcessingPipeline.baseStates(snap))
        job.phase = .queued(reason)
        publish(id, job)
    }

    // MARK: - Jobs

    private func runJob(_ id: UUID) async {
        await laneTail?.value
        let generation = modelsGeneration
        let status = await engine.modelStatus()
        guard status == .ready, cancelReasons[id] == nil else {
            if let reason = cancelReasons[id] {
                settleCancelled(id, reason, attemptCounted: false)
            } else {
                queue.insert(id, at: 0)
                if generation == modelsGeneration { waitingForModels = true }
                Self.log.info("job \(id, privacy: .public): waiting for speech models")
                refreshQueuedReasons()
            }
            finishRunning(id)
            return
        }

        // The attempt is counted before any work starts, so a run the OS kills (jetsam in the diariser,
        // a crash) still uses one: launch recovery then gives up after `maxAttempts` instead of retrying
        // the same recording first on every launch. Pre-emption gives the attempt back (`releaseAttempt`).
        let store = self.store
        let attempts = (try? await lane { try store.incrementAttempt(id: id) }) ?? Self.maxAttempts
        if attempts > Self.maxAttempts, cancelReasons[id] == nil {
            _ = try? await lane { try store.markFailed(id: id, message: Self.failureMessage) }
            var job = JobProgress()
            job.phase = .failed(Self.failureMessage)
            publish(id, job, force: true)
            finishRunning(id)
            return
        }

        let token = await background.begin(recordingID: id, title: Self.backgroundTitle, onExpire: { [weak self] in
            Task { await self?.backgroundExpired(id) }
        })
        tokens[id] = token
        jobs[id] = JobProgress()

        do {
            guard let outcome = try await runPipeline(id) else {
                // Already ready, failed or capturing: nothing to run.
                releaseAttempt(id)
                endBackground(id, success: true)
                events.yield(.clear(id))
                finishRunning(id)
                return
            }
            if cancelReasons[id] == .removed { throw CancellationError() }
            var job = jobs[id] ?? JobProgress()
            for step in ProcessingStep.allCases {
                if case .skipped = job.states[step] { continue }
                job.states[step] = .done
            }
            job.phase = .finished(outcome)
            Self.log.info("job \(id, privacy: .public): finished auto=\(outcome.autoLabelled) ask=\(outcome.suggested) unnamed=\(outcome.unnamed) noSpeech=\(outcome.noSpeech)")
            jobs[id] = job
            publish(id, job, force: true)
            endBackground(id, success: true)
        } catch {
            await settleFailure(id, error, attempts: attempts)
        }
        finishRunning(id)
    }

    /// Gives back the attempt counted at the start of a run that was pre-empted rather than failed.
    private func releaseAttempt(_ id: UUID) {
        let store = self.store
        laneRun { try? store.releaseAttempt(id: id) }
    }

    private func settleCancelled(_ id: UUID, _ reason: CancelReason, attemptCounted: Bool) {
        if attemptCounted, reason != .removed { releaseAttempt(id) }
        switch reason {
        case .removed:
            Self.log.info("job \(id, privacy: .public): removed")
            events.yield(.clear(id))
        case .capture:
            Self.log.info("job \(id, privacy: .public): paused for recording")
            queue.insert(id, at: 0)
            markQueued(id, .pausedForRecording)
        case .backgroundExpiry:
            Self.log.info("job \(id, privacy: .public): background time expired")
            parkedByExpiry = true
            queue.insert(id, at: 0)
            for q in queue { markQueued(q, .pausedByBackgroundExpiry) }
        case .modelRemoval:
            Self.log.info("job \(id, privacy: .public): paused while speech models are removed")
            queue.insert(id, at: 0)
            waitingForModels = true
            refreshQueuedReasons()
        }
    }

    private func settleFailure(_ id: UUID, _ error: any Error, attempts: Int) async {
        if let reason = cancelReasons[id] {
            endBackground(id, success: false)
            settleCancelled(id, reason, attemptCounted: true)
            return
        }
        endBackground(id, success: false)
        if case StoreError.notFound = error {
            events.yield(.clear(id))           // deleted while running
            return
        }
        if let e = error as? EngineError, e == .modelsMissing {
            releaseAttempt(id)
            queue.insert(id, at: 0)
            waitingForModels = true
            refreshQueuedReasons()
            return
        }
        if error is CancellationError || (error as? EngineError) == .cancelled {
            releaseAttempt(id)                  // not an attempt: try again in turn
            queue.append(id)
            markQueued(id, currentReason())
            return
        }
        // The attempt was counted when the run started (`runJob`).
        let store = self.store
        Self.log.error("job \(id, privacy: .public): attempt \(attempts) failed: \(String(describing: error), privacy: .public)")
        if attempts < Self.maxAttempts {
            queue.append(id)
            markQueued(id, currentReason())
        } else {
            _ = try? await lane { try store.markFailed(id: id, message: Self.failureMessage) }
            var job = jobs[id] ?? JobProgress()
            job.phase = .failed(Self.failureMessage)
            publish(id, job, force: true)
        }
    }

    private func backgroundExpired(_ id: UUID) {
        guard running?.id == id, cancelReasons[id] == nil else { return }
        cancelReasons[id] = .backgroundExpiry
        running?.task.cancel()
    }

    private func endBackground(_ id: UUID, success: Bool) {
        guard let token = tokens.removeValue(forKey: id) else { return }
        events.yield(.endBackground(token, success: success))
    }

    // MARK: - Recovery

    private func repairAndQueue(_ id: UUID, candidates: [RecoverySnapshot]) async {
        guard let snap = candidates.first(where: { $0.id == id }) else { return }
        let url = paths.audioURL(fileName: snap.audioFileName)
        let store = self.store
        do {
            let duration = try WAVRepair.repairHeader(at: url)
            guard duration >= 1 else {
                _ = try? await lane { try store.discardRecording(id: id) }
                return
            }
            let peaks = (try? WaveformPeaks.peaks(ofWAV: url, bins: 200)) ?? []
            try await lane { try store.repairCaptured(id: id, duration: duration, peaks: peaks) }
            enqueue(id)
        } catch {
            _ = try? await lane { try store.markFailed(id: id, message: RecoveryPlanner.audioMissingMessage) }
        }
    }

    /// After a background expiry the queue waits until the app is in front again, then resumes.
    private func observeActivation() {
        guard !observingActivation else { return }
        observingActivation = true
        #if os(iOS)
        // UIApplication.didBecomeActiveNotification, by name: TranscribeKit does not import UIKit.
        _ = NotificationCenter.default.addObserver(forName: Notification.Name("UIApplicationDidBecomeActiveNotification"),
                                                   object: nil, queue: nil) { [weak self] _ in
            Task { await self?.appBecameActive() }
        }
        #endif
    }

    func appBecameActive() {
        guard parkedByExpiry else { return }
        parkedByExpiry = false
        refreshQueuedReasons()
        pump()
    }

    // MARK: - Store lane

    /// Runs `op` on the main actor after every previously issued store operation.
    func lane<T: Sendable>(_ op: @escaping @MainActor @Sendable () throws -> T) async throws -> T {
        try await laneTask(op).value
    }

    @discardableResult
    func laneTask<T: Sendable>(_ op: @escaping @MainActor @Sendable () throws -> T) -> Task<T, any Error> {
        let previous = laneTail
        let task = Task { @MainActor () throws -> T in
            await previous?.value
            return try op()
        }
        laneTail = Task { _ = await task.result }
        return task
    }

    @discardableResult
    func laneRun<T: Sendable>(_ op: @escaping @MainActor @Sendable () -> T) -> Task<T, Never> {
        let previous = laneTail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return op()
        }
        laneTail = Task { _ = await task.value }
        return task
    }

    // MARK: - Publishing

    func publish(_ id: UUID, _ job: JobProgress, force: Bool = true) {
        let now = ContinuousClock.now
        if !force, let last = lastProgressPublish[id], now - last < Self.progressInterval {
            // Too soon: publish the latest state once the interval has passed, unless something
            // else publishes first.
            guard !trailingFlush.contains(id) else { return }
            trailingFlush.insert(id)
            let wait = Self.progressInterval - (now - last)
            Task {
                try? await Task.sleep(for: wait)
                self.flushTrailing(id)
            }
            return
        }
        lastProgressPublish[id] = now
        trailingFlush.remove(id)
        let snapshot = job.snapshot(id)
        publishObserver?(snapshot)
        events.yield(.update(snapshot, tokens[id]))
    }

    private func flushTrailing(_ id: UUID) {
        guard trailingFlush.contains(id), let job = jobs[id], job.phase == .running else {
            trailingFlush.remove(id)
            return
        }
        publish(id, job, force: true)
    }

    /// Updates a running job's state and publishes it (progress-only changes are throttled).
    func updateJob(_ id: UUID, force: Bool = true, _ change: (inout JobProgress) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
        publish(id, job, force: force)
    }

    nonisolated static func backgroundSubtitle(_ s: ProcessingSnapshot) -> String {
        let percent = "\(Int((s.overall * 100).rounded()))%"
        guard let step = s.currentStep else { return percent }
        return "\(step.activeTitle) · \(percent)"
    }
}
