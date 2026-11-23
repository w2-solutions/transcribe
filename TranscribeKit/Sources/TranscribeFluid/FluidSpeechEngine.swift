import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import Synchronization
import os
import TranscribeCore

/// Real engine on FluidAudio 0.18.4 (§5.10): Parakeet TDT 0.6B v3 for text, NVIDIA Nemotron 3 Diarization
/// (fp16 `fast128`) for speaker separation with the pyannote community-1 offline pipeline as its fallback, and
/// community-1's WeSpeaker ResNet34 embedder for voice vectors.
///
/// The models ship read-only inside the app (`FluidModelPaths.bundledRoot()`); nothing is downloaded, removed or
/// written. `FluidRuntime.lockDown()` puts FluidAudio in offline mode before any loader runs.
///
/// Holds `AsrManager`, `AsrModels`, `OfflineDiarizerModels` and the diarizer config. It never stores an
/// `OfflineDiarizerManager` (not Sendable, its async methods are `@concurrent`); `makeDiarizer()` builds one
/// per job and returns it as `sending`. Nemotron 3's models and diarizer are not Sendable either: they live only
/// inside `NemotronSeparation.run`, loaded and released per job.
public actor FluidSpeechEngine: SpeechEngine {
    public nonisolated let info = EngineInfo(
        kind: .fluid, asrDisplayName: "Parakeet", asrModelID: FluidModelPaths.asrModelID,
        embeddingModel: .communityOneResNet34)

    public nonisolated let paths: FluidModelPaths
    let modelsRoot: URL

    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "FluidSpeechEngine")
    private let captureFactory: @Sendable () -> any CaptureSource
    private let asrConfig: ASRConfig
    private let diarizerConfig: OfflineDiarizerConfig

    private var asr: AsrManager?
    private var asrModels: AsrModels?
    private var diarizerModels: OfflineDiarizerModels?
    private var isReady = false
    private var prepareTask: Task<Void, any Error>?
    private var loadFailure: String?
    /// Why Nemotron 3 cannot be used on this device: set when Nemotron fails to load in this process. Separation
    /// then goes straight to community-1.
    private var nemotronUnavailable: String?
    /// Nemotron 3 loaded once in this process (prepare's warm-up), so its Neural Engine compile is done.
    private var nemotronLoaded = false

    /// The embedding dimension of WeSpeaker ResNet34 (community-1).
    static let embeddingDimension = EmbeddingModelID.communityOneResNet34.dimension
    static let sampleRate = 16_000
    /// Parakeet's minimum input (`ASRConstants.minimumAudioDurationSeconds`).
    static let minimumASRSeconds = ASRConstants.minimumAudioDurationSeconds

    public init(modelsRoot: URL) {
        self.init(modelsRoot: modelsRoot, captureFactory: { MicrophoneCapture() })
    }

    /// Tests inject a scripted capture source.
    init(modelsRoot: URL, captureFactory: @escaping @Sendable () -> any CaptureSource) {
        FluidRuntime.lockDown()
        self.modelsRoot = modelsRoot
        self.paths = FluidModelPaths(root: modelsRoot)
        self.captureFactory = captureFactory
        self.asrConfig = Self.makeASRConfig()
        self.diarizerConfig = Self.makeDiarizerConfig()
    }

    /// ASR folder (`AsrModels.load(from:)` takes the repo folder itself).
    var asrDirectory: URL { paths.asrDirectory }

    // MARK: Configuration

    /// Long audio is decoded by cloned managers sharing the models: 1 on iPhone to limit memory, 4 on Mac.
    static func makeASRConfig() -> ASRConfig {
        #if os(iOS)
        ASRConfig(parallelChunkConcurrency: 1)
        #else
        ASRConfig(parallelChunkConcurrency: 4)
        #endif
    }

    /// Batch 8 keeps the segmentation peak near 100 MB (32 → ~400 MB, a jetsam risk on iPhone).
    /// Overlapping segments are kept: TurnBuilder flags overlap words itself.
    static func makeDiarizerConfig() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.segmentation.batchSize = 8
        config.embedding.batchSize = 8
        config.postProcessing.exclusiveSegments = false
        return config
    }

    /// No GPU: iOS forbids GPU work in the background, and processing may continue there.
    static func makeDiarizerMLConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }

    // MARK: Models

    public func modelStatus() async -> ModelStatus {
        if isReady { return .ready }
        if prepareTask != nil { return .preparing }
        guard paths.allInstalled else { return .failed(ModelStatus.missingFromAppMessage) }
        if let loadFailure { return .failed(loadFailure) }
        return .installed
    }

    public func prepareModels() async throws {
        if isReady { return }
        if let prepareTask {
            do { try await prepareTask.value } catch { throw FluidErrorMapping.engineError(error) }
            return
        }
        guard paths.allInstalled else { throw EngineError.modelsMissing }
        let task = Task { try await self.loadAndWarmUp() }
        prepareTask = task
        defer { prepareTask = nil }
        do {
            try await task.value
            loadFailure = nil
        } catch {
            loadFailure = FluidErrorMapping.describe(error)
            log.error("Model preparation failed: \(self.loadFailure ?? "", privacy: .public)")
            throw FluidErrorMapping.engineError(error)
        }
    }

    /// Load (compiling for the Neural Engine on first use), then a 1 s silent warm-up transcription.
    private func loadAndWarmUp() async throws {
        let start = Date()
        let models = try await AsrModels.load(from: paths.asrDirectory, version: .v3)
        let manager = AsrManager(config: asrConfig)
        try await manager.loadModels(models)
        if diarizerModels == nil {
            diarizerModels = try await OfflineDiarizerModels.load(
                from: paths.diarizerLoadDirectory, configuration: Self.makeDiarizerMLConfiguration())
        }
        var warmState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: Self.sampleRate), decoderState: &warmState)
        await warmUpNemotron()
        asr = manager
        asrModels = models
        isReady = true
        log.info("Speech models ready in \(Date().timeIntervalSince(start), format: .fixed(precision: 2)) s")
    }

    /// Loads Nemotron 3 once so its Neural Engine compile happens while "Preparing", then releases it (each
    /// separation loads it again). A failure is not fatal: separation falls back to community-1.
    private func warmUpNemotron() async {
        guard !nemotronLoaded, nemotronUnavailable == nil, paths.nemotronInstalled else { return }
        do {
            let seconds = try await NemotronSeparation.warmUp(directory: paths.nemotronDirectory)
            nemotronLoaded = true
            log.info("Nemotron 3 (\(NemotronSeparation.presetName, privacy: .public)) loaded in \(seconds, format: .fixed(precision: 2)) s")
        } catch {
            nemotronUnavailable = FluidErrorMapping.describe(error)
            log.error("Nemotron 3 failed to load; using community-1 for speaker separation: \(self.nemotronUnavailable ?? "", privacy: .public)")
        }
    }

    // MARK: Microphone

    public func microphonePermission() async -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    public func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Capture

    public func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        guard await microphonePermission() == .granted else { throw EngineError.microphoneDenied }
        return try await startRecording(request, source: captureFactory())
    }

    /// Capture from any source (the microphone in the app, a scripted source in tests).
    func startRecording(_ request: RecordingRequest, source: any CaptureSource,
                        liveConfig: SlidingWindowAsrConfig = FluidLiveRecording.liveConfig) async throws -> FluidLiveRecording {
        let recording = FluidLiveRecording(request: request, source: source,
                                           liveModels: { [weak self] in await self?.liveModels() },
                                           liveConfig: liveConfig)
        try await recording.start()
        return recording
    }

    /// The loaded ASR models for live text, shared with the batch manager. Nil until prepared.
    func liveModels() -> AsrModels? { isReady ? asrModels : nil }

    // MARK: Post-processing

    public func transcribe(_ audio: URL, language: LanguageHint,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        guard isReady, let asr else { throw EngineError.modelsMissing }
        let duration = try Self.audioDuration(audio)
        guard duration >= Self.minimumASRSeconds else { throw EngineError.tooShort }
        let counter = WindowProgressCounter(sink: progress)
        await asr.setWindowHandler { window in counter.windowFinished(index: window.index, of: window.windowCount) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        do {
            let result = try await asr.transcribe(audio, decoderState: &state, language: LanguageMapping.fluid(language))
            await asr.setWindowHandler(nil)
            progress(1)
            let words = Self.words(from: result.tokenTimings ?? [], text: result.text, duration: result.duration)
            log.info("Transcribed \(duration, format: .fixed(precision: 1)) s → \(words.count) words, RTFx \(result.rtfx, format: .fixed(precision: 1))")
            return words
        } catch {
            await asr.setWindowHandler(nil)
            throw FluidErrorMapping.engineError(error)
        }
    }

    /// The share of the separation step the diariser fills; per-speaker embeddings report the rest.
    static let separationProgressShare = 0.6

    /// Nemotron 3 decides who spoke when; community-1 runs instead when Nemotron is missing, failed to load,
    /// throws, hears nothing, or uses all 8 speaker channels (§5.10). Either way no voice vectors are needed
    /// from this step: the pipeline embeds each speaker's clean speech with `embedVoice`.
    public func separateSpeakers(_ audio: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        try await separateSpeakers(audio, only: nil, progress: progress)
    }

    /// Tests compare the separators: `only: .communityOne` skips Nemotron 3; `only: .nemotron3` returns
    /// Nemotron's own result and throws (instead of falling back) when the rules above would fall back.
    func separateSpeakers(_ audio: URL, only: SpeakerSeparator?,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        guard isReady, diarizerModels != nil else { throw EngineError.modelsMissing }
        let duration = try Self.audioDuration(audio)
        // The diariser fills the first 60% of the step (per-speaker embeddings follow in the pipeline), and a slow
        // heartbeat keeps the bar (and the background task's progress) moving below that.
        let share = Self.separationProgressShare
        let reported = Mutex<Double>(0)
        let report: @Sendable (Double) -> Void = { fraction in
            let raise = reported.withLock { current -> Bool in
                guard fraction > current else { return false }
                current = fraction
                return true
            }
            if raise { progress(fraction) }
        }
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                report(Swift.min(reported.withLock { $0 } + 0.005, share - 0.005))
            }
        }
        defer { heartbeat.cancel() }

        let reason: NemotronSeparation.FallbackReason
        if only == .communityOne {
            return try await separateWithCommunityOne(audio, share: share, report: report)
        } else if let skip = nemotronSkipReason() {
            reason = skip
        } else {
            let start = Date()
            do {
                let activities = try await NemotronSeparation.run(audio: audio, directory: paths.nemotronDirectory) { f in
                    report(share * f)
                }
                let elapsed = Date().timeIntervalSince(start)
                switch NemotronSeparation.decide(activities) {
                case .use(let separation):
                    report(share)
                    log.info("Nemotron 3 separated \(Set(separation.segments.map(\.speakerKey)).count) speakers in \(separation.segments.count) segments from \(duration, format: .fixed(precision: 1)) s in \(elapsed, format: .fixed(precision: 2)) s")
                    return separation
                case .fallback(let why):
                    reason = why
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw EngineError.cancelled }
                log.error("Nemotron 3 separation failed: \(FluidErrorMapping.describe(error), privacy: .public)")
                reason = .failed
            }
        }
        if only == .nemotron3 { throw EngineError.failed("Nemotron 3 would fall back: \(reason.rawValue)") }
        log.info("Speaker separation falls back to community-1 (\(reason.rawValue, privacy: .public))")
        if Task.isCancelled { throw EngineError.cancelled }
        return try await separateWithCommunityOne(audio, share: share, report: report)
    }

    /// Why this job cannot use Nemotron 3 at all, or nil to try it.
    private func nemotronSkipReason() -> NemotronSeparation.FallbackReason? {
        if nemotronUnavailable != nil { return .unavailable }
        if !paths.nemotronInstalled { return .notInstalled }
        return nil
    }

    /// The pyannote community-1 offline pipeline (the original separator, now the fallback).
    private func separateWithCommunityOne(_ audio: URL, share: Double,
                                          report: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        do {
            let diarizer = try makeDiarizer()
            // FluidAudio reports segmentation only; embedding and clustering run after it with no callback.
            let result = try await diarizer.process(audio) { done, total in
                guard total > 0 else { return }
                report(share * Swift.min(1, Double(done) / Double(total)))
            }
            report(share)
            let separation = Self.separation(from: result)
            guard !separation.segments.isEmpty else { throw EngineError.noSpeech }
            log.info("Community-1 separated \(separation.centroids.count) speakers in \(separation.segments.count) segments")
            return separation
        } catch {
            throw FluidErrorMapping.engineError(error)
        }
    }

    public func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] {
        guard isReady, diarizerModels != nil else { throw EngineError.modelsMissing }
        guard !spans.isEmpty else { return [] }
        do {
            let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: audio, targetSampleRate: Self.sampleRate)
            defer { source.cleanup() }
            let duration = Double(source.sampleCount) / Double(Self.sampleRate)
            let ranges = try Self.embeddingRanges(spans, audioDuration: duration)
            let diarizer = try makeDiarizer()
            let raw = try await diarizer.embedSpans(audioSource: source, spans: ranges)
            guard raw.count == spans.count else { throw EngineError.failed("Expected \(spans.count) embeddings, got \(raw.count)") }
            return try raw.map { values in
                guard let vector = VoiceVector(raw: values, expectedDimension: Self.embeddingDimension) else {
                    throw EngineError.failed("The voice embedding was not a finite \(Self.embeddingDimension)-number vector")
                }
                return vector
            }
        } catch {
            throw FluidErrorMapping.engineError(error)
        }
    }

    /// A fresh manager per job over the shared, already-loaded models (cheap: it only stores references).
    private func makeDiarizer() throws -> sending OfflineDiarizerManager {
        guard let diarizerModels else { throw EngineError.modelsMissing }
        let manager = OfflineDiarizerManager(config: diarizerConfig)
        manager.initialize(models: diarizerModels)
        return manager
    }

    // MARK: Mapping (internal for tests)

    /// Word timings from Parakeet's token timings. If a result carries text but no timings, the words are
    /// spread evenly over the audio so no text is lost.
    static func words(from tokenTimings: [TokenTiming], text: String, duration: TimeInterval) -> [TimedWord] {
        let timed = buildWordTimings(from: tokenTimings).compactMap { w -> TimedWord? in
            let word = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, w.startTime.isFinite, w.endTime.isFinite else { return nil }
            return TimedWord(text: word, range: TimeRange(start: w.startTime, end: Swift.max(w.startTime, w.endTime)))
        }
        if !timed.isEmpty { return timed.sorted { $0.range.start < $1.range.start } }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, duration > 0 else { return [] }
        let step = duration / Double(tokens.count)
        return tokens.enumerated().map { i, word in
            TimedWord(text: word, range: TimeRange(start: Double(i) * step, end: Double(i + 1) * step))
        }
    }

    /// Community-1 output → contract types: segments sorted by start, and L2-normalised centroids per speaker
    /// (from `speakerDatabase`, else from the segments' centroid embedding).
    static func separation(from result: DiarizationResult) -> SpeakerSeparation {
        let segments = result.segments
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .map { s in
                SpeakerSegment(speakerKey: s.speakerId,
                               range: TimeRange(start: Double(s.startTimeSeconds), end: Double(s.endTimeSeconds)),
                               quality: s.qualityScore)
            }
            .sorted { ($0.range.start, $0.range.end, $0.speakerKey) < ($1.range.start, $1.range.end, $1.speakerKey) }
        var raw: [String: [Float]] = result.speakerDatabase ?? [:]
        for s in result.segments where raw[s.speakerId] == nil && !s.embedding.isEmpty {
            raw[s.speakerId] = s.embedding
        }
        let speakers = Set(segments.map(\.speakerKey))
        var centroids: [SpeakerKey: VoiceVector] = [:]
        for (key, values) in raw where speakers.contains(key) {
            if let v = VoiceVector(raw: values, expectedDimension: embeddingDimension) { centroids[key] = v }
        }
        return SpeakerSeparation(segments: segments, centroids: centroids, separator: .communityOne)
    }

    /// Spans → FluidAudio ranges, clamped to the audio. Throws for spans that start outside the audio or are empty.
    static func embeddingRanges(_ spans: [TimeRange], audioDuration: TimeInterval) throws -> [Range<TimeInterval>] {
        try spans.map { span in
            let end = Swift.min(span.end, audioDuration)
            guard span.start.isFinite, span.end.isFinite, span.start >= 0, span.start < audioDuration, end > span.start else {
                throw EngineError.failed("Voice span \(span.start)–\(span.end) s is outside the \(audioDuration) s recording")
            }
            return span.start..<end
        }
    }

    /// Duration from the file header. Missing or unreadable files fail with a clear message.
    static func audioDuration(_ url: URL) throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.failed("Audio file not found: \(url.lastPathComponent)")
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            return rate > 0 ? Double(file.length) / rate : 0
        } catch {
            throw EngineError.failed("Could not read the audio file: \(FluidErrorMapping.describe(error))")
        }
    }
}
