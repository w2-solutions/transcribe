import FluidAudio
import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFluid

/// Real FluidAudio models on the Mac host (§8.1). Run only when `TRANSCRIBE_MODELS_DIR` is set and the fixtures
/// from `scripts/make-fixtures.sh` exist. `TRANSCRIBE_MODELS_DIR` must be a complete `BundledModels` folder, the
/// one the app ships; nothing is downloaded into it. Test 9 alone fetches the 102 MB c128-split-w8a8 build once,
/// for comparison only, into `~/Library/Caches/transcribe-nemotron-compare`.
///
///   make models        (or ./scripts/fetch-models.sh --from ~/Library/Caches/transcribe-test-models)
///   ./scripts/make-fixtures.sh
///   cd TranscribeKit && TRANSCRIBE_MODELS_DIR=$PWD/../BundledModels swift test --filter FluidEngineTests
///
/// The old `~/Library/Caches/transcribe-test-models` folder no longer loads directly: its `.fluidaudio-revision`
/// marker conflicts with the diarizer's "main" revision override (`FluidRuntime`).
///
/// Run this suite on its own (with `--filter`): test 9 briefly turns `ModelHub.offlineMode` off, which would race
/// `engineLocksFluidAudioDown` if both suites ran at once.
///
/// Peak memory is logged, not asserted. None of this says anything about the iPhone 15 (A16, no Mac RAM).
@Suite("Fluid engine (gated)", .serialized,
       .enabled(if: FluidGate.isEnabled, "Set TRANSCRIBE_MODELS_DIR and run scripts/make-fixtures.sh"))
struct FluidEngineTests {
    static var modelsDirectory: String? { FluidGate.modelsDirectory }
    static func fixture(_ name: String) -> URL { FluidGate.fixture(name) }

    /// One engine for the whole suite: prepare once.
    static let shared = Task<FluidSpeechEngine, any Error> {
        let root = URL(fileURLWithPath: modelsDirectory ?? NSTemporaryDirectory(), isDirectory: true)
        let engine = FluidSpeechEngine(modelsRoot: root)
        guard engine.paths.allInstalled else {
            throw EngineError.failed("TRANSCRIBE_MODELS_DIR is not a complete BundledModels folder: run scripts/fetch-models.sh")
        }
        let clock = ContinuousClock()
        let start = clock.now
        try await engine.prepareModels()
        log("prepare (load + compile + 1 s warm-up) took \(clock.now - start); footprint \(Memory.footprintMB().rounded()) MB")
        return engine
    }

    static func log(_ message: String) { print("[FluidEngineTests] \(message)") }

    @Test("1. Parakeet v3 and the diarizer load")
    func modelsLoad() async throws {
        let engine = try await Self.shared.value
        #expect(await engine.modelStatus() == .ready)
        #expect(engine.paths.allInstalled)
        Self.log("on disk: speech \(engine.paths.speechBytesOnDisk / 1_000_000) MB, speakers \(engine.paths.speakersBytesOnDisk / 1_000_000) MB")
        try await engine.prepareModels()   // idempotent
    }

