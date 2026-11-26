import Foundation
import Observation
import os
import TranscribeCore

/// Where a dictation's text goes. The Mac app supplies it (`PasteService`, or `SimulatedOutput` in a simulated run);
/// tests use a spy. Kept out of TranscribeKit so this package never touches the clipboard or posts events.
@MainActor
public protocol DictationOutput: AnyObject {
    /// The frontmost app's process id now; nil when unknown (tests, simulated runs).
    func noteTarget() -> Int32?
    /// Pastes `text` into the app that was in front when the dictation stopped (`target`), or only copies it when it
    /// cannot (no permission, secure input, the user switched apps).
    func deliver(_ text: String, target: Int32?) async -> DeliveryOutcome
    /// Leaves `text` on the clipboard without pasting.
    func copy(_ text: String, reason: CopyReason) -> DeliveryOutcome
}

/// Runs one dictation at a time (Mac): the capture gate, the microphone, the exclusive engine hold, Parakeet, and the
/// hand-off to `DictationOutput`. `DictationMachine.reduce` decides every step; this class runs the effects and feeds
/// their results back.
///
/// Rules it keeps:
/// - Never touches the library, sync or Audio/: the audio goes to `Dictation/` and is deleted as soon as it is
///   transcribed (or the dictation ends).
/// - Model calls stay one at a time: the microphone opens with live text off; the exclusive hold is taken after
///   `DictationLimits.minimumHold` (or at stop), and live text and `transcribe` run only under it. A tap shorter than
///   that, or a cancel before it, never pre-empts processing.
/// - The hold and the capture gate are given back only once every engine call this dictation started (stop, discard,
///   transcribe) has ended, so nothing it started can overlap a job or a meeting's live text.
/// - Every async result carries its attempt id. A result for an attempt that has ended is dropped and cleaned up: a
///   late session is discarded, a late file deleted.
/// - Time comes from the injected `now` and `sleep`, so tests can drive the 0.3 s rule, the limits and the waits.
@MainActor @Observable
public final class DictationController {
    public private(set) var phase: DictationMachine.State = .idle
    public private(set) var mode: DictationMode?
    /// The last `DictationLimits.levelHistory` input levels, 0...1.
    public private(set) var levels: [Float] = []
    public private(set) var liveText = LiveText()
    public private(set) var lastOutcome: DictationMachine.Outcome?
    /// New for every finish, so the same outcome twice shows the HUD again.
    public private(set) var lastOutcomeID = UUID()
    /// The first Esc after `DictationLimits.escapeConfirmAfter` was pressed: a second one within the window cancels.
    public private(set) var escapeConfirmPending = false
    private var storedLastText: String?

    /// The last delivered text, for Copy Last Dictation: memory only, for `DictationLimits.lastTextLifetime`. Never
    /// saved or logged.
    public var lastText: String? {
        guard let text = storedLastText, let at = lastTextAt,
              now() - at < .seconds(DictationLimits.lastTextLifetime) else { return nil }
        return text
    }
    public var isBusy: Bool { phase != .idle }
    /// Esc means something now (every state but idle and delivering).
    public var acceptsEscape: Bool {
        switch phase {
        case .idle, .delivering: false
        default: true
        }
    }

