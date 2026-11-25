import Foundation
import Testing
import TranscribeCore
@testable import TranscribeKit

/// The pure setup-progress tracker (§ setup progress).
@Suite("SetupProgress")
struct SetupProgressTests {
    /// The iPhone's built-in cold stages, in run order: diarizer 1.5, nemotron 1.5 (CPU), asr 20, warmup 0.25
    /// (23.25 s in all).
    static func coldPlan(fromDevice: Bool = true, nemotron: Bool = true) -> PreparePlan {
        var steps = [PreparePlan.Step(stage: .diarizer, expectedSeconds: 1.5)]
        if nemotron { steps.append(PreparePlan.Step(stage: .nemotron, expectedSeconds: 1.5)) }
        steps += [PreparePlan.Step(stage: .asr, expectedSeconds: 20),
                  PreparePlan.Step(stage: .warmup, expectedSeconds: 0.25)]
        return PreparePlan(steps: steps, timesFromThisDevice: fromDevice)
    }

    static let total = 1.5 + 1.5 + 20 + 0.25

    /// Runs the stages in order, each taking its expected time, starting at `t`; returns the end time.
    static func run(_ p: inout SetupProgress, _ stages: [(PrepareStage, Double)], from t: Double) -> Double {
        var t = t
        for (stage, seconds) in stages {
            p.apply(.stageStarted(stage), at: t)
            t += seconds
            p.apply(.stageFinished(stage), at: t)
        }
        return t
    }

