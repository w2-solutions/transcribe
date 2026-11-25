import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Records short background tasks (the prepare's) apart from job tasks.
final class ShortTaskSpy: BackgroundTaskBridge, Sendable {
    struct Short {
        let name: String
        let token: BackgroundToken
        let onExpire: @Sendable () -> Void
    }
    struct State {
        var short: [Short] = []
        var ended: [(token: BackgroundToken, success: Bool)] = []
        var jobBegins = 0
        var grants = true
    }
    let state = Mutex(State())
    /// Runs inside the first `beginShortTask`, before it returns (to move the app while the begin is awaited).
    let duringFirstBegin: (@Sendable () -> Void)?
    /// When set, every short-task begin after the first waits for it to open (a begin still pending).
    let laterBegins: OpenGate?
    /// Runs inside the first `end` of a short task, before it returns (to bring the app back while the prepare
    /// ends its short task).
    let duringFirstShortEnd = Mutex<(@Sendable () async -> Void)?>(nil)

    init(grants: Bool = true, laterBegins: OpenGate? = nil, duringFirstBegin: (@Sendable () -> Void)? = nil) {
        self.duringFirstBegin = duringFirstBegin
        self.laterBegins = laterBegins
        state.withLock { $0.grants = grants }
    }

    func begin(recordingID: UUID, title: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? {
        state.withLock { $0.jobBegins += 1 }
        return BackgroundToken()
    }
    func update(_ token: BackgroundToken, fraction: Double, subtitle: String) async {}
    func end(_ token: BackgroundToken, success: Bool) async {
        let firstShortEnd = state.withLock { s in
            s.short.contains { $0.token == token } && !s.ended.contains { e in s.short.contains { $0.token == e.token } }
        }
        if firstShortEnd, let hook = duringFirstShortEnd.withLock({ $0 }) { await hook() }
        state.withLock { $0.ended.append((token, success)) }
    }
    func beginShortTask(name: String, onExpire: @escaping @Sendable () -> Void) async -> BackgroundToken? {
        if state.withLock({ $0.short.isEmpty }) {
            duringFirstBegin?()
        } else if let laterBegins {
            await laterBegins.wait()
        }
        return state.withLock { s in
            guard s.grants else { return nil }
            let token = BackgroundToken()
            s.short.append(Short(name: name, token: token, onExpire: onExpire))
            return token
        }
    }

    /// The system ends the latest short task's time.
    func expireLatestShort() { state.withLock { $0.short.last?.onExpire }?() }
    var shortNames: [String] { state.withLock { $0.short.map(\.name) } }
    var jobBegins: Int { state.withLock { $0.jobBegins } }
    /// `end` results for short tasks, in order.
    var shortEnds: [Bool] {
        state.withLock { s in
            let tokens = Set(s.short.map(\.token))
            return s.ended.filter { tokens.contains($0.token) }.map(\.success)
        }
    }
    /// Every short task begun has been ended exactly once.
    var everyShortTaskEnded: Bool {
        state.withLock { s in
            let ended = s.ended.map(\.token)
            return s.short.allSatisfy { short in ended.filter { $0 == short.token }.count == 1 }
        }
    }
}

/// An engine whose prepares follow a script (one step per call: return, or throw as the real engine would), with
/// jobs run by a prepared fake engine. Its status mirrors `FluidSpeechEngine`: preparing while a prepare runs, ready
/// after one succeeds, installed after a pause (`EngineError.cancelled`), failed after a failure.
actor ScriptedPrepareEngine: SpeechEngine {
    typealias Step = @Sendable () async throws -> Void
    nonisolated let info = EngineInfo(kind: .fake, asrDisplayName: "Parakeet", asrModelID: "scripted", embeddingModel: .fake)
    let inner: FakeSpeechEngine
    private var steps: [Step]
    private var status: ModelStatus = .installed
    private(set) var prepareCalls = 0

    init(_ steps: [Step] = []) {
        self.steps = steps
        let config = LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"], environment: ["TRANSCRIBE_SPEED": "instant"])
        inner = FakeSpeechEngine(config: config, script: FakeScript.named(.newVoices))
    }

    func setSteps(_ steps: [Step]) { self.steps = steps }

    func modelStatus() async -> ModelStatus { status }
    func prepareModels() async throws {
        if status == .ready { return }
        prepareCalls += 1
        status = .preparing
        let step = steps.isEmpty ? nil : steps.removeFirst()
        do {
            try await step?()
            try await inner.prepareModels()
            status = .ready
        } catch EngineError.cancelled {
            status = .installed
            throw EngineError.cancelled
        } catch {
            status = .failed("\(error)")
            throw error
        }
    }
    func microphonePermission() async -> MicPermission { .granted }
    func requestMicrophonePermission() async -> Bool { true }
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording {
        try await inner.startRecording(request)
    }
    func transcribe(_ audio: URL, language: LanguageHint, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord] {
        try await inner.transcribe(audio, language: language, progress: progress)
    }
    func separateSpeakers(_ audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation {
        try await inner.separateSpeakers(audio, progress: progress)
    }
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector] {
        try await inner.embedVoice(audio, spans: spans)
    }
}

/// A gate that callers wait at until it opens; counts the callers that arrived.
final class OpenGate: Sendable {
    private struct State {
        var open = false
        var arrived = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                s.arrived += 1
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }
    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
    var arrived: Int { state.withLock { $0.arrived } }
}

/// A flag a step sets (steps run on the engine's actor).
final class StepFlag: Sendable {
    private let value = Mutex<[Bool]>([])
    func record(_ v: Bool) { value.withLock { $0.append(v) } }
    var all: [Bool] { value.withLock { $0 } }
}

@Suite("ModelManager in the background")
@MainActor
struct ModelManagerBackgroundTests {
    func manager(_ engine: ScriptedPrepareEngine, activity: AppActivity, spy: ShortTaskSpy,
                 counter: ModelManagerReadyCounter) -> ModelManager {
        ModelManager(engine: engine, background: spy, activity: activity, onReady: { counter.count += 1 })
    }

    @Test func prepareHoldsShortBackgroundTask() async {
        let activity = AppActivity(backgroundInference: true)
        let held = StepFlag()
        let engine = ScriptedPrepareEngine([{ held.record(activity.hasGrace) }])
        let spy = ShortTaskSpy()
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: spy, counter: counter)
        await m.prepareIfInstalled()
        #expect(m.status == .ready && counter.count == 1)
        #expect(spy.shortNames == ["Preparing speech models"])
        #expect(held.all == [true], "the grace is held while the engine prepares")
        #expect(spy.shortEnds == [true])
        #expect(!activity.hasGrace)
        #expect(spy.jobBegins == 0, "never a job's continued-processing task")

        // A failure and a pause end it with success false.
        let failing = ScriptedPrepareEngine([{ throw EngineError.failed("boom") }])
        let failSpy = ShortTaskSpy()
        let f = manager(failing, activity: AppActivity(), spy: failSpy, counter: counter)
        await f.prepareIfInstalled()
        #expect(f.status == .failed("boom"))
        #expect(failSpy.shortEnds == [false])
        let pausing = ScriptedPrepareEngine([{ throw EngineError.cancelled }])
        let pauseSpy = ShortTaskSpy()
        let p = manager(pausing, activity: AppActivity(), spy: pauseSpy, counter: counter)
        await p.prepareIfInstalled()
        #expect(p.status == .installed)
        #expect(pauseSpy.shortEnds == [false])
        #expect(pauseSpy.jobBegins == 0 && failSpy.jobBegins == 0)
    }

    @Test func pauseWhileBackgroundResumesOnForeground() async {
        let activity = AppActivity(backgroundInference: false)
        let engine = ScriptedPrepareEngine([{ activity.enterBackground(); throw EngineError.cancelled }])
        let spy = ShortTaskSpy()
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: spy, counter: counter)
        await m.prepareIfInstalled()
        #expect(m.status == .installed, "a pause is not a failure")
        #expect(m.failureText == nil && m.settingsValue == "Getting ready…")
        #expect(await engine.prepareCalls == 1)
        // Still in the background (a stray call): the engine reports installed, but nothing starts.
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 1)
        #expect(m.status == .installed)
        // Back in front: exactly one more run.
        activity.becomeActive()
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 2)
        #expect(m.status == .ready && counter.count == 1)
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 2 && counter.count == 1)
        #expect(spy.everyShortTaskEnded)
    }

    @Test func pauseArrivingAfterReturnRerunsAtOnce() async {
        let activity = AppActivity(backgroundInference: false)
        let engine = ScriptedPrepareEngine([{
            activity.enterBackground()
            activity.becomeActive()
            throw EngineError.cancelled
        }])
        let spy = ShortTaskSpy()
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: spy, counter: counter)
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 2, "came back mid-stage: prepared again at once")
        #expect(m.status == .ready && counter.count == 1)
        #expect(spy.shortNames.count == 2 && spy.shortEnds == [false, true])
    }

    /// Review finding: the epoch the pause rule compares against was read after the short task's begin was
    /// awaited, so a trip away that started during the begin was not seen as a change, and a pause that ended with
    /// the app back in front left "Getting ready…" with nothing running.
    @Test(arguments: [true, false])
    func aTripAwayDuringTheShortTaskBeginStillRerunsOnReturn(entitled: Bool) async {
        let activity = AppActivity(backgroundInference: entitled)
        let spy = ShortTaskSpy(duringFirstBegin: { activity.enterBackground() })
        let engine = ScriptedPrepareEngine([{
            activity.becomeActive()   // back in front mid-pass (onPhase(.active) found the prepare busy)
            throw EngineError.cancelled
        }])
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: spy, counter: counter)
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 2, "came back while paused: prepared again at once")
        #expect(m.status == .ready && counter.count == 1)
        #expect(spy.everyShortTaskEnded)
    }

    @Test func cancelledWithoutBackgroundDoesNotLoop() async {
        let activity = AppActivity()
        let engine = ScriptedPrepareEngine([{ throw EngineError.cancelled }])
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: ShortTaskSpy(), counter: counter)
        await m.prepareIfInstalled()
        #expect(m.status == .installed)
        #expect(await engine.prepareCalls == 1)
        #expect(counter.count == 0)
    }

    @Test func readyInBackgroundDefersOnReady() async {
        let activity = AppActivity(backgroundInference: true)
        let engine = ScriptedPrepareEngine([{ activity.enterBackground() }])
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: ShortTaskSpy(), counter: counter)
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        #expect(counter.count == 0, "no job may start from the background")
        await m.prepareIfInstalled()   // still in the background
        #expect(counter.count == 0)
        activity.becomeActive()
        await m.prepareIfInstalled()
        #expect(counter.count == 1)
        activity.enterBackground()
        activity.becomeActive()
        await m.prepareIfInstalled()
        #expect(counter.count == 1, "fired once")
        #expect(await engine.prepareCalls == 1)
    }

    @Test func failureInForegroundIsFailed() async {
        let activity = AppActivity(backgroundInference: true)
        let engine = ScriptedPrepareEngine([{ throw EngineError.failed("ANE compile failed") }])
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: ShortTaskSpy(), counter: counter)
        await m.prepareIfInstalled()
        #expect(m.status == .failed("ANE compile failed"))
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 1, "only Try again runs it again")
        await m.retry()
        #expect(await engine.prepareCalls == 2 && m.status == .ready && counter.count == 1)
    }

    @Test func expiryIsRecordedAndReturnGetsANewShortTask() async {
        let activity = AppActivity(backgroundInference: true)
        let spy = ShortTaskSpy()
        let counter = ModelManagerReadyCounter()
        let seen = StepFlag()
        let engine = ScriptedPrepareEngine()
        let m = manager(engine, activity: activity, spy: spy, counter: counter)
        await engine.setSteps([{
            activity.enterBackground()
            seen.record(activity.mayStartStage)    // true: entitled, short task held
            spy.expireLatestShort()
            seen.record(activity.mayStartStage)    // false: expired
            activity.becomeActive()
            await m.appBecameActive()
            activity.enterBackground()
            seen.record(activity.mayStartStage)    // true again: this trip has its own short task
            activity.becomeActive()
        }])
        await m.prepareIfInstalled()
        #expect(seen.all == [true, false, true])
        #expect(activity.transitions().map(\.kind) == [.background, .expired, .active, .background, .active])
        #expect(spy.shortNames.count == 2)
        #expect(spy.everyShortTaskEnded)
        #expect(m.status == .ready && counter.count == 1)
        // Not busy: a later return begins nothing.
        await m.appBecameActive()
        #expect(spy.shortNames.count == 2)
    }

    @Test func aRefusedShortTaskLeavesNoGrace() async {
        let activity = AppActivity(backgroundInference: true)
        let seen = StepFlag()
        let engine = ScriptedPrepareEngine([{
            activity.enterBackground()
            seen.record(activity.mayStartStage)
            activity.becomeActive()
        }])
        let m = manager(engine, activity: activity, spy: ShortTaskSpy(grants: false), counter: ModelManagerReadyCounter())
        await m.prepareIfInstalled()
        #expect(seen.all == [false], "no background time granted: no stage may start in the background")
    }

    /// Review finding: the prepare ended its short task, and while that end was awaited the app came back
    /// (`appBecameActive`: still busy, no grace), which began a new short task that nothing ended once the prepare
    /// had finished. Covers the new begin returning before the end does (`beginPending` false) and after the prepare
    /// has returned (true), on the ready and the failed paths.
    @Test(arguments: [false, true], [false, true])
    func aReturnWhileThePrepareEndsItsShortTaskLeavesNothingHeld(beginPending: Bool, fails: Bool) async {
        let activity = AppActivity(backgroundInference: true)
        let gate = beginPending ? OpenGate() : nil
        let spy = ShortTaskSpy(laterBegins: gate)
        let engine = ScriptedPrepareEngine([{
            activity.enterBackground()
            if fails { throw EngineError.failed("boom") }
        }])
        let counter = ModelManagerReadyCounter()
        let m = manager(engine, activity: activity, spy: spy, counter: counter)
        let returning = Mutex<Task<Void, Never>?>(nil)
        spy.duringFirstShortEnd.withLock {
            $0 = {
                await MainActor.run { activity.becomeActive() }
                guard let gate else { await m.appBecameActive(); return }
                let task = Task { @MainActor in await m.appBecameActive() }
                returning.withLock { $0 = task }
                while gate.arrived == 0 { await Task.yield() }   // the new begin is pending
            }
        }
        await m.prepareIfInstalled()
        #expect(m.status == (fails ? .failed("boom") : .ready))
        gate?.open()
        await returning.withLock { $0 }?.value
        #expect(spy.shortNames.count == 2, "the return began a second short task")
        #expect(spy.everyShortTaskEnded, "no short task is left held once the prepare has ended")
        #expect(!activity.hasGrace)
    }

    @Test func aLaunchInTheBackgroundWaitsForTheFront() async {
        let activity = AppActivity(backgroundInference: true)
        activity.enterBackground()
        let engine = ScriptedPrepareEngine()
        let spy = ShortTaskSpy()
        let m = manager(engine, activity: activity, spy: spy, counter: ModelManagerReadyCounter())
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 0)
        #expect(m.status == .installed && spy.shortNames.isEmpty)
        activity.becomeActive()
        await m.prepareIfInstalled()
        #expect(await engine.prepareCalls == 1 && m.status == .ready)
    }
}

