import Foundation
import TranscribeCore

/// The steps the user sees while the speech models get ready, in run order (`PrepareStage`): the short ones first,
/// Parakeet and its warm-up last, as one step. Only the running step's title is shown, never "Step n of N": the two
/// short steps take about 2 s and are over before the card appears (1.5 s), so a count would open on "Step 3 of 3"
/// at about a tenth of the bar.
public enum SetupStep: Int, Sendable, CaseIterable, Comparable {
    case voiceRecognition = 1
    case speakerSeparation
    case transcription

    public init(_ stage: PrepareStage) {
        switch stage {
        case .asr, .warmup: self = .transcription
        // community-1 is the voice embedder (and the fallback separator).
        case .diarizer: self = .voiceRecognition
        case .nemotron: self = .speakerSeparation
        }
    }

    public var title: String {
        switch self {
        case .transcription: "Setting up transcription"
        case .voiceRecognition: "Setting up voice recognition"
        case .speakerSeparation: "Setting up speaker separation"
        }
    }

    public static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }
}

/// What the setup views show at one moment (`ModelManager.setupSnapshot(at:)`).
public struct SetupSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case working
        /// The prepare paused while the app was in the background; it carries on when the app is opened.
        case paused
        /// Setup really stopped while the app was away (it paused, or iOS suspended the app) and now carries on
        /// where it left off. A short trip away that interrupted nothing does not count.
        case resumed
        /// Ready: the bar is full and the card is about to go.
        case finishing
    }

    /// 0...1. Never goes backwards while setup runs; exactly 1 once ready.
    public var fraction: Double
    public var phase: Phase
    public var step: SetupStep
    /// "About 2 minutes left" … "Almost done", only from estimates measured on this device.
    public var timeLeftText: String?
    /// Some step of this setup had to be prepared from scratch (the once-after-installing-or-updating setup), not
    /// only reloaded from what this device kept. A warm launch that is merely slow says nothing about installing.
    public var isColdSetup: Bool
    /// No times measured on this device yet (a first install) and a good share of the work still to come
    /// (`SetupProgress.typicalTimeMinimumShare`): the views show the hedged typical-time line (`DeviceCopy.setupTypicalTime`) instead of a
    /// time left. Never while paused, and not for the few warm seconds left after a return from the background.
    public var showsTypicalTime: Bool
    /// "Carrying on where it left off." shows: the phase is `.resumed` (it stays set once the snapshot turns to
    /// `.finishing`, whose views show no working lines anyway).
    public var showsResumed: Bool

    public init(fraction: Double, phase: Phase, step: SetupStep, timeLeftText: String?, isColdSetup: Bool = true,
                showsTypicalTime: Bool = false, showsResumed: Bool? = nil) {
        self.fraction = fraction; self.phase = phase; self.step = step
        self.timeLeftText = timeLeftText; self.isColdSetup = isColdSetup
        self.showsTypicalTime = showsTypicalTime; self.showsResumed = showsResumed ?? (phase == .resumed)
    }

    public var percent: Int { Int((fraction * 100).rounded(.down)) }
    /// The progress bar's accessibility value, "34%".
    public var percentText: String { "\(percent)%" }

    /// "Setting up transcription", or "Paused".
    public var stepLine: String { phase == .paused ? "Paused" : step.title }

    /// Inside a recording's processing panel, labelled as setup so it is never read as the recording's own steps
    /// (its rows Transcribing, Separating speakers…): "Setup in progress", or "Setup paused".
    public var compactLine: String { phase == .paused ? "Setup paused" : "Setup in progress" }
}

/// Setup progress for the whole process, built from the engine's `PrepareEvent`s (§ setup progress). Pure; time is
/// a monotonic number of seconds (`ProcessInfo.systemUptime` in the app) passed in by the caller.
///
/// - Weights: each stage's expected cold seconds from the first plan in the process; later plans only add stages
///   the first did not have. A stage is earned once it finishes in any prepare of the process, once a later stage
///   of the plan starts (stages run strictly in plan order, so an earlier one finished, was done or failed and was
///   skipped: a Nemotron that fails to load in front falls back to community-1 and setup carries on), or once a
///   plan leaves it out (Nemotron disabled for the process).
/// - Within the running stage, f = elapsed / expected, eased so that it never passes 0.97 of the stage.
/// - The value shown never goes backwards: a pause sets a floor at the value shown then, and a stage restarted after
///   a pause holds at the floor until it catches up. Time spent suspended (from the short task's expiry to the
///   return to the front) does not count.
/// - The time left is shown only from estimates measured on this device, never while paused, and never once the
///   running stage has taken more than 1.25 times its estimate.
public struct SetupProgress: Equatable, Sendable {
    struct Running: Equatable, Sendable {
        var stage: PrepareStage
        var startedAt: TimeInterval
        var expected: Double
    }

