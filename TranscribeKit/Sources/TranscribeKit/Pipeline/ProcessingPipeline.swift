import Foundation
import TranscribeCore

/// The step state of one job, published as a `ProcessingSnapshot`.
struct JobProgress: Sendable, Equatable {
    var states: [ProcessingStep: StepState] = [:]
    var voicesFound: Int?
    var comparedWith: [String] = []
    var phase: ProcessingPhase = .running

    func snapshot(_ id: UUID) -> ProcessingSnapshot {
        let steps = ProcessingStep.allCases.map { step in
            let state = states[step] ?? .waiting
            return StepStatus(step: step, state: state,
                              subtitle: ProcessingCopy.subtitle(step: step, state: state, voicesFound: voicesFound,
                                                                comparedWith: comparedWith))
        }
        return ProcessingSnapshot(recordingID: id, steps: steps, overall: ProcessingPipeline.overall(states),
                                  voicesFound: voicesFound, comparedWith: comparedWith, phase: phase)
    }
}

/// Pure pieces of the processing pipeline (§5.6). The steps themselves run in `ProcessingCoordinator`.
public enum ProcessingPipeline {
    public enum ResumePoint: Sendable, Equatable { case transcribe, separate, match }

    public static let identifyOffReason = "Identify speakers is off"
    public static let recogniseOffReason = "Recognise saved voices is off"
    public static let noSavedVoicesReason = "No saved voices yet"
    public static let noSpeechDetectedReason = "No speech detected"
    public static let noSpeechFoundReason = "No speech found"

    /// Σ weights of done or skipped steps + weight(active) × fraction, in 0...1.
    public static func overall(_ states: [ProcessingStep: StepState]) -> Double {
        var total = 0.0
        for step in ProcessingStep.allCases {
            let weight = ProcessingCopy.weights[step] ?? 0
            switch states[step] ?? .waiting {
            case .done, .skipped: total += weight
            case .active(let fraction): total += weight * Swift.min(1, Swift.max(0, fraction ?? 0))
            case .waiting: break
            }
        }
        return Swift.min(1, total)
    }

    /// Where a job continues: the stage is the checkpoint, the transcript blob is step 1's output.
    public static func resumePoint(_ s: RecordingSnapshot) -> ResumePoint {
        if s.transcript == nil { return .transcribe }
        if s.stage == .separated || s.stage == .matching { return .match }
        return .separate
    }

    /// The last completed checkpoint, which is what a waiting or cancelled job persists
    /// (cancelling `.separating` leaves `.transcribed`).
    public static func checkpointStage(_ s: RecordingSnapshot) -> RecordingStage {
        switch resumePoint(s) {
        case .transcribe: .queued
        case .separate: .transcribed
        case .match: .separated
        }
    }

    /// Step states implied by the persisted checkpoint (for queued and resumed jobs).
    static func baseStates(_ s: RecordingSnapshot) -> [ProcessingStep: StepState] {
        switch resumePoint(s) {
        case .transcribe: [:]
        case .separate: [.transcribing: .done]
        case .match: [.transcribing: .done, .separating: .done]
        }
    }

    /// Speaker-less paragraphs over the document's words.
    public static func paragraphDocument(_ doc: TranscriptDocument, config: AlignmentConfig) -> TranscriptDocument {
        TranscriptDocument(words: doc.words, turns: TurnBuilder.paragraphs(words: doc.words, config: config),
                           language: doc.language, asrModelID: doc.asrModelID)
    }

    static func languageCode(_ hint: LanguageHint) -> String? {
        if case .language(let code) = hint { code } else { nil }
    }

    // MARK: Mac audio (decision D1)

    /// Which stream each speaker of a recording was heard on, and which file each is embedded from.
    struct SourcePlan: Sendable, Equatable {
        var sources: CaptureSources
        var audio: URL
        /// The stems of a Both recording, when both files exist.
        var stems: CaptureStems?
        var attribution: [SpeakerKey: SourceAttribution.Result] = [:]
        var silent = false