/// Jobs and a prepare that ends in the background (critique: jobs must not start from the background).
@Suite("Jobs wait for a prepare that ends in the background")
@MainActor
struct BackgroundPrepareJobTests {
    @Test(arguments: [true, false])
    func aJobQueuedDuringThePrepareStartsOnlyInFront(prepareSucceedsInBackground: Bool) async throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let activity = AppActivity(backgroundInference: true)
        let engine = ScriptedPrepareEngine()
        let spy = ShortTaskSpy()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "bgprep-\(UUID().uuidString)")!)
        let coordinator = ProcessingCoordinator(engine: engine, store: h.store, monitor: ProcessingMonitor(),
                                                settings: settings, paths: h.paths, background: spy)
        let m = ModelManager(engine: engine, background: spy, activity: activity,
                             onReady: { Task { await coordinator.modelsBecameReady() } })
        let id = try h.queuedRecording(script: engine.inner.script, writeAudio: true)
        await engine.setSteps([{
            // The user leaves; a recording ends from the background (a call, a route loss) and queues its job.
            activity.enterBackground()
            await coordinator.enqueue(id)
            await coordinator.waitUntilIdle()
            if !prepareSucceedsInBackground { throw EngineError.cancelled }
        }])
        await m.prepareIfInstalled()
        #expect(m.status == (prepareSucceedsInBackground ? .ready : .installed))
        await coordinator.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await engine.inner.callCount("transcribe") == 0, "no job starts from the background")
        #expect(try h.recording(id).queueReason == .modelsNotReady)
        #expect(spy.jobBegins == 0)

        // Back in front (AppEnvironment.onPhase(.active) → prepareIfInstalled).
        activity.becomeActive()
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        #expect(await wp3WaitFor { await engine.inner.callCount("transcribe") == 1 })
        await coordinator.waitUntilIdle()
        #expect(try h.recording(id).stage == .ready)
        #expect(await engine.prepareCalls == (prepareSucceedsInBackground ? 1 : 2))
    }
}

