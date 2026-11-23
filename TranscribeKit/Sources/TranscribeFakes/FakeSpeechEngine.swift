import Foundation
import TranscribeCore
import TranscribeKit

/// Scripted engine for simulator runs, UI tests and pipeline tests (§7.3). No models, no microphone.
/// It counts calls and records the peak number of model calls in flight, so tests can assert
/// "one engine call at a time" and "resume skips transcribe".
///
/// Models ship in the app, so the fake starts `.installed`. `TRANSCRIBE_MODELS=missing` means "first launch on
/// this device": a slow on-device prepare, no download.
public actor FakeSpeechEngine: SpeechEngine {
    public nonisolated let info = EngineInfo(
        kind: .fake, asrDisplayName: "Parakeet", asrModelID: "fake-parakeet", embeddingModel: .fake)

    public nonisolated let script: FakeScript
    public nonisolated let speed: FakeSpeed
    private var status: ModelStatus
    /// First launch on this device (`.missing`): the first prepare is slow (2 s at instant speed, 20 s at demo).
    /// 20 s leaves a UI test time to launch, record, stop and still see "Waiting for speech models".
    private let firstPrepare: Bool
    private var mic: MicPermission

    /// Calls per method name ("transcribe", "separateSpeakers", "embedVoice", …).
    public private(set) var callCounts: [String: Int] = [:]
    /// Peak number of model calls running at once (must stay ≤ 1).
    public private(set) var maxConcurrentCalls = 0
    private var inFlight = 0

    public init(config: LaunchConfig, paths: AppPaths) {
        self.init(config: config, script: FakeScript.named(config.script))
    }

    /// Tests: inject a script directly.
    public init(config: LaunchConfig, script: FakeScript) {
        self.script = script
        self.speed = config.speed
        self.status = .installed
        self.firstPrepare = config.models == .missing
        self.mic = config.mic
    }

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
        switch status {
        case .ready: return
        case .failed: throw EngineError.modelsMissing
        case .installed, .preparing:
            status = .preparing
            try await sleep(firstPrepare ? (speed == .instant ? 2 : 20) : (speed == .instant ? 0.05 : 0.5))
            status = .ready
        }
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
            guard let segment = script.segments.first(where: { $0.range.contains(mid) }),
                  let vector = script.vectors[segment.speakerKey] else {
                throw EngineError.failed("No voice at \(mid)")
            }
            return vector
        }
    }
}
