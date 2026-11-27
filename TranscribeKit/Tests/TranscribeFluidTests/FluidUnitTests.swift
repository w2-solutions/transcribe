@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFluid

// Tests that need no models and no microphone. The model-backed tests are in FluidEngineTests.swift.

@Suite("LanguageMapping")
struct LanguageMappingTests {
    @Test("Every Parakeet v3 language maps to a FluidAudio language with the same code",
          arguments: Languages.parakeetV3.map(\.code))
    func everyParakeetLanguageMaps(code: String) throws {
        let language = try #require(LanguageMapping.fluid(.language(code)))
        #expect(language.rawValue == code)
    }

    @Test func automaticIsNil() {
        #expect(LanguageMapping.fluid(.automatic) == nil)
    }

    @Test func codesAreCaseInsensitiveAndUnknownIsAutomatic() {
        #expect(LanguageMapping.fluid(.language("EN")) == .english)
        #expect(LanguageMapping.fluid(.language("xx")) == nil)
    }
}

@Suite("FluidModelPaths")
struct FluidModelPathsTests {
    private func makeDiarizer(in paths: FluidModelPaths, skipping: String? = nil, partialIn: String? = nil,
                              noCoreMLDataIn: String? = nil) throws {
        let fm = FileManager.default
        for name in FluidModelPaths.diarizerRequiredFiles where name != skipping {
            let url = paths.diarizerDirectory.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                if name != noCoreMLDataIn { try Data(repeating: 1, count: 1_000).write(to: url.appendingPathComponent("coremldata.bin")) }
                if name == partialIn {
                    let weights = url.appendingPathComponent("weights", isDirectory: true)
                    try fm.createDirectory(at: weights, withIntermediateDirectories: true)
                    try Data([1]).write(to: weights.appendingPathComponent("weight.bin.partial"))
                }
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: url)
            }
        }
    }

    @Test func folderLayoutMatchesTheLoaders() {
        let paths = FluidModelPaths(root: URL(fileURLWithPath: "/models", isDirectory: true))
        // FluidAudio's cache folder names drop the repo's "-coreml" suffix (`Repo.folderName`).
        #expect(paths.asrDirectory.path == "/models/parakeet-tdt-0.6b-v3")
        #expect(paths.diarizerDirectory.path == "/models/speaker-diarization")
        #expect(paths.diarizerLoadDirectory.path == "/models")
        #expect(FluidModelPaths.diarizerRequiredFiles ==
                ["Embedding.mlmodelc", "FBank.mlmodelc", "PldaRho.mlmodelc", "Segmentation.mlmodelc", "plda-parameters.json"])
        // Nemotron3Models.load(config:directory:) reads a flat folder: the bundle next to its asset.
        #expect(paths.nemotronDirectory.path == "/models/nemotron-3-diarization")
        #expect(FluidModelPaths.nemotronRequiredFiles == ["Nemotron3Diarizer_fast128.mlmodelc", "learnable_sil_emb.bin"])
        #expect(FluidModelPaths.nemotronSilenceEmbeddingBytes == 2_048)
    }

    @Test func bundledRootIsResourcesBundledModels() {
        let root = FluidModelPaths.bundledRoot(in: .main)
        #expect(root.lastPathComponent == "BundledModels")
        #expect(FluidModelPaths.bundledFolderName == "BundledModels")
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        #expect(root.deletingLastPathComponent().standardizedFileURL.path == resources.standardizedFileURL.path)
    }

    /// Lays out the Nemotron 3 files flat, the way the app bundle ships them.
    private func makeNemotron(in paths: FluidModelPaths, skipping: String? = nil, partial: Bool = false,
                              silBytes: Int = 2_048) throws {
        let fm = FileManager.default
        for name in FluidModelPaths.nemotronRequiredFiles where name != skipping {
            let url = paths.nemotronDirectory.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try fm.createDirectory(at: url.appendingPathComponent("weights"), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 600).write(to: url.appendingPathComponent("coremldata.bin"))
                if partial { try Data([1]).write(to: url.appendingPathComponent("weights/weight.bin.partial")) }
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0, count: silBytes).write(to: url)
            }
        }
    }

    @Test func completeFlatNemotronFolderIsInstalled() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        #expect(!paths.nemotronInstalled)
        try makeNemotron(in: paths)
        #expect(paths.nemotronInstalled)
        #expect(paths.speakersBytesOnDisk > 0)
        #expect(!paths.allInstalled) // ASR and community-1 still missing
    }

    @Test func hubLayoutNemotronIsNotInstalled() throws {
        // The hub's `monolithic/v2/<bundle>` layout is not what `load(directory:)` reads.
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        let fm = FileManager.default
        let bundle = paths.nemotronDirectory.appendingPathComponent("monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data([1]).write(to: bundle.appendingPathComponent("coremldata.bin"))
        try Data(repeating: 0, count: 2_048).write(to: paths.nemotronDirectory.appendingPathComponent("learnable_sil_emb.bin"))
        #expect(!paths.nemotronInstalled)
    }

    @Test func wrongSizeSilenceEmbeddingIsNotInstalled() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeNemotron(in: paths, silBytes: 2_047)
        #expect(!paths.nemotronInstalled)
    }

    @Test func nemotronMissingAnAssetOrMidDownloadIsNotInstalled() throws {
        let noSilence = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeNemotron(in: noSilence, skipping: "learnable_sil_emb.bin")
        #expect(!noSilence.nemotronInstalled)
        let noBundle = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeNemotron(in: noBundle, skipping: "Nemotron3Diarizer_fast128.mlmodelc")
        #expect(!noBundle.nemotronInstalled)
        let partial = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeNemotron(in: partial, partial: true)
        #expect(!partial.nemotronInstalled)
    }

    @Test func bundleWithoutNemotronIsNotAllInstalled() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeDiarizer(in: paths)
        #expect(paths.diarizerInstalled && !paths.nemotronInstalled && !paths.allInstalled)
    }

    @Test func diarizerWithARevisionMarkerIsNotInstalled() throws {
        // With the "main" revision override, FluidAudio would reject a folder whose marker names the pinned commit.
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeDiarizer(in: paths)
        #expect(paths.diarizerInstalled)
        try Data((Repo.diarizer.revision + "\n").utf8)
            .write(to: paths.diarizerDirectory.appendingPathComponent(".fluidaudio-revision"))
        #expect(!paths.diarizerInstalled)
    }

    @Test func emptyRootIsNotInstalled() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        #expect(!paths.asrInstalled)
        #expect(!paths.diarizerInstalled)
        #expect(!paths.allInstalled)
        #expect(paths.speechBytesOnDisk == 0)
    }

    @Test func completeDiarizerFolderIsInstalled() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeDiarizer(in: paths)
        #expect(paths.diarizerInstalled)
        #expect(paths.speakersBytesOnDisk > 0)
        #expect(!paths.allInstalled) // ASR still missing
    }

    @Test func missingFileMakesDiarizerIncomplete() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeDiarizer(in: paths, skipping: "plda-parameters.json")
        #expect(!paths.diarizerInstalled)
    }

    @Test func missingCoreMLDataMakesDiarizerIncomplete() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeDiarizer(in: paths, noCoreMLDataIn: "Embedding.mlmodelc")
        #expect(!paths.diarizerInstalled)
    }

    @Test func leftoverPartialDownloadMakesDiarizerIncomplete() throws {
        let paths = FluidModelPaths(root: try TestAudio.temporaryDirectory())
        try makeDiarizer(in: paths, partialIn: "Segmentation.mlmodelc")
        #expect(!paths.diarizerInstalled)
    }
}