/// `AppEnvironment` moves the activity on the iPhone only, first in `onPhase`, and seeds it at launch. Platform-neutral,
/// so `swift test` on the Mac covers the iPhone wiring.
@Suite("AppEnvironment and the app's activity")
@MainActor
struct AppActivityWiringTests {
    func app(_ engine: ScriptedPrepareEngine, activity: AppActivity, spy: ShortTaskSpy = ShortTaskSpy(),
             phase: (@MainActor () -> AppPhase)?) throws -> AppEnvironment {
        let config = LaunchConfig(arguments: [LaunchConfig.argUseFakeEngine, LaunchConfig.argUITesting],
                                  environment: ["TRANSCRIBE_SPEED": "instant"])
        return try AppEnvironment(config: config, engine: engine, background: spy,
                                  deviceIdentity: FixedDeviceIdentity("activity-test"), seeder: nil,
                                  activity: activity, activityPhase: phase)
    }

    @Test func aLaunchInTheBackgroundPreparesOnlyOnReturn() async throws {
        let activity = AppActivity(backgroundInference: false)
        let engine = ScriptedPrepareEngine()
        let phase = Mutex(AppPhase.background)
        let env = try app(engine, activity: activity, phase: { phase.withLock { $0 } })
        defer { try? FileManager.default.removeItem(at: env.paths.root) }
        await env.onLaunch()
        #expect(activity.inBackground, "seeded from the app's state: SwiftUI reports no change for the start")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await engine.prepareCalls == 0)
        #expect(env.models.status == .installed)
        phase.withLock { $0 = .active }
        await env.onPhase(.active)
        #expect(!activity.inBackground)
        // Under load the launch's own `Task { prepareIfInstalled }` can run only now, in front, and win the prepare
        // (onPhase's call then returns early as busy), so wait for it rather than read it at once.
        #expect(await wp3WaitFor { env.models.status == .ready })
        #expect(await engine.prepareCalls == 1)
    }