    @Test("2. The transcript contains \"transcription\"")
    func transcribes() async throws {
        let engine = try await Self.shared.value
        let url = Self.fixture("two-voices.wav")
        let duration = try FluidSpeechEngine.audioDuration(url)
        let progress = ProgressLog()
        let clock = ContinuousClock()
        let start = clock.now
        let words = try await engine.transcribe(url, language: .language("en")) { progress.append($0) }
        let elapsed = clock.now - start
        let text = words.map(\.text).joined(separator: " ")
        Self.log("transcribe \(String(format: "%.1f", duration)) s audio in \(elapsed) (RTF \(Self.rtf(elapsed, duration))); progress \(progress.values)")
        Self.log("text: \(text)")
        #expect(text.lowercased().contains("transcription"))
        #expect(words.count > 40)
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.range.start <= $1.range.start })
        #expect(words.allSatisfy { $0.range.start >= 0 && $0.range.end <= duration + 0.5 })
        #expect(progress.values.last == 1)
    }

    @Test("3. Nemotron 3 finds exactly two speakers (turns only, no centroids)")
    func separatesTwoSpeakers() async throws {
        let engine = try await Self.shared.value
        let url = Self.fixture("two-voices.wav")
        let duration = try FluidSpeechEngine.audioDuration(url)
        let progress = ProgressLog()
        let clock = ContinuousClock()
        let start = clock.now
        let separation = try await engine.separateSpeakers(url) { progress.append($0) }
        let elapsed = clock.now - start
        Self.log("separate in \(elapsed) (RTF \(Self.rtf(elapsed, duration))) by \(separation.separator); footprint \(Memory.footprintMB().rounded()) MB; progress \(progress.values)")
        for s in separation.segments {
            Self.log("  \(s.speakerKey) \(String(format: "%.2f–%.2f", s.range.start, s.range.end)) q=\(String(format: "%.2f", s.quality))")
        }
        #expect(separation.separator == .nemotron3)
        let speakers = Set(separation.segments.map(\.speakerKey))
        #expect(speakers.count == 2)
        #expect(separation.centroids.isEmpty)
        #expect(zip(separation.segments, separation.segments.dropFirst()).allSatisfy { $0.range.start <= $1.range.start })
        #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(progress.values.last == FluidSpeechEngine.separationProgressShare)
        // The first turn (Daniel) and the second (Karen) belong to different speakers.
        let first = try #require(separation.segments.first)
        let atEight = try #require(separation.segments.first { $0.range.contains(8.5) })
        #expect(first.speakerKey != atEight.speakerKey)
    }

    @Test("4. Voice vectors are 256-d and finite, and separate the two Nemotron speakers")
    func embedsSpans() async throws {
        let engine = try await Self.shared.value
        let url = Self.fixture("two-voices.wav")
        let separation = try await engine.separateSpeakers(url) { _ in }
        // The pipeline's own rule: each speaker's clean (non-overlap) speech, trimmed, ≥ 1 s per span.
        let keys = Set(separation.segments.map(\.speakerKey)).sorted()
        var perSpeaker: [[VoiceVector]] = []
        let clock = ContinuousClock()
        let start = clock.now
        for key in keys {
            let spans = CleanSpeech.embeddingSpans(CleanSpeech.spans(for: key, in: separation.segments))
            #expect(!spans.isEmpty, "\(key) has clean speech")
            let vectors = try await engine.embedVoice(url, spans: spans)
            #expect(vectors.count == spans.count)
            for v in vectors {
                #expect(v.dimension == 256)
                #expect(v.values.allSatisfy { $0.isFinite })
                #expect(abs(v.values.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
            }
            perSpeaker.append(vectors)
        }
        Self.log("embedVoice for \(keys.count) speakers in \(clock.now - start)")
        if perSpeaker.count == 2, let a = perSpeaker[0].first, let b = perSpeaker[1].first {
            let means = perSpeaker.map { VoiceVector.weightedMean($0.map { ($0, 1) }) }
            Self.log("cosine between the two speakers' first spans: \(a.cosine(b))")
            // Each speaker's spans are closer to their own mean voice than to the other speaker's.
            for (i, vectors) in perSpeaker.enumerated() {
                let own = try #require(means[i]), other = try #require(means[1 - i])
                for v in vectors { #expect(v.cosine(own) > v.cosine(other)) }
            }
        }
    }

    @Test("5. Same-voice embeddings score higher than cross-voice ones")
    func sameVoiceScoresHigher() async throws {
        let engine = try await Self.shared.value
        let a = Self.fixture("voice-a.wav"), b = Self.fixture("voice-b.wav")
        let da = try FluidSpeechEngine.audioDuration(a), db = try FluidSpeechEngine.audioDuration(b)
        // Each file holds two sentences by one voice with a 1 s pause in the middle: embed the halves.
        let va = try await engine.embedVoice(a, spans: [TimeRange(start: 0, end: da / 2 - 0.5), TimeRange(start: da / 2 + 0.5, end: da)])
        let vb = try await engine.embedVoice(b, spans: [TimeRange(start: 0, end: db / 2 - 0.5), TimeRange(start: db / 2 + 0.5, end: db)])
        let sameA = va[0].cosine(va[1]), sameB = vb[0].cosine(vb[1])
        let cross = [va[0].cosine(vb[0]), va[0].cosine(vb[1]), va[1].cosine(vb[0]), va[1].cosine(vb[1])]
        Self.log("same-voice cosine: Daniel \(sameA), Karen \(sameB); cross-voice: \(cross)")
        #expect(sameA > (cross.max() ?? 1))
        #expect(sameB > (cross.max() ?? 1))
    }

    @Test("6. Silence → .noSpeech")
    func silenceIsNoSpeech() async throws {
        let engine = try await Self.shared.value
        let url = Self.fixture("silence.wav")
        await #expect(throws: EngineError.noSpeech) { _ = try await engine.separateSpeakers(url) { _ in } }
        let words = try await engine.transcribe(url, language: .automatic) { _ in }
        Self.log("transcribe(silence) → \(words.count) words: \(words.map(\.text))")
        #expect(words.filter { $0.text.contains(where: \.isLetter) }.isEmpty)
    }

    @Test("7. Audio under 0.3 s → .tooShort")
    func shortAudioIsTooShort() async throws {
        let engine = try await Self.shared.value
        await #expect(throws: EngineError.tooShort) {
            _ = try await engine.transcribe(Self.fixture("short.wav"), language: .automatic) { _ in }
        }
    }

    @Test("8. Live text from the shared models while capturing (file-fed capture source)")
    func liveTextWhileCapturing() async throws {
        let engine = try await Self.shared.value
        let source = try FileCaptureSource(url: Self.fixture("two-voices.wav"))
        let out = try TestAudio.temporaryDirectory().appendingPathComponent("live.wav")
        let recording = try await engine.startRecording(RecordingRequest(audioURL: out, liveText: true, language: .language("en")),
                                                       source: source)
        let events = collectEvents(recording.events)
        let clock = ContinuousClock()
        let start = clock.now
        await source.play()
        let audio = try await recording.stop()
        Self.log("live capture of \(String(format: "%.1f", audio.duration)) s finished in \(clock.now - start); footprint \(Memory.footprintMB().rounded()) MB")
        let live = await events.value.compactMap { e -> LiveText? in if case .liveText(let t) = e { t } else { nil } }
        Self.log("live updates: \(live.count); last confirmed: \"\(live.last?.confirmed ?? "")\" volatile: \"\(live.last?.volatile ?? "")\"")
        #expect(!live.isEmpty)
        #expect(live.contains { !$0.isEmpty })
        #expect(abs(audio.duration - (await source.duration)) < 0.01)
        #expect(audio.peaks.count == 200)
        // The batch path still works after the live manager released its references.
        let words = try await engine.transcribe(out, language: .language("en")) { _ in }
        #expect(words.map(\.text).joined(separator: " ").lowercased().contains("transcription"))
        Self.log("peak footprint over the suite: \(Memory.peakFootprintMB().rounded()) MB")
    }

    /// Candidate live-text window layouts: (name, chunk, left, right) in seconds.
    static let liveLayouts: [(String, Double, Double, Double)] = [
        ("fluid .streaming 11+2+2", 11, 2, 2), ("app 2 s step", 2, 10, 1),
    ]

    @Test("8b. Live text keeps up with speech played in real time (logged per window layout)", arguments: 0..<liveLayouts.count)
    func liveTextLatency(_ index: Int) async throws {
        let (name, chunk, left, right) = Self.liveLayouts[index]
        let engine = try await Self.shared.value
        let fixture = Self.fixture("three-voices.wav")
        let source = try FileCaptureSource(url: fixture)
        let out = try TestAudio.temporaryDirectory().appendingPathComponent("live.wav")
        let config = name.hasPrefix("app") ? FluidLiveRecording.liveConfig
            : SlidingWindowAsrConfig(chunkSeconds: chunk, hypothesisChunkSeconds: 1, leftContextSeconds: left,
                                     rightContextSeconds: right, minContextForConfirmation: 4, confirmationThreshold: 0.8)
        let recording = try await engine.startRecording(RecordingRequest(audioURL: out, liveText: true, language: .language("en")),
                                                       source: source, liveConfig: config)
        let events = collectEvents(recording.events)
        await source.play(chunkPause: .milliseconds(97))      // about real time
        let duration = await source.duration
        _ = try await recording.stop()
        // Audio position (from the ticks) at which each live text update arrived.
        var position = 0.0
        var updates: [(at: Double, text: LiveText)] = []
        for event in await events.value {
            if case .tick(let elapsed, _) = event { position = elapsed }
            if case .liveText(let text) = event { updates.append((position, text)) }
        }
        let during = updates.filter { $0.at < duration - 0.2 }
        let gaps = zip(during.dropFirst(), during).map { $0.at - $1.at }
        let live = updates.last.map { FluidLiveRecording.join($0.text.confirmed, $0.text.volatile) } ?? ""
        let batch = try await engine.transcribe(fixture, language: .language("en")) { _ in }.map(\.text)
        func bag(_ words: [String]) -> [String: Int] {
            words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
                .reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let liveBag = bag(live.split(separator: " ").map(String.init)), batchBag = bag(batch)
        let shared = batchBag.reduce(0) { $0 + Swift.min($1.value, liveBag[$1.key] ?? 0) }
        let recall = Double(shared) / Double(Swift.max(1, batchBag.values.reduce(0, +)))
        Self.log("live layout \(name): first text at \(String(format: "%.1f", during.first?.at ?? -1)) s of \(String(format: "%.1f", duration)) s; "
                 + "\(during.count) updates while speaking, longest wait \(String(format: "%.1f", gaps.max() ?? 0)) s; "
                 + "\(Int((recall * 100).rounded()))% of the batch words; live words \(liveBag.values.reduce(0, +)) vs batch \(batchBag.values.reduce(0, +))")
        Self.log("live layout \(name) text: \(live)")
        #expect(!during.isEmpty)
        if name.hasPrefix("app") {
            #expect((during.first?.at ?? 99) < 6)
            #expect((gaps.max() ?? 99) < 6)
            #expect(recall > 0.85)
        }
    }

    /// The 95 MB split-graph W8A8 build, for comparison only (the app ships fp16 `fast128`).
    static let splitW8A8 = Nemotron3Config(
        chunkLen: 128, chunkRightContext: 4, fifoLen: 40, spkcacheUpdatePeriod: 40,
        modelFileName: "Nemotron3Diarizer_c128_split_w8a8.mlmodelc", splitGraph: true)

    @Test("9. Nemotron 3 fast128 vs c128-split-w8a8 vs community-1 (logged comparison)",
          arguments: ["two-voices", "three-voices"])
    func comparesSeparators(fixture: String) async throws {
        let engine = try await Self.shared.value
        let url = Self.fixture("\(fixture).wav")
        let truth = try TrueTurns.load(Self.fixture("\(fixture).turns.json"))
        let duration = try FluidSpeechEngine.audioDuration(url)
        // The comparison build is not part of the app: fetch it once (about 102 MB) into its own cache, never into
        // the models folder, then lay it out flat (bundle + both assets) the way `NemotronSeparation.run` reads it.
        let flat = try await Self.flatSplitW8A8()
        enum Run: CaseIterable { case fast128, w8a8, communityOne }
        var reports: [SeparatorReport] = []
        for run in Run.allCases {
            func once() async throws -> SpeakerSeparation {
                switch run {
                case .fast128: return try await engine.separateSpeakers(url, only: .nemotron3) { _ in }
                case .communityOne: return try await engine.separateSpeakers(url, only: .communityOne) { _ in }
                case .w8a8:
                    let activities = try await NemotronSeparation.run(audio: url, directory: flat, config: Self.splitW8A8) { _ in }
                    guard case .use(let separation) = NemotronSeparation.decide(activities) else {
                        throw EngineError.failed("w8a8 would fall back")
                    }
                    return separation
                }
            }
            _ = try await once()   // warm, then measure the second run
            let sampler = FootprintSampler()
            let before = Memory.footprintMB()
            let clock = ContinuousClock()
            let start = clock.now
            let separation = try await once()
            let elapsed = clock.now - start
            let peak = sampler.stop()
            let label = switch run { case .fast128: "nemotron3-fast128"; case .w8a8: "nemotron3-c128-split-w8a8"; case .communityOne: "communityOne" }
            let report = SeparatorReport(fixture: fixture, separator: separation.separator, label: label,
                                         separation: separation, truth: truth, duration: duration, elapsed: elapsed,
                                         footprintBeforeMB: before, peakMB: peak, residentGrowthMB: sampler.residentGrowthMB)
            Self.log(report.summary)
            for s in separation.segments {
                Self.log("    \(s.speakerKey) \(String(format: "%.2f–%.2f", s.range.start, s.range.end))")
            }
            reports.append(report)
        }
        let diff = SegmentDiff(reports[0].segments, reports[1].segments, duration: duration)
        Self.log("COMPARE \(fixture) fast128 vs c128-split-w8a8: \(diff.summary)")
        // Hard checks only where the result is stable. On `say` voices Nemotron 3's speaker count for three voices
        // depends on the third voice (Moira: 2 speakers; Rishi: 3, every turn right), so that row is logged, not asserted.
        let fast128 = reports[0]
        #expect(fast128.separator == .nemotron3)
        #expect(fast128.coveredShare > 0.95, "Nemotron 3 leaves no turn edges uncovered in \(fixture)")
        if fixture == "two-voices" {
            #expect(fast128.speakers == 2)
            #expect(fast128.attributedShare > 0.95, "Nemotron 3 gives >95% of the speech to the right voice")
        }
    }

    /// `~/Library/Caches/transcribe-nemotron-compare/flat-c128-split-w8a8`, filled once from Hugging Face.
    static func flatSplitW8A8() async throws -> URL {
        let fm = FileManager.default
        let compareRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("transcribe-nemotron-compare", isDirectory: true)
        let flat = compareRoot.appendingPathComponent("flat-c128-split-w8a8", isDirectory: true)
        let bundle = Self.splitW8A8.modelFileName
        guard !fm.fileExists(atPath: flat.appendingPathComponent("\(bundle)/coremldata.bin").path) else { return flat }
        do {
            ModelHub.offlineMode = false
            defer { ModelHub.offlineMode = true }
            _ = try await Nemotron3Models.loadFromHuggingFace(config: Self.splitW8A8, cacheDirectory: compareRoot,
                                                              computeUnits: NemotronSeparation.computeUnits)
        }
        let repo = compareRoot.appendingPathComponent(FluidModelPaths.nemotronFolderName, isDirectory: true)
        if fm.fileExists(atPath: flat.path) { try fm.removeItem(at: flat) }
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for (from, name) in [(repo.appendingPathComponent("\(Self.splitW8A8.hubSubdirectory)/\(bundle)"), bundle),
                             (repo.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile), ModelNames.Nemotron3.silenceEmbeddingFile),
                             (repo.appendingPathComponent(ModelNames.Nemotron3.preEncodeProjectionFile), ModelNames.Nemotron3.preEncodeProjectionFile)] {
            try fm.copyItem(at: from, to: flat.appendingPathComponent(name))   // clones on APFS
        }
        return flat
    }

    /// A copy of the models folder in a fresh temporary directory (`copyItem` clones on APFS).
    static func cloneModels(from root: URL) throws -> URL {
        let clone = try TestAudio.temporaryDirectory().appendingPathComponent(FluidModelPaths.bundledFolderName, isDirectory: true)
        try FileManager.default.copyItem(at: root, to: clone)
        return clone
    }

    /// Every item below `root`, hidden files included: relative path → size and modification date.
    static func snapshot(_ root: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw EngineError.failed("Cannot list \(root.path)")
        }
        let base = root.resolvingSymlinksInPath().path
        var out: [String: String] = [:]
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: Set(keys))
            var relative = item.resolvingSymlinksInPath().path
            if relative.hasPrefix(base) { relative.removeFirst(base.count) }
            let date = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1
            out[relative] = "\(values.isDirectory == true ? "dir" : "\(values.fileSize ?? -1)")@\(date)"
        }
        return out
    }

    static func chmod(_ mode: String, _ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", mode, url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EngineError.failed("chmod -R \(mode) failed") }
    }

    @Test("10. Nothing writes into the models folder")
    func nothingWritesIntoTheModelsFolder() async throws {
        let shared = try await Self.shared.value
        let clone = try Self.cloneModels(from: shared.paths.root)
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let before = try Self.snapshot(clone)
        #expect(!before.isEmpty)
        let engine = FluidSpeechEngine(modelsRoot: clone)
        try await engine.prepareModels()
        let url = Self.fixture("two-voices.wav")
        _ = try await engine.transcribe(url, language: .language("en")) { _ in }
        _ = try await engine.separateSpeakers(url, only: .nemotron3) { _ in }
        _ = try await engine.separateSpeakers(url, only: .communityOne) { _ in }
        _ = try await engine.embedVoice(url, spans: [TimeRange(start: 0, end: 3)])
        let after = try Self.snapshot(clone)
        #expect(after == before, "added or changed: \(after.filter { before[$0.key] != $0.value }.keys.sorted()); removed: \(Set(before.keys).subtracting(after.keys).sorted())")
    }

    @Test("11. Loads from a read-only copy")
    func loadsFromAReadOnlyCopy() async throws {
        let shared = try await Self.shared.value
        let clone = try Self.cloneModels(from: shared.paths.root)
        try Self.chmod("a-w", clone)
        defer {
            try? Self.chmod("u+w", clone)
            try? FileManager.default.removeItem(at: clone.deletingLastPathComponent())
        }
        let engine = FluidSpeechEngine(modelsRoot: clone)
        try await engine.prepareModels()
        #expect(await engine.modelStatus() == .ready)
        let separation = try await engine.separateSpeakers(Self.fixture("two-voices.wav"), only: .nemotron3) { _ in }
        #expect(separation.separator == .nemotron3)
    }

    @Test("12. Without Background Inference, nothing starts in the background; a pause is not a failure")
    func withoutEntitlementPausesBeforeStart() async throws {
        let shared = try await Self.shared.value
        let base = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let log = base.appendingPathComponent("prepare-log.jsonl")
        let activity = AppActivity(backgroundInference: false)
        let engine = FluidSpeechEngine(modelsRoot: shared.paths.root, prepareLog: log, activity: activity)
        activity.armGrace(UUID())   // a held short task is not enough without the entitlement
        activity.enterBackground()
        let refusedEvents = PrepareEventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: refusedEvents.sink) }
        #expect(refusedEvents.stages.isEmpty, "a refused stage sends no start")
        #expect(refusedEvents.plans.count == 1)
        #expect(await engine.modelStatus() == .installed)
        #expect(await engine.nemotronDisabledReason == nil)
        let record = try #require(await engine.lastPrepareRecord)
        Self.log("log line: \(PrepareLog.line(record) ?? "")")
        #expect(record.outcome == "paused" && record.pauseReason == "startRefused")
        #expect(record.stages.map(\.verdict) == ["notStarted"])

        // Back in front: ready, and both prepares are in the log file.
        activity.becomeActive()
        let events = PrepareEventLog()
        try await engine.prepareModels(onEvent: events.sink)
        #expect(await engine.modelStatus() == .ready)
        // The plan, then a started/finished pair per stage, in order.
        #expect(events.plans.count == 1 && events.all.first == .planned(events.plans[0]))
        #expect(events.plans.first?.steps.map(\.stage) == [.diarizer, .nemotron, .asr, .warmup])
        #expect(events.stages == PrepareEventLog.pairs([.diarizer, .nemotron, .asr, .warmup]))

        let ready = try #require(await engine.lastPrepareRecord)
        Self.log("log line: \(PrepareLog.line(ready) ?? "")")
        #expect(ready.resumesPause == true)
        #expect(ready.stages.map(\.name) == ["diarizer", "nemotron", "asr", "warmup"])
        #expect(ready.nemotronUnits == "cpuOnly")
        #expect(ready.stages.allSatisfy { $0.verdict == "kept" && $0.bgAtStart == false })
        #expect(ready.nemotronWarmUpOK == true)
        #expect(PrepareLog.read(log).map(\.outcome) == ["paused", "ready"])
    }

    @Test("13. With Background Inference, stages run and are kept in the background; ready in the background")
    func withEntitlementRunsInBackground() async throws {
        let shared = try await Self.shared.value
        let activity = AppActivity(backgroundInference: true)
        let engine = FluidSpeechEngine(modelsRoot: shared.paths.root, activity: activity)
        let grace = UUID()
        activity.armGrace(grace)
        activity.enterBackground()
        try await engine.prepareModels()
        #expect(await engine.modelStatus() == .ready, "a stage that returns in the background is kept")
        let ready = try #require(await engine.lastPrepareRecord)
        Self.log("background: \(PrepareLog.summary(ready))")
        #expect(ready.outcome == "ready" && ready.pauseReason == nil && ready.readyInBackground == true)
        #expect(ready.backgroundInference == true)
        #expect(ready.stages.map(\.name) == ["diarizer", "nemotron", "asr", "warmup"])
        #expect(ready.stages.allSatisfy {
            $0.verdict == "kept" && $0.bgAtStart == true && $0.bgAtEnd == true && $0.error == nil
                && $0.aneAtStart == true && $0.aneAtEnd == true
        })
        #expect(await engine.nemotronDisabledReason == nil)
        let words = try await engine.transcribe(Self.fixture("two-voices.wav"), language: .language("en")) { _ in }
        #expect(!words.isEmpty)

        // After the short task expired, a new prepare (another engine) starts nothing.
        let later = FluidSpeechEngine(modelsRoot: shared.paths.root, activity: activity)
        activity.graceExpired(grace)
        await #expect(throws: EngineError.cancelled) { try await later.prepareModels() }
        let refused = try #require(await later.lastPrepareRecord)
        #expect(refused.pauseReason == "startRefused" && refused.stages.map(\.verdict) == ["notStarted"])
        #expect(activity.transitions().last?.kind == .expired)
        #expect(refused.transitions?.isEmpty == true, "the record keeps only transitions during its own prepare")
        #expect(await later.modelStatus() == .installed)
    }

    @Test("13b. With Background Inference but no Neural Engine listed, Neural Engine stages only prime; ready in front")
    func withEntitlementWithoutNeuralEnginePrimes() async throws {
        let shared = try await Self.shared.value
        let activity = AppActivity(backgroundInference: true)
        // Core ML lists the Neural Engine only while the app is in front.
        let engine = FluidSpeechEngine(modelsRoot: shared.paths.root, activity: activity,
                                       neuralEngineProbe: { !activity.inBackground },
                                       captureFactory: { MicrophoneCapture() })
        activity.armGrace(UUID())
        activity.enterBackground()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels() }
        #expect(await engine.modelStatus() == .installed, "a model that may have loaded for the CPU is never kept")
        let primed = try #require(await engine.lastPrepareRecord)
        Self.log("background: \(PrepareLog.summary(primed))")
        #expect(primed.outcome == "paused" && primed.pauseReason == "primedInBackground")
        #expect(primed.stages.map(\.name) == ["diarizer", "nemotron", "asr", "warmup"])
        #expect(primed.stages.allSatisfy { $0.bgAtStart == true && $0.aneAtEnd == false })
        // Nemotron runs on the CPU: whether Core ML lists the Neural Engine says nothing about it, so it is kept.
        #expect(primed.stages.map(\.verdict) == ["primed", "kept", "primed", "primed"])
        #expect(await engine.nemotronDisabledReason == nil)
        #expect(await engine.liveModels() == nil)

        // In front: every Neural Engine model loads again (warm) and is kept; Nemotron is not loaded again.
        activity.becomeActive()
        try await engine.prepareModels()
        #expect(await engine.modelStatus() == .ready)
        let ready = try #require(await engine.lastPrepareRecord)
        Self.log("front: \(PrepareLog.summary(ready))")
        #expect(ready.outcome == "ready" && ready.resumesPause == true && ready.readyInBackground == nil)
        #expect(ready.stages.map(\.name) == ["diarizer", "asr", "warmup"])
        #expect(ready.stages.allSatisfy { $0.verdict == "kept" && $0.bgAtStart == false })
    }

    @Test("14. Without Background Inference, a stage that spanned a trip away is dropped; the next prepare is warm")
    func withoutEntitlementDropsStageThatSpannedBackground() async throws {
        let shared = try await Self.shared.value
        // A fresh path, so the dropped stage compiles cold and the resumed one shows whether that compile was kept.
        let clone = try Self.cloneModels(from: shared.paths.root)
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let activity = AppActivity(backgroundInference: false)
        let engine = FluidSpeechEngine(modelsRoot: clone, activity: activity, afterStageWork: { name in
            if name == "asr", activity.epoch == 0 { activity.enterBackground(); activity.becomeActive() }
        }, captureFactory: { MicrophoneCapture() })
        let droppedEvents = PrepareEventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: droppedEvents.sink) }
        #expect(droppedEvents.stages == PrepareEventLog.pairs([.diarizer, .nemotron, .asr]),
                "a dropped stage's compile is done: finished; the warm-up never starts")
        #expect(await engine.modelStatus() == .installed)
        let dropped = try #require(await engine.lastPrepareRecord)
        Self.log("dropped: \(PrepareLog.summary(dropped))")
        #expect(dropped.pauseReason == "returnedInBackground")
        #expect(dropped.stages.map(\.verdict) == ["kept", "kept", "droppedBackground"])
        #expect(await engine.liveModels() == nil)
        let coldASR = try #require(dropped.stages.first { $0.name == "asr" })
        #expect(coldASR.epochChanged == true && coldASR.error == nil)
        #expect(coldASR.seconds > 2, "the dropped asr stage compiled cold on its new path (\(coldASR.seconds) s)")

        let resumedEvents = PrepareEventLog()
        try await engine.prepareModels(onEvent: resumedEvents.sink)
        #expect(await engine.modelStatus() == .ready)
        #expect(resumedEvents.plans.first?.step(.asr)?.expectedSeconds == PrepareEstimates.warmDefaults[.asr],
                "asr compiled in this process: warm")
        let ready = try #require(await engine.lastPrepareRecord)
        Self.log("resumed: \(PrepareLog.summary(ready))")
        #expect(ready.resumesPause == true)
        #expect(ready.stages.map(\.name) == ["asr", "warmup"], "the diarizer and Nemotron were kept")
        #expect(ready.stages.allSatisfy { $0.verdict == "kept" })
        let asr = try #require(ready.stages.first { $0.name == "asr" })
        #expect(asr.seconds < coldASR.seconds / 4,
                "asr reloads warm from the dropped stage's compile (\(asr.seconds) s after \(coldASR.seconds) s cold)")
    }

    @Test("15. After the warm-up is dropped, the next plan keeps the diarizer and Nemotron done and runs the rest warm")
    func aDroppedStageStillFinishesAndTheKeptStagesAreDone() async throws {
        let shared = try await Self.shared.value
        let activity = AppActivity(backgroundInference: false)
        // The user leaves and comes back during the warm-up, the last stage: it is dropped, and the prepare pauses.
        // The diarizer, Nemotron and Parakeet ran wholly in front; the diarizer and Nemotron are kept for the process.
        let engine = FluidSpeechEngine(modelsRoot: shared.paths.root, activity: activity, afterStageWork: { name in
            if name == "warmup", activity.epoch == 0 { activity.enterBackground(); activity.becomeActive() }
        }, captureFactory: { MicrophoneCapture() })
        let first = PrepareEventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: first.sink) }
        // A dropped stage's work returned (its compile is cached), so it still sends stageFinished; only a stage that
        // throws sends none (FluidEngineBackgroundTests).
        #expect(first.stages == PrepareEventLog.pairs([.diarizer, .nemotron, .asr, .warmup]))
        let second = PrepareEventLog()
        try await engine.prepareModels(onEvent: second.sink)
        #expect(await engine.modelStatus() == .ready)
        let plan = try #require(second.plans.first)
        #expect(plan.step(.diarizer)?.isDone == true, "the diarizer was kept: not loaded again")
        #expect(plan.step(.nemotron)?.isDone == true, "Nemotron was kept: not loaded again")
        #expect(plan.steps.filter { !$0.isDone }.allSatisfy { $0.expectedSeconds == PrepareEstimates.warmDefaults[$0.stage] },
                "every stage still to run compiled in this process: warm")
        #expect(plan.timesFromThisDevice)
        #expect(second.stages == PrepareEventLog.pairs([.asr, .warmup]))
    }

    @Test("16. Without Background Inference, Nemotron (CPU) is kept after a trip away; Parakeet then waits for the front")
    func theCPUStageIsKeptInTheBackgroundWithoutTheEntitlement() async throws {
        let shared = try await Self.shared.value
        let activity = AppActivity(backgroundInference: false)
        // The user leaves while Nemotron loads and stays away (the short task still held).
        let engine = FluidSpeechEngine(modelsRoot: shared.paths.root, activity: activity, afterStageWork: { name in
            if name == "nemotron", activity.epoch == 0 { activity.armGrace(UUID()); activity.enterBackground() }
        }, captureFactory: { MicrophoneCapture() })
        let first = PrepareEventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: first.sink) }
        #expect(first.stages == PrepareEventLog.pairs([.diarizer, .nemotron]), "Parakeet's start is refused")
        let paused = try #require(await engine.lastPrepareRecord)
        Self.log("cpu stage away: \(PrepareLog.summary(paused))")
        #expect(paused.pauseReason == "startRefused")
        #expect(paused.stages.map(\.verdict) == ["kept", "kept", "notStarted"])
        let nemotron = try #require(paused.stages.first { $0.name == "nemotron" })
        #expect(nemotron.bgAtEnd == true && nemotron.error == nil)
        #expect(await engine.nemotronDisabledReason == nil)

        activity.becomeActive()
        let second = PrepareEventLog()
        try await engine.prepareModels(onEvent: second.sink)
        #expect(await engine.modelStatus() == .ready)
        #expect(second.plans.first?.step(.nemotron)?.isDone == true)
        #expect(second.stages == PrepareEventLog.pairs([.asr, .warmup]))
    }

    @Test("17. A Nemotron that fails after a trip away pauses; in front it falls back to community-1 and setup reaches ready")
    func aNemotronLoadFailureFallsBackToCommunityOne() async throws {
        let shared = try await Self.shared.value
        // A copy whose Nemotron program is garbage: still "installed" (the bundle's files exist), but it cannot load.
        // (A truncated weight.bin is no good here: Core ML crashes reading it instead of throwing.)
        let clone = try Self.cloneModels(from: shared.paths.root)
        defer { try? FileManager.default.removeItem(at: clone.deletingLastPathComponent()) }
        let program = clone.appendingPathComponent(FluidModelPaths.nemotronFolderName, isDirectory: true)
            .appendingPathComponent("\(NemotronSeparation.config.modelFileName)/model.mil")
        try FileManager.default.removeItem(at: program)
        try Data("not a program".utf8).write(to: program)
        let activity = AppActivity(backgroundInference: false)
        let engine = FluidSpeechEngine(modelsRoot: clone, activity: activity, afterStageWork: { name in
            if name == "nemotron", activity.epoch == 0 { activity.enterBackground(); activity.becomeActive() }
        }, captureFactory: { MicrophoneCapture() })
        #expect(engine.paths.allInstalled)

        // After a trip away the failure may be the background's doing: a pause, and Nemotron is not disabled.
        let away = PrepareEventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: away.sink) }
        #expect(away.stages == PrepareEventLog.pairs([.diarizer]) + [.stageStarted(.nemotron)],
                "a stage that throws sends no finish")
        let paused = try #require(await engine.lastPrepareRecord)
        Self.log("nemotron failed away: \(PrepareLog.summary(paused))")
        #expect(paused.pauseReason == "failedInBackground")
        #expect(paused.stages.map(\.verdict) == ["kept", "paused"])
        #expect(await engine.nemotronDisabledReason == nil)

        // In front it fails again: Nemotron is disabled for the process and setup carries on to ready.
        let front = PrepareEventLog()
        try await engine.prepareModels(onEvent: front.sink)
        #expect(await engine.modelStatus() == .ready)
        #expect(front.plans.first?.step(.nemotron) != nil, "not disabled yet when the plan was made")
        #expect(front.stages == [.stageStarted(.nemotron)] + PrepareEventLog.pairs([.asr, .warmup]))
        let ready = try #require(await engine.lastPrepareRecord)
        Self.log("nemotron failed in front: \(PrepareLog.summary(ready))")
        #expect(ready.outcome == "ready" && ready.nemotronWarmUpOK == false)
        #expect(ready.stages.map(\.verdict) == ["failed", "kept", "kept"])
        #expect(ready.stages.first?.error != nil)
        #expect(await engine.nemotronDisabledReason != nil)

        let separation = try await engine.separateSpeakers(Self.fixture("two-voices.wav")) { _ in }
        #expect(separation.separator == .communityOne)
        #expect(Set(separation.segments.map(\.speakerKey)).count >= 2)
    }

    static func rtf(_ elapsed: Duration, _ audioSeconds: Double) -> String {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return String(format: "%.3f", seconds / Swift.max(audioSeconds, 0.001))
    }
}