    public static let stopFailedMessage = "Couldn't finish the recording."
    public static let captureFailedMessage = "Couldn't open the microphone."
    static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "dictation")

    @ObservationIgnored private let engine: any SpeechEngine
    @ObservationIgnored private let coordinator: ProcessingCoordinator
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let gate: CaptureGate
    @ObservationIgnored private let output: any DictationOutput
    @ObservationIgnored private let isMeetingActive: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    // The running attempt (nil at idle).
    @ObservationIgnored private var attempt: UUID?
    @ObservationIgnored private var session: (any LiveRecording)?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?
    @ObservationIgnored private var copyOnly = false
    @ObservationIgnored private var targetAtStop: Int32?
    @ObservationIgnored private var preempted = false
    /// Acquires the exclusive engine hold; its value is the hold (nil when cancelled before acquiring). Exactly one
    /// place releases it: `releaseHold`.
    @ObservationIgnored private var holdTask: Task<EngineHold?, Never>?
    /// For tests: how each released hold task ended, in order (true when it had acquired the hold). A task that ended
    /// without the hold can never acquire it later, so `[false]` proves a tap never pre-empted a job.
    @ObservationIgnored private(set) var resolvedHolds: [Bool] = []
    /// Engine calls this controller started that may still run (stop, discard, transcribe), by id; each removes
    /// itself when done.
    @ObservationIgnored private var engineWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var maxTask: Task<Void, Never>?
    @ObservationIgnored private var escapeTask: Task<Void, Never>?
    @ObservationIgnored private var modelsCapTask: Task<Void, Never>?
    @ObservationIgnored private var lastTextTask: Task<Void, Never>?
    @ObservationIgnored private var lastTextAt: ContinuousClock.Instant?
    // Events are handled one at a time, in order, even when an effect feeds one back at once.
    @ObservationIgnored private var queued: [(DictationMachine.Event, UUID?)] = []
    @ObservationIgnored private var draining = false

    public init(engine: any SpeechEngine, coordinator: ProcessingCoordinator, models: ModelManager, settings: AppSettings,
                paths: AppPaths, gate: CaptureGate, output: any DictationOutput,
                isMeetingActive: @escaping @MainActor () -> Bool,
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.engine = engine; self.coordinator = coordinator; self.models = models; self.settings = settings
        self.paths = paths; self.gate = gate; self.output = output; self.isMeetingActive = isMeetingActive
        self.now = now; self.sleep = sleep
    }

    /// A shortcut, Esc, or the Mac going to sleep or locking (`systemSleep`: the text is then only copied).
    public func handle(_ event: DictationMachine.Event) {
        if event == .systemSleep, phase != .idle { copyOnly = true }
        send(event, for: attempt)
    }

    // MARK: - The machine

    private func send(_ event: DictationMachine.Event, for sender: UUID?) {
        queued.append((event, sender))
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queued.isEmpty {
            let (next, from) = queued.removeFirst()
            guard from == attempt else { continue }   // a result for an attempt that has ended
            step(next)
        }
    }

    private func step(_ event: DictationMachine.Event) {
        let (next, effects) = DictationMachine.reduce(phase, event, context())
        if phase == .idle, next != .idle { beginAttempt() }
        phase = next
        switch next {
        case .starting(let m, _), .listening(let m): mode = m
        default: break
        }
        for effect in effects { run(effect) }
    }

    private func context() -> DictationMachine.Context {
        DictationMachine.Context(meetingActive: isMeetingActive(), modelsReady: models.isReady,
                                 modelsFailed: models.hasFailed, copyOnly: copyOnly, elapsed: currentElapsed(),
                                 escapeConfirmPending: escapeConfirmPending)
    }

    private func currentElapsed() -> TimeInterval {
        guard let startedAt else { return 0 }
        return Self.seconds(now() - startedAt)
    }

    private func beginAttempt() {
        attempt = UUID()
        pressedAt = now()
        levels = []; liveText = LiveText(); escapeConfirmPending = false
        copyOnly = false; preempted = false; targetAtStop = nil; startedAt = nil; fileURL = nil
    }

    private func run(_ effect: DictationMachine.Effect) {
        switch effect {
        case .claimAndCheckMic: claimAndCheckMic()
        case .startCapture: startCapture()
        case .scheduleHold: scheduleHold()
        case .stopCapture: stopCapture()
        case .discardCapture: discardCapture()
        case .awaitModels: awaitModels()
        case .transcribe: transcribe()
        case .deliver(let text): deliver(text)
        case .copyOnly(let text, let reason): copyOnly(text, reason)
        case .releaseHold: releaseHold()
        case .releaseGate: releaseGate()
        case .deleteFile: deleteFile()
        case .askEscapeAgain: askEscapeAgain()
        case .finish(let outcome): finish(outcome)
        }
    }

    // MARK: - Effects

    private func claimAndCheckMic() {
        guard gate.claim(.dictation) else {
            // A meeting, or a dictation still giving the engine back: nothing was claimed, so nothing is released.
            phase = .idle
            finish(.refusedBusy)
            return
        }
        let current = attempt
        let engine = self.engine
        Task {
            var permission = await engine.microphonePermission()
            var prompted = false
            if permission == .undetermined {
                prompted = true
                permission = await engine.requestMicrophonePermission() ? .granted : .denied
            }
            self.send(permission == .granted ? .micGranted(prompted: prompted) : .micDenied, for: current)
        }
    }

    private func startCapture() {
        let current = attempt
        do { try paths.prepareDictation() } catch {
            send(.captureFailed(Self.captureFailedMessage), for: current)
            return
        }
        let url = paths.newDictationURL()
        fileURL = url
        let request = RecordingRequest(audioURL: url, liveText: false, language: settings.language)
        let engine = self.engine
        Task {
            do {
                let started = try await engine.startRecording(request)
                guard current != nil, current == self.attempt, case .starting = self.phase else {
                    // Never leave the microphone open for an attempt that has ended.
                    await started.discard()
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.session = started
                self.startedAt = self.now()
                #if DEBUG
                if let pressedAt = self.pressedAt {
                    let ms = Int((Self.seconds(self.now() - pressedAt) * 1000).rounded())
                    Self.log.debug("press to capture: \(ms, privacy: .public) ms")
                }
                #endif
                self.send(.captureStarted, for: current)
                guard current == self.attempt, case .listening = self.phase else { return }
                self.consume(started, current)
                self.scheduleMaxDuration(current)
                if !self.models.isReady {
                    let models = self.models
                    Task { await models.prepareIfInstalled() }
                }
            } catch {
                self.send(.captureFailed(Self.message(for: error)), for: current)
            }
        }
    }

    private func consume(_ recording: any LiveRecording, _ current: UUID?) {
        eventsTask?.cancel()
        let events = recording.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.attempt == current else { return }
                switch event {
                case .tick(_, let level):
                    self.levels.append(Swift.min(1, Swift.max(0, level.isFinite ? level : 0)))
                    if self.levels.count > DictationLimits.levelHistory {
                        self.levels.removeFirst(self.levels.count - DictationLimits.levelHistory)
                    }
                case .liveText(let text):
                    self.liveText = text
                case .endedBySystem:
                    self.send(.maxDurationReached, for: current)
                case .liveTextUnavailable, .paused, .resumed:
                    break
                }
            }
        }
    }

    private func scheduleMaxDuration(_ current: UUID?) {
        let limit = mode == .handsFree ? DictationLimits.handsFreeMax : DictationLimits.holdMax
        let sleep = self.sleep
        maxTask?.cancel()
        maxTask = Task {
            do { try await sleep(.seconds(limit)) } catch { return }
            self.send(.maxDurationReached, for: current)
        }
    }

    /// The hold is taken once the dictation has lasted `minimumHold`, so a tap never pre-empts a job.
    private func scheduleHold() {
        let current = attempt
        let wait = Swift.max(0, DictationLimits.minimumHold - currentElapsed())
        let coordinator = self.coordinator
        let sleep = self.sleep
        holdTask = Task {
            if wait > 0 {
                do { try await sleep(.seconds(wait)) } catch { return nil }
            }
            guard !Task.isCancelled else { return nil }
            let hold = await coordinator.acquireExclusiveEngine()
            self.holdAcquired(hold, current)
            return hold
        }
    }

    /// Takes the hold now if it is not held yet (a stop before `minimumHold`, hands-free).
    private func takeHoldNow() {
        let coordinator = self.coordinator
        let current = attempt
        guard let waiting = holdTask else {
            holdTask = Task {
                let hold = await coordinator.acquireExclusiveEngine()
                self.holdAcquired(hold, current)
                return hold
            }
            return
        }
        waiting.cancel()   // still sleeping: returns nil at once; already acquiring or held: returns the hold
        holdTask = Task {
            if let hold = await waiting.value { return hold }
            guard !Task.isCancelled else { return nil }
            let hold = await coordinator.acquireExclusiveEngine()
            self.holdAcquired(hold, current)
            return hold
        }
    }

    private func holdAcquired(_ hold: EngineHold, _ current: UUID?) {
        guard current == attempt else { return }
        if hold.preemptedJob { preempted = true }
        // Live text runs the model, so it starts only under the hold.
        if case .listening = phase, models.isReady, let session {
            Task { await session.setLiveTextEnabled(true) }
        }
    }

    private func stopCapture() {
        targetAtStop = output.noteTarget()
        eventsTask?.cancel()
        maxTask?.cancel()
        takeHoldNow()
        let current = attempt
        guard let recording = session else {
            send(.transcribeFailed(Self.stopFailedMessage), for: current)
            return
        }
        session = nil
        let url = fileURL
        track {
            do {
                let audio = try await recording.stop()
                guard current == self.attempt else {
                    try? FileManager.default.removeItem(at: audio.url)   // written after the dictation ended
                    return
                }
                self.send(.stopped(duration: audio.duration), for: current)
            } catch {
                guard current == self.attempt else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.send(.transcribeFailed(Self.stopFailedMessage), for: current)
            }
        }
    }

    private func discardCapture() {
        eventsTask?.cancel()
        maxTask?.cancel()
        guard let recording = session else { return }
        session = nil
        let url = fileURL
        track {
            await recording.discard()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func awaitModels() {
        let current = attempt
        let sleep = self.sleep
        modelsCapTask?.cancel()
        modelsCapTask = Task {
            do { try await sleep(.seconds(DictationLimits.modelsWaitCap)) } catch { return }
            guard self.phase == .waitingForModels else { return }
            self.send(.modelsUnavailable, for: current)
        }
        if !models.isReady, !models.hasFailed {
            let models = self.models
            Task { await models.prepareIfInstalled() }
        }
        checkModels(current)
    }

    /// While waiting for setup: ready → transcribe; failed (or nothing setting up) → give up. Re-arms itself on every
    /// change of the models' status, with no time limit but the cap.
    private func checkModels(_ current: UUID?) {
        guard current == attempt, phase == .waitingForModels else { return }
        if models.isReady {
            send(.modelsReady, for: current)
            return
        }
        if models.hasFailed || !models.isSettingUp {
            send(.modelsUnavailable, for: current)
            return
        }
        let models = self.models
        withObservationTracking {
            _ = models.status
        } onChange: { [weak self] in
            Task { @MainActor in self?.checkModels(current) }
        }
    }

    private func transcribe() {
        modelsCapTask?.cancel()
        let current = attempt
        guard let url = fileURL else {
            send(.transcribeFailed(Self.stopFailedMessage), for: current)
            return
        }
        if holdTask == nil { takeHoldNow() }
        let holding = holdTask
        let engine = self.engine
        let language = settings.language
        let removeFillers = settings.removeFillers
        transcribeTask = track {
            // Never call the model without the hold.
            guard await holding?.value != nil, current == self.attempt else { return }
            do {
                let words = try await engine.transcribe(url, language: language, progress: { _ in })
                guard current == self.attempt else { return }
                self.send(.transcribed(DictationText.format(words, removeFillers: removeFillers)), for: current)
            } catch {
                guard current == self.attempt else { return }
                switch error {
                case EngineError.tooShort, EngineError.noSpeech: self.send(.transcribed(nil), for: current)
                case EngineError.modelsMissing: self.send(.modelsUnavailable, for: current)
                default: self.send(.transcribeFailed(Self.message(for: error)), for: current)
                }
            }
        }
    }

    private func deliver(_ text: String) {
        let current = attempt
        let target = targetAtStop
        let output = self.output
        Task {
            let outcome = await output.deliver(text, target: target)
            self.remember(text)
            self.send(.delivered(outcome), for: current)
        }
    }

    private func copyOnly(_ text: String, _ reason: CopyReason) {
        let outcome = output.copy(text, reason: reason)
        remember(text)
        send(.delivered(outcome), for: attempt)
    }

    /// Gives the hold back once every engine call this dictation started has ended (a cancelled transcription
    /// included), so a job can never overlap it.
    private func releaseHold() {
        guard let holding = holdTask else { return }
        holdTask = nil
        holding.cancel()
        let work = Array(engineWork.values)
        let coordinator = self.coordinator
        Task {
            for task in work { await task.value }
            let hold = await holding.value
            self.resolvedHolds.append(hold != nil)
            if let hold { await coordinator.releaseExclusiveEngine(hold) }
        }
    }

    /// Frees the gate at once when nothing this dictation started is still running, else when it has ended.
    private func releaseGate() {
        let work = Array(engineWork.values)
        guard !work.isEmpty else {
            gate.release(.dictation)
            return
        }
        let gate = self.gate
        Task {
            for task in work { await task.value }
            gate.release(.dictation)
        }
    }

    private func deleteFile() {
        guard let url = fileURL else { return }
        fileURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func askEscapeAgain() {
        escapeConfirmPending = true
        let current = attempt
        let sleep = self.sleep
        escapeTask?.cancel()
        escapeTask = Task {
            do { try await sleep(.seconds(DictationLimits.escapeConfirmWindow)) } catch { return }
            guard current == self.attempt else { return }
            self.escapeConfirmPending = false
        }
    }

    private func finish(_ outcome: DictationMachine.Outcome) {
        Self.log.info("""
            dictation \(Self.modeName(self.mode), privacy: .public) \(Self.outcomeName(outcome), privacy: .public) \
            duration=\(String(format: "%.1f", self.currentElapsed()), privacy: .public) \
            models=\(self.models.isReady ? "ready" : (self.models.hasFailed ? "failed" : "settingUp"), privacy: .public) \
            preempted=\(self.preempted, privacy: .public)
            """)
        lastOutcome = outcome
        lastOutcomeID = UUID()
        endAttempt()
    }

    /// Stops everything the attempt still runs. The machine has already released what it holds; the rest is a
    /// backstop.
    private func endAttempt() {
        eventsTask?.cancel(); eventsTask = nil
        maxTask?.cancel(); maxTask = nil
        escapeTask?.cancel(); escapeTask = nil
        modelsCapTask?.cancel(); modelsCapTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        if session != nil { discardCapture() }
        if holdTask != nil { releaseHold() }
        deleteFile()
        escapeConfirmPending = false
        attempt = nil
        mode = nil
        startedAt = nil
        pressedAt = nil
        copyOnly = false
        targetAtStop = nil
    }

    // MARK: - Helpers

    /// Runs `body` on the main actor, kept in `engineWork` until it ends.
    @discardableResult
    private func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task {
            await body()
            self.engineWork[id] = nil
        }
        engineWork[id] = task
        return task
    }

    private func remember(_ text: String) {
        let at = now()
        storedLastText = text
        lastTextAt = at
        let sleep = self.sleep
        lastTextTask?.cancel()
        lastTextTask = Task {
            do { try await sleep(.seconds(DictationLimits.lastTextLifetime)) } catch { return }
            guard self.lastTextAt == at else { return }
            self.storedLastText = nil
            self.lastTextAt = nil
        }
    }

    nonisolated static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }

    /// User-facing wording for an engine error.
    static func message(for error: any Error) -> String {
        switch error {
        case EngineError.microphoneDenied: "Microphone access is off."
        case EngineError.failed(let text): text
        case EngineError.modelsMissing: DictationMachine.modelsUnavailableMessage
        default: captureFailedMessage
        }
    }

    static func modeName(_ mode: DictationMode?) -> String {
        switch mode {
        case .hold: "hold"
        case .handsFree: "handsFree"
        case nil: "none"
        }
    }

    /// The outcome without any text, for the log.
    static func outcomeName(_ outcome: DictationMachine.Outcome) -> String {
        switch outcome {
        case .refusedMeeting: "refusedMeeting"
        case .refusedBusy: "refusedBusy"
        case .refusedModelsFailed: "refusedModelsFailed"
        case .micDenied: "micDenied"
        case .micJustGranted: "micJustGranted"
        case .tooShortHint: "tooShort"
        case .cancelled: "cancelled"
        case .noSpeech: "noSpeech"
        case .pasted: "pasted"
        case .copied(let reason): "copied.\(reason)"
        case .failed: "failed"
        }
    }
}
