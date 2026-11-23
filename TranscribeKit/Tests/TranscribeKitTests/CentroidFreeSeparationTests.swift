import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// The real engine's primary separator (Nemotron 3) returns speaker turns only, with no centroid vectors.
/// This wraps the fake engine to behave the same way, so the pipeline must get every voice vector from
/// `embedVoice` (WeSpeaker on each speaker's clean speech) for naming and auto-labelling to keep working.
actor CentroidFreeEngine: SpeechEngine {
    let base: FakeSpeechEngine
    nonisolated var info: EngineInfo { base.info }
    private(set) var separations: [SpeakerSeparation] = []

    init(base: FakeSpeechEngine) { self.base = base }

    func modelStatus() async -> ModelStatus { await base.modelStatus() }
    func installModels(progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws {
        try await base.installModels(progress: progress)
    }
    func removeModels() async throws { try await base.removeModels() }
    func prepareModels() async throws { try await base.prepareModels() }
    func microphonePermission() async -> MicPermission { await base.microphonePermission() }
    func requestMicrophonePermission() async -> Bool { await base.requestMicrophonePermission() }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        try await base.startRecording(request)
    }
    func transcribe(_ audio: URL, language: LanguageHint,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        try await base.transcribe(audio, language: language, progress: progress)
    }
    func separateSpeakers(_ audio: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        let full = try await base.separateSpeakers(audio, progress: progress)
        let turnsOnly = SpeakerSeparation(segments: full.segments, centroids: [:], separator: .nemotron3)
        separations.append(turnsOnly)
        return turnsOnly
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] {
        try await base.embedVoice(audio, spans: spans)
    }
}

@Suite("Separation without centroids (Nemotron 3 shape)")
@MainActor
struct CentroidFreeSeparationTests {
    private func makeCoordinator(_ script: FakeScriptName, seed: SeedName) async throws
        -> (WP3Harness, CentroidFreeEngine, ProcessingCoordinator) {
        let h = try WP3Harness()
        try h.seed(seed)
        let fake = FakeSpeechEngine(config: LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"], environment: [:]),
                                    script: .named(script))
        try await fake.prepareModels()
        let engine = CentroidFreeEngine(base: fake)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "centroid-free-\(UUID().uuidString)")!)
        let coordinator = ProcessingCoordinator(engine: engine, store: h.store, monitor: ProcessingMonitor(), settings: settings,
                                                paths: h.paths, background: SpyBackgroundBridge())
        return (h, engine, coordinator)
    }

    @Test func everySpeakerStillGetsAWeSpeakerVector() async throws {
        let (h, engine, coordinator) = try await makeCoordinator(.newVoices, seed: .empty)
        defer { h.cleanup() }
        let id = try h.queuedRecording(script: engine.base.script, writeAudio: true)
        await coordinator.enqueue(id)
        await coordinator.waitUntilIdle()

        let separations = await engine.separations
        #expect(separations.count == 1 && separations.allSatisfy { $0.centroids.isEmpty && $0.separator == .nemotron3 })
        let r = try h.recording(id)
        #expect(r.stage == .ready)
        #expect(r.sortedSpeakers.count == 2)
        #expect(r.sortedSpeakers.allSatisfy { $0.vector != nil && $0.cleanSeconds >= 10 })
        #expect(await engine.base.callCount("embedVoice") == 2)
    }

    @Test func savedVoicesAreStillRecognised() async throws {
        let (h, engine, coordinator) = try await makeCoordinator(.knownVoices, seed: .library)
        defer { h.cleanup() }
        let id = try h.queuedRecording(script: engine.base.script, writeAudio: true)
        await coordinator.enqueue(id)
        await coordinator.waitUntilIdle()

        let r = try h.recording(id)
        #expect(r.stage == .ready)
        #expect(r.sortedSpeakers.count == 2)
        #expect(r.sortedSpeakers.map(\.displayName) == ["Liam", "Karan"])
        #expect(r.sortedSpeakers.map(\.label) == [.autoLabelled, .autoLabelled])
    }
}
