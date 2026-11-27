import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A scripted capture engine that says it can record Mac audio, keeps the last request, and reports the microphone
/// as denied (so a Mac-audio-only start must not ask for it).
final class SystemAudioScriptedEngine: SpeechEngine, @unchecked Sendable {
    let inner: ScriptedCaptureEngine
    var lastRequest: RecordingRequest?
    var micAsked = 0
    init(inner: ScriptedCaptureEngine) { self.inner = inner }
    var info: EngineInfo { inner.info }
    var systemAudioAvailable: Bool { true }
    func modelStatus() async -> ModelStatus { await inner.modelStatus() }
    func prepareModels() async throws { try await inner.prepareModels() }
    func microphonePermission() async -> MicPermission { micAsked += 1; return .denied }
    func requestMicrophonePermission() async -> Bool { micAsked += 1; return false }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        lastRequest = request
        return try await inner.startRecording(request)
    }
    func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        try await inner.transcribe(audio, language: language, progress: progress)
    }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        try await inner.separateSpeakers(audio, progress: progress)
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] { try await inner.embedVoice(audio, spans: spans) }
}

/// The step-0 Kit contracts for Mac audio: the recorder's sources, levels and notices, the stem paths, the shared
/// millisecond rule and the committed 0.3.x capture details.
@Suite("Capture sources in the Kit", .serialized)
@MainActor
struct CaptureSourcesKitTests {
    let rigs = RecorderControllerTests()

