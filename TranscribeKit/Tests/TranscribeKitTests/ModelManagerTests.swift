import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Engine whose prepare fails a set number of times before it succeeds (e.g. a Neural Engine compile failure).
private actor FlakyPrepareEngine: SpeechEngine {
    nonisolated let info = EngineInfo(kind: .fake, asrDisplayName: "Parakeet", asrModelID: "flaky", embeddingModel: .fake)
    private var failuresLeft: Int
    private var status: ModelStatus = .installed
    private(set) var prepareCalls = 0

    init(failures: Int) { failuresLeft = failures }

    func modelStatus() async -> ModelStatus { status }
    func prepareModels() async throws {
        prepareCalls += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            status = .failed("ANE compile failed")
            throw EngineError.failed("ANE compile failed")
        }
        status = .ready
    }
    func microphonePermission() async -> MicPermission { .granted }
    func requestMicrophonePermission() async -> Bool { true }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording { throw EngineError.failed("unused") }
    func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] { [] }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        SpeakerSeparation(segments: [], centroids: [:])
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] { [] }
}

/// Engine whose bundled models are missing or damaged: status says so and prepare throws `.modelsMissing`.
private actor MissingModelsEngine: SpeechEngine {
    nonisolated let info = EngineInfo(kind: .fake, asrDisplayName: "Parakeet", asrModelID: "missing", embeddingModel: .fake)
    private(set) var prepareCalls = 0

    func modelStatus() async -> ModelStatus { .failed(ModelStatus.missingFromAppMessage) }
    func prepareModels() async throws {
        prepareCalls += 1
        throw EngineError.modelsMissing
    }
    func microphonePermission() async -> MicPermission { .granted }
    func requestMicrophonePermission() async -> Bool { true }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording { throw EngineError.failed("unused") }
    func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] { [] }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        SpeakerSeparation(segments: [], centroids: [:])
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] { [] }
}

@MainActor
final class ModelManagerReadyCounter {
    var count = 0
}

@Suite("ModelManager")
@MainActor
struct ModelManagerTests {
    let info = EngineInfo(kind: .fake, asrDisplayName: "Parakeet", asrModelID: "x", embeddingModel: .fake)

    func fakeEngine(models: String) -> FakeSpeechEngine {
        let config = LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"],
                                  environment: ["TRANSCRIBE_MODELS": models, "TRANSCRIBE_SPEED": "instant"])
        return FakeSpeechEngine(config: config, script: FakeScript.named(.newVoices))
    }

    func manager(_ engine: any SpeechEngine, counter: ModelManagerReadyCounter) -> ModelManager {
        ModelManager(engine: engine, onReady: { counter.count += 1 })
    }

    @Test func prepareIfInstalledMakesInstalledModelsReady() async {
        let counter = ModelManagerReadyCounter()
        let m = manager(fakeEngine(models: "installed"), counter: counter)
        await m.refresh()
        #expect(m.status == .installed)
        #expect(m.settingsValue == "Getting ready…")
        #expect(m.isSettingUp)
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        #expect(m.isReady)
        #expect(m.settingsValue == "Parakeet")
        #expect(!m.isSettingUp)
        #expect(counter.count == 1)
        // Already ready: nothing happens, onReady is not called again.
        await m.prepareIfInstalled()
        #expect(counter.count == 1)
    }

    @Test func firstLaunchPrepareNeedsNoDownload() async {
        // "missing" now means the first launch on this device: the models ship in the app, only the prepare is slow.
        let counter = ModelManagerReadyCounter()
        let m = manager(fakeEngine(models: "missing"), counter: counter)
        await m.refresh()
        #expect(m.status == .installed)
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        #expect(counter.count == 1)
    }

    @Test func failedPrepareWaitsForTryAgain() async {
        let counter = ModelManagerReadyCounter()
        let engine = FlakyPrepareEngine(failures: 1)
        let m = manager(engine, counter: counter)
        await m.prepareIfInstalled()
        #expect(m.status == .failed("ANE compile failed"))
        #expect(m.failureText == "ANE compile failed")
        #expect(m.settingsValue == "Not ready")
        #expect(!m.isSettingUp)
        #expect(counter.count == 0)
        // A foreground does not retry a failed prepare on its own (no repeated Neural Engine compiles).
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 1)
        #expect(m.status == .failed("ANE compile failed"))
        await m.retry()
        #expect(m.status == .ready)
        #expect(counter.count == 1)
        #expect(await engine.prepareCalls == 2)
    }

    @Test func retryIsIgnoredUnlessFailed() async {
        let counter = ModelManagerReadyCounter()
        let engine = FlakyPrepareEngine(failures: 0)
        let m = manager(engine, counter: counter)
        await m.refresh()
        #expect(m.status == .installed)
        await m.retry()
        #expect(await engine.prepareCalls == 0)
        #expect(m.status == .installed)
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        await m.retry()
        #expect(await engine.prepareCalls == 1)
        #expect(counter.count == 1)
    }

    @Test func missingModelsSayInstallAgain() async {
        let counter = ModelManagerReadyCounter()
        let engine = MissingModelsEngine()
        let m = manager(engine, counter: counter)
        await m.refresh()
        #expect(m.status == .failed(ModelStatus.missingFromAppMessage))
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 0)
        await m.retry()
        #expect(await engine.prepareCalls == 1)
        #expect(m.status == .failed(ModelStatus.missingFromAppMessage))
        #expect(m.failureText == ModelStatus.missingFromAppMessage)
        #expect(counter.count == 0)
    }

    @Test func concurrentPreparesRunOnce() async {
        let counter = ModelManagerReadyCounter()
        let engine = FlakyPrepareEngine(failures: 0)
        let m = manager(engine, counter: counter)
        async let first: Void = m.prepareIfInstalled()
        async let second: Void = m.prepareIfInstalled()
        async let third: Void = m.retry()
        _ = await (first, second, third)
        #expect(m.status == .ready)
        #expect(await engine.prepareCalls == 1)
        #expect(counter.count == 1)
    }

    @Test func errorMessages() {
        #expect(ModelManager.message(for: EngineError.modelsMissing) == ModelStatus.missingFromAppMessage)
        #expect(ModelManager.message(for: EngineError.failed("boom")) == "boom")
        #expect(ModelManager.message(for: EngineError.failed("")) == ModelManager.Copy.loadFailed)
        #expect(ModelManager.message(for: EngineError.cancelled) == ModelManager.Copy.loadFailed)
    }

    @Test(arguments: [
        (ModelStatus.ready, "Parakeet"),
        (.installed, "Getting ready…"),
        (.preparing, "Getting ready…"),
        (.failed("x"), "Not ready"),
    ])
    func settingsRowValue(_ status: ModelStatus, _ expected: String) {
        #expect(ModelManager.settingsValue(status, info: info) == expected)
    }
}