        var stemsFound: Bool { stems != nil }

        /// nil for a microphone-only recording (stored as nil: no sync change for such recordings); `.system` for Mac
        /// audio only; in Both mode the attributed source, or `.mixed` when the stems are gone (processing ran again
        /// after they were deleted) or the speaker has no clean speech to attribute.
        func source(of key: SpeakerKey) -> SpeakerSource? {
            switch sources {
            case .microphone: nil
            case .macAudio: .system
            case .both: stems == nil ? .mixed : (attribution[key]?.source ?? .mixed)
            }
        }

        /// The file a speaker is embedded from: its own stem in Both mode, else the recording.
        func embeddingURL(for source: SpeakerSource?) -> URL {
            guard sources == .both, let stems else { return audio }
            switch source {
            case .system?: return stems.system
            case .mic?: return stems.mic
            case .mixed?, nil: return audio
            }
        }
    }

    /// Reads the system stem of a Both recording and attributes every speaker (`SourceAttribution`). A missing or
    /// unreadable stem leaves `stems` nil, so every speaker is mixed.
    static func sourcePlan(sources: CaptureSources, audio: URL, spans: [SpeakerKey: [TimeRange]],
                           policy: SourceAttributionPolicy) -> SourcePlan {
        var plan = SourcePlan(sources: sources, audio: audio)
        guard sources == .both else { return plan }
        let stems = CaptureStems.beside(audioURL: audio)
        let fm = FileManager.default
        guard fm.fileExists(atPath: stems.mic.path), fm.fileExists(atPath: stems.system.path),
              let levels = try? SourceAttribution.levels(ofWAV: stems.system, policy: policy) else { return plan }
        let analysis = SourceAttribution.analyse(levels, policy: policy)
        plan.stems = stems
        plan.silent = analysis.silent
        plan.attribution = spans.mapValues {
            SourceAttribution.attribute(spans: $0, levels: levels, analysis: analysis, policy: policy)
        }
        return plan
    }

    /// Adds the speaker's source and system share to the traces of a recording that captured Mac audio (trace v3).
    /// A microphone-only recording's traces are left exactly as they were.
    static func annotate(_ traces: [SpeakerKey: MatchTrace], sources: CaptureSources,
                         attribution: [SpeakerKey: SourceAttribution.Result]) -> [SpeakerKey: MatchTrace] {
        guard sources != .microphone else { return traces }
        return traces.mapValues { trace in
            var t = trace
            if let a = attribution[t.key] {
                t.speakerSource = a.source.rawValue
                t.systemShare = SourceAttribution.rounded(a.share)
            } else if sources == .macAudio {
                t.speakerSource = SpeakerSource.system.rawValue
            }
            t.version = Swift.max(t.version, MatchTrace.groupsVersion)
            return t
        }
    }
}

// MARK: - Steps