@Suite("Capture metering")
struct CaptureMeteringTests {
    @Test func silenceIsZeroAndFullScaleIsOne() {
        #expect(LevelMeter.normalisedLevel(rms: 0) == 0)
        #expect(LevelMeter.normalisedLevel(rms: 1) == 1)
        #expect(abs(LevelMeter.normalisedLevel(rms: 0.001) - 0) < 1e-6)        // -60 dBFS
        #expect(abs(LevelMeter.normalisedLevel(rms: 0.0316228) - 0.5) < 1e-3)  // -30 dBFS
    }

    @Test func oneTickPer50msWithTheEndFrame() {
        var meter = LevelMeter()
        let ticks = meter.ingest([Float](repeating: 0.5, count: 2_000))   // 125 ms
        #expect(ticks.map(\.endFrame) == [800, 1_600])
        let more = meter.ingest([Float](repeating: 0.5, count: 400))
        #expect(more.map(\.endFrame) == [2_400])
        #expect(meter.totalFrames == 2_400)
    }

    @Test func levelRisesFastAndFallsSlowly() {
        var meter = LevelMeter()
        let up = meter.ingest([Float](repeating: 0.5, count: 800))[0].level
        let target = LevelMeter.normalisedLevel(rms: 0.5)
        #expect(abs(up - target * LevelMeter.attack) < 1e-5)
        let down = meter.ingest([Float](repeating: 0, count: 800))[0].level
        #expect(down > 0 && down < up)
    }

    @Test func peaksKeepTheMaximumPerBin() {
        var bins = PeakBins()
        var samples = [Float](repeating: 0.1, count: 8_000)   // 10 bins of 50 ms
        samples[850] = -0.9
        bins.ingest(samples)
        let peaks = bins.result()
        #expect(peaks.count == 10)
        #expect(peaks[1] == 0.9)
        #expect(peaks[0] == 0.1)
    }

    @Test func longRecordingsStayAt200Bins() {
        var bins = PeakBins()
        // 70 s in 1 s chunks: 1400 initial bins worth, merged twice.
        for second in 0..<70 {
            bins.ingest([Float](repeating: second == 35 ? 0.8 : 0.2, count: 16_000))
        }
        let peaks = bins.result()
        #expect(peaks.count == 200)
        #expect(peaks.max() == 0.8)
        #expect(peaks.allSatisfy { $0 >= 0.2 && $0 <= 1 })
        #expect(bins.binFrames == 3_200)
    }

    @Test func maxPoolHandlesUnevenGroups() {
        #expect(PeakBins.maxPool([1, 2, 3], to: 5) == [1, 2, 3])
        #expect(PeakBins.maxPool([1, 5, 2, 4, 3], to: 2) == [5, 4])
        #expect(PeakBins.maxPool([0.1, 0.2, 0.3, 0.4], to: 4) == [0.1, 0.2, 0.3, 0.4])
    }
}

@Suite("FluidLiveRecording (scripted source)")
struct FluidLiveRecordingTests {
    private func makeRecording(liveText: Bool = false, source: ScriptedCaptureSource = ScriptedCaptureSource(),
                               freeBytes: @escaping @Sendable (URL) -> Int64? = { _ in 10_000_000_000 })
        throws -> (FluidLiveRecording, ScriptedCaptureSource, URL) {
        let url = try TestAudio.temporaryDirectory().appendingPathComponent("rec.wav")
        let request = RecordingRequest(audioURL: url, liveText: liveText, language: .automatic)
        let recording = FluidLiveRecording(request: request, source: source, liveModels: { nil }, freeBytes: freeBytes)
        return (recording, source, url)
    }

