import Foundation
import Observation
import os
import TranscribeCore

/// The "models" log (nonisolated, so the expiry handler can use it from a system queue).
private let modelsLog = Logger(subsystem: "ai.w2solutions.transcribe", category: "models")

/// Status and the on-device prepare of the bundled speech models.
///
/// The models ship read-only inside the app, so nothing is downloaded or removed. The prepare step (load, Neural
/// Engine compile, warm-up) runs on its own at launch and on foreground, but only from `.installed`. After a
/// failure it runs again only when the user taps "Try again" (`retry()`), so a load that fails every time does not
/// repeat the costly compile on every foreground.
///
/// Background (iPhone; `activity`): a prepare starts only in front. While it runs it holds a short background task
/// ("Preparing speech models", `BackgroundTaskBridge.beginShortTask`), begun again each time the app comes back to the
/// front while the prepare still runs (`appBecameActive`), so every trip to the background gets its own grace. The
/// engine decides what may run in that time (`FluidSpeechEngine`). When it pauses (`EngineError.cancelled`) the
/// status goes back to `.installed`, never failed: the next return to the front prepares again (warm for every stage
/// whose compile finished), and a pause that arrives when the app is already back in front prepares again at once.
/// A prepare that succeeds while the app is in the background fires `onReady` only at the next return to the front,
/// so jobs waiting for the models never start from the background.
///
/// Setup progress (§ setup progress): the engine's `PrepareEvent`s feed `setup` (`SetupProgress`), in order, and
/// every event lands before `status` changes. The views redraw from `setupSnapshot(at:)` on their own timer; this
/// type never ticks. The Library card (`setupCard`) is revealed only when a prepare is still running `revealDelay`
/// after it started and its plan has a step to prepare from scratch (`SetupProgress.isColdSetup`), so a warm
/// relaunch (well under a second) shows nothing. A warm prepare that runs slow (a cold file cache after a restart,
/// memory pressure) shows the card only if it is still running `slowWarmReveal` later, without the "once after
/// installing" note. When the models become ready a shown card holds "Ready" for `finishHold`, then goes; if that
/// happens in the background, the hold and the VoiceOver announcement wait for the return to the front, so both
/// are actually seen and heard.
@MainActor @Observable
public final class ModelManager {
    public private(set) var status: ModelStatus = .installed
    /// Setup progress for this process (changes only on events, pause, resume and expiry).
    public private(set) var setup = SetupProgress()
    /// Whether the Library shows the setup card.
    public private(set) var setupCard: SetupCardPhase = .hidden

    public enum SetupCardPhase: Equatable, Sendable {
        case hidden
        case showing
        /// Ready: the full bar and "Ready on this iPhone", for `finishHold`.
        case finishing
    }

    /// User-facing copy shared by the Library card and the Speech models screen.
    public enum Copy {
        public static let loadFailed = "The speech models couldn't load. Try again."
        /// VoiceOver, once, when a shown setup card turns to ready.
        public static let readyAnnouncement = "Transcribe is ready."
    }

    /// Posts a VoiceOver announcement (set by the app; tests may record it).
    @ObservationIgnored public var announce: (@MainActor (String) -> Void)?

    /// The short background task's name (iPhone: `beginBackgroundTask(withName:)`; Mac: the activity's reason).
    public static let shortTaskName = "Preparing speech models"

    /// Whether the app is in front (iPhone), shared with the engine.
    @ObservationIgnored public let activity: AppActivity
    @ObservationIgnored private let engine: any SpeechEngine
    @ObservationIgnored private let platform: DevicePlatform
    @ObservationIgnored private let background: any BackgroundTaskBridge
    @ObservationIgnored private let onReady: @MainActor () -> Void
    @ObservationIgnored private var isBusy = false
    /// The prepare succeeded in the background: `onReady` fires at the next return to the front.
    @ObservationIgnored private var pendingReady = false
    /// The card turned to Ready in the background: its hold and announcement wait for the front.
    @ObservationIgnored private var pendingFinish = false
    /// The short background task held while a prepare runs: its token (nil until granted, or when refused) and the
    /// grace id it holds in `activity`.
    @ObservationIgnored private var shortTask: (token: BackgroundToken?, grace: UUID)?
    /// Monotonic seconds (`ProcessInfo.systemUptime`): never the app clock, which UI tests freeze.
    @ObservationIgnored public let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private let revealDelay: Duration
    @ObservationIgnored private let slowWarmReveal: Duration
    @ObservationIgnored private let finishHold: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    /// Bumped by every prepare: a reveal timer acts only for the prepare that started it.
    @ObservationIgnored private var prepareGeneration = 0

    public static let defaultRevealDelay: Duration = .milliseconds(1500)
    /// After `revealDelay`, how much longer a warm prepare may run before the card shows anyway.
    public static let defaultSlowWarmReveal: Duration = .seconds(5)
    public static let defaultFinishHold: Duration = .milliseconds(1200)