extension ProcessingCoordinator {
    /// Runs the remaining steps of one recording from its checkpoint. Returns nil when there is nothing
    /// to do (already ready, failed or still capturing). Throws on cancellation or failure.
    func runPipeline(_ id: UUID) async throws -> ProcessingOutcome? {
        let store = self.store
        let engine = self.engine
        let alignment = self.alignment
        let snap = try await lane { try store.snapshot(of: id) }
        guard snap.stage >= .queued, snap.stage < .ready else { return nil }
        Self.log.info("job \(id, privacy: .public): starting at \(String(describing: ProcessingPipeline.resumePoint(snap)), privacy: .public) (stage \(String(describing: snap.stage), privacy: .public))")
        let options = await settings.pipeline
        let audio = paths.audioURL(fileName: snap.audioFileName)
        updateJob(id) { $0.states = ProcessingPipeline.baseStates(snap); $0.phase = .running }

        // Step 1: transcribe (skipped when the transcript checkpoint exists).
        var document: TranscriptDocument
        if let existing = snap.transcript {
            document = existing
        } else {
            try await lane { try store.setStage(.transcribing, queueReason: nil, for: id) }
            updateJob(id) { $0.states[.transcribing] = .active(fraction: 0) }
            var words: [TimedWord]
            do {
                words = try await withProgress(id, .transcribing) { progress in
                    try await engine.transcribe(audio, language: snap.language, progress: progress)
                }
            } catch EngineError.tooShort {
                words = []
            }
            words.sort { $0.range.start < $1.range.start }
            updateJob(id) { $0.states[.transcribing] = .done }
            let language = ProcessingPipeline.languageCode(snap.language)
            if words.isEmpty {
                updateJob(id) {
                    $0.states[.separating] = .skipped(ProcessingPipeline.noSpeechDetectedReason)
                    $0.states[.matching] = .skipped(ProcessingPipeline.noSpeechDetectedReason)
                }
                let empty = TranscriptDocument(words: [], turns: [], language: language, asrModelID: engine.info.asrModelID)
                return try await lane { try store.finishWithoutMatching(id: id, document: empty, noSpeech: true) }
            }
            document = TranscriptDocument(words: words, turns: TurnBuilder.paragraphs(words: words, config: alignment),
                                          language: language, asrModelID: engine.info.asrModelID)
            let checkpoint = document
            try await lane { try store.checkpointTranscript(id: id, document: checkpoint) }
        }
        try Task.checkCancellation()

        // Step 2: separate speakers.
        guard options.identifySpeakers else {
            updateJob(id) {
                $0.states[.separating] = .skipped(ProcessingPipeline.identifyOffReason)
                $0.states[.matching] = .skipped(ProcessingPipeline.identifyOffReason)
            }
            let doc = ProcessingPipeline.paragraphDocument(document, config: alignment)
            return try await lane { try store.finishWithoutMatching(id: id, document: doc, noSpeech: false) }
        }
        // Which stream each speaker was heard on (Both mode only), kept for the match traces of this run.
        var attribution: [SpeakerKey: SourceAttribution.Result] = [:]
        if ProcessingPipeline.resumePoint(snap) == .match {
            let voices = try await lane { try store.probes(for: id).count }
            updateJob(id) { $0.voicesFound = voices; $0.states[.separating] = .done }
        } else {
            try await lane { try store.setStage(.separating, queueReason: nil, for: id) }
            updateJob(id) { $0.states[.separating] = .active(fraction: 0) }
            // One progress run for the whole step: the engine reports the diariser, then each speaker's voice
            // embedding moves the bar on (the heaviest part on long recordings), so it never sits at 100%.
            let documentSoFar = document
            let built = try await withProgress(id, .separating) { progress in
                var separation: SpeakerSeparation
                do {
                    separation = try await engine.separateSpeakers(audio, progress: progress)
                } catch EngineError.noSpeech {
                    separation = SpeakerSeparation(segments: [], centroids: [:])
                }
                Self.log.info("job \(id, privacy: .public): speakers separated by \(separation.separator.rawValue, privacy: .public)")
                return try await self.buildSpeakers(document: documentSoFar, separation: separation, audio: audio,
                                                    sources: snap.captureSources, progress: progress)
            }
            attribution = built.attribution
            Self.log.info("job \(id, privacy: .public): \(built.drafts.count) voices found")
            if built.drafts.isEmpty {
                updateJob(id) {
                    $0.voicesFound = 0
                    $0.states[.separating] = .done
                    $0.states[.matching] = .skipped(ProcessingPipeline.noSpeechFoundReason)
                }
                let doc = ProcessingPipeline.paragraphDocument(document, config: alignment)
                return try await lane { try store.finishWithoutMatching(id: id, document: doc, noSpeech: false) }
            }
            let doc = built.document, drafts = built.drafts
            try await lane { try store.checkpointSeparation(id: id, document: doc, speakers: drafts) }
            updateJob(id) { $0.voicesFound = drafts.count; $0.states[.separating] = .done }
        }
        try Task.checkCancellation()

        // Step 3: match saved voices.
        let modelKey = engine.info.embeddingModel.key
        let candidates = options.recogniseVoices ? try await lane { try store.matchCandidates(modelKey: modelKey) } : []
        let eligible = candidates.filter { !$0.samples.isEmpty && !$0.needsResample }
        let probes = try await lane { try store.probes(for: id) }
        let decisions: [SpeakerKey: MatchDecision]
        let traces: [SpeakerKey: MatchTrace]
        if !options.recogniseVoices || eligible.isEmpty {
            let reason = options.recogniseVoices ? ProcessingPipeline.noSavedVoicesReason : ProcessingPipeline.recogniseOffReason
            updateJob(id) { $0.states[.matching] = .skipped(reason) }
            decisions = Dictionary(probes.map { ($0.key, MatchDecision.unknown(.noEligibleProfiles)) },
                                   uniquingKeysWith: { a, _ in a })
            traces = [:]
        } else {
            try await lane { try store.setStage(.matching, queueReason: nil, for: id) }
            let names = eligible.map(\.name)
            updateJob(id) { $0.comparedWith = names; $0.states[.matching] = .active(fraction: nil) }
            let cohort = try await lane { try store.matchCohort(modelKey: modelKey, excludingRecording: id) }
            let run = VoiceMatcher.decideWithTrace(probes: probes, profiles: candidates, modelKey: modelKey,
                                                   policy: policy, cohort: cohort)
            decisions = run.decisions
            traces = ProcessingPipeline.annotate(run.traces, sources: snap.captureSources, attribution: attribution)
            for trace in traces.values.sorted(by: { $0.key < $1.key }) { Self.logTrace(trace, job: id) }
            updateJob(id) { $0.states[.matching] = .done }
        }
        let policy = self.policy
        return try await lane { try store.applyMatches(id: id, decisions: decisions, traces: traces, policy: policy) }
    }

