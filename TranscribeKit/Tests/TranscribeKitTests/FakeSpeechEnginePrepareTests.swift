import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// The fake engine's staged prepare: the real order, scripted seconds, the same events, the real start rule.
@Suite("FakeSpeechEngine prepare")
struct FakeSpeechEnginePrepareTests {
    final class EventLog: Sendable {
        private let events = Mutex<[PrepareEvent]>([])
        func add(_ e: PrepareEvent) { events.withLock { $0.append(e) } }
        var all: [PrepareEvent] { events.withLock { $0 } }
        var sink: @Sendable (PrepareEvent) -> Void { { [self] in add($0) } }
    }

    static func engine(models: String, speed: String = "instant", activity: AppActivity? = nil,
                       beforeStage: (@Sendable (PrepareStage) async -> Void)? = nil) -> FakeSpeechEngine {
        let config = LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"],
                                  environment: ["TRANSCRIBE_MODELS": models, "TRANSCRIBE_SPEED": speed])
        return FakeSpeechEngine(config: config, script: FakeScript.named(.newVoices), activity: activity,
                                beforeStage: beforeStage)
    }

    /// The run order (decided 2026-11-25): the short stages first, Parakeet and its warm-up last.
    static let order: [PrepareStage] = [.diarizer, .nemotron, .asr, .warmup]

    static func pairs(_ stages: [PrepareStage]) -> [PrepareEvent] {
        stages.flatMap { [PrepareEvent.stageStarted($0), .stageFinished($0)] }
    }

    @Test func theFirstPrepareSendsTheScriptedPlanAndPairedStages() async throws {
        let log = EventLog()
        let engine = Self.engine(models: "missing")
        try await engine.prepareModels(onEvent: log.sink)
        #expect(await engine.modelStatus() == .ready)
        let plan = PreparePlan(steps: [PreparePlan.Step(stage: .diarizer, expectedSeconds: 0.05),
                                       PreparePlan.Step(stage: .nemotron, expectedSeconds: 0.05),
                                       PreparePlan.Step(stage: .asr, expectedSeconds: 1.88),
                                       PreparePlan.Step(stage: .warmup, expectedSeconds: 0.02)],
                               timesFromThisDevice: true)
        let events = log.all
        guard case .planned(let sent) = events.first else { Issue.record("no plan first"); return }
        #expect(sent.steps.map(\.stage) == Self.order)
        #expect(PrepareStage.allCases == Self.order, "the engines run PrepareStage.allCases in order")
        for (a, b) in zip(sent.steps, plan.steps) { #expect(abs(a.expectedSeconds - b.expectedSeconds) < 1e-9) }
        #expect(!sent.timesFromThisDevice, "a first install has no times measured on this device")
        #expect(sent.steps.allSatisfy { !$0.isWarm }, "every first-launch stage is cold")
        #expect(Array(events.dropFirst()) == Self.pairs(Self.order))
        #expect(FakeSpeechEngine.coldSeconds.reduce(0) { $0 + $1.1 } == 20)
        #expect(abs(FakeSpeechEngine.warmSeconds.reduce(0) { $0 + $1.1 } - 0.5) < 1e-9)
    }

    @Test func aWarmPrepareIsShortAndTheSameShape() async throws {
        let log = EventLog()
        let engine = Self.engine(models: "installed")
        try await engine.prepareModels(onEvent: log.sink)
        guard case .planned(let plan) = log.all.first else { Issue.record("no plan first"); return }
        #expect(abs(plan.steps.reduce(0) { $0 + $1.expectedSeconds } - 0.05) < 1e-9)
        #expect(plan.steps.allSatisfy { $0.isWarm } && plan.timesFromThisDevice)
        #expect(Array(log.all.dropFirst()) == Self.pairs(Self.order))
        // Ready: a second call sends nothing.
        let again = EventLog()
        try await engine.prepareModels(onEvent: again.sink)
        #expect(again.all.isEmpty)
    }

    /// In the background without leave to start a stage (no Background Inference here), the stage is refused: a
    /// pause, with no start event. Back in front, the next prepare runs everything.
    @Test func aRefusedStageSendsNoStart() async throws {
        let activity = AppActivity(backgroundInference: false)
        let engine = Self.engine(models: "missing", activity: activity)
        activity.enterBackground()
        let first = EventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: first.sink) }
        #expect(await engine.modelStatus() == .installed)
        #expect(first.all.count == 1, "the plan only: the diarizer's start was refused")
        activity.becomeActive()
        let second = EventLog()
        try await engine.prepareModels(onEvent: second.sink)
        #expect(await engine.modelStatus() == .ready)
        #expect(Array(second.all.dropFirst()) == Self.pairs(Self.order))
    }

    /// The real keep rule: without Background Inference a Neural Engine stage that returns after a trip to the
    /// background is dropped (its compile counts: it sends stageFinished and runs again warm) and the prepare pauses.
    /// Stages kept before it stay kept.
    @Test func aStageThatSpansATripAwayIsDroppedAndThePreparePauses() async throws {
        let activity = AppActivity(backgroundInference: false)
        let engine = Self.engine(models: "missing", activity: activity, beforeStage: { stage in
            // The user leaves and comes back while Parakeet compiles.
            if stage == .asr, activity.epoch == 0 { activity.enterBackground(); activity.becomeActive() }
        })
        let first = EventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: first.sink) }
        #expect(await engine.modelStatus() == .installed)
        #expect(Array(first.all.dropFirst()) == Self.pairs([.diarizer, .nemotron, .asr]),
                "the dropped stage still finished its compile; the warm-up never started")

        let second = EventLog()
        try await engine.prepareModels(onEvent: second.sink)
        #expect(await engine.modelStatus() == .ready)
        guard case .planned(let plan) = second.all.first else { Issue.record("no plan first"); return }
        #expect(plan.step(.diarizer)?.isDone == true, "the diarizer ran wholly in front: kept")
        #expect(plan.step(.nemotron)?.isDone == true, "Nemotron ran wholly in front: kept")
        #expect(plan.step(.asr)?.isDone == false, "Parakeet was dropped: it runs again")
        #expect(plan.step(.asr)?.isWarm == true, "warm: its compile finished")
        #expect(abs((plan.step(.asr)?.expectedSeconds ?? 0) - 0.02) < 1e-9)
        #expect(Array(second.all.dropFirst()) == Self.pairs([.asr, .warmup]))
    }

    /// Nemotron 3 runs on the CPU: a trip away while it runs drops nothing, even without Background Inference.
    /// Still in the background when it returns, the next stage (Parakeet, Neural Engine) is refused: a pause, and
    /// back in front only Parakeet and the warm-up run.
    @Test func theCPUStageIsKeptAfterATripAwayWithoutBackgroundInference() async throws {
        let activity = AppActivity(backgroundInference: false)
        let engine = Self.engine(models: "missing", activity: activity, beforeStage: { stage in
            if stage == .nemotron, activity.epoch == 0 { activity.armGrace(UUID()); activity.enterBackground() }
        })
        let first = EventLog()
        await #expect(throws: EngineError.cancelled) { try await engine.prepareModels(onEvent: first.sink) }
        #expect(Array(first.all.dropFirst()) == Self.pairs([.diarizer, .nemotron]), "Parakeet's start was refused")

        activity.becomeActive()
        let second = EventLog()
        try await engine.prepareModels(onEvent: second.sink)
        #expect(await engine.modelStatus() == .ready)
        guard case .planned(let plan) = second.all.first else { Issue.record("no plan first"); return }
        #expect(plan.step(.nemotron)?.isDone == true, "kept although it ran in the background")
        #expect(Array(second.all.dropFirst()) == Self.pairs([.asr, .warmup]))
    }

    /// With Background Inference the same trip keeps the stage, as the real engine does with the Neural Engine
    /// listed.
    @Test func withBackgroundInferenceAStageThatSpansATripAwayIsKept() async throws {
        let activity = AppActivity(backgroundInference: true)
        let engine = Self.engine(models: "missing", activity: activity, beforeStage: { stage in
            if stage == .asr, activity.epoch == 0 { activity.enterBackground(); activity.becomeActive() }
        })
        try await engine.prepareModels()
        #expect(await engine.modelStatus() == .ready)
    }

    @Test func withBackgroundInferenceAndAHeldShortTaskStagesRunInTheBackground() async throws {
        let activity = AppActivity(backgroundInference: true)
        let grace = UUID()
        activity.armGrace(grace)
        activity.enterBackground()
        let engine = Self.engine(models: "installed", activity: activity)
        try await engine.prepareModels()
        #expect(await engine.modelStatus() == .ready)
    }

    @Test func withoutAnActivityNothingIsRefused() async throws {
        let engine = Self.engine(models: "installed")
        try await engine.prepareModels()
        #expect(await engine.modelStatus() == .ready)
    }
}
