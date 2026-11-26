import Foundation
import Synchronization
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// `wp3WaitFor` that only guards against a hang. The whole TranscribeKitTests run shares one main actor and one
/// cooperative pool among hundreds of tests; early in a full run a single hop from the main actor to the fake engine
/// was measured taking 60–80 s, and a dictation step makes several (main actor, fake engine, coordinator). So the
/// limit is as long as a whole run, not a guess at how long a step takes.
func dictationWait(_ condition: @MainActor () async throws -> Bool) async rethrows -> Bool {
    try await wp3WaitFor(.seconds(600), condition)
}

/// A clock the test moves by hand: `now` and `sleep` for `DictationController`. A sleeper wakes when `advance` passes
/// its deadline, or throws `CancellationError` when its task is cancelled.
final class ManualClock: Sendable {
    private struct Sleeper { let deadline: Duration; let seconds: Double; let continuation: CheckedContinuation<Void, any Error> }
    private struct State {
        var offset: Duration = .zero
        var sleepers: [UUID: Sleeper] = [:]
        var cancelledEarly: Set<UUID> = []
    }
    private let base = ContinuousClock.now
    private let state = Mutex(State())

    var now: ContinuousClock.Instant { base + state.withLock { $0.offset } }

    /// The durations (in seconds) of the sleepers waiting now.
    var pendingSeconds: [Double] { state.withLock { $0.sleepers.values.map(\.seconds) } }

    func hasSleeper(seconds: Double) -> Bool { pendingSeconds.contains { abs($0 - seconds) < 0.001 } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        let seconds = DictationController.seconds(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let early: Result<Void, any Error>? = state.withLock { s in
                    if s.cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    s.sleepers[id] = Sleeper(deadline: s.offset + duration, seconds: seconds, continuation: c)
                    return nil
                }
                if let early { c.resume(with: early) }
            }
        } onCancel: {
            let c = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                if let sleeper = s.sleepers.removeValue(forKey: id) { return sleeper.continuation }
                s.cancelledEarly.insert(id)
                return nil
            }
            c?.resume(throwing: CancellationError())
        }
    }

    func advance(_ seconds: Double) {
        let due = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
            s.offset += .seconds(seconds)
            let ready = s.sleepers.filter { $0.value.deadline <= s.offset }
            for key in ready.keys { s.sleepers[key] = nil }
            return ready.values.map(\.continuation)
        }
        for c in due { c.resume() }
    }
}

/// A door a test opens: everything that called `wait()` before or after `open()` goes on. Not cancellable, so a call
/// held here keeps running after its task is cancelled (like a model call that does not honour cancellation).
final class AsyncGate: Sendable {
    private struct State { var open = false; var arrivals = 0; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())

    var arrivals: Int { state.withLock { $0.arrivals } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = state.withLock { s -> Bool in
                s.arrivals += 1
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if go { c.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for c in waiters { c.resume() }
    }
}

/// A capture session that records what was asked of it, over the fake's own session.
actor SpyLiveRecording: LiveRecording {
    nonisolated let base: any LiveRecording
    nonisolated var events: AsyncStream<RecordingEvent> { base.events }
    private(set) var stopCalls = 0
    private(set) var discardCalls = 0
    private(set) var liveTextCalls: [Bool] = []

    init(base: any LiveRecording) { self.base = base }

    func pause() async { await base.pause() }
    func resume() async { await base.resume() }
    func markMoment() async -> TimeInterval { await base.markMoment() }
    func setLiveTextEnabled(_ enabled: Bool) async {
        liveTextCalls.append(enabled)
        await base.setLiveTextEnabled(enabled)
    }
    func stop() async throws -> CapturedAudio {
        stopCalls += 1
        return try await base.stop()
    }
    func discard() async {
        discardCalls += 1
        await base.discard()
    }
}

/// The fake engine with doors in front of capture, the models' prepare and transcription, and spy sessions.
final class DictationSpyEngine: SpeechEngine, Sendable {
    let base: FakeSpeechEngine
    let startGate: AsyncGate?
    let prepareGate: AsyncGate?
    let transcribeGate: AsyncGate?
    let failPrepare: Bool
    private let started = Mutex<[SpyLiveRecording]>([])

    init(base: FakeSpeechEngine, startGate: AsyncGate? = nil, prepareGate: AsyncGate? = nil,
         transcribeGate: AsyncGate? = nil, failPrepare: Bool = false) {
        self.base = base; self.startGate = startGate; self.prepareGate = prepareGate
        self.transcribeGate = transcribeGate; self.failPrepare = failPrepare
    }

    var sessions: [SpyLiveRecording] { started.withLock { $0 } }

    var info: EngineInfo { base.info }
    func modelStatus() async -> ModelStatus { await base.modelStatus() }
    func prepareModels() async throws { try await prepareModels(onEvent: { _ in }) }
    func prepareModels(onEvent: @escaping @Sendable (PrepareEvent) -> Void) async throws {
        await prepareGate?.wait()
        if failPrepare { throw EngineError.failed("Broken models") }
        try await base.prepareModels(onEvent: onEvent)
    }
    func microphonePermission() async -> MicPermission { await base.microphonePermission() }
    func requestMicrophonePermission() async -> Bool { await base.requestMicrophonePermission() }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        await startGate?.wait()
        let session = SpyLiveRecording(base: try await base.startRecording(request))
        started.withLock { $0.append(session) }
        return session
    }
    func transcribe(_ audio: URL, language: LanguageHint,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        await transcribeGate?.wait()
        return try await base.transcribe(audio, language: language, progress: progress)
    }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        try await base.separateSpeakers(audio, progress: progress)
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] {
        try await base.embedVoice(audio, spans: spans)
    }
}