    @Test func macAudioIsRefusedWhenTheEngineCannotRecordIt() async throws {
        let rig = try rigs.makeRig(macAudio: .unavailable)   // as on an iPhone
        defer { rig.cleanUp() }
        #expect(!rig.engine.systemAudioAvailable)
        for sources in [CaptureSources.both, .macAudio] {
            await #expect(throws: EngineError.sourceUnavailable) { try await rig.recorder.start(sources: sources) }
            #expect(rig.recorder.state == .idle && rig.recorder.recordingID == nil)
        }
        #expect(try rig.container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 0)
        // The fake engine refuses it too when asked directly.
        let url = rig.paths.audioURL(fileName: "x.wav")
        await #expect(throws: EngineError.sourceUnavailable) {
            _ = try await rig.engine.startRecording(RecordingRequest(audioURL: url, liveText: false, language: .automatic, sources: .both))
        }
    }

    @Test func microphoneRecordingsAskForNothingNew() async throws {
        let (rig, engine) = try rigs.makeScriptedRig(failStop: false)
        defer { rig.cleanUp() }
        _ = try await rig.recorder.start()
        #expect(rig.recorder.sources == .microphone && rig.recorder.notice == nil)
        let session = try #require(engine.session)
        session.continuation.yield(.tick(elapsed: 0.5, level: 0.4))
        #expect(await rigs.wait { rig.recorder.levels == [0.4] })
        #expect(rig.recorder.systemLevels.isEmpty)
        _ = try await rig.recorder.stop()
    }

    @Test func macAudioOnlyStartsWithoutTheMicrophoneAndBothGetsStems() async throws {
        let (base, scripted) = try rigs.makeScriptedRig(failStop: false)
        defer { base.cleanUp() }
        let engine = SystemAudioScriptedEngine(inner: scripted)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "sources-\(UUID().uuidString)")!)
        let recorder = RecorderController(engine: engine, store: base.store, coordinator: base.coordinator, models: base.models,
                                          paths: base.paths, settings: settings, clock: .frozen(base.now))

        // Mac audio only: the denied microphone is never asked about, and there are no stems.
        let first = try await recorder.start(sources: .macAudio)
        #expect(engine.micAsked == 0 && recorder.sources == .macAudio)
        #expect(engine.lastRequest?.sources == .macAudio && engine.lastRequest?.stems == nil)
        #expect(try await recorder.stop() == first)

        // Both: the microphone is asked about (denied here).
        await #expect(throws: EngineError.microphoneDenied) { try await recorder.start(sources: .both) }
        #expect(engine.micAsked == 1 && recorder.state == .idle)
    }

    @Test func bothRequestCarriesTheStemsAndTicksFillBothMeters() async throws {
        let (base, scripted) = try rigs.makeScriptedRig(failStop: false)
        defer { base.cleanUp() }
        /// Grants the microphone, unlike `SystemAudioScriptedEngine`.
        final class GrantingEngine: SpeechEngine, @unchecked Sendable {
            let inner: SystemAudioScriptedEngine
            init(_ inner: SystemAudioScriptedEngine) { self.inner = inner }
            var info: EngineInfo { inner.info }
            var systemAudioAvailable: Bool { true }
            func modelStatus() async -> ModelStatus { await inner.modelStatus() }
            func prepareModels() async throws { try await inner.prepareModels() }
            func microphonePermission() async -> MicPermission { .granted }
            func requestMicrophonePermission() async -> Bool { true }
            func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording { try await inner.startRecording(request) }
            func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
                try await inner.transcribe(audio, language: language, progress: progress)
            }
            func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
                try await inner.separateSpeakers(audio, progress: progress)
            }
            func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] { try await inner.embedVoice(audio, spans: spans) }
        }
        let recorderEngine = SystemAudioScriptedEngine(inner: scripted)
        let engine = GrantingEngine(recorderEngine)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "sources-\(UUID().uuidString)")!)
        let recorder = RecorderController(engine: engine, store: base.store, coordinator: base.coordinator, models: base.models,
                                          paths: base.paths, settings: settings, clock: .frozen(base.now))

        let id = try await recorder.start(sources: .both)
        let request = try #require(recorderEngine.lastRequest)
        #expect(request.sources == .both && request.audioURL == base.paths.audioURL(fileName: base.paths.newAudioFileName(for: id)))
        #expect(request.stems == base.paths.stems(recordingID: id))
        #expect(request.stems == CaptureStems.beside(audioURL: request.audioURL))

        let session = try #require(scripted.session)
        session.continuation.yield(.tick(elapsed: 0.5, level: 0.4, systemLevel: 0.25))
        session.continuation.yield(.tick(elapsed: 0.55, level: 0.3, systemLevel: 2))
        session.continuation.yield(.notice(.systemAudioSilent))
        #expect(await rigs.wait { recorder.notice == .systemAudioSilent })
        #expect(recorder.levels == [0.4, 0.3] && recorder.systemLevels == [0.25, 1])
        session.continuation.yield(.notice(.systemAudioLost))
        #expect(await rigs.wait { recorder.notice == .systemAudioLost })
        _ = try await recorder.stop()
    }

    @Test func stemPathsFollowTheAudioFolder() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/lib", isDirectory: true))
        let id = UUID(uuidString: "A5000000-0000-4000-8000-000000000001")!
        #expect(paths.stemsDirectory.path == "/tmp/lib/Audio/Stems")
        #expect(paths.stemURL(recordingID: id, stream: .mic).path == "/tmp/lib/Audio/Stems/\(id.uuidString).mic.wav")
        #expect(paths.stemURL(recordingID: id, stream: .system).path == "/tmp/lib/Audio/Stems/\(id.uuidString).system.wav")
        #expect(paths.stems(recordingID: id) == CaptureStems.beside(audioURL: paths.audioURL(fileName: paths.newAudioFileName(for: id))))
    }

    @Test func syncValueMillisIsSyncMillis() {
        for t in [0, 1.0004, 1.0005, 1.0006, 1_794_873_600.123_4, -2.0004] {
            let d = Date(timeIntervalSince1970: t)
            #expect(SyncValue.millis(d) == SyncMillis.millis(d))
            #expect(SyncValue.dateFrom(millis: SyncValue.millis(d)) == SyncMillis.date(millis: SyncMillis.millis(d)))
        }
    }

    /// The capture details committed in the V3 and V4 fixtures (written by 0.3.x types) are what this build encodes.
    @Test func committedCaptureDetailsAreByteIdentical() throws {
        let v3 = try V3FixtureWriter.decoder.decode(V3FixtureWriter.Manifest.self, from: Data(contentsOf:
            try V3FixtureWriter.fixtureDirectory.appendingPathComponent("manifest.json")))
        let v4 = try V4FixtureWriter.decoder.decode(V4FixtureWriter.Manifest.self, from: Data(contentsOf:
            try V4FixtureWriter.fixtureDirectory.appendingPathComponent("manifest.json")))
        let committed = Set((v3.recordings + v4.recordings).compactMap(\.captureDetailJSON))
        #expect(committed == [V3FixtureWriter.iphoneDetail.json(), V3FixtureWriter.macDetail.json()])
        for json in committed { #expect(CaptureDetail.decode(json)?.json() == json) }
    }

    @Test func speakerSourceReadsTheStoredField() {
        let s = RecordingSpeaker(key: "S1", ordinal: 1, colourSlot: 0)
        #expect(s.captureSource == nil && s.source == .mic)
        s.captureSource = SpeakerSource.system.rawValue
        #expect(s.source == .system)
        s.captureSource = SpeakerSource.mixed.rawValue
        #expect(s.source == .mixed)
    }
}
