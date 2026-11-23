import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Every snapshot the coordinator published, in order.
final class SnapshotLog: Sendable {
    private let items = Mutex<[ProcessingSnapshot]>([])
    func append(_ s: ProcessingSnapshot) { items.withLock { $0.append(s) } }
    var all: [ProcessingSnapshot] { items.withLock { $0 } }
}

/// A store, a fake engine and a coordinator wired together (instant fake speed).
@MainActor
final class WP3Pipeline {
    let h: WP3Harness
    let engine: FakeSpeechEngine
    let monitor = ProcessingMonitor()
    let settings: AppSettings
    let background = SpyBackgroundBridge()
    let coordinator: ProcessingCoordinator
    let published = SnapshotLog()

    init(_ script: FakeScriptName, seed: SeedName? = nil, modelsReady: Bool = true, harness: WP3Harness? = nil,
         customScript: FakeScript? = nil) async throws {
        h = try harness ?? WP3Harness()
        if let seed { try h.seed(seed) }
        let env = modelsReady ? [:] : ["TRANSCRIBE_MODELS": "missing"]
        engine = FakeSpeechEngine(config: LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"], environment: env),
                                  script: customScript ?? .named(script))
        if modelsReady { try await engine.prepareModels() }
        settings = AppSettings(defaults: UserDefaults(suiteName: "wp3-\(UUID().uuidString)")!)
        coordinator = ProcessingCoordinator(engine: engine, store: h.store, monitor: monitor, settings: settings,
                                            paths: h.paths, background: background)
        let published = self.published
        await coordinator.setPublishObserver { s in published.append(s) }
    }

    var script: FakeScript { engine.script }

    func record() throws -> UUID { try h.queuedRecording(script: script, writeAudio: true) }

    func snapshots(_ id: UUID) -> [ProcessingSnapshot] { published.all.filter { $0.recordingID == id } }

    /// Waits for the coordinator to go idle and for the monitor to show the job's final phase.
    func settle(_ id: UUID) async -> ProcessingSnapshot? {
        await coordinator.waitUntilIdle()
        _ = await wp3WaitFor { [self] in
            guard let last = snapshots(id).last, monitor.snapshot(for: id) == last else { return false }
            switch last.phase {
            case .finished, .failed, .queued: return true
            case .running: return false
            }
        }
        return monitor.snapshot(for: id)
    }

    func run(_ id: UUID) async -> ProcessingSnapshot? {
        await coordinator.enqueue(id)
        return await settle(id)
    }

    func waitForSeparation() async -> Bool {
        await wp3WaitFor { [engine] in await engine.callCount("separateSpeakers") >= 1 }
    }

    func cleanup() { h.cleanup() }
}

@Suite("WP3: processing pipeline")
@MainActor
struct ProcessingPipelineTests {
    @Test func newVoicesRunsEveryStepInOrderAndEndsWithTwoUnnamedSpeakers() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
        #expect(final.voicesFound == 2 && final.overall == 1)
        #expect(final.steps.map(\.axValue) == ["done", "done", "skipped"])
        #expect(final.steps[2].subtitle == "No saved voices yet")

        let r = try p.h.recording(id)
        #expect(r.stage == .ready && r.queueReason == nil && r.attemptCount == 0)
        #expect(r.sortedSpeakers.map(\.displayName) == ["Speaker 1", "Speaker 2"])
        #expect(r.sortedSpeakers.map(\.label) == [.unnamed, .unnamed])
        #expect(r.sortedSpeakers.map(\.colourSlot) == [0, 1])
        #expect(r.sortedSpeakers.allSatisfy { $0.cleanSeconds >= 10 && $0.vector != nil && $0.turnCount == 2 })
        #expect(r.transcript?.hasSpeakers == true && r.transcript?.turns.count == 4)
        #expect(r.transcript?.words.count == p.script.words.count)
        #expect(r.speakersNeedingName.count == 2 && !r.hasUnseenResult)

