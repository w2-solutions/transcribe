import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Engine whose install fails a set number of times before it succeeds.
private actor FlakyInstallEngine: SpeechEngine {
    nonisolated let info = EngineInfo(kind: .fake, asrDisplayName: "Parakeet", asrModelID: "flaky",
                                      embeddingModel: .fake, speechDownloadBytes: 483_000_000, speakersDownloadBytes: 22_000_000)
    private var failuresLeft: Int
    private var status: ModelStatus = .notInstalled
    private(set) var installCalls = 0
    private(set) var removeCalls = 0

    init(failures: Int) { failuresLeft = failures }

    func modelStatus() async -> ModelStatus { status }
    func installModels(progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws {
        installCalls += 1
        progress(ModelInstallProgress(fraction: 0.2, phase: .downloading(.speech, completedFiles: 1, totalFiles: 5)))
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw EngineError.failed("Network connection lost.")
        }
        status = .installed
    }
    func removeModels() async throws { removeCalls += 1; status = .notInstalled }
    func prepareModels() async throws {
        guard status == .installed || status == .ready else { throw EngineError.modelsMissing }
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

@MainActor
final class ModelManagerReadyCounter {
    var count = 0
}

@Suite("ModelManager")
@MainActor
struct ModelManagerTests {
    let info = EngineInfo(kind: .fake, asrDisplayName: "Parakeet", asrModelID: "x", embeddingModel: .fake,
                          speechDownloadBytes: 483_000_000, speakersDownloadBytes: 22_000_000)

    func fakeEngine(models: String) -> FakeSpeechEngine {
        let config = LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"],
                                  environment: ["TRANSCRIBE_MODELS": models, "TRANSCRIBE_SPEED": "instant"])
        return FakeSpeechEngine(config: config, script: FakeScript.named(.newVoices))
    }

    func manager(_ engine: any SpeechEngine, free: Int64? = 10_000_000_000, counter: ModelManagerReadyCounter) -> ModelManager {
        ModelManager(engine: engine, monitorsNetwork: false, freeSpace: { free }, onReady: { counter.count += 1 })
    }

    @Test func installGoesToReadyAndCallsOnReadyOnce() async {
        let counter = ModelManagerReadyCounter()
        let m = manager(fakeEngine(models: "missing"), counter: counter)
        await m.refresh()
        #expect(m.status == .notInstalled)
        #expect(m.canInstall)
        #expect(m.settingsValue == "Not downloaded")
        await m.install()
        #expect(m.status == .ready)
        #expect(m.isReady)
        #expect(counter.count == 1)
        #expect(m.settingsValue == "Parakeet")
        #expect(!m.canInstall)
        #expect(m.canRemove)
    }

    @Test func failureThenRetrySucceeds() async {
        let counter = ModelManagerReadyCounter()
        let engine = FlakyInstallEngine(failures: 1)
        let m = manager(engine, counter: counter)
        await m.install()
        #expect(m.status == .failed("Network connection lost."))
        #expect(m.failureText == "Network connection lost.")
        #expect(m.settingsValue == "Download failed")
        #expect(counter.count == 0)
        #expect(m.canInstall)
        await m.install()
        #expect(m.status == .ready)
        #expect(counter.count == 1)
        #expect(await engine.installCalls == 2)
    }

    @Test func lowSpaceBlocksTheDownloadWithoutCallingTheEngine() async {
        let counter = ModelManagerReadyCounter()
        let engine = FlakyInstallEngine(failures: 0)
        let m = manager(engine, free: 1_499_999_999, counter: counter)
        #expect(!m.hasEnoughSpace)
        #expect(!m.canInstall)
        await m.install()
        #expect(m.status == .failed(ModelManager.Copy.lowSpace))
        #expect(await engine.installCalls == 0)
        #expect(counter.count == 0)
    }

    @Test func unknownFreeSpaceDoesNotBlock() {
        let m = manager(FlakyInstallEngine(failures: 0), free: nil, counter: ModelManagerReadyCounter())
        #expect(m.hasEnoughSpace)
    }

    @Test func exactlyTheRequiredSpaceIsEnough() {
        let m = manager(FlakyInstallEngine(failures: 0), free: ModelManager.requiredFreeBytes, counter: ModelManagerReadyCounter())
        #expect(m.hasEnoughSpace)
    }

    @Test func prepareIfInstalledMakesInstalledModelsReady() async {
        let counter = ModelManagerReadyCounter()
        let m = manager(fakeEngine(models: "installed"), counter: counter)
        await m.refresh()
        #expect(m.status == .installed)
        #expect(m.settingsValue == "Preparing…")
        #expect(m.phaseText == ModelManager.Copy.preparing)
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        #expect(counter.count == 1)
        // Already ready: nothing happens, onReady is not called again.
        await m.prepareIfInstalled()
        #expect(counter.count == 1)
    }

    @Test func prepareIfInstalledLeavesMissingModelsAlone() async {
        let counter = ModelManagerReadyCounter()
        let m = manager(fakeEngine(models: "missing"), counter: counter)
        await m.prepareIfInstalled()
        #expect(m.status == .notInstalled)
        #expect(counter.count == 0)
    }

    @Test func removeReturnsToNotInstalled() async {
        let counter = ModelManagerReadyCounter()
        let engine = FlakyInstallEngine(failures: 0)
        let m = manager(engine, counter: counter)
        await m.install()
        #expect(m.isReady)
        await m.remove()
        #expect(m.status == .notInstalled)
        #expect(await engine.removeCalls == 1)
    }

    @Test func removeHoldsProcessingFirst() async {
        let counter = ModelManagerReadyCounter()
        let engine = FlakyInstallEngine(failures: 0)
        let m = manager(engine, counter: counter)
        await m.install()
        var removeCallsWhenHeld: Int?
        m.beforeRemove = { removeCallsWhenHeld = await engine.removeCalls }
        await m.remove()
        #expect(removeCallsWhenHeld == 0)        // processing was held before the engine removed anything
        #expect(await engine.removeCalls == 1)
    }

    @Test func downloadSizeText() {
        let m = manager(fakeEngine(models: "missing"), counter: ModelManagerReadyCounter())
        #expect(m.downloadSizeText == "505 MB")
        #expect(m.speechSizeText == "483 MB")
        #expect(m.speakersSizeText == "22 MB")
    }

    @Test func phaseLines() {
        let speechHalf = ModelInstallProgress(fraction: 0.957 * 212.0 / 483.0, phase: .downloading(.speech, completedFiles: 2, totalFiles: 5))
        #expect(ModelManager.phaseText(speechHalf, info: info) == "Downloading speech model · 212 of 483 MB")
        let speakers = ModelInstallProgress(fraction: 0.97, phase: .downloading(.speakers, completedFiles: 1, totalFiles: 5))
        #expect(ModelManager.phaseText(speakers, info: info) == "Speaker models · 22 MB")
        let compiling = ModelInstallProgress(fraction: 1, phase: .compiling(.speech))
        #expect(ModelManager.phaseText(compiling, info: info) == "Preparing for this iPhone… (one time, about a minute)")
        #expect(ModelManager.phaseText(ModelInstallProgress(fraction: 0, phase: .checking), info: info) == ModelManager.Copy.checking)
    }

    @Test(arguments: [
        (ModelStatus.ready, "Parakeet"),
        (.preparing, "Preparing…"),
        (.installed, "Preparing…"),
        (.notInstalled, "Not downloaded"),
        (.installing(ModelInstallProgress(fraction: 0.42, phase: .checking)), "Downloading 42%"),
        (.failed("x"), "Download failed"),
    ])
    func settingsRowValue(_ status: ModelStatus, _ expected: String) {
        #expect(ModelManager.settingsValue(status, info: info) == expected)
    }

    @Test func expensiveNetworkFlag() {
        let m = manager(FlakyInstallEngine(failures: 0), counter: ModelManagerReadyCounter())
        #expect(!m.isExpensiveNetwork)
        m.setExpensiveNetworkForTesting(true)
        #expect(m.isExpensiveNetwork)
    }
}