    /// One line per speaker for tuning: numbers are public, profile ids private.
    static func logTrace(_ t: MatchTrace, job id: UUID) {
        func f(_ x: Float?) -> String { x.map { String(format: "%.4f", $0) } ?? "-" }
        let cohortMax = t.profiles.compactMap(\.cohortMax).max()
        let blocked = t.profiles.filter(\.blocked).count
        let profile = t.profileID?.uuidString ?? "-"
        let source = t.speakerSource ?? "-"
        Self.log.info("job \(id, privacy: .public): match \(t.key, privacy: .public) \(t.kind.rawValue, privacy: .public) reason=\(t.reason, privacy: .public) profile=\(profile, privacy: .private) score=\(f(t.score), privacy: .public) margin=\(f(t.margin), privacy: .public) runnerUp=\(f(t.runnerUp), privacy: .public) cohortMax=\(f(cohortMax), privacy: .public) blocked=\(blocked, privacy: .public) source=\(source, privacy: .public) systemShare=\(f(t.systemShare), privacy: .public)")
    }

    /// Speaker turns, ordinals, clean speech and one voice vector per speaker (§5.6 step 2).
    /// Speaker separation share of the step's progress; the rest is per-speaker voice embedding.
    static let separationProgressShare = 0.6
    /// The stream attribution constants (untested starting values; logged in the matching log's policy block).
    static let attributionPolicy = SourceAttributionPolicy.default