    @Test func withinAStageTheFractionFollowsTheEaseAndNeverPasses97Percent() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan()), at: 0)
        p.apply(.stageStarted(.asr), at: 0)   // the two short stages before it are earned by its start
        let before = 3 / Self.total
        let weight = 20 / Self.total
        var last = -1.0
        for i in 0...400 {
            let t = Double(i) * 0.25   // up to 100 s, far past the 20 s estimate
            let f = p.shownFraction(at: t)
            #expect(f >= last, "never backwards at \(t) s")
            #expect(f <= before + 0.97 * weight + 1e-9, "never past 0.97 of the stage")
            last = f
        }
        #expect(abs(p.shownFraction(at: 10) - (before + 0.5 * weight)) < 1e-9, "linear to 0.85")
        #expect(abs(SetupProgress.eased(1) - 0.8811) < 0.001, "about 0.88 at the estimate")
        #expect(SetupProgress.eased(10) < 0.97)
        #expect(SetupProgress.eased(-1) == 0)
    }

    @Test func overallStaysAtOrBelow99PercentUntilReady() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan()), at: 0)
        let end = Self.run(&p, [(.diarizer, 1.5), (.nemotron, 1.5), (.asr, 20), (.warmup, 0.25)], from: 0)
        #expect(p.shownFraction(at: end) == 0.99, "every stage earned: capped until ModelManager sees ready")
        #expect(p.snapshot(at: end + 100).fraction <= 0.99)
    }

    @Test func aFinishedStageJumpsToItsFullWeightAndTheNextStartsThere() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan()), at: 0)
        _ = Self.run(&p, [(.diarizer, 1.5), (.nemotron, 1.5)], from: 0)
        p.apply(.stageStarted(.asr), at: 3)
        let before = p.shownFraction(at: 8)
        p.apply(.stageFinished(.asr), at: 8)   // faster than expected
        let after = p.shownFraction(at: 8)
        #expect(after > before)
        #expect(abs(after - 23 / Self.total) < 1e-9)
        p.apply(.stageStarted(.warmup), at: 8)
        #expect(abs(p.shownFraction(at: 8) - 23 / Self.total) < 1e-9, "the next stage starts from there")
    }

    /// Two pauses, then ready: the floor holds, a Parakeet restarted cold holds at the floor until it catches up,
    /// and a warm rerun of an earned Parakeet adds nothing. Sampled every 0.1 s, the value never goes down.
    @Test func pauseAndResumeNeverGoBackwards() {
        var p = SetupProgress()
        var samples: [Double] = []
        func sample(_ from: Double, _ to: Double) {
            var t = from
            while t <= to { samples.append(p.shownFraction(at: t)); t += 0.1 }
        }
        p.apply(.planned(Self.coldPlan()), at: 0)
        p.apply(.stageStarted(.diarizer), at: 0); sample(0, 1.5); p.apply(.stageFinished(.diarizer), at: 1.5)
        p.apply(.stageStarted(.nemotron), at: 1.5); sample(1.5, 3); p.apply(.stageFinished(.nemotron), at: 3)
        p.apply(.stageStarted(.asr), at: 3); sample(3, 15)
        // Parakeet throws in the background at 15 s: a pause, before it finished.
        let firstFloor = p.shownFraction(at: 15)
        p.paused(at: 15)
        #expect(p.isPaused)
        #expect(p.shownFraction(at: 15) == firstFloor, "the floor is the value shown at the pause")
        #expect(p.snapshot(at: 20).phase == .paused)
        #expect(p.snapshot(at: 20).timeLeftText == nil, "no time while paused")
        #expect(p.snapshot(at: 20).stepLine == "Paused")
        sample(15, 60)
        // Back at 60 s: the diarizer and Nemotron are kept, Parakeet starts cold again.
        let rerun = PreparePlan(steps: [PreparePlan.Step(stage: .diarizer, expectedSeconds: 0, isDone: true),
                                        PreparePlan.Step(stage: .nemotron, expectedSeconds: 0, isDone: true),
                                        PreparePlan.Step(stage: .asr, expectedSeconds: 20),
                                        PreparePlan.Step(stage: .warmup, expectedSeconds: 0.25)],
                                timesFromThisDevice: true)
        p.apply(.planned(rerun), at: 60)
        #expect(p.snapshot(at: 60).phase == .resumed)
        #expect(p.snapshot(at: 60).step == .transcription, "earned steps stay earned: the step does not go back")
        p.apply(.stageStarted(.asr), at: 60)
        #expect(p.shownFraction(at: 62) == firstFloor, "a cold restart holds at the floor")
        sample(60, 80)
        #expect(p.shownFraction(at: 76) > firstFloor, "then catches up")
        p.apply(.stageFinished(.asr), at: 80)
        // The warm-up is refused in the background at 80 s: a second pause, Parakeet earned.
        let secondFloor = p.shownFraction(at: 80)
        p.paused(at: 80)
        sample(80, 120)
        let warm = PreparePlan(steps: [PreparePlan.Step(stage: .diarizer, expectedSeconds: 0, isDone: true),
                                       PreparePlan.Step(stage: .nemotron, expectedSeconds: 0, isDone: true),
                                       PreparePlan.Step(stage: .asr, expectedSeconds: 1, isWarm: true),
                                       PreparePlan.Step(stage: .warmup, expectedSeconds: 0.25)],
                               timesFromThisDevice: true)
        p.apply(.planned(warm), at: 120)
        p.apply(.stageStarted(.asr), at: 120); sample(120, 121); p.apply(.stageFinished(.asr), at: 121)
        #expect(p.shownFraction(at: 121) == secondFloor, "a warm rerun of an earned stage adds nothing")
        p.apply(.stageStarted(.warmup), at: 121); sample(121, 121.25); p.apply(.stageFinished(.warmup), at: 121.25)
        sample(121.25, 122)
        #expect(p.shownFraction(at: 122) == 0.99)
        for (a, b) in zip(samples, samples.dropFirst()) { #expect(b >= a) }
    }

    @Test func suspendedTimeDoesNotCount() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan()), at: 0)
        p.apply(.stageStarted(.asr), at: 0)
        let atExpiry = p.shownFraction(at: 5)
        p.suspended(at: 5)
        #expect(p.shownFraction(at: 100) == atExpiry, "frozen while suspended")
        p.unsuspended(at: 100)
        #expect(abs(p.shownFraction(at: 100) - atExpiry) < 1e-9, "carries on from the expiry, not 95 s further")
        #expect(abs(p.shownFraction(at: 105) - p.shownFraction(at: 100) - 5 / Self.total) < 1e-9)
        p.unsuspended(at: 120)   // a second return without a new expiry moves nothing
        #expect(abs(p.shownFraction(at: 105) - (3 + 5 + 5) / Self.total) < 1e-9, "the short stages, then 10 s")
    }

    @Test func timeLeftWording() {
        #expect(SetupProgress.timeLeftText(150) == "About 3 minutes left")
        #expect(SetupProgress.timeLeftText(101) == "About 2 minutes left")
        #expect(SetupProgress.timeLeftText(70) == "About a minute left")
        #expect(SetupProgress.timeLeftText(25) == "Less than a minute left")
        #expect(SetupProgress.timeLeftText(5) == "Almost done")
        #expect(SetupProgress.timeLeftText(0) == "Almost done")
    }

    @Test func timeLeftCountsTheRunningStageAndEveryLaterOne() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan()), at: 0)
        p.apply(.stageStarted(.diarizer), at: 0)
        // 23.25 s at the start.
        #expect(p.snapshot(at: 0).timeLeftText == "Less than a minute left")
        #expect(abs((p.timeLeft(at: 1) ?? 0) - (Self.total - 1)) < 1e-9)
        p.apply(.stageFinished(.diarizer), at: 1.5)
        p.apply(.stageStarted(.nemotron), at: 1.5); p.apply(.stageFinished(.nemotron), at: 3)
        p.apply(.stageStarted(.asr), at: 3)
        #expect(abs((p.timeLeft(at: 3) ?? 0) - 20.25) < 1e-9, "Parakeet and the warm-up")
        #expect(p.snapshot(at: 3).timeLeftText == "Less than a minute left")
        #expect(p.snapshot(at: 15).timeLeftText == "Almost done")              // 8.25 s
        // Over 1.25 times its estimate: the estimate is wrong, so no time at all.
        #expect(p.snapshot(at: 3 + 20 * 1.25 - 0.1).timeLeftText == "Almost done")
        #expect(p.snapshot(at: 3 + 20 * 1.25 + 0.1).timeLeftText == nil)
    }

    @Test func noTimeLeftFromBuiltInNumbers() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan(fromDevice: false)), at: 0)
        p.apply(.stageStarted(.asr), at: 0)
        #expect(p.snapshot(at: 1).timeLeftText == nil)
        #expect(p.shownFraction(at: 11) > 0, "the bar still moves")
    }

    /// The steps in run order: voice recognition, speaker separation, then transcription (Parakeet and its warm-up).
    /// Only the title shows, never a count: the short steps are over before the card appears.
    @Test func stepLabels() {
        var p = SetupProgress()
        #expect(p.snapshot(at: 0).stepLine == "Setting up voice recognition", "no plan yet: the first step")
        p.apply(.planned(Self.coldPlan()), at: 0)
        p.apply(.stageStarted(.diarizer), at: 0)
        #expect(p.snapshot(at: 1).stepLine == "Setting up voice recognition")
        p.apply(.stageFinished(.diarizer), at: 1.5)
        p.apply(.stageStarted(.nemotron), at: 1.5)
        #expect(p.snapshot(at: 2).stepLine == "Setting up speaker separation")
        p.apply(.stageFinished(.nemotron), at: 3)
        p.apply(.stageStarted(.asr), at: 3)
        #expect(p.snapshot(at: 3).stepLine == "Setting up transcription")
        p.apply(.stageFinished(.asr), at: 23)
        p.apply(.stageStarted(.warmup), at: 23)
        #expect(p.snapshot(at: 23).stepLine == "Setting up transcription")
        #expect(!p.snapshot(at: 23).stepLine.contains("Step"), "no step count")

        var two = SetupProgress()
        two.apply(.planned(Self.coldPlan(nemotron: false)), at: 0)
        two.apply(.stageStarted(.diarizer), at: 0)
        #expect(two.snapshot(at: 0).stepLine == "Setting up voice recognition")
        two.apply(.stageFinished(.diarizer), at: 0.5)
        two.apply(.stageStarted(.asr), at: 0.5)
        #expect(two.snapshot(at: 1).stepLine == "Setting up transcription")
    }

    /// Nemotron fails to load in front (the community-1 fallback): it sends a start and no finish, and the engine
    /// carries on to Parakeet. The next stage's start earns it, so the step and the bar move on; a later plan that
    /// leaves Nemotron out (disabled for the process) never waits for it either.
    @Test func aStageThatFailedAndWasSkippedIsEarnedWhenTheNextStarts() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan()), at: 0)
        _ = Self.run(&p, [(.diarizer, 1.5)], from: 0)
        p.apply(.stageStarted(.nemotron), at: 1.5)   // throws at 2.5 s: no stageFinished
        p.apply(.stageStarted(.asr), at: 2.5)
        #expect(p.earned == [.diarizer, .nemotron])
        #expect(p.snapshot(at: 3).step == .transcription)
        #expect(p.snapshot(at: 3).stepLine == "Setting up transcription")
        #expect(abs(p.shownFraction(at: 2.5) - 3 / Self.total) < 1e-9, "Nemotron's weight is earned at once")
        p.apply(.stageFinished(.asr), at: 22.5)
        p.apply(.stageStarted(.warmup), at: 22.5)
        p.apply(.stageFinished(.warmup), at: 22.75)
        #expect(p.shownFraction(at: 22.75) == 0.99, "every stage earned: the bar reaches the top, not 94%")

        // A pause before Parakeet finished; the next plan (Nemotron disabled) leaves it out.
        var q = SetupProgress()
        q.apply(.planned(Self.coldPlan()), at: 0)
        _ = Self.run(&q, [(.diarizer, 1.5)], from: 0)
        q.apply(.stageStarted(.nemotron), at: 1.5)
        q.paused(at: 2)
        q.apply(.planned(PreparePlan(steps: [PreparePlan.Step(stage: .diarizer, expectedSeconds: 0, isDone: true),
                                             PreparePlan.Step(stage: .asr, expectedSeconds: 20),
                                             PreparePlan.Step(stage: .warmup, expectedSeconds: 0.25)],
                                     timesFromThisDevice: false)), at: 10)
        #expect(q.earned.contains(.nemotron), "a stage the plan leaves out never runs again in this process")
        #expect(q.snapshot(at: 10).step == .transcription)
    }

    /// A Parakeet that never finished before a pause is shown again on its own step after it.
    @Test func anUnfinishedTranscriptionStepIsShownAgainAfterAPause() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan()), at: 0)
        _ = Self.run(&p, [(.diarizer, 1.5), (.nemotron, 1.5)], from: 0)
        p.apply(.stageStarted(.asr), at: 3)
        p.paused(at: 5)   // asr never finished
        p.apply(.planned(Self.coldPlan()), at: 10)
        p.apply(.stageStarted(.asr), at: 10)
        #expect(p.snapshot(at: 11).step == .transcription)
        #expect(p.snapshot(at: 11).phase == .resumed)
    }

    @Test func laterPlansOnlyAddStagesAndKeepTheFirstWeights() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan(nemotron: false)), at: 0)
        p.apply(.planned(Self.coldPlan()), at: 1)
        #expect(p.weights[.asr] == 20 && p.weights[.nemotron] == 1.5)
        p.apply(.planned(PreparePlan(steps: [PreparePlan.Step(stage: .asr, expectedSeconds: 1)],
                                     timesFromThisDevice: true)), at: 2)
        #expect(p.weights[.asr] == 20, "a warm rerun keeps the cold weight")
        #expect(p.order == [.diarizer, .asr, .warmup, .nemotron], "a stage the first plan lacked goes last")

        var full = SetupProgress()
        full.apply(.planned(Self.coldPlan()), at: 0)
        #expect(full.order == [.diarizer, .nemotron, .asr, .warmup])
    }

    /// "Carrying on where it left off." only after setup really stopped: a pause, or iOS suspending the app. A
    /// return with nothing interrupted changes nothing.
    @Test func resumedOnlyAfterARealStop() {
        var p = SetupProgress()
        p.unsuspended(at: 0)
        #expect(p.snapshot(at: 0).phase == .working, "no plan, no suspension: nothing")
        p.apply(.planned(Self.coldPlan()), at: 0)
        p.apply(.stageStarted(.asr), at: 0)
        p.unsuspended(at: 5)
        #expect(p.snapshot(at: 5).phase == .working, "back without a suspension: nothing stopped")
        p.suspended(at: 6)
        p.unsuspended(at: 40)
        #expect(p.snapshot(at: 40).phase == .resumed, "iOS suspended the app meanwhile")
    }

    /// Whether this is the once-after-an-update setup comes from the plan, not from how long it takes.
    @Test func aWarmPlanIsNotTheColdSetup() {
        var warm = SetupProgress()
        let warmPlan = PreparePlan(steps: PrepareStage.allCases.map {
            PreparePlan.Step(stage: $0, expectedSeconds: 1, isWarm: true)
        }, timesFromThisDevice: true)
        warm.apply(.planned(warmPlan), at: 0)
        #expect(!warm.isColdSetup && !warm.snapshot(at: 0).isColdSetup)
        // A done step is not cold either.
        warm.apply(.planned(PreparePlan(steps: [PreparePlan.Step(stage: .diarizer, expectedSeconds: 0, isDone: true)],
                                        timesFromThisDevice: true)), at: 1)
        #expect(!warm.isColdSetup)

        var cold = SetupProgress()
        cold.apply(.planned(Self.coldPlan()), at: 0)
        #expect(cold.isColdSetup)
        // A later all-warm rerun (after a pause) is still the same cold setup.
        cold.apply(.planned(warmPlan), at: 10)
        #expect(cold.snapshot(at: 10).isColdSetup)
    }

    /// A first install has no times measured here: the hedged line instead of a time left, never while paused.
    @Test func theTypicalTimeShowsOnlyWithoutMeasuredTimes() {
        var first = SetupProgress()
        first.apply(.planned(Self.coldPlan(fromDevice: false)), at: 0)
        first.apply(.stageStarted(.asr), at: 0)
        #expect(first.snapshot(at: 5).showsTypicalTime && first.snapshot(at: 5).timeLeftText == nil)
        first.paused(at: 6)
        #expect(!first.snapshot(at: 7).showsTypicalTime)

        var measured = SetupProgress()
        measured.apply(.planned(Self.coldPlan()), at: 0)
        measured.apply(.stageStarted(.asr), at: 0)
        #expect(!measured.snapshot(at: 5).showsTypicalTime && measured.snapshot(at: 5).timeLeftText != nil)
        #expect(!SetupProgress().snapshot(at: 0).showsTypicalTime, "nothing before a plan")
    }

    /// Back from the background on a first install, with only warm work left (Parakeet's compile kept, the warm-up
    /// still unmeasured): no "This can take a little while." under a nearly full bar beside "Carrying on…".
    @Test func theTypicalTimeHidesWhenOnlyAFewWarmSecondsAreLeft() {
        var p = SetupProgress()
        p.apply(.planned(Self.coldPlan(fromDevice: false)), at: 0)
        _ = Self.run(&p, [(.diarizer, 1.5), (.nemotron, 1.5)], from: 0)
        p.apply(.stageStarted(.asr), at: 3)
        #expect(p.snapshot(at: 4).showsTypicalTime, "Parakeet's 20 s compile still to come")
        p.apply(.stageFinished(.asr), at: 30)
        p.paused(at: 30)   // the warm-up's start was refused in the background
        let back = PreparePlan(steps: [PreparePlan.Step(stage: .diarizer, expectedSeconds: 0, isDone: true),
                                       PreparePlan.Step(stage: .nemotron, expectedSeconds: 0, isDone: true),
                                       PreparePlan.Step(stage: .asr, expectedSeconds: 1, isWarm: true),
                                       PreparePlan.Step(stage: .warmup, expectedSeconds: 0.25)],
                               timesFromThisDevice: false)
        p.apply(.planned(back), at: 60)
        p.apply(.stageStarted(.asr), at: 60)
        let s = p.snapshot(at: 60.5)
        #expect(s.phase == .resumed && s.showsResumed)
        #expect(!s.showsTypicalTime && s.timeLeftText == nil)

        // Without Background Inference Parakeet starts cold again on return: the hedge is still true.
        var cold = SetupProgress()
        cold.apply(.planned(Self.coldPlan(fromDevice: false)), at: 0)
        _ = Self.run(&cold, [(.diarizer, 1.5), (.nemotron, 1.5)], from: 0)
        cold.apply(.stageStarted(.asr), at: 3)
        cold.paused(at: 8)
        cold.apply(.planned(PreparePlan(steps: [PreparePlan.Step(stage: .diarizer, expectedSeconds: 0, isDone: true),
                                                PreparePlan.Step(stage: .nemotron, expectedSeconds: 0, isDone: true),
                                                PreparePlan.Step(stage: .asr, expectedSeconds: 20),
                                                PreparePlan.Step(stage: .warmup, expectedSeconds: 0.25)],
                                        timesFromThisDevice: false)), at: 40)
        cold.apply(.stageStarted(.asr), at: 40)
        #expect(cold.snapshot(at: 41).showsTypicalTime)
    }

    /// In a recording's panel the setup line is labelled as setup, never read as the recording's own steps.
    @Test func theCompactLineIsLabelledAsSetup() {
        var p = SetupProgress()
        #expect(p.snapshot(at: 0).compactLine == "Setup in progress")
        p.apply(.planned(Self.coldPlan()), at: 0)
        _ = Self.run(&p, [(.diarizer, 1.5), (.nemotron, 1.5)], from: 0)
        #expect(p.snapshot(at: 4).compactLine == "Setup in progress")
        p.paused(at: 10)
        #expect(p.snapshot(at: 11).compactLine == "Setup paused")
    }
}