    public init(engine: any SpeechEngine, platform: DevicePlatform = .current,
                background: any BackgroundTaskBridge = NoopBackgroundTaskBridge(), activity: AppActivity = AppActivity(),
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                revealDelay: Duration = ModelManager.defaultRevealDelay,
                slowWarmReveal: Duration = ModelManager.defaultSlowWarmReveal,
                finishHold: Duration = ModelManager.defaultFinishHold,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                onReady: @escaping @MainActor () -> Void) {
        self.engine = engine
        self.platform = platform
        self.background = background
        self.activity = activity
        self.uptime = uptime
        self.revealDelay = revealDelay
        self.slowWarmReveal = slowWarmReveal
        self.finishHold = finishHold
        self.sleep = sleep
        self.onReady = onReady
    }

    // MARK: Derived state

    public var isReady: Bool { status == .ready }

    /// The prepare failed (or the models are missing from this copy of the app): nothing happens until "Try again".
    public var hasFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// Reason text for `.failed`.
    public var failureText: String? {
        if case .failed(let reason) = status { return reason }
        return nil
    }

    /// Settings → Model row value: "Parakeet", "Getting ready…" or "Not ready".
    public var settingsValue: String { Self.settingsValue(status, info: engine.info) }

    /// Setup is not finished and has not failed (the models are installed, preparing or paused).
    public var isSettingUp: Bool {
        switch status {
        case .installed, .preparing: true
        case .ready, .failed: false
        }
    }

    /// What the setup views show at `now` (`uptime()`): the full bar once ready (the views drop the working lines
    /// then, animated).
    public func setupSnapshot(at now: TimeInterval) -> SetupSnapshot {
        var snapshot = setup.snapshot(at: now)
        if status == .ready || setupCard == .finishing {
            snapshot.fraction = 1
            snapshot.phase = .finishing
        }
        return snapshot
    }

    // MARK: Actions

    /// Reads the engine's status (left alone while a prepare is running here).
    public func refresh() async {
        guard !isBusy else { return }
        status = await engine.modelStatus()
    }

    /// Prepares the models when the engine reports them shipped but not loaded. Does nothing after a failure:
    /// that waits for `retry()`. Never starts a prepare while the app is in the background (it waits for the front;
    /// a prepare already running may carry on there). Fires a deferred `onReady` once the app is in front.
    public func prepareIfInstalled() async {
        guard !isBusy else { return }
        let current = await engine.modelStatus()
        guard !isBusy else { return }
        status = current
        if current == .ready { firePendingReady(); firePendingFinish() }
        guard current == .installed else { return }
        guard !activity.inBackground else {
            modelsLog.info("Speech model prepare waits for the app to come to the front")
            return
        }
        await prepare()
    }

    /// "Try again" after a failed prepare. The setup card shows at once: the user asked for it.
    public func retry() async {
        guard !isBusy, case .failed = status else { return }
        setupCard = .showing
        await prepare()
    }

    /// The app came back to the front (iPhone): the clock of a suspended stage skips the gap (and setup reads as
    /// carrying on, since it really stopped), a Ready card that turned while away starts its hold now, and a prepare
    /// still running gets a new short background task for the next trip to the background, since the last one
    /// expired or was refused. A short trip that interrupted nothing changes nothing on the card.
    public func appBecameActive() async {
        setup.unsuspended(at: uptime())
        firePendingFinish()
        guard isBusy, !activity.hasGrace else { return }
        modelsLog.notice("Speech model prepare resumed in front; new short background task")
        await beginShortTask()
    }

    private func prepare() async {
        isBusy = true
        defer { isBusy = false }
        if case .failed = status { setup = SetupProgress() }
        prepareGeneration += 1
        startRevealTimer(generation: prepareGeneration)
        while true {
            status = .preparing
            // Read before the short task is begun: every caller is in front here (prepareIfInstalled checked it, the
            // `continue` below runs only in front, retry is a tap), so a trip away that starts while the begin is
            // awaited still counts as a change and a pause that ends with the app back in front carries on.
            let epoch = activity.epoch
            await beginShortTask()
            do {
                try await runEngineWithEvents()
                await endShortTask(success: true)
                status = .ready
                finishSetupCard()
                if activity.inBackground {
                    pendingReady = true
                    modelsLog.notice("Speech models ready in the background; onReady deferred to the front")
                } else {
                    onReady()
                }
            } catch EngineError.cancelled {
                await endShortTask(success: false)
                setup.paused(at: uptime())
                status = .installed
                if !activity.inBackground, activity.epoch != epoch {
                    // The app went to the background and came back while a stage ran: carry on now (warm).
                    modelsLog.notice("Speech model prepare paused while the app was away and it is back: preparing again")
                    continue
                }
                modelsLog.notice("Speech model prepare paused; it carries on when the app comes to the front")
            } catch {
                await endShortTask(success: false)
                setup = SetupProgress()
                setupCard = .hidden
                status = .failed(Self.message(for: error))
            }
            return
        }
    }

