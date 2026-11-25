import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A sleep the test releases by hand (the reveal timer and the finish hold).
final class ManualSleep: Sendable {
    private struct State {
        var waiters: [CheckedContinuation<Void, Never>] = []
        var calls: [Duration] = []
    }
    private let state = Mutex(State())

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                state.withLock { $0.waiters.append(c); $0.calls.append(duration) }
            }
        }
    }
    /// Sleeps waiting now.
    var pending: Int { state.withLock { $0.waiters.count } }
    var calls: [Duration] { state.withLock { $0.calls } }
    /// Ends every sleep waiting now.
    func fireAll() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Holds the manager for engine hooks made before it.
@MainActor final class ManagerBox {
    var manager: ModelManager?
    var announcements: [String] = []
    var earnedAtReady: Set<PrepareStage>?
}

/// An engine that sends a plan and starts asr, waits at a gate (one per call), then fails on the first call when
/// `fails`, and otherwise succeeds.
actor EventScriptEngine: SpeechEngine {
    nonisolated let info = EngineInfo(kind: .fake, asrDisplayName: "Parakeet", asrModelID: "events", embeddingModel: .fake)
    nonisolated let gates = [OpenGate(), OpenGate()]
    nonisolated var gate: OpenGate { gates[0] }
    let fails: Bool
    /// The plan's asr step is warm (a relaunch whose compile is cached).
    let warm: Bool
    private var calls = 0
    private var status: ModelStatus = .installed
    init(fails: Bool, warm: Bool = false) { self.fails = fails; self.warm = warm }

    func modelStatus() async -> ModelStatus { status }
    func prepareModels() async throws { try await prepareModels(onEvent: { _ in }) }
    func prepareModels(onEvent: @escaping @Sendable (PrepareEvent) -> Void) async throws {
        status = .preparing
        onEvent(.planned(PreparePlan(steps: [PreparePlan.Step(stage: .asr, expectedSeconds: 10, isWarm: warm)],
                                     timesFromThisDevice: true)))
        onEvent(.stageStarted(.asr))
        calls += 1
        await gates[Swift.min(calls, gates.count) - 1].wait()
        if fails, calls == 1 {
            status = .failed("ANE compile failed")
            throw EngineError.failed("ANE compile failed")
        }
        onEvent(.stageFinished(.asr))
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

@Suite("ModelManager setup progress")
@MainActor
struct ModelManagerSetupTests {
    /// Waits end as soon as their condition holds. In a full `swift test` run the fake engine's short sleeps can
    /// take minutes (every suite shares the cooperative pool; ModelManagerTests sees the same), so the limit is
    /// generous rather than tight.
    static let patience: Duration = .seconds(600)

    static func fake(models: String, activity: AppActivity? = nil,
                     beforeStage: (@Sendable (PrepareStage) async -> Void)? = nil) -> FakeSpeechEngine {
        let config = LaunchConfig(arguments: ["-useFakeEngine", "-uiTesting"],
                                  environment: ["TRANSCRIBE_MODELS": models, "TRANSCRIBE_SPEED": "instant"])
        return FakeSpeechEngine(config: config, script: FakeScript.named(.newVoices), activity: activity,
                                beforeStage: beforeStage)
    }

    func manager(_ engine: any SpeechEngine, sleeper: ManualSleep, box: ManagerBox,
                 background: any BackgroundTaskBridge = NoopBackgroundTaskBridge(),
                 activity: AppActivity = AppActivity()) -> ModelManager {
        let m = ModelManager(engine: engine, background: background, activity: activity, sleep: sleeper.sleep,
                             onReady: { [box] in box.earnedAtReady = box.manager?.setup.earned })
        m.announce = { [box] in box.announcements.append($0) }
        box.manager = m
        return m
    }

    @Test func aWarmPrepareNeverShowsTheCard() async {
        let sleeper = ManualSleep()
        let box = ManagerBox()
        let m = manager(Self.fake(models: "installed"), sleeper: sleeper, box: box)
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 })
        #expect(sleeper.calls == [ModelManager.defaultRevealDelay], "the reveal timer was started")
        sleeper.fireAll()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(m.setupCard == .hidden, "finished before the reveal delay: nothing shows")
        #expect(box.announcements.isEmpty)
        #expect(m.setupSnapshot(at: m.uptime()).fraction == 1)
    }

    @Test func aColdPrepareShowsTheCardThenFinishesAndHides() async {
        let sleeper = ManualSleep()
        let box = ManagerBox()
        let gate = OpenGate()
        let engine = Self.fake(models: "missing", beforeStage: { stage in if stage == .asr { await gate.wait() } })
        let m = manager(engine, sleeper: sleeper, box: box)
        let running = Task { await m.prepareIfInstalled() }
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 && gate.arrived == 1 })
        #expect(m.setupCard == .hidden, "not before the reveal delay")
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { m.setupCard == .showing })
        // Events land on the main actor in order; wait for Nemotron's.
        #expect(await waitUntil(Self.patience) { m.setup.earned == [.diarizer, .nemotron] })
        let mid = m.setupSnapshot(at: m.uptime())
        #expect(mid.phase == .working)
        #expect(mid.fraction > 0.04 && mid.fraction < 0.06,
                "the two short stages earned, a twentieth of the whole: \(mid.fraction)")
        #expect(mid.stepLine == "Setting up transcription")
        #expect(mid.timeLeftText == nil && mid.showsTypicalTime,
                "a first install has no times measured here: the hedged line, never a time left")
        #expect(mid.isColdSetup)
        gate.open()
        await running.value
        #expect(m.status == .ready)
        #expect(m.setupCard == .finishing)
        let done = m.setupSnapshot(at: m.uptime())
        #expect(done.fraction == 1 && done.phase == .finishing)
        #expect(done.isColdSetup)
        #expect(box.announcements == ["Transcribe is ready."])
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 })
        #expect(sleeper.calls.last == ModelManager.defaultFinishHold)
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { m.setupCard == .hidden })
    }

    @Test func everyEventLandsBeforeReady() async {
        let box = ManagerBox()
        let m = manager(Self.fake(models: "missing"), sleeper: ManualSleep(), box: box)
        await m.prepareIfInstalled()
        #expect(box.earnedAtReady == [.asr, .warmup, .diarizer, .nemotron], "the stream is drained before ready")
    }

    @Test func aFailureClearsSetupAndShowsTheFailureAtOnce() async {
        let sleeper = ManualSleep()
        let box = ManagerBox()
        let engine = EventScriptEngine(fails: true)
        let m = manager(engine, sleeper: sleeper, box: box)
        let running = Task { await m.prepareIfInstalled() }
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 && engine.gate.arrived == 1 })
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { m.setupCard == .showing })
        #expect(await waitUntil(Self.patience) { m.setup.hasPlan })
        engine.gate.open()
        await running.value
        #expect(m.status == .failed("ANE compile failed"))
        #expect(m.setupCard == .hidden, "the failure card replaces the setup card")
        #expect(!m.setup.hasPlan)
        #expect(box.announcements.isEmpty)

        // Try again shows the setup card at once (the user asked), without waiting for the reveal.
        let again = Task { await m.retry() }
        #expect(await waitUntil(Self.patience) { engine.gates[1].arrived == 1 })
        #expect(m.status == .preparing && m.setupCard == .showing)
        engine.gates[1].open()
        await again.value
        #expect(m.status == .ready && m.setupCard == .finishing)
    }

    /// The user leaves while Parakeet compiles (the third stage) and the short task expires. With Background
    /// Inference Parakeet is kept; the warm-up's start is refused, the prepare pauses, and the card stays with the
    /// bar held. Back in front, setup carries on from there (Parakeet again, warm; then the warm-up) and ends ready.
    @Test func leavingMidSetupPausesThenCarriesOn() async {
        let sleeper = ManualSleep()
        let box = ManagerBox()
        let activity = AppActivity(backgroundInference: true)
        let spy = ShortTaskSpy()
        let gate = OpenGate()
        let firstASR = Mutex(true)
        let seen = Mutex<[SetupSnapshot]>([])
        let engine = Self.fake(models: "missing", activity: activity, beforeStage: { stage in
            guard stage == .asr else { return }
            if firstASR.withLock({ let first = $0; $0 = false; return first }) {
                activity.enterBackground()
                spy.expireLatestShort()
                await gate.wait()
            } else {
                // The new plan reaches the main actor after this hook may run: wait for it.
                while await MainActor.run(body: { box.manager?.setup.isPaused ?? false }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let snapshot = await MainActor.run { box.manager.map { $0.setupSnapshot(at: $0.uptime()) } }
                if let snapshot { seen.withLock { $0.append(snapshot) } }
            }
        })
        let m = manager(engine, sleeper: sleeper, box: box, background: spy, activity: activity)
        let running = Task { await m.prepareIfInstalled() }
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 && gate.arrived == 1 })
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { m.setupCard == .showing })
        gate.open()
        await running.value

        #expect(m.status == .installed, "paused, not failed")
        #expect(m.setupCard == .showing, "the card stays")
        let paused = m.setupSnapshot(at: m.uptime())
        #expect(paused.phase == .paused && paused.timeLeftText == nil)
        #expect(paused.stepLine == "Paused")
        #expect(m.setup.earned == [.diarizer, .nemotron, .asr])
        let floor = paused.fraction
        #expect(floor > 0.9, "Parakeet's weight is held: \(floor)")

        // Back in front.
        activity.becomeActive()
        await m.appBecameActive()
        await m.prepareIfInstalled()
        #expect(m.status == .ready)
        #expect(m.setup.earned == [.diarizer, .nemotron, .asr, .warmup])
        let during = seen.withLock { $0 }
        #expect(during.count == 1)
        #expect(during.allSatisfy { $0.phase == .resumed && $0.fraction >= floor })
        #expect(m.setupCard == .finishing)
        #expect(spy.everyShortTaskEnded)
    }

    @Test func theExpiryStopsTheRunningStageClockUntilTheReturn() async {
        let activity = AppActivity(backgroundInference: true)
        let spy = ShortTaskSpy()
        let now = Mutex(100.0)
        let engine = EventScriptEngine(fails: false)
        let m = ModelManager(engine: engine, background: spy, activity: activity, uptime: { now.withLock { $0 } },
                             sleep: ManualSleep().sleep, onReady: {})
        let running = Task { await m.prepareIfInstalled() }
        #expect(await waitUntil(Self.patience) { engine.gate.arrived == 1 && m.setup.current != nil })
        now.withLock { $0 = 104 }   // 4 s into asr (10 s expected)
        activity.enterBackground()
        spy.expireLatestShort()
        #expect(await waitUntil(Self.patience) { m.setup.suspendedSince != nil })
        let atExpiry = m.setupSnapshot(at: 104).fraction
        #expect(abs(atExpiry - 0.4) < 1e-9)
        now.withLock { $0 = 160 }
        #expect(m.setupSnapshot(at: 160).fraction == atExpiry, "frozen while suspended")
        activity.becomeActive()
        await m.appBecameActive()
        #expect(abs(m.setupSnapshot(at: 161).fraction - 0.5) < 1e-9, "one more second after the return")
        engine.gate.open()
        await running.value
        #expect(m.status == .ready)
    }

    /// A warm prepare that runs slow (a cold file cache after a restart) shows the card only after the longer
    /// fallback, and never as the once-after-installing setup.
    @Test func aSlowWarmPrepareShowsTheCardLaterWithoutTheInstallNote() async {
        let sleeper = ManualSleep()
        let box = ManagerBox()
        let engine = EventScriptEngine(fails: false, warm: true)
        let m = manager(engine, sleeper: sleeper, box: box)
        let running = Task { await m.prepareIfInstalled() }
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 && engine.gate.arrived == 1 && m.setup.hasPlan })
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 }, "a second, longer wait for a warm plan")
        #expect(sleeper.calls == [ModelManager.defaultRevealDelay, ModelManager.defaultSlowWarmReveal])
        #expect(m.setupCard == .hidden, "not at the usual reveal: the plan is warm")
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { m.setupCard == .showing })
        #expect(!m.setupSnapshot(at: m.uptime()).isColdSetup, "no \"once after installing\" for a warm load")
        engine.gate.open()
        await running.value
        #expect(m.status == .ready)
    }

    /// Ready while the app is in the background: the hold and the VoiceOver announcement wait for the front, so
    /// the Ready card is seen and heard.
    @Test func readyInTheBackgroundHoldsTheReadyCardUntilTheFront() async {
        let sleeper = ManualSleep()
        let box = ManagerBox()
        let activity = AppActivity(backgroundInference: true)
        let engine = EventScriptEngine(fails: false)
        let m = manager(engine, sleeper: sleeper, box: box, activity: activity)
        let running = Task { await m.prepareIfInstalled() }
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 && engine.gate.arrived == 1 })
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { m.setupCard == .showing })
        activity.enterBackground()
        engine.gate.open()
        await running.value
        #expect(m.status == .ready && m.setupCard == .finishing)
        #expect(box.announcements.isEmpty, "nobody hears an announcement in the background")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sleeper.pending == 0, "the hold has not started")

        activity.becomeActive()
        await m.appBecameActive()
        #expect(box.announcements == ["Transcribe is ready."])
        #expect(await waitUntil(Self.patience) { sleeper.pending == 1 })
        #expect(sleeper.calls.last == ModelManager.defaultFinishHold)
        sleeper.fireAll()
        #expect(await waitUntil(Self.patience) { m.setupCard == .hidden })
    }

    /// A short trip away that interrupts nothing does not claim setup carried on after a stop.
    @Test func aShortTripAwayIsNotAResume() async {
        let sleeper = ManualSleep()
        let box = ManagerBox()
        let activity = AppActivity(backgroundInference: true)
        let engine = EventScriptEngine(fails: false)
        let m = manager(engine, sleeper: sleeper, box: box, background: ShortTaskSpy(), activity: activity)
        let running = Task { await m.prepareIfInstalled() }
        #expect(await waitUntil(Self.patience) { engine.gate.arrived == 1 && m.setup.hasPlan })
        activity.enterBackground()
        activity.becomeActive()
        await m.appBecameActive()
        #expect(m.setupSnapshot(at: m.uptime()).phase == .working)
        engine.gate.open()
        await running.value
        #expect(m.status == .ready)
    }
}