    @Test func writesA16kMonoInt16WAVWithTheCapturedDuration() async throws {
        let (recording, source, url) = try makeRecording()
        let events = collectEvents(recording.events)
        try await recording.start()
        await source.sendSine(seconds: 2)
        let audio = try await recording.stop()

        #expect(audio.url == url)
        #expect(abs(audio.duration - 2.0) < 1e-9)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(file.length == 32_000)
        #expect(try TestAudio.headerDataBytes(url) == 64_000)
        let samples = try TestAudio.readSamples(url)
        #expect(abs((samples.max() ?? 0) - 0.5) < 0.01)

        #expect(audio.peaks.count == 40)
        #expect(audio.peaks.allSatisfy { abs($0 - 0.5) < 0.01 })

        let ticks = await events.value.compactMap { e -> (TimeInterval, Float)? in
            if case .tick(let t, let l, _) = e { return (t, l) } else { return nil }
        }
        #expect(ticks.count == 40)
        #expect(abs((ticks.last?.0 ?? 0) - 2.0) < 1e-9)
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $0.0 < $1.0 })
        #expect(ticks.allSatisfy { $0.1 > 0.5 && $0.1 <= 1 })
        #expect(await source.calls == ["start", "stop"])
    }

    @Test func pausesAreExcludedFromElapsedAndMarksUseTheAudioTimeline() async throws {
        let (recording, source, _) = try makeRecording()
        let events = collectEvents(recording.events)
        try await recording.start()
        await source.sendSine(seconds: 1)
        #expect(await eventually { await recording.capturedDuration >= 1.0 })
        await recording.pause()
        #expect(await source.send([Float](repeating: 0.3, count: 16_000)) == false)   // nothing captured while paused
        await recording.resume()
        let mark = await recording.markMoment()
        await source.sendSine(seconds: 1)
        let audio = try await recording.stop()

        #expect(mark == 1.0)
        #expect(audio.marks == [1.0])
        #expect(abs(audio.duration - 2.0) < 1e-9)
        let states = await events.value.filter { if case .tick = $0 { false } else { true } }
        #expect(states == [.liveTextUnavailable(.modelsNotReady), .paused(.user), .resumed])
        #expect(await source.calls == ["start", "pause", "resume", "stop"])
    }

    @Test func headerIsFlushedEveryFiveSecondsWhileRecording() async throws {
        let (recording, source, url) = try makeRecording()
        try await recording.start()
        await source.sendSine(seconds: 6)
        #expect(await eventually { await recording.capturedDuration >= 6.0 })
        // Before stop: the header already covers at least the first 5 s (crash safety).
        #expect(try TestAudio.headerDataBytes(url) >= 5 * 32_000)
        _ = try await recording.stop()
        #expect(try TestAudio.headerDataBytes(url) == 6 * 32_000)
    }

    @Test func interruptionPausesAndResumesWhenTheSystemRecommendsIt() async throws {
        let (recording, source, _) = try makeRecording()
        let events = collectEvents(recording.events)
        try await recording.start()
        await source.send(event: .interrupted)
        #expect(await eventually { await source.calls.contains("pause") })
        await source.send(event: .interruptionEnded(shouldResume: true))
        #expect(await eventually { await source.calls.contains("resume") })
        _ = try await recording.stop()
        let states = await events.value.filter { if case .tick = $0 { false } else { true } }
        #expect(states == [.liveTextUnavailable(.modelsNotReady), .paused(.interruption), .resumed])
    }

    @Test func interruptionWithoutResumeRecommendationStaysPaused() async throws {
        let (recording, source, _) = try makeRecording()
        let events = collectEvents(recording.events)
        try await recording.start()
        await source.send(event: .interrupted)
        await source.send(event: .interruptionEnded(shouldResume: false))
        #expect(await eventually { await source.calls.contains("pause") })
        _ = try await recording.stop()
        #expect(await !source.calls.contains("resume"))
        #expect(await events.value.contains(.paused(.interruption)))
        #expect(await !events.value.contains(.resumed))
    }

    @Test func routeLostPausesCapture() async throws {
        let (recording, source, _) = try makeRecording()
        let events = collectEvents(recording.events)
        try await recording.start()
        await source.send(event: .routeLost)
        #expect(await eventually { await source.calls.contains("pause") })
        _ = try await recording.stop()
        #expect(await events.value.contains(.paused(.routeLost)))
    }

    @Test func mediaServicesResetEndsCaptureButKeepsTheAudio() async throws {
        let (recording, source, _) = try makeRecording()
        let events = collectEvents(recording.events)
        try await recording.start()
        await source.sendSine(seconds: 1)
        await source.send(event: .mediaServicesReset)
        #expect(await eventually { await source.calls.contains("stop") })
        let audio = try await recording.stop()
        #expect(abs(audio.duration - 1.0) < 1e-9)
        #expect(await events.value.contains(.endedBySystem(.mediaServicesReset)))
    }

    @Test func lowStorageEndsCapture() async throws {
        let (recording, _, _) = try makeRecording(freeBytes: { _ in 100_000_000 })
        let events = collectEvents(recording.events)
        try await recording.start()
        _ = try await recording.stop()
        #expect(await events.value.contains(.endedBySystem(.lowStorage)))
    }

    @Test func liveTextWithoutModelsReportsModelsNotReady() async throws {
        let (recording, _, _) = try makeRecording(liveText: true)
        let events = collectEvents(recording.events)
        try await recording.start()
        _ = try await recording.stop()
        #expect(await events.value == [.liveTextUnavailable(.modelsNotReady)])
    }

    @Test func turningLiveTextOffInTheBackgroundIsReported() async throws {
        let (recording, _, _) = try makeRecording(liveText: true)
        let events = collectEvents(recording.events)
        try await recording.start()
        await recording.setLiveTextEnabled(false)
        _ = try await recording.stop()
        #expect(await events.value == [.liveTextUnavailable(.modelsNotReady), .liveTextUnavailable(.pausedInBackground)])
    }

    @Test func discardDeletesTheFileAndFinishesEvents() async throws {
        let (recording, source, url) = try makeRecording()
        let events = collectEvents(recording.events)
        try await recording.start()
        await source.sendSine(seconds: 0.5)
        await recording.discard()
        _ = await events.value
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: EngineError.self) { _ = try await recording.stop() }
    }

    @Test func startFailureLeavesNoFile() async throws {
        let (recording, _, url) = try makeRecording(source: ScriptedCaptureSource(failStart: true))
        await #expect(throws: EngineError.failed("No microphone input is available")) { try await recording.start() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("FluidSpeechEngine without models")
struct FluidEngineNoModelsTests {
    private func makeEngine() throws -> FluidSpeechEngine {
        FluidSpeechEngine(modelsRoot: try TestAudio.temporaryDirectory(), captureFactory: { ScriptedCaptureSource() })
    }

    @Test func infoMatchesTheBlueprint() throws {
        let info = try makeEngine().info
        #expect(info.kind == .fluid)
        #expect(info.asrDisplayName == "Parakeet")
        #expect(info.asrModelID == FluidModelPaths.asrModelID)
        #expect(info.embeddingModel == .communityOneResNet34)
    }

    @Test func emptyRootIsMissingFromTheAppAndModelCallsThrowModelsMissing() async throws {
        let root = try TestAudio.temporaryDirectory()
        let engine = FluidSpeechEngine(modelsRoot: root, captureFactory: { ScriptedCaptureSource() })
        #expect(await engine.modelStatus() == .failed(ModelStatus.missingFromAppMessage))
        await #expect(throws: EngineError.modelsMissing) { try await engine.prepareModels() }
        let url = URL(fileURLWithPath: "/nonexistent.wav")
        await #expect(throws: EngineError.modelsMissing) { _ = try await engine.transcribe(url, language: .automatic) { _ in } }
        await #expect(throws: EngineError.modelsMissing) { _ = try await engine.separateSpeakers(url) { _ in } }
        await #expect(throws: EngineError.modelsMissing) {
            _ = try await engine.embedVoice(url, spans: [TimeRange(start: 0, end: 1)])
        }
        #expect(await engine.modelStatus() == .failed(ModelStatus.missingFromAppMessage))
        // Nothing is ever written into the models root.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func noModelsWritesNoPrepareRecord() async throws {
        let base = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("BundledModels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = base.appendingPathComponent("prepare-log.jsonl")
        let engine = FluidSpeechEngine(modelsRoot: root, prepareLog: log, captureFactory: { ScriptedCaptureSource() })
        await #expect(throws: EngineError.modelsMissing) { try await engine.prepareModels() }
        #expect(await engine.modelStatus() == .failed(ModelStatus.missingFromAppMessage))
        #expect(await engine.lastPrepareRecord == nil)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    /// A complete-looking but unloadable model tree: the prepare fails in front, and each attempt writes one
    /// failed record (to the file and, as a summary, to the unified log).
    @Test func aFailedPrepareInFrontIsRecorded() async throws {
        let base = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let bundle = try FakeModelTree.make(in: base.appendingPathComponent("App.app", isDirectory: true))
        let log = base.appendingPathComponent("prepare-log.jsonl")
        let engine = FluidSpeechEngine(modelsRoot: bundle, prepareLog: log, captureFactory: { ScriptedCaptureSource() })
        #expect(await engine.modelStatus() == .installed)
        await #expect(throws: EngineError.self) { try await engine.prepareModels() }
        guard case .failed = await engine.modelStatus() else {
            Issue.record("a failed prepare reads failed")
            return
        }
        let record = try #require(await engine.lastPrepareRecord)
        #expect(record.outcome == "failed" && record.pauseReason == nil)
        #expect(record.error?.isEmpty == false)
        #expect(record.stages.map(\.name) == ["diarizer"], "the first stage fails; nothing after it runs")
        #expect(record.stages.allSatisfy { $0.error != nil && $0.verdict == "failed" && $0.seconds >= 0 })
        #expect(record.backgroundInference == false)
        #expect(PrepareLog.read(log) == [record])

        // Try again: the same failure, one more line.
        await #expect(throws: EngineError.self) { try await engine.prepareModels() }
        #expect(PrepareLog.read(log).map(\.outcome) == ["failed", "failed"])
        let summary = PrepareLog.summary(try #require(await engine.lastPrepareRecord))
        #expect(summary.hasPrefix("prepare outcome=failed") && summary.contains("diarizer=") && summary.contains("!/f"))
        #expect(summary.utf8.count <= PrepareLog.summaryLimit)
    }

    @Test func engineLocksFluidAudioDown() throws {
        _ = try makeEngine()
        #expect(ModelHub.offlineMode == true)
        #expect(ModelRegistry.revisionOverrides[Repo.diarizer.remotePath] == "main")
    }

    @Test func recordingWorksWithoutModels() async throws {
        let engine = try makeEngine()
        let url = try TestAudio.temporaryDirectory().appendingPathComponent("r.wav")
        let source = ScriptedCaptureSource()
        let recording = try await engine.startRecording(RecordingRequest(audioURL: url, liveText: true, language: .automatic),
                                                       source: source)
        let events = collectEvents(recording.events)
        await source.sendSine(seconds: 0.5)
        let audio = try await recording.stop()
        #expect(abs(audio.duration - 0.5) < 1e-9)
        #expect(await events.value.first == .liveTextUnavailable(.modelsNotReady))
    }

    @Test func wordsComeFromTokenTimingsWithPunctuationAttached() {
        let tokens = [
            TokenTiming(token: "▁Hey", tokenId: 1, startTime: 0.10, endTime: 0.30, confidence: 0.9),
            TokenTiming(token: ",", tokenId: 2, startTime: 0.30, endTime: 0.35, confidence: 0.9),
            TokenTiming(token: "▁Ka", tokenId: 3, startTime: 0.50, endTime: 0.70, confidence: 0.9),
            TokenTiming(token: "ran", tokenId: 4, startTime: 0.70, endTime: 0.90, confidence: 0.9),
            TokenTiming(token: ".", tokenId: 5, startTime: 0.90, endTime: 0.95, confidence: 0.9),
        ]
        let words = FluidSpeechEngine.words(from: tokens, text: "Hey, Karan.", duration: 1)
        #expect(words.map(\.text) == ["Hey,", "Karan."])
        #expect(words[0].range == TimeRange(start: 0.10, end: 0.35))
        #expect(words[1].range == TimeRange(start: 0.50, end: 0.95))
        #expect(words.allSatisfy { !$0.isOverlap })
    }

    @Test func wordsFallBackToEvenSpacingWithoutTimings() {
        let words = FluidSpeechEngine.words(from: [], text: "one two", duration: 2)
        #expect(words == [TimedWord(text: "one", range: TimeRange(start: 0, end: 1)),
                          TimedWord(text: "two", range: TimeRange(start: 1, end: 2))])
        #expect(FluidSpeechEngine.words(from: [], text: "", duration: 2).isEmpty)
    }

    @Test func separationIsSortedWithNormalisedCentroids() throws {
        let s1 = [Float](repeating: 2, count: 256)
        var s2 = [Float](repeating: 0, count: 256); s2[0] = 3
        let result = DiarizationResult(segments: [
            TimedSpeakerSegment(speakerId: "S2", embedding: s2, startTimeSeconds: 5, endTimeSeconds: 9, qualityScore: 0.8),
            TimedSpeakerSegment(speakerId: "S1", embedding: s1, startTimeSeconds: 0, endTimeSeconds: 5.5, qualityScore: 0.9),
            TimedSpeakerSegment(speakerId: "S1", embedding: s1, startTimeSeconds: 9, endTimeSeconds: 9, qualityScore: 0.9),
        ], speakerDatabase: ["S1": s1])
        let separation = FluidSpeechEngine.separation(from: result)
        #expect(separation.separator == .communityOne)
        #expect(separation.segments.map(\.speakerKey) == ["S1", "S2"])     // zero-length segment dropped
        #expect(separation.segments[0].range == TimeRange(start: 0, end: 5.5))
        #expect(separation.segments[1].quality == 0.8)
        let c1 = try #require(separation.centroids["S1"])
        let c2 = try #require(separation.centroids["S2"])                    // from the segment embedding
        #expect(c1.dimension == 256 && c2.dimension == 256)
        #expect(abs(c2.values[0] - 1) < 1e-6)
        #expect(abs(c1.values.reduce(0) { $0 + $1 * $1 } - 1) < 1e-4)
    }

    @Test func embeddingSpansAreClampedOrRejected() throws {
        let ranges = try FluidSpeechEngine.embeddingRanges(
            [TimeRange(start: 1, end: 3), TimeRange(start: 9, end: 12)], audioDuration: 10)
        #expect(ranges == [1..<3, 9..<10])
        #expect(throws: EngineError.self) { _ = try FluidSpeechEngine.embeddingRanges([TimeRange(start: 10, end: 11)], audioDuration: 10) }
        #expect(throws: EngineError.self) { _ = try FluidSpeechEngine.embeddingRanges([TimeRange(start: 2, end: 2)], audioDuration: 10) }
    }

    @Test func errorsMapOntoTheContract() {
        #expect(FluidErrorMapping.engineError(ASRError.invalidAudioData) == .tooShort)
        #expect(FluidErrorMapping.engineError(ASRError.notInitialized) == .modelsMissing)
        #expect(FluidErrorMapping.engineError(OfflineDiarizationError.noSpeechDetected) == .noSpeech)
        #expect(FluidErrorMapping.engineError(CancellationError()) == .cancelled)
        #expect(FluidErrorMapping.engineError(URLError(.cancelled)) == .cancelled)
        #expect(FluidErrorMapping.engineError(EngineError.microphoneDenied) == .microphoneDenied)
        #expect(FluidErrorMapping.engineError(DownloadError.modelMissing(repo: "x", missing: [])) == .modelsMissing)
        #expect(FluidErrorMapping.describe(EngineError.modelsMissing) == ModelStatus.missingFromAppMessage)
        if case .failed(let message) = FluidErrorMapping.engineError(Nemotron3Error.modelLoadFailed("no ANE")) {
            #expect(message.contains("no ANE"))
        } else {
            Issue.record("Nemotron3Error should map to .failed")
        }
        if case .failed(let message) = FluidErrorMapping.engineError(ASRError.processingFailed("boom")) {
            #expect(message.contains("boom"))
        } else {
            Issue.record("processingFailed should map to .failed")
        }
    }

    @Test func audioDurationReadsTheHeader() throws {
        let url = try TestAudio.temporaryDirectory().appendingPathComponent("short.wav")
        let writer = try WAVFileWriter(url: url)
        try writer.append([Float](repeating: 0, count: 3_200))
        try writer.finish()
        #expect(abs(try FluidSpeechEngine.audioDuration(url) - 0.2) < 1e-6)
        #expect(throws: EngineError.self) { _ = try FluidSpeechEngine.audioDuration(URL(fileURLWithPath: "/missing.wav")) }
    }
}

@Suite("Nemotron 3 separation (no models)")
struct NemotronSeparationTests {
    typealias Activity = NemotronSeparation.Activity

    private func use(_ activities: [Activity]) throws -> SpeakerSeparation {
        guard case .use(let separation) = NemotronSeparation.decide(activities) else {
            Issue.record("expected a Nemotron result")
            throw CancellationError()
        }
        return separation
    }

    private func reason(_ activities: [Activity]) -> NemotronSeparation.FallbackReason? {
        if case .fallback(let reason) = NemotronSeparation.decide(activities) { return reason }
        return nil
    }

    @Test func presetIsTheFullPrecisionFast128Bundle() throws {
        let config = NemotronSeparation.config
        let upstream = try #require(Nemotron3Config.preset(named: NemotronSeparation.presetName))
        #expect(NemotronSeparation.presetName == "fast128")
        #expect(config.modelFileName == upstream.modelFileName)
        #expect(config.modelFileName == "Nemotron3Diarizer_fast128.mlmodelc")
        #expect(!config.splitGraph && !upstream.splitGraph)
        #expect(config.hubSubdirectory == "monolithic/v2")
        // Never the `offline` preset: it fails the Neural Engine compile and runs on the GPU.
        #expect(config.modelFileName != Nemotron3Config.offline.modelFileName)
        #expect(config.chunkMelFrames <= 1_376, "the largest monolithic chunk that still compiles for the ANE")
        #expect((config.chunkLen, config.chunkRightContext, config.fifoLen, config.spkcacheLen, config.spkcacheUpdatePeriod)
                == (upstream.chunkLen, upstream.chunkRightContext, upstream.fifoLen, upstream.spkcacheLen, upstream.spkcacheUpdatePeriod))
        #expect(config.numSpeakers == NemotronSeparation.speakerChannels)
        // On the CPU only (decided 2026-11-25): its Neural Engine compile took 55–58 s of every setup on an iPhone 15,
        // the CPU load under a second. The background rules treat its stage as CPU work, so the two must agree.
        #expect(NemotronSeparation.computeUnits == .cpuOnly)
        #expect(PrepareStage.nemotron.usesNeuralEngine == (NemotronSeparation.computeUnits != .cpuOnly))
        #expect(FluidSpeechEngine.makeDiarizerMLConfiguration().computeUnits == .cpuAndNeuralEngine,
                "community-1 stays on the Neural Engine")
        #expect(PrepareStage.diarizer.usesNeuralEngine && PrepareStage.asr.usesNeuralEngine)
    }

    @Test func speakersAreKeyedByFirstSpeechAndSegmentsSorted() throws {
        // Channel 3 speaks first, then channel 0, then channel 3 again; overlap is kept.
        let separation = try use([
            Activity(channel: 0, start: 4.0, end: 7.5, meanProbability: 0.9),
            Activity(channel: 3, start: 0.2, end: 4.1, meanProbability: 0.8),
            Activity(channel: 3, start: 7.4, end: 9.0, meanProbability: 0.7),
        ])
        #expect(separation.separator == .nemotron3)
        #expect(separation.centroids.isEmpty)   // voice vectors come from embedVoice
        #expect(separation.segments.map(\.speakerKey) == ["S1", "S2", "S1"])
        #expect(separation.segments.map(\.range) == [TimeRange(start: 0.2, end: 4.1), TimeRange(start: 4.0, end: 7.5),
                                                     TimeRange(start: 7.4, end: 9.0)])
        #expect(separation.segments.map(\.quality) == [0.8, 0.9, 0.7])
    }

    @Test func invalidStretchesAreDropped() throws {
        let separation = try use([
            Activity(channel: 1, start: 1, end: 2, meanProbability: 0.9),
            Activity(channel: 1, start: 3, end: 3, meanProbability: 0.9),          // empty
            Activity(channel: 2, start: .nan, end: 5, meanProbability: 0.9),       // non-finite
            Activity(channel: 8, start: 5, end: 6, meanProbability: 0.9),          // no such channel
            Activity(channel: 0, start: 6, end: 7, meanProbability: .infinity),    // bad quality → 0
        ])
        #expect(separation.segments.map(\.speakerKey) == ["S1", "S2"])
        #expect(separation.segments.last?.quality == 0)
    }

    @Test func nothingHeardFallsBackAsNoSpeech() {
        #expect(reason([]) == .noSpeech)
        #expect(reason([Activity(channel: 0, start: 2, end: 2, meanProbability: 1)]) == .noSpeech)
    }

    @Test func allEightChannelsFallBackAsSaturated() throws {
        let eight = (0..<8).map { Activity(channel: $0, start: Double($0), end: Double($0) + 0.8, meanProbability: 0.9) }
        #expect(reason(eight) == .saturated)
        let seven = Array(eight.prefix(7))
        #expect(Set(try use(seven).segments.map(\.speakerKey)).count == 7)
    }

    @Test func frameProbabilitiesBecomeStretchesWithTheirMeanProbability() throws {
        // 300 frames (3 s), 8 channels: channel 2 active over frames 10..<110 at 0.8, channel 5 over 150..<300 at 0.6,
        // and a sub-threshold blip on channel 0.
        let frames = 300, channels = 8
        var p = [Float](repeating: 0, count: frames * channels)
        for f in 10..<110 { p[f * channels + 2] = 0.8 }
        for f in 150..<300 { p[f * channels + 5] = 0.6 }
        for f in 50..<60 { p[f * channels + 0] = 0.4 }
        let stretches = NemotronSeparation.activities(probabilities: p, frameCount: frames)
        #expect(stretches.count == 2)
        let first = try #require(stretches.first)
        #expect(first.channel == 2 && abs(first.start - 0.1) < 1e-6 && abs(first.end - 1.1) < 1e-6)
        #expect(abs(first.meanProbability - 0.8) < 1e-6)
        let second = try #require(stretches.last)
        #expect(second.channel == 5 && abs(second.start - 1.5) < 1e-6 && abs(second.end - 3.0) < 1e-6)
        #expect(abs(second.meanProbability - 0.6) < 1e-6)
        #expect(NemotronSeparation.activities(probabilities: [], frameCount: 10).isEmpty)
    }
}

