import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A capture session the test drives: it writes real audio on start, emits what the test sends, and its
/// `stop()` can fail after capture has ended (as a failed WAV finalise does).
actor ScriptedLiveRecording: LiveRecording {
    nonisolated let events: AsyncStream<RecordingEvent>
    nonisolated let continuation: AsyncStream<RecordingEvent>.Continuation
    let url: URL
    let failStop: Bool
    private(set) var stopCalls = 0
    init(url: URL, failStop: Bool) throws {
        self.url = url; self.failStop = failStop
        (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
        _ = try SyntheticAudio.write(to: url, duration: 4, segments: [(TimeRange(start: 0.5, end: 3.5), .karan)])
    }
    func pause() {}
    func resume() {}
    func markMoment() -> TimeInterval { 0 }
    func setLiveTextEnabled(_ enabled: Bool) {}
    func stop() throws -> CapturedAudio {
        stopCalls += 1
        continuation.finish()
        guard stopCalls == 1 else { throw EngineError.failed("Recording already stopped") }
        if failStop { throw EngineError.failed("Could not finish the audio file") }
        return CapturedAudio(url: url, duration: 4, marks: [], peaks: [0.5])
    }
    func discard() { continuation.finish() }
}

/// The fake engine, except that capture uses a `ScriptedLiveRecording`.
final class ScriptedCaptureEngine: SpeechEngine, @unchecked Sendable {
    let base: FakeSpeechEngine
    let failStop: Bool
    var session: ScriptedLiveRecording?
    init(base: FakeSpeechEngine, failStop: Bool) { self.base = base; self.failStop = failStop }
    var info: EngineInfo { base.info }
    func modelStatus() async -> ModelStatus { await base.modelStatus() }
    func installModels(progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws { try await base.installModels(progress: progress) }
    func removeModels() async throws { try await base.removeModels() }
    func prepareModels() async throws { try await base.prepareModels() }
    func microphonePermission() async -> MicPermission { .granted }
    func requestMicrophonePermission() async -> Bool { true }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        let s = try ScriptedLiveRecording(url: request.audioURL, failStop: failStop)
        session = s
        return s
    }
    func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        try await base.transcribe(audio, language: language, progress: progress)
    }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        try await base.separateSpeakers(audio, progress: progress)
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] { try await base.embedVoice(audio, spans: spans) }
}

@Suite("RecorderController on the fake engine", .serialized)
@MainActor
struct RecorderControllerTests {
    @MainActor struct Rig {
        let container: ModelContainer
        let store: LibraryStore
        let monitor: ProcessingMonitor
        let coordinator: ProcessingCoordinator
        let models: ModelManager
        let paths: AppPaths
        let engine: FakeSpeechEngine
        let recorder: RecorderController
        let now: Date

        func recording(_ id: UUID) throws -> Recording? {
            var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try container.mainContext.fetch(descriptor).first
        }

        func cleanUp() { try? FileManager.default.removeItem(at: paths.root) }
    }