    @Test func aTripAwayDuringLaunchIsNotMissed() async throws {
        let activity = AppActivity(backgroundInference: false)
        let engine = ScriptedPrepareEngine()
        let env = try app(engine, activity: activity, phase: { .active })
        defer { try? FileManager.default.removeItem(at: env.paths.root) }
        // Before onLaunch has finished (isLaunched false): the activity still follows.
        await env.onPhase(.background)
        #expect(activity.inBackground)
        await env.onPhase(.active)
        #expect(!activity.inBackground && activity.epoch == 1)
        await env.onLaunch()
        #expect(await wp3WaitFor { env.models.status == .ready })
        #expect(await engine.prepareCalls == 1)
    }

    @Test func aPrepareRunningOnReturnGetsANewShortTask() async throws {
        let activity = AppActivity(backgroundInference: true)
        let engine = ScriptedPrepareEngine()
        let spy = ShortTaskSpy()
        let env = try app(engine, activity: activity, spy: spy, phase: { .active })
        defer { try? FileManager.default.removeItem(at: env.paths.root) }
        await engine.setSteps([{
            await env.onPhase(.background)
            spy.expireLatestShort()
            await env.onPhase(.active)
        }])
        await env.onLaunch()
        #expect(await wp3WaitFor { env.models.status == .ready })
        #expect(spy.shortNames.count == 2)
        #expect(spy.everyShortTaskEnded)
        #expect(activity.transitions().map(\.kind) == [.background, .expired, .active])
    }