/// The background rules (`FluidSpeechEngine` type doc) on a complete-looking but unloadable model tree: a pause
/// is never a failure, and leaves the status installed.
@Suite("FluidSpeechEngine in the background (no models)")
struct FluidEngineBackgroundTests {
    struct Rig {
        let base: URL
        let bundle: URL
        var log: URL { base.appendingPathComponent("prepare-log.jsonl") }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    func rig() throws -> Rig {
        let base = try TestAudio.temporaryDirectory()
        let bundle = try FakeModelTree.make(in: base.appendingPathComponent("App.app", isDirectory: true))
        return Rig(base: base, bundle: bundle)
    }

    @Test func withoutTheEntitlementNoStageStartsInTheBackground() async throws {
        let r = try rig()
        defer { r.cleanup() }
        let activity = AppActivity(backgroundInference: false)
        let engine = FluidSpeechEngine(modelsRoot: r.bundle, prepareLog: r.log, activity: activity,
                                       captureFactory: { ScriptedCaptureSource() })
        activity.enterBackground()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels() }
        #expect(await engine.modelStatus() == .installed, "a pause never reads as couldn't load")
        let first = try #require(await engine.lastPrepareRecord)
        #expect(first.outcome == "paused" && first.pauseReason == "startRefused")
        #expect(first.backgroundInference == false)
        #expect(first.stages.map(\.name) == ["diarizer"], "the first stage (Neural Engine) is refused")
        #expect(first.stages.first?.verdict == "notStarted" && first.stages.first?.bgAtStart == true)
        #expect(first.resumesPause == nil)
        #expect(first.transitions?.isEmpty == true, "the trip began before this prepare")
        #expect(await engine.nemotronDisabledReason == nil)