    /// Runs the engine's prepare, applying its events to `setup` in order on the main actor. The stream is drained
    /// before this returns or throws, so every event lands before `status` changes.
    private func runEngineWithEvents() async throws {
        let (events, continuation) = AsyncStream.makeStream(of: (PrepareEvent, TimeInterval).self,
                                                            bufferingPolicy: .unbounded)
        let uptime = self.uptime
        let consumer = Task { @MainActor [weak self] in
            for await (event, at) in events { self?.setup.apply(event, at: at) }
        }
        do {
            try await engine.prepareModels(onEvent: { event in continuation.yield((event, uptime())) })
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
        continuation.finish()
        await consumer.value
    }

    /// Shows the card if the prepare that started this timer is still running when it fires and has a step to
    /// prepare from scratch (or no plan yet); a warm prepare gets `slowWarmReveal` more before the card shows.
    private func startRevealTimer(generation: Int) {
        guard setupCard == .hidden else { return }
        let sleep = self.sleep, delay = revealDelay, slow = slowWarmReveal
        Task { @MainActor [weak self] in
            await sleep(delay)
            guard let self, self.revealStillWanted(generation) else { return }
            if self.setup.hasPlan, !self.setup.isColdSetup {
                await sleep(slow)
                guard self.revealStillWanted(generation) else { return }
            }
            self.setupCard = .showing
        }
    }

    private func revealStillWanted(_ generation: Int) -> Bool {
        prepareGeneration == generation && isBusy && setupCard == .hidden && isSettingUp
    }

    /// Ready: a shown card holds "Ready" for `finishHold` and VoiceOver hears it once; a hidden card stays hidden.
    /// In the background both wait for the front (`firePendingFinish`).
    private func finishSetupCard() {
        guard setupCard == .showing else {
            setupCard = .hidden
            return
        }
        setupCard = .finishing
        guard !activity.inBackground else {
            pendingFinish = true
            modelsLog.notice("Setup card ready in the background; its hold waits for the front")
            return
        }
        startFinishHold()
    }

    /// A Ready card that turned while away: announce it and start its hold now that the app is in front.
    private func firePendingFinish() {
        guard pendingFinish, !activity.inBackground else { return }
        pendingFinish = false
        guard setupCard == .finishing else { return }
        startFinishHold()
    }

    private func startFinishHold() {
        announce?(Copy.readyAnnouncement)
        let sleep = self.sleep, hold = finishHold
        Task { @MainActor [weak self] in
            await sleep(hold)
            guard let self, self.setupCard == .finishing else { return }
            self.setupCard = .hidden
        }
    }

    private func firePendingReady() {
        guard pendingReady, !activity.inBackground else { return }
        pendingReady = false
        modelsLog.notice("Speech models ready: firing the deferred onReady in front")
        onReady()
    }

    /// Holds a new short background task for the running prepare, ending the one it replaces (the bridge already
    /// released the system's time when it expired). The grace is armed before asking, so an early expiry is not lost.
    private func beginShortTask() async {
        let previous = shortTask
        let grace = UUID()
        let activity = self.activity
        activity.armGrace(grace)
        shortTask = (nil, grace)
        let uptime = self.uptime
        let token = await background.beginShortTask(name: Self.shortTaskName, onExpire: { [weak self] in
            let at = uptime()
            activity.graceExpired(grace)
            modelsLog.notice("Speech model prepare: the short background task expired")
            // The app is about to be suspended: the running stage's clock stops at this moment.
            // (Skipped if the app is already back in front by the time this runs.)
            Task { @MainActor in
                guard let self, self.activity.inBackground else { return }
                self.setup.suspended(at: at)
            }
        })
        if shortTask?.grace == grace {
            shortTask?.token = token
            if token == nil { activity.graceEnded(grace) }
        } else if let token {
            await background.end(token, success: true)   // the prepare ended meanwhile
        }
        if let old = previous?.token { await background.end(old, success: true) }
    }

    /// Ends the prepare's short task. A return to the front while the end is awaited (`appBecameActive`: still busy,
    /// no grace) may begin another, so it loops until none is held; one whose begin is still pending finds itself
    /// replaced and ends its own token (`beginShortTask`).
    private func endShortTask(success: Bool) async {
        while let current = shortTask {
            shortTask = nil
            activity.graceEnded(current.grace)
            if let token = current.token { await background.end(token, success: success) }
        }
    }

    // MARK: Pure helpers (tested)

    public static func settingsValue(_ status: ModelStatus, info: EngineInfo) -> String {
        switch status {
        case .ready: info.asrDisplayName
        case .installed, .preparing: "Getting ready…"
        case .failed: "Not ready"
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case EngineError.modelsMissing: ModelStatus.missingFromAppMessage
        case EngineError.failed(let text) where !text.isEmpty: text
        default: Copy.loadFailed
        }
    }
}