    func buildSpeakers(document: TranscriptDocument, separation: SpeakerSeparation, audio: URL,
                       sources: CaptureSources = .microphone,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws
        -> (document: TranscriptDocument, drafts: [SpeakerDraft], attribution: [SpeakerKey: SourceAttribution.Result]) {
        let segments = separation.segments.sorted { $0.range.start < $1.range.start }
        guard !segments.isEmpty, !document.words.isEmpty else { return (document, [], [:]) }
        let turns = TurnBuilder.speakerTurns(words: document.words, segments: segments, config: alignment)
        let ordinals = SpeakerOrdinals.assign(turns: turns)
        let model = engine.info.embeddingModel
        var drafts: [SpeakerDraft] = []
        let ordered = ordinals.sorted(by: { $0.value < $1.value })
        let cleanSpans = Dictionary(uniqueKeysWithValues: ordered.map { key, _ in
            (key, CleanSpeech.spans(for: key, in: segments, config: alignment))
        })
        let plan = ProcessingPipeline.sourcePlan(sources: sources, audio: audio, spans: cleanSpans,
                                                 policy: Self.attributionPolicy)
        if sources != .microphone {
            Self.log.info("sources \(sources.rawValue, privacy: .public): stems \(plan.stemsFound ? "found" : "missing", privacy: .public), system stream \(plan.silent ? "silent" : "active", privacy: .public)")
        }
        let share = Self.separationProgressShare
        for (index, (key, ordinal)) in ordered.enumerated() {
            defer { progress?(share + (1 - share) * Double(index + 1) / Double(ordered.count)) }
            try Task.checkCancellation()
            let spans = cleanSpans[key] ?? []
            let source = plan.source(of: key)
            var vector: VoiceVector?
            var coherence: Float?
            if !spans.isEmpty {
                let embedSpans = CleanSpeech.embeddingSpans(spans, config: alignment)
                do {
                    // Each speaker from its own stream: system speakers from the system stem, microphone speakers
                    // from the microphone stem, mixed speakers (and every speaker of a one-stream recording) from
                    // the recording itself.
                    let vectors = try await engine.embedVoice(plan.embeddingURL(for: source), spans: embedSpans)
                    if vectors.count == embedSpans.count,
                       let robust = VoiceVector.robustMean(zip(vectors, embedSpans).map { ($0, $1.duration) },
                                                           dropBelow: policy.spanDropBelow,
                                                           minKeptFraction: policy.spanMinKeptFraction) {
                        vector = robust.vector
                        coherence = robust.coherence
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                }
                if vector == nil { vector = separation.centroids[key]; coherence = nil }
                if let v = vector, v.dimension != model.dimension { vector = nil; coherence = nil }
            }
            drafts.append(SpeakerDraft(key: key, ordinal: ordinal, cleanSeconds: CleanSpeech.seconds(spans),
                                       totalSeconds: CleanSpeech.totalSeconds(for: key, in: segments),
                                       turnCount: turns.filter { $0.speakerKey == key }.count,
                                       vector: vector, embeddingModel: model, coherence: coherence, source: source))
        }
        let flagged = turns.flatMap(\.words)
        let words = flagged.count == document.words.count ? flagged : document.words
        let doc = TranscriptDocument(words: words, turns: turns, language: document.language, asrModelID: document.asrModelID)
        return (doc, drafts, plan.attribution)
    }

    /// Runs one engine call while forwarding its progress, in order, to the job's snapshot.
    /// Every progress update has been applied before this returns.
    func withProgress<T: Sendable>(_ id: UUID, _ step: ProcessingStep,
                                   _ body: (@escaping @Sendable (Double) -> Void) async throws -> T) async throws -> T {
        let (stream, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { [self] in
            for await fraction in stream { stepProgress(id, step, fraction) }
        }
        do {
            let value = try await body { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            return value
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }

    func stepProgress(_ id: UUID, _ step: ProcessingStep, _ fraction: Double) {
        let f = Swift.min(1, Swift.max(0, fraction))
        updateJob(id, force: f >= 1) { job in
            guard case .active(let current) = job.states[step] else { return }
            // Never move backwards: separation and voice embedding report on one bar.
            if let current, f < current { return }
            job.states[step] = .active(fraction: f)
        }
    }
}
