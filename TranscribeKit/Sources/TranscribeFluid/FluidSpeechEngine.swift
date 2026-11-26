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
/// written. `FluidRuntime.lockDown()` puts FluidAudio in offline mode before any loader runs. Every prepare writes
/// one `PrepareRecord` (per-stage timings) to `prepareLog` when there is one, and a summary line to the unified log.
///
/// Progress: `prepareModels(onEvent:)` sends a `PreparePlan` (expected seconds per stage, from `PrepareEstimates` and
/// the prepare log) and a started/finished pair per stage, to the caller that started the prepare only.
///
/// Stages, in order (`PrepareStage`): diarizer (community-1, Neural Engine), nemotron (Nemotron 3, CPU only), asr
/// (Parakeet, Neural Engine, the long compile) and warmup (a silent transcription through Parakeet). The short ones
/// run first so they are done before the user can leave mid-compile. The engine is ready once, when every stage has
/// been kept; there is no partial readiness.
///
/// Background (iPhone; `activity`, see `AppActivity`). A Neural Engine stage starts in the background only when the
/// build has Background Inference and the short background task is still held; otherwise the prepare pauses before
/// it (`startRefused`). A stage that returns wholly in front is kept. A Neural Engine stage that touched the
/// background and returned is kept too with Background Inference (the entitlement grants the Neural Engine in the
/// background), so the prepare can reach ready while the app is away (`readyInBackground`; `ModelManager` fires
/// `onReady` only back in front). The exception is a stage at whose start or end Core ML did not list the Neural
/// Engine: its model may have loaded for the CPU, so it only primes the compile (`primed`: the prepare goes on and
/// then pauses, and the next prepare in front loads it again warm). Without Background Inference, a Neural Engine
/// stage that touched the background is dropped and the prepare pauses at once. The CPU-only stage (nemotron) needs
/// neither the entitlement nor the Neural Engine: it may start in the background while the short task is held, and
/// it is kept whenever it returns. A stage that throws is a failure only when it ran wholly in front; otherwise it
/// is a pause too. A pause throws `EngineError.cancelled`, sets no load failure (the status reads installed, so the
/// next foreground prepares again) and never disables Nemotron. Nothing measures wall time: a stage that spans a
/// suspension is judged by its transitions, not its seconds; each stage's record keeps `bgAtStart`/`bgAtEnd` and
/// `aneAtStart`/`aneAtEnd`, so a slow stage kept in the background still shows. The Mac never moves `activity` to
/// the background.
///
/// iOS drops the compiled Neural Engine models on every install or update, wherever the model files live (measured
/// on an iPhone 15, 2026-11-25), so the first prepare after each install compiles Parakeet and community-1 again.
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
    /// Where each prepare's `PrepareRecord` is appended (`<AppPaths.root>/prepare-log.jsonl`), or nil to only log it.
    let prepareLog: URL?
    /// The last prepare's record (tests).
    private(set) var lastPrepareRecord: PrepareRecord?
    /// Whether the app is in front, and whether this build may use the Neural Engine in the background.
    public nonisolated let activity: AppActivity
    /// Tests: called when each stage's work has returned or thrown, before its verdict (to move the app mid-stage).
    private let afterStageWork: (@Sendable (String) async -> Void)?
    /// Whether Core ML lists a Neural Engine now (`PrepareLog.neuralEngineAvailable`; tests replace it).
    private let neuralEngineProbe: @Sendable () -> Bool
    /// A prepare in this process paused.
    private var hasPaused = false
    /// Stages whose work returned in this process (kept, primed or dropped): their compile is cached, so they run
    /// again warm.
    private var compiledThisProcess: Set<PrepareStage> = []
    /// The running prepare's event sink (only its starter's).
    private var eventSink: (@Sendable (PrepareEvent) -> Void)?
    /// The stages the running prepare's plan expects warm (recorded per stage as `expectedWarm`).
    private var plannedWarm: Set<PrepareStage> = []

    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "FluidSpeechEngine")
    /// Makes the capture source for what a recording captures, with the stems a Both recording writes.
    private let captureFactory: @Sendable (CaptureSources, CaptureStems) -> any CaptureSource
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
    /// Nemotron 3 loaded once in this process (the prepare's nemotron stage), so it is known to load here.
    private var nemotronLoaded = false

    /// The embedding dimension of WeSpeaker ResNet34 (community-1).
    static let embeddingDimension = EmbeddingModelID.communityOneResNet34.dimension
    static let sampleRate = 16_000
    /// Parakeet's minimum input (`ASRConstants.minimumAudioDurationSeconds`).
    static let minimumASRSeconds = ASRConstants.minimumAudioDurationSeconds

    /// No I/O: the app builds this engine even for fake-engine runs. `prepareLog` is only written by a prepare.
    public init(modelsRoot: URL, prepareLog: URL? = nil, activity: AppActivity = AppActivity()) {
        self.init(modelsRoot: modelsRoot, prepareLog: prepareLog, activity: activity,
                  captureFactory: { MicrophoneCapture() }, sourceFactory: Self.makeCaptureSource)
    }

    /// Tests inject a scripted capture source, a Neural Engine probe and a hook between a stage's work and its
    /// verdict. `captureFactory` makes microphone sources; `sourceFactory`, when given, makes every source instead
    /// (Mac audio tests). Without it, Mac audio uses the real sources.
    init(modelsRoot: URL, prepareLog: URL? = nil, activity: AppActivity = AppActivity(),
         afterStageWork: (@Sendable (String) async -> Void)? = nil,
         neuralEngineProbe: @escaping @Sendable () -> Bool = { PrepareLog.neuralEngineAvailable() },
         captureFactory: @escaping @Sendable () -> any CaptureSource,
         sourceFactory: (@Sendable (CaptureSources, CaptureStems) -> any CaptureSource)? = nil) {
        FluidRuntime.lockDown()
        self.activity = activity
        self.afterStageWork = afterStageWork
        self.neuralEngineProbe = neuralEngineProbe
        self.modelsRoot = modelsRoot
        self.paths = FluidModelPaths(root: modelsRoot)
        self.prepareLog = prepareLog
        self.captureFactory = sourceFactory ?? { sources, stems in
            sources == .microphone ? captureFactory() : Self.makeCaptureSource(sources, stems)
        }
        self.asrConfig = Self.makeASRConfig()
        self.diarizerConfig = Self.makeDiarizerConfig()
    }

    /// ASR folder (`AsrModels.load(from:)` takes the repo folder itself).
    var asrDirectory: URL { paths.asrDirectory }
    /// Why Nemotron 3 is disabled for this process, or nil (tests: a pause never disables it).
    var nemotronDisabledReason: String? { nemotronUnavailable }

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
        try await prepareModels(onEvent: { _ in })
    }

    public func prepareModels(onEvent: @escaping @Sendable (PrepareEvent) -> Void) async throws {
        if isReady { return }
        if let prepareTask {
            do { try await prepareTask.value } catch { throw FluidErrorMapping.engineError(error) }
            return
        }
        guard paths.allInstalled else { throw EngineError.modelsMissing }
        eventSink = onEvent
        let task = Task { try await self.loadAndWarmUp() }
        prepareTask = task
        defer { prepareTask = nil; eventSink = nil }
        do {
            try await task.value
            loadFailure = nil
        } catch {
            let mapped = Self.isCancellation(error) ? EngineError.cancelled : FluidErrorMapping.engineError(error)
            if mapped == .cancelled {
                // A pause (the app went to the background) or a cancelled task: not a failure. No load failure is
                // kept, so the status reads installed and the next foreground prepares again.
                loadFailure = nil
                log.notice("Model preparation paused: \(FluidErrorMapping.describe(error), privacy: .public)")
                throw EngineError.cancelled
            }
            loadFailure = FluidErrorMapping.describe(error)
            log.error("Model preparation failed: \(self.loadFailure ?? "", privacy: .public)")
            throw mapped
        }
    }

    /// Load every model (compiling for the Neural Engine on first use after an install), then a 1 s silent warm-up
    /// transcription. One `PrepareRecord` is written whatever the outcome.
    private func loadAndWarmUp() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let startDate = Date()
        var record = PrepareRecord.begin()
        record.backgroundInference = activity.backgroundInference
        record.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if hasPaused { record.resumesPause = true }
        func finish(_ outcome: String) {
            record.outcome = outcome
            record.nemotronWarmUpOK = nemotronLoaded
            record.totalSeconds = PrepareLog.seconds(clock.now - start)
            record.noteTransitions(activity.transitions(since: startDate))
            writeRecord(record)
        }
        do {
            try await loadStages(record: &record)
        } catch let pause as PrepareInterruption {
            hasPaused = true
            record.pauseReason = pause.reason.rawValue
            finish("paused")
            throw pause
        } catch {
            record.error = FluidErrorMapping.describe(error)
            finish("failed")
            throw error
        }
        isReady = true
        if activity.inBackground { record.readyInBackground = true }
        finish("ready")
        log.info("Speech models ready in \(record.totalSeconds, format: .fixed(precision: 2)) s")
    }

    /// The four stages, timed into `record`, short ones first (`PrepareStage`): community-1, Nemotron 3 (CPU),
    /// Parakeet, then the warm-up (it needs the loaded Parakeet, so the two run back to back as one step for the
    /// user). community-1 and Nemotron are kept for the process as soon as each is kept; Parakeet is stored only
    /// when every stage was kept (see the type doc), so a pause throws `PrepareInterruption` and the next prepare
    /// loads Parakeet again (warm).
    private func loadStages(record: inout PrepareRecord) async throws {
        let paths = self.paths
        let plan = currentPlan()
        plannedWarm = Set(plan.steps.filter(\.isWarm).map(\.stage))
        emit(.planned(plan))
        var everyStageKept = true
        if diarizerModels == nil {
            let configuration = Self.makeDiarizerMLConfiguration()
            let run = try await runStage(.diarizer, record: &record) {
                try await OfflineDiarizerModels.load(from: paths.diarizerLoadDirectory, configuration: configuration)
            }
            if run.kept {
                diarizerModels = run.value
            } else {
                everyStageKept = false
            }
        }
        if !nemotronLoaded, nemotronUnavailable == nil, paths.nemotronInstalled {
            // Loads Nemotron 3 once on the CPU (about 1 s) and releases it (each separation loads it again): the
            // check that it loads on this device. A failure in front is not fatal: separation falls back to
            // community-1 for the rest of the process.
            do {
                let run = try await runStage(.nemotron, record: &record) {
                    try await NemotronSeparation.warmUp(directory: paths.nemotronDirectory)
                }
                if run.kept {
                    nemotronLoaded = true
                    log.info("Nemotron 3 (\(NemotronSeparation.presetName, privacy: .public)) loaded in \(run.value, format: .fixed(precision: 2)) s")
                } else {
                    everyStageKept = false
                }
            } catch let pause as PrepareInterruption {
                throw pause
            } catch {
                nemotronUnavailable = FluidErrorMapping.describe(error)
                log.error("Nemotron 3 failed to load; using community-1 for speaker separation: \(self.nemotronUnavailable ?? "", privacy: .public)")
            }
        }
        let manager = AsrManager(config: asrConfig)
        let asrRun = try await runStage(.asr, record: &record) { () async throws -> AsrModels in
            let models = try await AsrModels.load(from: paths.asrDirectory, version: .v3)
            try await manager.loadModels(models)
            return models
        }
        everyStageKept = everyStageKept && asrRun.kept
        let sampleRate = Self.sampleRate
        let warmRun = try await runStage(.warmup, record: &record) {
            var warmState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            _ = try await manager.transcribe([Float](repeating: 0, count: sampleRate), decoderState: &warmState)
        }
        everyStageKept = everyStageKept && warmRun.kept
        // A stage that only primed (in the background without the Neural Engine listed): pause, so the next prepare
        // (in front) loads it again, warm.
        guard everyStageKept else { throw PrepareInterruption(reason: .primedInBackground) }
        asr = manager
        asrModels = asrRun.value
    }

    /// Runs one stage under the background rules (type doc) and records it. Returns the stage's result and whether
    /// it was kept; a result that was not kept (primed) must be released. Throws `PrepareInterruption` for a pause,
    /// and the stage's own error for a failure in front.
    private func runStage<T>(_ stage: PrepareStage, record: inout PrepareRecord,
                             _ work: () async throws -> T) async throws -> (value: T, kept: Bool) {
        let name = stage.rawValue
        guard let window = activity.stageWindow(usesNeuralEngine: stage.usesNeuralEngine) else {
            record.addRefusedStage(name, at: Date(), inBackground: activity.inBackground)
            log.notice("Prepare stage \(name, privacy: .public) not started: the app is in the background")
            throw PrepareInterruption(reason: .startRefused)
        }
        emit(.stageStarted(stage))
        let started = Date()
        let aneAtStart = neuralEngineProbe()
        func note(_ verdict: StageVerdict, error: String? = nil, aneAtEnd: Bool? = nil) {
            let ended = Date()
            record.addStage(name, start: started, end: ended, error: error)
            record.noteLastStage(bgAtStart: window.inBackground, bgAtEnd: activity.inBackground,
                                 epochChanged: activity.epoch != window.epoch, verdict: verdict,
                                 suspendedSeconds: PrepareLog.suspendedSeconds(start: started, end: ended,
                                                                               transitions: activity.transitions()),
                                 aneAtStart: aneAtStart, aneAtEnd: aneAtEnd ?? neuralEngineProbe(),
                                 expectedWarm: plannedWarm.contains(stage))
        }
        let value: T
        do {
            value = try await work()
            // The compile is done whatever the verdict (kept, primed or dropped): the next run of it is warm.
            compiledThisProcess.insert(stage)
            emit(.stageFinished(stage))
            await afterStageWork?(name)
        } catch {
            await afterStageWork?(name)
            let message = FluidErrorMapping.describe(error)
            guard activity.isForegroundClean(window) else {
                note(.paused, error: message)
                log.notice("Prepare stage \(name, privacy: .public) threw after a trip to the background; pausing: \(message, privacy: .public)")
                throw PrepareInterruption(reason: .failedInBackground)
            }
            note(.failed, error: message)
            throw error
        }
        if activity.isForegroundClean(window) {
            note(.kept)
            return (value, true)
        }
        if !stage.usesNeuralEngine {
            // CPU only: the background changes nothing about what it loaded, so it is kept wherever it ran.
            note(.kept)
            log.notice("Prepare stage \(name, privacy: .public) returned after a trip to the background; kept (CPU only)")
            return (value, true)
        }
        if activity.backgroundInference {
            // The entitlement grants the Neural Engine in the background, so a stage that returned is kept wherever
            // it ran, unless Core ML did not list the Neural Engine at its start or end: then it may have loaded for
            // the CPU, so it only primes the compile and is loaded again in front.
            let aneAtEnd = neuralEngineProbe()
            if aneAtStart && aneAtEnd {
                note(.kept, aneAtEnd: aneAtEnd)
                log.notice("Prepare stage \(name, privacy: .public) returned after a trip to the background; kept (Background Inference)")
                return (value, true)
            }
            note(.primed, aneAtEnd: aneAtEnd)
            log.notice("Prepare stage \(name, privacy: .public) returned in the background without the Neural Engine listed; primed only")
            return (value, false)
        }
        note(.droppedBackground)
        log.notice("Prepare stage \(name, privacy: .public) returned after a trip to the background; dropped, pausing")
        throw PrepareInterruption(reason: .returnedInBackground)
    }

    /// The plan for the prepare starting now (`PrepareEstimates`), from the prepare log and this process's state.
    private func currentPlan() -> PreparePlan {
        let records = prepareLog.map(PrepareLog.read) ?? []
        return PrepareEstimates.plan(
            records: records, osBuild: PrepareLog.osBuild(), installStamp: PrepareLog.installStamp(),
            nemotronUnits: PrepareEstimates.unitsName(NemotronSeparation.computeUnits),
            hwModel: PrepareLog.hardwareModel(),
            compiled: compiledThisProcess, diarizerDone: diarizerModels != nil, nemotronDone: nemotronLoaded,
            includeNemotron: nemotronUnavailable == nil && paths.nemotronInstalled)
    }

    private func emit(_ event: PrepareEvent) {
        eventSink?(event)
    }

    private func writeRecord(_ record: PrepareRecord) {
        lastPrepareRecord = record
        PrepareLog.append(record, to: prepareLog)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || FluidErrorMapping.engineError(error) == .cancelled
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

    /// Mac audio (a Core Audio process tap) exists on the Mac only.
    public nonisolated var systemAudioAvailable: Bool { Self.recordsMacAudio }
    #if os(macOS)
    static let recordsMacAudio = true
    #else
    static let recordsMacAudio = false
    #endif

    /// The real source for each choice: the microphone, Mac audio alone (straight into the recording's file, no
    /// stems), or both mixed with stems.
    static func makeCaptureSource(_ sources: CaptureSources, _ stems: CaptureStems) -> any CaptureSource {
        #if os(macOS)
        switch sources {
        case .microphone: return MicrophoneCapture()
        case .macAudio: return SystemAudioCapture()
        case .both: return MixedCaptureSource(mic: MicrophoneCapture(), system: SystemAudioCapture(), stems: stems)
        }
        #else
        return MicrophoneCapture()
        #endif
    }

    public func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        guard request.sources == .microphone || systemAudioAvailable else { throw EngineError.sourceUnavailable }
        // Mac audio alone needs no microphone; its access is asked by the system when the tap first runs.
        if request.sources.includesMicrophone {
            guard await microphonePermission() == .granted else { throw EngineError.microphoneDenied }
        }
        let stems = request.stems ?? CaptureStems.beside(audioURL: request.audioURL)
        return try await startRecording(request, source: captureFactory(request.sources, stems))
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