    /// The session's stages in run order, with their weights.
    private(set) var order: [PrepareStage] = []
    private(set) var weights: [PrepareStage: Double] = [:]
    private(set) var earned: Set<PrepareStage> = []
    /// The latest plan (its estimates are warm for a rerun).
    private(set) var latestPlan: PreparePlan?
    private(set) var current: Running?
    /// The value shown when the last pause began; nothing below it is ever shown again.
    private(set) var floor: Double = 0
    private(set) var pausedAt: TimeInterval?
    private(set) var resumed = false
    /// When the short background task expired, while the app has not come back yet.
    private(set) var suspendedSince: TimeInterval?
    /// Some plan of this process had a step that was neither done nor warm.
    private(set) var sawColdStep = false

    public init() {}

    /// A plan has arrived (any prepare of this process).
    public var hasPlan: Bool { latestPlan != nil }
    public var isPaused: Bool { pausedAt != nil }
    /// Some step of this setup is (or was) prepared from scratch, not only reloaded (`SetupSnapshot.isColdSetup`).
    public var isColdSetup: Bool { sawColdStep }

    // MARK: Changes

    public mutating func apply(_ event: PrepareEvent, at now: TimeInterval) {
        switch event {
        case .planned(let plan):
            for step in plan.steps where weights[step.stage] == nil {
                order.append(step.stage)
                weights[step.stage] = Swift.max(0.05, step.expectedSeconds)
            }
            // A step done before this plan was finished earlier in the process.
            for step in plan.steps where step.isDone { earned.insert(step.stage) }
            // A stage this plan leaves out never runs again in this process (Nemotron disabled after a failure).
            for stage in order where plan.step(stage) == nil { earned.insert(stage) }
            if plan.steps.contains(where: { !$0.isDone && !$0.isWarm }) { sawColdStep = true }
            if pausedAt != nil { resumed = true }
            pausedAt = nil
            suspendedSince = nil
            latestPlan = plan
            current = nil
        case .stageStarted(let stage):
            // Stages run in plan order: every one before this is finished, done, or failed and skipped.
            let runOrder = latestPlan?.steps.map(\.stage) ?? order
            if let index = runOrder.firstIndex(of: stage) { earned.formUnion(runOrder[..<index]) }
            let expected = latestPlan?.step(stage)?.expectedSeconds ?? weights[stage] ?? 1
            current = Running(stage: stage, startedAt: now, expected: Swift.max(0.05, expected))
        case .stageFinished(let stage):
            earned.insert(stage)
        }
    }

    /// The prepare paused (the app is in the background). The bar holds at the value shown now.
    public mutating func paused(at now: TimeInterval) {
        floor = shownFraction(at: now)
        pausedAt = now
        current = nil
    }

    /// The short background task expired: the app is about to be suspended, and this stage's clock stops.
    public mutating func suspended(at now: TimeInterval) {
        if suspendedSince == nil { suspendedSince = now }
    }

    /// The app is in front again: the running stage's clock skips the suspended gap, and setup reads as carrying on
    /// (iOS really stopped it meanwhile).
    public mutating func unsuspended(at now: TimeInterval) {
        guard let since = suspendedSince else { return }
        suspendedSince = nil
        if hasPlan { resumed = true }
        if var running = current {
            running.startedAt += Swift.max(0, now - since)
            current = running
        }
    }

    // MARK: Reads

    /// The fraction while working (≤ 0.99), never below the floor.
    public func shownFraction(at now: TimeInterval) -> Double {
        Swift.min(0.99, Swift.max(floor, overall(at: now)))
    }

