import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("CaptureGate")
@MainActor
struct CaptureGateTests {
    @Test func oneOwnerAtATime() {
        let gate = CaptureGate()
        #expect(gate.owner == nil)
        #expect(gate.claim(.dictation))
        #expect(!gate.claim(.meeting))
        #expect(!gate.claim(.dictation), "a second claim is refused, even by the same owner")
        gate.release(.meeting)   // not the owner: ignored
        #expect(gate.owner == .dictation)
        gate.release(.dictation)
        #expect(gate.owner == nil)
        #expect(gate.claim(.meeting))
        #expect(gate.owner == .meeting)
        gate.release(.meeting)
        gate.release(.meeting)
        #expect(gate.owner == nil)
        #expect(CaptureGate.dictationBusyMessage == "Finish dictating first.")
    }
}

/// The fake engine, except that starting a capture fails.
final class FailingStartEngine: SpeechEngine, Sendable {
    let base: FakeSpeechEngine
    init(base: FakeSpeechEngine) { self.base = base }
    var info: EngineInfo { base.info }
    func modelStatus() async -> ModelStatus { await base.modelStatus() }
    func prepareModels() async throws { try await base.prepareModels() }
    func microphonePermission() async -> MicPermission { .granted }
    func requestMicrophonePermission() async -> Bool { true }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        throw EngineError.failed("The microphone is busy")
    }
    func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        try await base.transcribe(audio, language: language, progress: progress)
    }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        try await base.separateSpeakers(audio, progress: progress)
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] { try await base.embedVoice(audio, spans: spans) }
}

/// The recorder claims the capture gate for a meeting and gives it back however the recording ends.
extension RecorderControllerTests {
    @Test func theGateIsClaimedWhileRecordingAndFreedOnStop() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        #expect(rig.recorder.gate.owner == nil)
        try await rig.recorder.start()
        #expect(rig.recorder.gate.owner == .meeting)
        _ = try await rig.recorder.stop()
        #expect(rig.recorder.gate.owner == nil)
    }

    @Test func theGateIsFreedOnDiscard() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        try await rig.recorder.start()
        await rig.recorder.discard()
        #expect(rig.recorder.gate.owner == nil)
    }

    @Test func theGateIsFreedWhenTheMicrophoneIsDenied() async throws {
        let rig = try makeRig(mic: .denied)
        defer { rig.cleanUp() }
        await #expect(throws: EngineError.microphoneDenied) { try await rig.recorder.start() }
        #expect(rig.recorder.gate.owner == nil)
    }

    @Test func theGateIsFreedWhenStartFails() async throws {
        let base = try makeRig()
        defer { base.cleanUp() }
        let recorder = RecorderController(engine: FailingStartEngine(base: base.engine), store: base.store,
                                          coordinator: base.coordinator, models: base.models, paths: base.paths,
                                          settings: AppSettings(defaults: UserDefaults(suiteName: "gate-\(UUID().uuidString)")!),
                                          clock: .frozen(base.now))
        await #expect(throws: EngineError.failed("The microphone is busy")) { try await recorder.start() }
        #expect(recorder.gate.owner == nil && recorder.state == .idle)
        #expect(try base.container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 0)
    }

    @Test func theGateIsFreedWhenStopFails() async throws {
        let (rig, _) = try makeScriptedRig(failStop: true)
        defer { rig.cleanUp() }
        try await rig.recorder.start()
        await #expect(throws: EngineError.self) { try await rig.recorder.stop() }
        #expect(rig.recorder.gate.owner == nil)
    }

    @Test func aRecordingDuringADictationIsRefused() async throws {
        let rig = try makeRig()
        defer { rig.cleanUp() }
        #expect(rig.recorder.gate.claim(.dictation))
        await #expect(throws: EngineError.failed(CaptureGate.dictationBusyMessage)) { try await rig.recorder.start() }
        #expect(rig.recorder.state == .idle && rig.recorder.gate.owner == .dictation)
        #expect(try rig.container.mainContext.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(await rig.engine.callCount("startRecording") == 0)
        rig.recorder.gate.release(.dictation)
        try await rig.recorder.start()
        #expect(rig.recorder.gate.owner == .meeting)
        await rig.recorder.discard()
    }
}
