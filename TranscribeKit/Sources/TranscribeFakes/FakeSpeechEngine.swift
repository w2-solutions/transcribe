import Foundation
import TranscribeCore
import TranscribeKit

/// Scripted engine for simulator runs, UI tests and pipeline tests (§7.3). No models, no microphone.
/// It counts calls and records the peak number of model calls in flight, so tests can assert
/// "one engine call at a time" and "resume skips transcribe".
///
/// Models ship in the app, so the fake starts `.installed`. `TRANSCRIBE_MODELS=missing` means "first launch on
/// this device": a slow on-device prepare, no download.
///
/// The prepare runs the real engine's stages in its order (diarizer, nemotron, asr, warmup: `PrepareStage.allCases`)
/// with scripted durations (`coldSeconds`, `warmSeconds`) and sends the same `PrepareEvent`s, with exact estimates.
/// With an `AppActivity` it applies the real start rule: a Neural Engine stage due to start in the background
/// without leave to (no Background Inference, or no short task held) throws `EngineError.cancelled`, a pause; the
/// CPU-only stage (nemotron) needs only the short task. It also applies the real keep rule: without Background
/// Inference a Neural Engine stage that returns after a trip to the background is dropped (its compile counts, so
/// it sends `stageFinished` and runs again warm) and the prepare pauses; the CPU-only stage is kept wherever it ran.
/// Like the real engine it keeps the diarizer and Nemotron once they finished and runs asr and the warm-up again,
/// warm, after a pause.
public actor FakeSpeechEngine: SpeechEngine {
    public nonisolated let info = EngineInfo(
        kind: .fake, asrDisplayName: "Parakeet", asrModelID: "fake-parakeet", embeddingModel: .fake)

    public nonisolated let script: FakeScript
    public nonisolated let speed: FakeSpeed
    private var status: ModelStatus
    /// First launch on this device (`.missing`): the first prepare is slow (2 s at instant speed, 20 s at demo).
    /// 20 s leaves a UI test time to launch, record, stop and still see "Waiting for setup".
    private let firstPrepare: Bool
    private var mic: MicPermission
    /// Whether the app is in front (the real start rule); nil: always allowed (tests).
    private let activity: AppActivity?
    /// Tests: runs before each stage starts (after the start rule allowed it).
    private let beforeStage: (@Sendable (PrepareStage) async -> Void)?
    /// Stages whose (scripted) compile finished: they run warm from now on.
    private var compiled: Set<PrepareStage> = []
    /// Stages kept for the process (the diarizer and Nemotron): skipped by later prepares.
    private var kept: Set<PrepareStage> = []

    /// Calls per method name ("transcribe", "separateSpeakers", "embedVoice", …).
    public private(set) var callCounts: [String: Int] = [:]
    /// Peak number of model calls running at once (must stay ≤ 1).
    public private(set) var maxConcurrentCalls = 0
    private var inFlight = 0

    public init(config: LaunchConfig, paths: AppPaths, activity: AppActivity? = nil) {
        self.init(config: config, script: FakeScript.named(config.script), activity: activity)
    }

    /// Tests: inject a script directly, and optionally a hook before each prepare stage.
    public init(config: LaunchConfig, script: FakeScript, activity: AppActivity? = nil,
                beforeStage: (@Sendable (PrepareStage) async -> Void)? = nil) {
        self.script = script
        self.speed = config.speed
        self.status = .installed
        self.firstPrepare = config.models == .missing
        self.mic = config.mic
        self.activity = activity
        self.beforeStage = beforeStage
    }

    /// The first prepare on this device (`models == .missing`), per stage at demo speed, in run order: 20 s in all,
    /// about the real iPhone 15's proportions (the diarizer and Nemotron about 1 s together, Parakeet nearly all the
    /// rest). Instant speed is a tenth.
    public static let coldSeconds: [(PrepareStage, Double)] = [(.diarizer, 0.5), (.nemotron, 0.5), (.asr, 18.8), (.warmup, 0.2)]
    /// A warm prepare at demo speed: 0.5 s in all.
    public static let warmSeconds: [(PrepareStage, Double)] = [(.diarizer, 0.1), (.nemotron, 0.15), (.asr, 0.2), (.warmup, 0.05)]

    public func callCount(_ name: String) -> Int { callCounts[name, default: 0] }

    // MARK: Timing

    private var stepSeconds: Double { speed == .instant ? 0.15 : 1.5 }
    private var stepTicks: Int { speed == .instant ? 3 : 10 }

    private func sleep(_ seconds: Double) async throws {
        do { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) } catch { throw EngineError.cancelled }
    }

    private func enter(_ name: String) {
        callCounts[name, default: 0] += 1
        inFlight += 1
        maxConcurrentCalls = Swift.max(maxConcurrentCalls, inFlight)
    }

    private func leave() { inFlight -= 1 }

    private func runSteps(progress: @Sendable (Double) -> Void) async throws {
        for i in 1...stepTicks {
            try await sleep(stepSeconds / Double(stepTicks))
            progress(Double(i) / Double(stepTicks))
        }
    }

    // MARK: Models

    public func modelStatus() async -> ModelStatus { status }

    public func prepareModels() async throws {
        try await prepareModels(onEvent: { _ in })
    }

    public func prepareModels(onEvent: @escaping @Sendable (PrepareEvent) -> Void) async throws {
        // A second caller waits for the running prepare (no events), as the real engine does.
        while status == .preparing { try await sleep(0.01) }
        switch status {
        case .ready: return
        case .failed: throw EngineError.modelsMissing
        case .preparing, .installed:
            status = .preparing
            let plan = currentPlan()
            onEvent(.planned(plan))
            do {
                for step in plan.steps where !step.isDone {
                    let window = activity?.stageWindow(usesNeuralEngine: step.stage.usesNeuralEngine)
                    if activity != nil, window == nil { throw EngineError.cancelled }
                    await beforeStage?(step.stage)
                    onEvent(.stageStarted(step.stage))
                    try await sleep(step.expectedSeconds)
                    compiled.insert(step.stage)
                    onEvent(.stageFinished(step.stage))
                    if let activity, let window, !activity.isForegroundClean(window), !activity.backgroundInference,
                       step.stage.usesNeuralEngine {
                        throw EngineError.cancelled   // dropped: it touched the background without the entitlement
                    }
                    if step.stage == .diarizer || step.stage == .nemotron { kept.insert(step.stage) }
                }
            } catch {
                status = .installed
                throw EngineError.cancelled
            }
            status = .ready
        }
    }

    /// The scripted plan for a prepare starting now. Like the real engine on a first install, the first-launch
    /// prepare (`models == .missing`) has no times measured on this device yet, so `timesFromThisDevice` is false
    /// there (the card shows the hedged typical-time line, never a time left); a warm launch's estimates
    /// count as measured.
    func currentPlan() -> PreparePlan {
        let scale = speed == .instant ? 0.1 : 1
        let cold = Dictionary(uniqueKeysWithValues: Self.coldSeconds)
        let warm = Dictionary(uniqueKeysWithValues: Self.warmSeconds)
        let steps = Self.coldSeconds.map { stage, _ -> PreparePlan.Step in
            if kept.contains(stage) { return PreparePlan.Step(stage: stage, expectedSeconds: 0, isDone: true) }
            let isCold = firstPrepare && !compiled.contains(stage)
            return PreparePlan.Step(stage: stage, expectedSeconds: (isCold ? cold[stage]! : warm[stage]!) * scale,
                                    isWarm: !isCold)
        }
        return PreparePlan(steps: steps, timesFromThisDevice: !firstPrepare)
    }

    // MARK: Microphone

    public func microphonePermission() async -> MicPermission { mic }

    public func requestMicrophonePermission() async -> Bool {
        let granted = mic != .denied
        mic = granted ? .granted : .denied
        return granted
    }

    // MARK: Capture

    public func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        guard request.sources == .microphone || systemAudioAvailable else { throw EngineError.sourceUnavailable }
        guard mic == .granted else { throw EngineError.microphoneDenied }
        callCounts["startRecording", default: 0] += 1
        let session = FakeLiveRecording(script: script, speed: speed, request: request)
        await session.begin()
        return session
    }

    // MARK: Post-processing

    public func transcribe(_ audio: URL, language: LanguageHint,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        enter("transcribe"); defer { leave() }
        guard status == .ready else { throw EngineError.modelsMissing }
        try await runSteps(progress: progress)
        return script.behaviour == .noSpeech ? [] : script.words
    }

    public func separateSpeakers(_ audio: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        enter("separateSpeakers"); defer { leave() }
        guard status == .ready else { throw EngineError.modelsMissing }
        switch script.behaviour {
        case .noSpeech:
            try await runSteps(progress: progress)
            throw EngineError.noSpeech
        case .failSeparation:
            try await runSteps(progress: progress)
            throw EngineError.failed("Simulated failure")
        case .holdAtSeparating:
            progress(0.6)
            try await sleep(86_400)
            throw EngineError.cancelled
        case .normal:
            try await runSteps(progress: progress)
            return SpeakerSeparation(segments: script.segments, centroids: script.vectors)
        }
    }

    public func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] {
        enter("embedVoice"); defer { leave() }
        guard status == .ready else { throw EngineError.modelsMissing }
        return try spans.map { span in
            let mid = span.mid
            if let override = script.spanVectors.first(where: { $0.range.contains(mid) }) { return override.vector }
            guard let segment = script.segments.first(where: { $0.range.contains(mid) }),
                  let vector = script.vectors[segment.speakerKey] else {
                throw EngineError.failed("No voice at \(mid)")
            }
            return vector
        }
    }
}