        // Step order: transcribing becomes active before separating, which is active before the end.
        let snaps = p.snapshots(id)
        let firstActiveT = try #require(snaps.firstIndex { $0.currentStep == .transcribing })
        let firstActiveS = try #require(snaps.firstIndex { $0.currentStep == .separating })
        #expect(firstActiveT < firstActiveS)
        #expect(await p.engine.callCount("transcribe") == 1)
        #expect(await p.engine.callCount("separateSpeakers") == 1)
        #expect(await p.engine.callCount("embedVoice") == 2)
        #expect(await p.engine.maxConcurrentCalls == 1)
        #expect(p.background.beginCount == 1 && p.background.endResults == [true])
    }

    @Test func snapshotsArriveInOrderWithRisingProgress() async throws {
        let p = try await WP3Pipeline(.knownVoices, seed: .library)
        defer { p.cleanup() }
        let id = try p.record()
        _ = await p.run(id)
        let snaps = p.snapshots(id)
        #expect(snaps.count >= 4)
        let running = snaps.drop { if case .queued = $0.phase { true } else { false } }
        let overall = running.map(\.overall)
        #expect(overall == overall.sorted(), "overall progress went backwards: \(overall)")
        #expect(snaps.last?.overall == 1)
        if case .finished = snaps.last?.phase {} else { Issue.record("last phase \(String(describing: snaps.last?.phase))") }
        #expect(snaps.dropLast().allSatisfy { if case .finished = $0.phase { false } else { true } })
        // The monitor ends where the stream ended.
        #expect(p.monitor.snapshot(for: id) == snaps.last && p.monitor.lastFinished == snaps.last)
    }

    @Test func identifySpeakersOffSkipsSeparationAndMatching() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .library)
        defer { p.cleanup() }
        p.settings.identifySpeakers = false
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome()))
        #expect(final.steps.map(\.state) == [.done, .skipped("Identify speakers is off"), .skipped("Identify speakers is off")])
        #expect(final.stepCounterText == "Step 1 of 1")
        let r = try p.h.recording(id)
        #expect(r.stage == .ready && r.speakers.isEmpty && r.transcript?.hasSpeakers == false && !r.noSpeech)
        #expect(await p.engine.callCount("separateSpeakers") == 0)
    }

    @Test func recogniseVoicesOffLeavesEveryoneUnnamed() async throws {
        let p = try await WP3Pipeline(.knownVoices, seed: .library)
        defer { p.cleanup() }
        p.settings.recogniseVoices = false
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.steps[2].state == .skipped("Recognise saved voices is off"))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
        let r = try p.h.recording(id)
        #expect(r.sortedSpeakers.map(\.label) == [.unnamed, .unnamed])
        #expect(try p.h.profile(named: "Liam")?.samples.count == 3)
    }

    @Test func noSpeechFinishesWithNoSpeechDetected() async throws {
        let p = try await WP3Pipeline(.noSpeech, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(noSpeech: true)))
        #expect(final.steps.map(\.axValue) == ["done", "skipped", "skipped"])
        let r = try p.h.recording(id)
        #expect(r.stage == .ready && r.noSpeech && r.speakers.isEmpty && r.transcript?.words.isEmpty == true)
        #expect(await p.engine.callCount("separateSpeakers") == 0)
    }

    @Test func failSeparationRetriesTwiceThenFails() async throws {
        let p = try await WP3Pipeline(.failSeparation, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.phase == .failed("Couldn't finish processing"))
        let r = try p.h.recording(id)
        #expect(r.stage == .failed && r.failureMessage == "Couldn't finish processing" && r.attemptCount == 3)
        #expect(r.transcript != nil)                                   // the transcript checkpoint survives
        #expect(await p.engine.callCount("separateSpeakers") == 3)
        #expect(await p.engine.callCount("transcribe") == 1)            // attempts 2 and 3 resume at separation
        #expect(p.background.endResults == [false, false, false])

        // Retry starts again from the checkpoint with a fresh attempt count.
        await p.coordinator.retry(id)
        _ = await p.settle(id)
        #expect(try p.h.recording(id).attemptCount == 3)
        #expect(await p.engine.callCount("separateSpeakers") == 6)
        #expect(await p.engine.callCount("transcribe") == 1)
    }

    @Test func knownVoicesAgainstTheLibraryAutoLabelsBoth() async throws {
        let p = try await WP3Pipeline(.knownVoices, seed: .library)
        defer { p.cleanup() }
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(autoLabelled: 2)))
        #expect(final.comparedWith == ["Liam", "Karan"])
        #expect(final.steps[2].subtitle == "Compared with Liam and Karan")
        let r = try p.h.recording(id)
        #expect(r.sortedSpeakers.map(\.displayName) == ["Liam", "Karan"])
        #expect(r.sortedSpeakers.map(\.label) == [.autoLabelled, .autoLabelled])
        #expect(r.sortedSpeakers.map(\.colourSlot) == [0, 1])
        #expect(r.hasUnseenResult)
        // Liam's 0.82 match with lots of speech adds a strong sample; Karan's 4.6 s does not.
        let liam = try #require(try p.h.profile(named: "Liam"))
        let karan = try #require(try p.h.profile(named: "Karan"))
        #expect(liam.samples.count == 4 && liam.samples.contains { $0.origin == .strongMatch && $0.sourceRecordingID == id })
        #expect(karan.samples.count == 2)
        let s1 = try #require(r.speaker("S1"))
        #expect(abs((s1.matchScore ?? 0) - 0.82) < 1e-3)
    }

    @Test func anOutlierSpanDoesNotPullTheSpeakerVector() async throws {
        var script = FakeScript.named(.newVoices)
        let spans = CleanSpeech.spans(for: "S1", in: script.segments, config: .default)
        let embedded = CleanSpeech.embeddingSpans(spans, config: .default)
        let shortest = try #require(embedded.min { $0.duration < $1.duration })
        let embeddedSeconds = embedded.reduce(0) { $0 + $1.duration }
        try #require(embedded.count >= 2 && shortest.duration < embeddedSeconds / 2)
        script.spanVectors = [(range: shortest, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 49))]

        let p = try await WP3Pipeline(.newVoices, seed: .empty, customScript: script)
        defer { p.cleanup() }
        let id = try p.record()
        _ = await p.run(id)
        let s1 = try #require(try p.h.recording(id).speaker("S1"))
        let stored = try #require(s1.vector)
        let expected = try #require(script.vectors["S1"])
        #expect(zip(stored.values, expected.values).allSatisfy { abs($0 - $1) < 1e-5 })
        #expect(s1.vectorCoherence == 1)
    }

    @Test func thePipelineMatchesWithTheCohortAndWritesTraces() async throws {
        let p = try await WP3Pipeline(.knownVoices, seed: .library)
        defer { p.cleanup() }
        let id = try p.record()
        _ = await p.run(id)
        let cohort = try p.h.store.matchCohort(modelKey: EmbeddingModelID.fake.key, excludingRecording: id)
        #expect(!cohort.isEmpty)   // C's Speaker 2, never named
        let speakers = try p.h.recording(id).sortedSpeakers
        #expect(speakers.count == 2)
        for s in speakers {
            let trace = try JSONDecoder().decode(MatchTrace.self, from: try #require(s.matchTraceData))
            #expect(trace.key == s.key && trace.kind == .auto && trace.cohortSize == cohort.count)
        }
    }

    @Test func aCohortVoiceTurnsThePipelinesAutoLabelIntoAnAsk() async throws {
        // Liam at 0.6, but also 0.6 × 0.9 = 0.54 like C's never-named Speaker 2 (the stranger at 0.9):
        // the margin is 0.6 − 0.54 = 0.06, under 0.10, so the pipeline asks instead of auto-labelling.
        var script = FakeScript.named(.knownVoices)
        let voice = SyntheticVoices.mix([(.liam, 0.6), (.stranger, 0.6)], variant: 50)
        script.vectors["S1"] = voice
        let p = try await WP3Pipeline(.knownVoices, seed: .library, customScript: script)
        defer { p.cleanup() }
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(autoLabelled: 1, suggested: 1)))
        let s1 = try #require(try p.h.recording(id).speaker("S1"))
        #expect(s1.label == .suggested && s1.suggestedProfileID == Seeds.ID.liam)
        let trace = try JSONDecoder().decode(MatchTrace.self, from: try #require(s1.matchTraceData))
        #expect(trace.kind == .ask && trace.reason == "margin" && trace.profileID == Seeds.ID.liam)
        #expect(abs((trace.score ?? 0) - 0.6) < 1e-3 && abs((trace.margin ?? 0) - 0.06) < 1e-3)
        let liamCohortMax = try #require(trace.profiles.first { $0.profileID == Seeds.ID.liam }?.cohortMax)
        #expect(abs(liamCohortMax - 0.54) < 1e-3)
        // Without the cohort, the same voice would have been auto-labelled.
        let probe = SpeakerProbe(key: "S1", vector: voice, cleanSeconds: s1.cleanSeconds, rejectedProfileIDs: [],
                                 channel: try p.h.recording(id).captureChannel)
        let candidates = try p.h.store.matchCandidates(modelKey: EmbeddingModelID.fake.key)
        let alone = VoiceMatcher.decide(probes: [probe], profiles: candidates, modelKey: EmbeddingModelID.fake.key)
        guard case .autoLabel(Seeds.ID.liam, _, _)? = alone["S1"] else {
            Issue.record("expected an auto-label without the cohort, got \(String(describing: alone["S1"]))"); return
        }
    }

    @Test func askKaranAsksAboutKaran() async throws {
        let p = try await WP3Pipeline(.askKaran, seed: .library)
        defer { p.cleanup() }
        let id = try p.record()
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(autoLabelled: 1, suggested: 1)))
        let r = try p.h.recording(id)
        #expect(r.speaker("S1")?.label == .autoLabelled && r.speaker("S1")?.profile?.name == "Liam")
        #expect(r.speaker("S2")?.label == .suggested && r.speaker("S2")?.suggestedProfileID == Seeds.ID.karan)
        #expect(r.speakersNeedingName.map(\.key) == ["S2"])
    }

    @Test func atMostOneEngineCallInFlightAcrossJobs() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        let ids = try (0..<3).map { i in try p.h.queuedRecording(createdAt: Seeds.Dates.d.addingTimeInterval(Double(i)),
                                                                   script: p.script, writeAudio: true) }
        for id in ids { await p.coordinator.enqueue(id) }
        await p.coordinator.enqueue(ids[0])                            // a duplicate enqueue is ignored
        for id in ids { _ = await p.settle(id) }
        for id in ids { #expect(try p.h.recording(id).stage == .ready) }
        #expect(await p.engine.maxConcurrentCalls == 1)
        #expect(await p.engine.callCount("transcribe") == 3)
        // FIFO: jobs finished in the order they were queued.
        let finishOrder = p.published.all.compactMap { s -> UUID? in
            if case .finished = s.phase { s.recordingID } else { nil }
        }
        #expect(finishOrder == ids)
    }

    @Test func modelsNotReadyQueuesUntilModelsBecomeReady() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty, modelsReady: false)
        defer { p.cleanup() }
        let id = try p.record()
        let queued = try #require(await p.run(id))
        #expect(queued.phase == .queued(.modelsNotReady))
        #expect(try p.h.recording(id).stage == .queued && p.h.recording(id).queueReason == .modelsNotReady)
        #expect(await p.engine.callCount("transcribe") == 0)

        // A second recording joins the wait.
        let second = try p.record()
        await p.coordinator.enqueue(second)
        await p.coordinator.waitUntilIdle()
        #expect(try p.h.recording(second).queueReason == .modelsNotReady)

        try await p.engine.prepareModels()
        await p.coordinator.modelsBecameReady()
        let done = try #require(await p.settle(id))
        _ = await p.settle(second)
        #expect(done.phase == .finished(ProcessingOutcome(unnamed: 2)))
        #expect(try p.h.recording(second).stage == .ready)
        #expect(try p.h.recording(id).queueReason == nil)
    }

    @Test func deletingARunningRecordingStopsItsJob() async throws {
        let p = try await WP3Pipeline(.holdAtSeparating, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        let next = try p.record()
        await p.coordinator.enqueue(id)
        await p.coordinator.enqueue(next)
        #expect(await p.waitForSeparation())
        await p.coordinator.cancel(id)
        try p.h.store.delete(id: id)
        // The next job starts only once the cancelled one has really stopped.
        #expect(await wp3WaitFor { await p.engine.callCount("separateSpeakers") >= 2 })
        #expect(await p.engine.maxConcurrentCalls == 1)
        #expect(await p.coordinator.runningID == next)
        #expect(throws: StoreError.self) { try p.h.store.snapshot(of: id) }
        _ = await wp3WaitFor { p.monitor.snapshot(for: id) == nil }
        #expect(p.monitor.snapshot(for: id) == nil)
        await p.coordinator.cancel(next)
    }

    @Test func pipelineMath() {
        let snap = RecordingSnapshot(id: UUID(), audioFileName: "a.wav", duration: 1, stage: .separating, language: .automatic,
                                     transcript: WP3Docs.paragraphs(SeedContent.conversationB), attemptCount: 0)
        #expect(ProcessingPipeline.resumePoint(snap) == .separate)
        #expect(ProcessingPipeline.checkpointStage(snap) == .transcribed)
        var s = snap; s.stage = .matching
        #expect(ProcessingPipeline.checkpointStage(s) == .separated)
        s.transcript = nil; s.stage = .transcribing
        #expect(ProcessingPipeline.checkpointStage(s) == .queued && ProcessingPipeline.resumePoint(s) == .transcribe)
        #expect(ProcessingPipeline.overall([:]) == 0)
        #expect(abs(ProcessingPipeline.overall([.transcribing: .done, .separating: .active(fraction: 0.6)]) - 0.72) < 1e-9)
        #expect(ProcessingPipeline.overall([.transcribing: .done, .separating: .skipped("x"), .matching: .skipped("x")]) == 1)
    }
}