        // The next prepare in this process carries on from the pause.
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels() }
        let second = try #require(await engine.lastPrepareRecord)
        #expect(second.resumesPause == true)
        #expect(PrepareLog.read(r.log).map(\.outcome) == ["paused", "paused"])
        #expect(PrepareLog.summary(second).contains("pause=startRefused"))
        #expect(PrepareLog.summary(second).contains("diarizer=0.00/n^"))
    }

    @Test func withTheEntitlementAStageThatThrowsInTheBackgroundIsAPause() async throws {
        let r = try rig()
        defer { r.cleanup() }
        let activity = AppActivity(backgroundInference: true)
        let engine = FluidSpeechEngine(modelsRoot: r.bundle, activity: activity, captureFactory: { ScriptedCaptureSource() })
        activity.armGrace(UUID())
        activity.enterBackground()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels() }
        #expect(await engine.modelStatus() == .installed)
        let record = try #require(await engine.lastPrepareRecord)
        #expect(record.outcome == "paused" && record.pauseReason == "failedInBackground")
        #expect(record.backgroundInference == true)
        #expect(record.stages.map(\.name) == ["diarizer"])
        let stage = try #require(record.stages.first)
        #expect(stage.verdict == "paused" && stage.error != nil && stage.bgAtStart == true && stage.bgAtEnd == true)
        #expect(stage.epochChanged == false && stage.aneAtStart != nil && stage.suspendedSeconds == 0)
    }

    @Test func aStageThatThrowsAfterATripAwayIsAPauseAndInFrontAFailure() async throws {
        let r = try rig()
        defer { r.cleanup() }
        let activity = AppActivity(backgroundInference: false)
        let engine = FluidSpeechEngine(modelsRoot: r.bundle, activity: activity,
                                       afterStageWork: { _ in
                                           // The user leaves and comes back while the stage runs.
                                           if activity.epoch == 0 { activity.enterBackground(); activity.becomeActive() }
                                       },
                                       captureFactory: { ScriptedCaptureSource() })
        let events = Mutex<[PrepareEvent]>([])
        await #expect(throws: EngineError.cancelled) {
            try await engine.prepareModels(onEvent: { e in events.withLock { $0.append(e) } })
        }
        let sent = events.withLock { $0 }
        #expect(sent.count == 2 && sent.last == .stageStarted(.diarizer), "a stage that throws sends no finished event")
        #expect(await engine.modelStatus() == .installed)
        let paused = try #require(await engine.lastPrepareRecord)
        #expect(paused.pauseReason == "failedInBackground")
        #expect(paused.stages.first?.verdict == "paused" && paused.stages.first?.bgAtStart == false)
        #expect(paused.stages.first?.bgAtEnd == false && paused.stages.first?.epochChanged == true)
        #expect(paused.transitions?.map(\.kind) == ["background", "active"])
        #expect(paused.stages.first?.expectedWarm == false, "the plan expected a cold diarizer")

        // Wholly in front, the same throw is a real failure. Its plan does not count the stage that threw as
        // compiled: it is still cold, so the bar cannot treat it as nearly free.
        let again = Mutex<[PrepareEvent]>([])
        await #expect(throws: EngineError.self) {
            try await engine.prepareModels(onEvent: { e in again.withLock { $0.append(e) } })
        }
        let resent = again.withLock { $0 }
        guard case .planned(let plan) = resent.first else {
            Issue.record("no plan first")
            return
        }
        #expect(plan.step(.diarizer)?.isWarm == false)
        #expect(plan.step(.diarizer)?.expectedSeconds != PrepareEstimates.warmDefaults[.diarizer])
        #expect(!resent.contains(.stageFinished(.diarizer)), "the second throw sends no finished event either")
        guard case .failed = await engine.modelStatus() else {
            Issue.record("a failure in front reads failed")
            return
        }
        let failed = try #require(await engine.lastPrepareRecord)
        #expect(failed.outcome == "failed" && failed.pauseReason == nil && failed.resumesPause == true)
        #expect(failed.stages.map(\.verdict) == ["failed"])
    }

    @Test func suspendedSecondsCountOnlyTheFrozenPart() {
        let t = Date(timeIntervalSince1970: 0)
        func at(_ s: Double) -> Date { t.addingTimeInterval(s) }
        let transitions = [AppActivity.Transition(kind: .background, at: at(5)),
                           AppActivity.Transition(kind: .expired, at: at(35)),
                           AppActivity.Transition(kind: .active, at: at(100)),
                           AppActivity.Transition(kind: .background, at: at(110)),
                           AppActivity.Transition(kind: .expired, at: at(140))]
        #expect(PrepareLog.suspendedSeconds(start: at(0), end: at(120), transitions: transitions) == 65)
        #expect(PrepareLog.suspendedSeconds(start: at(50), end: at(60), transitions: transitions) == 10)
        #expect(PrepareLog.suspendedSeconds(start: at(130), end: at(150), transitions: transitions) == 10, "still frozen")
        #expect(PrepareLog.suspendedSeconds(start: at(0), end: at(30), transitions: transitions) == 0)
    }
}