    /// Speed `instant` (`-uiTesting`): a tick every 50 ms; models missing so no pipeline work starts on its own.
    func makeRig(mic: MicPermission = .granted, models: FakeModelState = .missing, script: FakeScriptName = .newVoices) throws -> Rig {
        let env = [
            LaunchConfig.envMic: mic.rawValue,
            LaunchConfig.envModels: models.rawValue,
            LaunchConfig.envScript: script.rawValue,
            LaunchConfig.envSpeed: FakeSpeed.instant.rawValue,
        ]
        let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting], environment: env)
        let paths = AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("recorder-\(UUID().uuidString)", isDirectory: true))
        try paths.prepare()
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let now = Seeds.Dates.b
        let clock = AppClock.frozen(now)
        let store = LibraryStore(context: container.mainContext, paths: paths,
                                 deviceIdentity: FixedDeviceIdentity("test-device"), clock: clock)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "recorder-\(UUID().uuidString)")!)
        let monitor = ProcessingMonitor()
        let engine = FakeSpeechEngine(config: config, script: FakeScript.named(config.script))
        let coordinator = ProcessingCoordinator(engine: engine, store: store, monitor: monitor, settings: settings,
                                                paths: paths, background: NoopBackgroundTaskBridge())
        let modelManager = ModelManager(engine: engine, onReady: {})
        let recorder = RecorderController(engine: engine, store: store, coordinator: coordinator, models: modelManager,
                                          paths: paths, settings: settings, clock: clock)
        return Rig(container: container, store: store, monitor: monitor, coordinator: coordinator, models: modelManager,
                   paths: paths, engine: engine, recorder: recorder, now: now)
    }

    /// A rig whose capture session is a `ScriptedLiveRecording`.
    func makeScriptedRig(failStop: Bool) throws -> (Rig, ScriptedCaptureEngine) {
        let base = try makeRig()
        let engine = ScriptedCaptureEngine(base: base.engine, failStop: failStop)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "recorder-\(UUID().uuidString)")!)
        let recorder = RecorderController(engine: engine, store: base.store, coordinator: base.coordinator, models: base.models,
                                          paths: base.paths, settings: settings, clock: .frozen(base.now))
        let rig = Rig(container: base.container, store: base.store, monitor: base.monitor, coordinator: base.coordinator,
                      models: base.models, paths: base.paths, engine: base.engine, recorder: recorder, now: base.now)
        return (rig, engine)
    }

    @Test func aSystemEndStopsAndSavesWithoutTheRecordingScreen() async throws {
        let (rig, engine) = try makeScriptedRig(failStop: false)
        defer { rig.cleanUp() }
        let id = try await rig.recorder.start()
        // Low storage while the recording screen is minimised: nothing in the UI calls stop().
        engine.session?.continuation.yield(.endedBySystem(.lowStorage))
        #expect(await wait { rig.recorder.systemStop != nil })
        #expect(rig.recorder.systemStop?.reason == .lowStorage && rig.recorder.systemStop?.recordingID == id)
        #expect(!rig.recorder.isActive && rig.recorder.systemEndReason == .lowStorage)
        #expect(try #require(try rig.recording(id)).stage == .queued)
        rig.recorder.acknowledgeSystemStop()
        #expect(rig.recorder.systemStop == nil)
    }

    @Test func aFailedStopEndsTheRecordingAndSalvagesTheAudio() async throws {
        let (rig, _) = try makeScriptedRig(failStop: true)
        defer { rig.cleanUp() }
        let id = try await rig.recorder.start()
        await #expect(throws: EngineError.self) { try await rig.recorder.stop() }
        // Not stuck "recording": the session is gone and processing may run again.
        #expect(!rig.recorder.isActive && rig.recorder.recordingID == nil)
        let row = try #require(try rig.recording(id))
        #expect(row.stage == .queued && abs(row.duration - 4) < 0.01)
        await #expect(throws: EngineError.self) { try await rig.recorder.stop() }   // "Not recording"
    }

    /// Polls the main actor until `condition` holds (the fake ticks in real time).
    func wait(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func fullLifecycleQueuesTheRecording() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        let recorder = rig.recorder

        let id = try await recorder.start()
        #expect(recorder.state == .recording)
        #expect(recorder.isActive)
        #expect(recorder.recordingID == id)
        #expect(recorder.startedAt == rig.now)
        let row = try #require(try rig.recording(id))
        #expect(row.stage == .capturing)
        #expect(row.source == .microphone)
        #expect(row.audioFileName == rig.paths.newAudioFileName(for: id))
        #expect(row.createdAt == rig.now)

        #expect(await wait { recorder.elapsed > 0.1 && !recorder.levels.isEmpty })

        await recorder.pause()
        #expect(recorder.state == .paused(.user))
        await recorder.resume()
        #expect(recorder.state == .recording)

        #expect(await wait { recorder.elapsed > 0.2 })
        await recorder.markMoment()
        #expect(recorder.marks.count == 1)
        #expect(recorder.lastMarkAt == recorder.marks.first)

        let stoppedID = try await recorder.stop()
        #expect(stoppedID == id)
        #expect(recorder.state == .idle)
        #expect(!recorder.isActive)
        #expect(recorder.recordingID == nil)

        let saved = try #require(try rig.recording(id))
        #expect(saved.stage != .capturing)
        #expect(saved.stage >= .queued)
        #expect(saved.duration == FakeScript.named(.newVoices).duration)
        #expect(saved.marks.count == 1)
        #expect(!saved.peaks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: rig.paths.audioURL(fileName: saved.audioFileName).path))
        // The coordinator published a snapshot for the queued job.
        #expect(await wait { rig.monitor.snapshot(for: id) != nil })
    }

    @Test func elapsedExcludesPauses() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        let recorder = rig.recorder
        try await recorder.start()
        #expect(await wait { recorder.elapsed >= 0.2 })
        await recorder.pause()
        try await Task.sleep(for: .milliseconds(120))   // let any in-flight tick land
        let pausedAt = recorder.elapsed
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.elapsed == pausedAt)
        await recorder.resume()
        #expect(await wait { recorder.elapsed >= pausedAt + 0.15 })
        // Wall time ≥ 0.2 + 0.52 + 0.15 s, but elapsed only counts the unpaused part.
        #expect(recorder.elapsed < pausedAt + 0.4)
        await recorder.discard()
    }

    @Test func microphoneDeniedThrowsAndCreatesNothing() async throws {
        let rig = try makeRig(mic: .denied)
        defer { rig.cleanUp() }
        await #expect(throws: EngineError.microphoneDenied) { try await rig.recorder.start() }
        #expect(rig.recorder.state == .idle)
        #expect(try rig.container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 0)
    }

    @Test func undeterminedPermissionIsRequested() async throws {
        let rig = try makeRig(mic: .undetermined)
        defer { rig.cleanUp() }
        let id = try await rig.recorder.start()
        #expect(rig.recorder.recordingID == id)
        await rig.recorder.discard()
    }

    @Test func liveTextNoteWhenModelsAreNotReady() async throws {
        let rig = try makeRig(models: .missing)
        defer { rig.cleanUp() }
        try await rig.recorder.start()
        #expect(rig.recorder.liveTextNote == RecorderController.modelsNotReadyNote)
        #expect(rig.recorder.liveTextNote == "Live text appears once speech models are ready")
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.recorder.liveText.isEmpty)
        await rig.recorder.discard()
    }

    @Test func liveTextArrivesWhenModelsAreReady() async throws {
        let rig = try makeRig(models: .installed)
        defer { rig.cleanUp() }
        await rig.models.prepareIfInstalled()
        #expect(rig.models.isReady)
        try await rig.recorder.start()
        #expect(rig.recorder.liveTextNote == nil)
        #expect(await wait { rig.recorder.liveText.confirmed.contains("Karan") })
        await rig.recorder.discard()
    }

    @Test func levelsKeepTheLast56() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        try await rig.recorder.start()
        #expect(await wait(timeout: 5) { rig.recorder.elapsed >= 3.2 })
        #expect(rig.recorder.levels.count == RecorderController.levelHistory)
        #expect(rig.recorder.levels.allSatisfy { (0...1).contains($0) })
        await rig.recorder.discard()
    }

    @Test func discardDeletesTheRowAndAudio() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        let id = try await rig.recorder.start()
        await rig.recorder.discard()
        #expect(rig.recorder.state == .idle)
        #expect(try rig.recording(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.paths.audioURL(fileName: rig.paths.newAudioFileName(for: id)).path))
    }

    @Test func startWhileActiveReturnsTheSameRecording() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        let first = try await rig.recorder.start()
        let second = try await rig.recorder.start()
        #expect(first == second)
        #expect(try rig.container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 1)
        await rig.recorder.discard()
    }

    @Test func stopWithoutARecordingThrows() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        await #expect(throws: EngineError.self) { try await rig.recorder.stop() }
    }

    @Test func pauseAndMarkAreIgnoredWhenIdle() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        await rig.recorder.pause()
        await rig.recorder.markMoment()
        #expect(rig.recorder.state == .idle)
        #expect(rig.recorder.marks.isEmpty)
    }

    @Test func startResetsThePreviousRecordingsValues() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        try await rig.recorder.start()
        #expect(await wait { rig.recorder.elapsed > 0.1 })
        await rig.recorder.markMoment()
        _ = try await rig.recorder.stop()
        try await rig.recorder.start()
        #expect(rig.recorder.marks.isEmpty)
        #expect(rig.recorder.lastMarkAt == nil)
        #expect(rig.recorder.elapsed < 0.2)
        await rig.recorder.discard()
    }
}
