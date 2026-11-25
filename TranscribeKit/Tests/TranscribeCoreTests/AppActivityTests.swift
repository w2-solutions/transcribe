import Foundation
import Synchronization
import Testing
import TranscribeCore

/// A clock the tests move by hand.
final class StepClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_000))
    func now() -> Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@Suite("AppActivity")
struct AppActivityTests {
    @Test func enterBackgroundStartsANewPeriodOnce() {
        let activity = AppActivity()
        #expect(!activity.inBackground && activity.epoch == 0)
        activity.enterBackground()
        #expect(activity.inBackground && activity.epoch == 1)
        activity.enterBackground()   // repeated (a seed at launch, then the phase change): no new period
        #expect(activity.epoch == 1)
        activity.becomeActive()
        activity.becomeActive()
        #expect(!activity.inBackground && activity.epoch == 1)
        activity.enterBackground()
        #expect(activity.epoch == 2)
        #expect(activity.transitions().map(\.kind) == [.background, .active, .background])
    }

    @Test func withoutTheEntitlementNoStageStartsInTheBackground() {
        let activity = AppActivity(backgroundInference: false)
        #expect(activity.mayStartStage)
        let grace = UUID()
        activity.armGrace(grace)
        activity.enterBackground()
        #expect(activity.hasGrace)
        #expect(!activity.mayStartStage, "a held short task does not make the Neural Engine usable")
        #expect(activity.stageWindow() == nil)
        activity.becomeActive()
        #expect(activity.stageWindow() == AppActivity.Window(epoch: 1, inBackground: false))
    }

    /// A CPU-only stage (Nemotron 3) needs no entitlement in the background, only the short task.
    @Test func aCPUStageStartsInTheBackgroundWhileTheShortTaskIsHeldWithoutTheEntitlement() {
        let activity = AppActivity(backgroundInference: false)
        activity.enterBackground()
        #expect(!activity.mayStartStage(usesNeuralEngine: false), "no short task held")
        let grace = UUID()
        activity.armGrace(grace)
        #expect(activity.mayStartStage(usesNeuralEngine: false))
        #expect(activity.stageWindow(usesNeuralEngine: false) == AppActivity.Window(epoch: 1, inBackground: true))
        #expect(activity.stageWindow(usesNeuralEngine: true) == nil, "a Neural Engine stage still waits")
        activity.graceExpired(grace)
        #expect(!activity.mayStartStage(usesNeuralEngine: false), "expired: the app is about to be suspended")
        #expect(!PrepareStage.nemotron.usesNeuralEngine)
        #expect(PrepareStage.allCases.filter(\.usesNeuralEngine) == [.diarizer, .asr, .warmup])
    }

    @Test func withTheEntitlementAStageStartsInTheBackgroundOnlyWhileTheShortTaskIsHeld() {
        let activity = AppActivity(backgroundInference: true)
        activity.enterBackground()
        #expect(!activity.mayStartStage, "no short task held")
        let first = UUID()
        activity.armGrace(first)
        #expect(activity.stageWindow() == AppActivity.Window(epoch: 1, inBackground: true))
        activity.graceExpired(first)
        #expect(!activity.hasGrace && !activity.mayStartStage, "expired: the app is about to be suspended")

        // Back in front, a new short task for the next trip: it counts in the next period, not the old one.
        activity.becomeActive()
        let second = UUID()
        activity.armGrace(second)
        activity.graceExpired(first)   // a stale expiry changes nothing
        #expect(activity.hasGrace)
        activity.enterBackground()
        #expect(activity.mayStartStage)
        activity.graceEnded(second)
        #expect(!activity.mayStartStage)
        #expect(activity.transitions().map(\.kind) == [.background, .expired, .active, .background])
    }

    @Test func ignoringTheStartRuleIsForMeasurementOnly() throws {
        let activity = AppActivity(backgroundInference: false, ignoresStartRule: true)
        activity.enterBackground()
        #expect(activity.mayStartStage)
        let window = try #require(activity.stageWindow())
        #expect(!activity.isForegroundClean(window), "the keep rule still refuses it")
    }

    @Test func foregroundCleanMeansInFrontAtBothEndsWithNoTripBetween() throws {
        let activity = AppActivity(backgroundInference: true)
        let window = try #require(activity.stageWindow())
        #expect(activity.isForegroundClean(window))
        activity.enterBackground()
        #expect(!activity.isForegroundClean(window))
        activity.becomeActive()
        #expect(!activity.isForegroundClean(window), "back in front, but it went away in between")
        let next = try #require(activity.stageWindow())
        #expect(activity.isForegroundClean(next))
    }

    @Test func keepsTheLast20TransitionsWithTheirTimes() {
        let clock = StepClock()
        let activity = AppActivity(backgroundInference: true, now: { clock.now() })
        let start = clock.now()
        for _ in 0..<15 {
            activity.enterBackground()
            clock.advance(1)
            activity.becomeActive()
            clock.advance(1)
        }
        let all = activity.transitions()
        #expect(all.count == AppActivity.keptTransitions)
        #expect(all.first?.kind == .background && all.last?.kind == .active)
        #expect(all.last?.at == start.addingTimeInterval(29))
        #expect(activity.transitions(since: start.addingTimeInterval(25)).count == 5)
    }
}