@Suite("Prepare log")
struct PrepareLogTests {
    private func record(_ at: String) -> PrepareRecord {
        var r = PrepareRecord.begin()
        r.at = at
        return r
    }

    @Test func keepsTheLast200Lines() throws {
        let folder = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("prepare-log.jsonl")
        for i in 0..<205 { PrepareLog.append(record("r\(i)"), to: file) }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == PrepareLog.keptLines)
        let records = PrepareLog.read(file)
        #expect(records.count == 200)
        #expect(records.first?.at == "r5")
        #expect(records.last?.at == "r204")
    }

    @Test func neverCreatesAFolder() throws {
        let absent = try TestAudio.temporaryDirectory().appendingPathComponent("Transcribe", isDirectory: true)
        PrepareLog.append(record("x"), to: absent.appendingPathComponent("prepare-log.jsonl"))
        #expect(!FileManager.default.fileExists(atPath: absent.path), "the log never creates the folder")
        PrepareLog.append(record("x"), to: nil)   // logged only
    }

    @Test func aRecordRoundTripsAsOneLineAndItsSummaryFitsTheUnifiedLog() throws {
        var r = record("2026-11-25T10:00:00.000Z")
        r.appVersion = "0.1.1"
        r.appBuild = "9200"
        r.osBuild = "24B156"
        r.addStage("asr", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2))
        r.noteLastStage(bgAtStart: false, bgAtEnd: true, epochChanged: true, verdict: .primed, suspendedSeconds: 0.5,
                        aneAtStart: true, aneAtEnd: false)
        r.addRefusedStage("diarizer", at: Date(timeIntervalSince1970: 3), inBackground: true)
        r.noteTransitions([AppActivity.Transition(kind: .background, at: Date(timeIntervalSince1970: 1))])
        r.totalSeconds = 3.25
        r.outcome = "paused"
        r.pauseReason = PreparePauseReason.startRefused.rawValue
        r.backgroundInference = true
        r.resumesPause = true
        r.lowPower = false
        r.error = String(repeating: "e", count: 2_000)
        let line = try #require(PrepareLog.line(r))
        #expect(!line.contains("\n"))
        let decoded = try JSONDecoder().decode(PrepareRecord.self, from: Data(line.utf8))
        #expect(decoded == r)
        #expect(decoded.stages.first?.start == "1970-01-01T00:00:00.000Z")
        #expect(decoded.transitions == [PrepareRecord.Transition(kind: "background", at: "1970-01-01T00:00:01.000Z")])
        #expect(decoded.stages.map(\.verdict) == ["primed", "notStarted"])
        // The JSON line is too long for the unified log, which gets the summary instead.
        #expect(line.utf8.count > 1_024)
        let summary = PrepareLog.summary(decoded)
        #expect(summary.hasPrefix("prepare outcome=paused pause=startRefused"))
        for part in ["build=9200", "os=24B156", "asr=2.00/p^", "diarizer=0.00/n^", "total=3.25", "bi=1", "tr=b",
                     "resumes=1", "error=eee"] {
            #expect(summary.contains(part), "\(part) in \(summary)")
        }
        #expect(!summary.contains("\n"))
        #expect(summary.utf8.count <= PrepareLog.summaryLimit, "\(summary.utf8.count) bytes")
    }

    @Test func theOSBuildIsRead() {
        #expect(PrepareLog.osBuild()?.isEmpty == false)
    }

    /// Lines written before `installStamp` and `nemotronUnits` existed still decode.
    @Test func oldLinesWithoutTheNewFieldsStillDecode() throws {
        let old = #"{"at":"2026-11-24T10:00:00.000Z","appBuild":"9200","osBuild":"24B156","outcome":"ready","stages":[{"end":"x","name":"asr","seconds":21.5,"start":"x","verdict":"kept"}],"totalSeconds":80.2}"#
        let folder = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("prepare-log.jsonl")
        try Data((old + "\n").utf8).write(to: file)
        let records = PrepareLog.read(file)
        #expect(records.count == 1)
        #expect(records.first?.installStamp == nil && records.first?.nemotronUnits == nil)
        #expect(records.first?.stages.first?.seconds == 21.5)
    }

    @Test func aNewRecordCarriesItsInstallAndNemotronUnits() {
        let r = PrepareRecord.begin()
        #expect(r.nemotronUnits == PrepareEstimates.unitsName(NemotronSeparation.computeUnits))
        #expect(PrepareLog.summary(r).contains("units=\(r.nemotronUnits ?? "")"))
        // The test runner has an executable: build@modified-seconds.
        #expect(r.installStamp?.contains("@") == true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8),
                                       attributes: [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(PrepareLog.installStamp(executable: file, build: "9300") == "9300@1700000000")
        #expect(PrepareLog.installStamp(executable: nil, build: "9300") == nil)
    }
}