/// Whether the gated suite can run: a models directory and the generated fixtures.
enum FluidGate {
    static var modelsDirectory: String? { ProcessInfo.processInfo.environment["TRANSCRIBE_MODELS_DIR"] }
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
    static let fixtureNames = ["two-voices.wav", "two-voices.turns.json", "three-voices.wav", "three-voices.turns.json",
                               "voice-a.wav", "voice-b.wav", "silence.wav", "short.wav"]
    static var isEnabled: Bool {
        modelsDirectory != nil && fixtureNames.allSatisfy { FileManager.default.fileExists(atPath: fixture($0).path) }
    }
}

/// Thread-safe progress recorder for engine callbacks.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ v: Double) { lock.withLock { storage.append(v) } }
    var values: [Double] { lock.withLock { storage } }
}

/// Collects a prepare's events (`FluidSpeechEngine.prepareModels(onEvent:)`).
final class PrepareEventLog: Sendable {
    private let events = Mutex<[PrepareEvent]>([])
    var sink: @Sendable (PrepareEvent) -> Void { { [self] e in events.withLock { $0.append(e) } } }
    var all: [PrepareEvent] { events.withLock { $0 } }
    var plans: [PreparePlan] { all.compactMap { if case .planned(let p) = $0 { p } else { nil } } }
    /// Every event but the plans.
    var stages: [PrepareEvent] { all.filter { if case .planned = $0 { false } else { true } } }
    static func pairs(_ stages: [PrepareStage]) -> [PrepareEvent] {
        stages.flatMap { [PrepareEvent.stageStarted($0), .stageFinished($0)] }
    }
}