/// Stands in for `PasteService`: pastes unless the frontmost app (`pid`) changed since the stop.
@MainActor
final class SpyOutput: DictationOutput {
    var pid: Int32? = 100
    private(set) var delivered: [(text: String, target: Int32?)] = []
    private(set) var copied: [(text: String, reason: CopyReason)] = []

    func noteTarget() -> Int32? { pid }

    func deliver(_ text: String, target: Int32?) async -> DeliveryOutcome {
        delivered.append((text, target))
        let unchanged = target == nil || target == pid
        switch PasteDecision.plan(postEventAllowed: true, secureInput: false, targetUnchanged: unchanged, clipboardReadable: true) {
        case .paste: return .pasted
        case .copyOnly(let reason): return .copied(reason)
        }
    }

    func copy(_ text: String, reason: CopyReason) -> DeliveryOutcome {
        copied.append((text, reason))
        return .copied(reason)
    }
}

@MainActor
final class MeetingFlag { var active = false }

/// A dictation controller over a real coordinator and in-memory store, the spy engine (instant fake speed), a spy
/// output and a manual clock.
@MainActor
final class DictationRig {
    let h: WP3Harness
    let base: FakeSpeechEngine
    let engine: DictationSpyEngine
    let coordinator: ProcessingCoordinator
    let models: ModelManager
    let settings: AppSettings
    let gate = CaptureGate()
    let output = SpyOutput()
    let clock = ManualClock()
    let meeting = MeetingFlag()
    let controller: DictationController

    init(script: FakeScriptName = .newVoices, modelsReady: Bool = true, mic: MicPermission = .granted,
         startGate: AsyncGate? = nil, prepareGate: AsyncGate? = nil, transcribeGate: AsyncGate? = nil,
         failPrepare: Bool = false) async throws {
        h = try WP3Harness()
        let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting],
                                  environment: [LaunchConfig.envMic: mic.rawValue, LaunchConfig.envSpeed: FakeSpeed.instant.rawValue])
        base = FakeSpeechEngine(config: config, script: .named(script))
        engine = DictationSpyEngine(base: base, startGate: startGate, prepareGate: prepareGate,
                                    transcribeGate: transcribeGate, failPrepare: failPrepare)
        settings = AppSettings(defaults: UserDefaults(suiteName: "dictation-\(UUID().uuidString)")!)
        let coordinator = ProcessingCoordinator(engine: engine, store: h.store, monitor: ProcessingMonitor(),
                                                settings: settings, paths: h.paths, background: NoopBackgroundTaskBridge())
        self.coordinator = coordinator
        models = ModelManager(engine: engine, onReady: { Task { await coordinator.modelsBecameReady() } })
        if modelsReady { await models.prepareIfInstalled() }
        let clock = self.clock, meeting = self.meeting
        controller = DictationController(engine: engine, coordinator: coordinator, models: models, settings: settings,
                                         paths: h.paths, gate: gate, output: output,
                                         isMeetingActive: { meeting.active },
                                         now: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    var session: SpyLiveRecording? { engine.sessions.last }

    var dictationFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: h.paths.dictationDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    /// Presses, waits for the microphone, then lets `seconds` pass on the clock (the hold is taken at 0.3 s).
    func pressAndListen(_ press: DictationMachine.Event = .holdPressed, for seconds: Double = 0.5) async -> Bool {
        controller.handle(press)
        let listening = await dictationWait { [self] in
            if case .listening = controller.phase { return clock.hasSleeper(seconds: DictationLimits.minimumHold) }
            return false
        }
        guard listening else { return false }
        clock.advance(seconds)
        if seconds >= DictationLimits.minimumHold {
            return await dictationWait { [coordinator] in await coordinator.exclusiveHoldCount == 1 }
        }
        return true
    }

    /// Waits until the dictation is idle with the gate and every hold given back.
    func settled() async -> Bool {
        await dictationWait { [self] in
            guard controller.phase == .idle, gate.owner == nil else { return false }
            return await coordinator.exclusiveHoldCount == 0
        }
    }

    func cleanup() { h.cleanup() }
}
