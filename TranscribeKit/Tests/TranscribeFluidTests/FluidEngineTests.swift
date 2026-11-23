import FluidAudio
import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFluid

/// Real FluidAudio models on the Mac host (§8.1). Run only when `TRANSCRIBE_MODELS_DIR` is set and the fixtures
/// from `scripts/make-fixtures.sh` exist. The first run downloads about 704 MB into that directory (an older
/// directory with only Parakeet and community-1 fetches just Nemotron 3 fast128, about 199 MB); test 9 also fetches
/// the 102 MB c128-split-w8a8 build once, for comparison only.
///
///   ./scripts/make-fixtures.sh
///   cd TranscribeKit && TRANSCRIBE_MODELS_DIR=/path/to/models swift test --filter "Fluid engine"
///
/// Peak memory is logged, not asserted. None of this says anything about the iPhone 15 (A16, no Mac RAM).
@Suite("Fluid engine (gated)", .serialized,
       .enabled(if: FluidGate.isEnabled, "Set TRANSCRIBE_MODELS_DIR and run scripts/make-fixtures.sh"))
struct FluidEngineTests {
    static var modelsDirectory: String? { FluidGate.modelsDirectory }
    static func fixture(_ name: String) -> URL { FluidGate.fixture(name) }

    /// One engine for the whole suite: install (if needed) and prepare once.
    static let shared = Task<FluidSpeechEngine, any Error> {
        let root = URL(fileURLWithPath: modelsDirectory ?? NSTemporaryDirectory(), isDirectory: true)
        let engine = FluidSpeechEngine(modelsRoot: root)
        let clock = ContinuousClock()
        if await engine.modelStatus() == .notInstalled {
            let start = clock.now
            let lastLogged = LockedDouble()
            try await engine.installModels { p in
                if p.fraction - lastLogged.value >= 0.1 || p.fraction == 1 {
                    lastLogged.value = p.fraction
                    log("install \(Int(p.fraction * 100))% \(p.phase)")
                }
            }
            log("install finished in \(clock.now - start)")
        }
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
        let root = engine.paths.nemotronLoadDirectory
        // The comparison build is not part of the app's install: fetch it once (about 102 MB) into the same folder.
        let w8a8Present = FileManager.default.fileExists(atPath: engine.paths.nemotronDirectory
            .appendingPathComponent("split/\(Self.splitW8A8.modelFileName)/coremldata.bin").path)
        if !w8a8Present {
            ModelHub.offlineMode = false
            defer { ModelHub.offlineMode = true }
            _ = try await Nemotron3Models.loadFromHuggingFace(config: Self.splitW8A8, cacheDirectory: root,
                                                              computeUnits: NemotronSeparation.computeUnits)
        }
        enum Run: CaseIterable { case fast128, w8a8, communityOne }
        var reports: [SeparatorReport] = []
        for run in Run.allCases {
            func once() async throws -> SpeakerSeparation {
                switch run {
                case .fast128: return try await engine.separateSpeakers(url, only: .nemotron3) { _ in }
                case .communityOne: return try await engine.separateSpeakers(url, only: .communityOne) { _ in }
                case .w8a8:
                    let activities = try await NemotronSeparation.run(audio: url, root: root, config: Self.splitW8A8) { _ in }
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

final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0.0
    var value: Double {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