    /// The snapshot while setup runs (the caller shows `finishing` itself once ready).
    public func snapshot(at now: TimeInterval) -> SetupSnapshot {
        let phase: SetupSnapshot.Phase = isPaused ? .paused : (resumed ? .resumed : .working)
        let measured = latestPlan?.timesFromThisDevice ?? true
        return SetupSnapshot(fraction: shownFraction(at: now), phase: phase, step: displayedStep,
                             timeLeftText: isPaused ? nil : timeLeft(at: now).map(Self.timeLeftText),
                             isColdSetup: sawColdStep || !hasPlan,
                             showsTypicalTime: hasPlan && !measured && !isPaused
                                && plannedSecondsLeft >= Self.typicalTimeMinimumShare * totalWeight)
    }

    /// The hedged typical-time line needs at least this share of the setup's expected seconds still to come: after
    /// a return from the background only a few warm seconds may be left (about 1 s of the 23 s on an iPhone 15), and
    /// "This can take a little while." would contradict the nearly full bar. A share, not seconds, so it holds for
    /// any device's numbers (and the fake engine's tenth-speed ones).
    public static let typicalTimeMinimumShare = 0.25

    /// Eased progress through one stage: linear to 0.85, then easing towards (never past) 0.97.
    public static func eased(_ f: Double) -> Double {
        let f = Swift.max(0, f)
        guard f > 0.85 else { return f }
        return 0.85 + 0.12 * (1 - exp(-(f - 0.85) / 0.5))
    }

    /// "About 3 minutes left", "About a minute left", "Less than a minute left", "Almost done".
    public static func timeLeftText(_ seconds: Double) -> String {
        if seconds > 100 { return "About \(Swift.max(2, Int((seconds / 60).rounded()))) minutes left" }
        if seconds >= 40 { return "About a minute left" }
        if seconds >= 10 { return "Less than a minute left" }
        return "Almost done"
    }

    // MARK: Building blocks

    /// The first step not yet finished (so a warm rerun of an earned stage never moves the step back), else the
    /// last one.
    var displayedStep: SetupStep {
        if let stage = order.first(where: { !earned.contains($0) }) { return SetupStep(stage) }
        if let current { return SetupStep(current.stage) }
        return order.last.map(SetupStep.init) ?? .voiceRecognition   // no plan yet: the step every setup starts with
    }

    /// The latest plan's expected seconds for every stage not yet finished, the running one in full (so the value
    /// changes only between stages, never mid-stage).
    var plannedSecondsLeft: Double {
        guard let plan = latestPlan else { return 0 }
        return plan.steps.filter { !$0.isDone && !earned.contains($0.stage) }.reduce(0) { $0 + $1.expectedSeconds }
    }

    /// Seconds the running stage has run, not counting a suspension still going on.
    func elapsed(_ running: Running, at now: TimeInterval) -> Double {
        let end = suspendedSince.map { Swift.min($0, now) } ?? now
        return Swift.max(0, end - running.startedAt)
    }

    /// The sum of the session's stage weights.
    var totalWeight: Double { order.reduce(0) { $0 + (weights[$1] ?? 0) } }

    /// Unclamped progress from the earned stages and the running one.
    func overall(at now: TimeInterval) -> Double {
        let total = totalWeight
        guard total > 0 else { return 0 }
        var done = earned.reduce(0) { $0 + (weights[$1] ?? 0) }
        if let running = current, !earned.contains(running.stage) {
            let f = elapsed(running, at: now) / running.expected
            done += (weights[running.stage] ?? 0) * Self.eased(f)
        }
        return Swift.min(1, done / total)
    }

    /// Seconds left, or nil when it must not be shown (built-in estimates, or the running stage is over 1.25 times
    /// its estimate).
    func timeLeft(at now: TimeInterval) -> Double? {
        guard let plan = latestPlan, plan.timesFromThisDevice else { return nil }
        var remaining = 0.0
        var later = plan.steps.filter { !$0.isDone && !earned.contains($0.stage) }
        if let running = current, !earned.contains(running.stage) {
            let elapsed = elapsed(running, at: now)
            guard elapsed <= 1.25 * running.expected else { return nil }
            remaining += Swift.max(0, running.expected - elapsed)
            let index = plan.steps.firstIndex { $0.stage == running.stage } ?? -1
            later = plan.steps.enumerated()
                .filter { $0.offset > index && !$0.element.isDone && !earned.contains($0.element.stage) }
                .map(\.element)
        }
        return remaining + later.reduce(0) { $0 + $1.expectedSeconds }
    }
}