    /// Review finding: the iPhone app reached `onPhase` only through a main-actor Task spawned by its scene-phase
    /// handler, so a stage ending in that gap was judged as still in front. `followActivity` moves it at once, and
    /// the `onPhase` that follows adds no second transition.
    @Test func theActivityMovesBeforeTheOnPhaseTask() async throws {
        let activity = AppActivity(backgroundInference: false)
        let window = try #require(activity.stageWindow())
        let env = try app(ScriptedPrepareEngine(), activity: activity, phase: { .active })
        defer { try? FileManager.default.removeItem(at: env.paths.root) }
        env.followActivity(.background)
        #expect(activity.inBackground && !activity.isForegroundClean(window), "synchronous, before any task runs")
        await env.onPhase(.background)
        env.followActivity(.active)
        #expect(!activity.inBackground)
        await env.onPhase(.active)
        #expect(activity.transitions().map(\.kind) == [.background, .active] && activity.epoch == 1)
    }

    @Test func theMacNeverMovesTheActivity() async throws {
        let activity = AppActivity()
        let engine = ScriptedPrepareEngine()
        let env = try app(engine, activity: activity, phase: nil)
        defer { try? FileManager.default.removeItem(at: env.paths.root) }
        env.followActivity(.background)
        await env.onPhase(.background)   // a Mac app whose windows closed keeps running
        #expect(!activity.inBackground && activity.transitions().isEmpty)
        await env.onLaunch()
        #expect(await wp3WaitFor { env.models.status == .ready })
    }
}
