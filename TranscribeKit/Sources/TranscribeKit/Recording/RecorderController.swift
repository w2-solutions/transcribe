import Foundation
import Observation
import TranscribeCore

/// Drives one microphone capture at a time (§5.9): permission, the `.capturing` row, pre-empting processing,
/// the engine session's events (elapsed, levels, live text, pauses, system ends), marks, and the hand-off to
/// the processing queue on stop.
@MainActor @Observable
public final class RecorderController {
    public enum State: Equatable { case idle, starting, recording, paused(PauseReason), stopping }
    public private(set) var state: State = .idle
    public private(set) var recordingID: UUID?
    public private(set) var startedAt: Date?
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var levels: [Float] = []          // last 56 levels (bars on screen 2)
    /// Mac audio's last 56 levels in a Both recording (the second meter); empty otherwise.
    public private(set) var systemLevels: [Float] = []
    /// What the running (or last) recording captures.
    public private(set) var sources: CaptureSources = .microphone
    /// The latest Mac audio notice of the running recording (silent, lost); nil until one comes.
    public private(set) var notice: RecordingNotice?
    public private(set) var liveText = LiveText()
    public private(set) var liveTextNote: String?         // e.g. "Live text starts when setup finishes."
    public private(set) var marks: [TimeInterval] = []
    public private(set) var lastMarkAt: TimeInterval?     // drives the "Moment marked 0:14" toast
    /// Set when the system ended capture (`.endedBySystem`). The recorder then stops and saves on its own,
    /// whether or not the recording screen is showing, and publishes the outcome in `systemStop`.
    public private(set) var systemEndReason: RecordingEndReason?
    /// The finished system stop, for an alert: the reason and the saved recording (nil if nothing was saved).
    /// Stays until `acknowledgeSystemStop()` or the next `start()`.
    public private(set) var systemStop: SystemStop?

    public struct SystemStop: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let reason: RecordingEndReason
        public let recordingID: UUID?
        public init(id: UUID = UUID(), reason: RecordingEndReason, recordingID: UUID?) {
            self.id = id; self.reason = reason; self.recordingID = recordingID
        }
    }
    public var isActive: Bool { state != .idle }

    public static let levelHistory = 56
    public static let modelsNotReadyNote = "Live text starts when setup finishes."
    /// Setup failed: no live text until "Try again" in Recordings gets it ready.
    public static let modelsFailedNote = "Live text is off because setup couldn't finish. Recording still works."

    /// The note for a recording without live text because the models are not ready.
    public static func noteWithoutModels(setupFailed: Bool) -> String {
        setupFailed ? modelsFailedNote : modelsNotReadyNote
    }

    @ObservationIgnored private let engine: any SpeechEngine
    @ObservationIgnored private let store: any LibraryStoring
    @ObservationIgnored private let coordinator: ProcessingCoordinator
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let clock: AppClock
    /// Shared with dictation (Mac): claimed in `start()`, given back whenever the recorder is idle again.
    @ObservationIgnored public let gate: CaptureGate
    @ObservationIgnored private var session: (any LiveRecording)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// The running recording started before the speech models were ready, so it has no live text yet.
    @ObservationIgnored private var liveTextWaitsForModels = false

    public init(engine: any SpeechEngine, store: any LibraryStoring, coordinator: ProcessingCoordinator,
                models: ModelManager, paths: AppPaths, settings: AppSettings, clock: AppClock,
                gate: CaptureGate = CaptureGate()) {
        self.engine = engine; self.store = store; self.coordinator = coordinator; self.models = models
        self.paths = paths; self.settings = settings; self.clock = clock; self.gate = gate
    }

    /// Asks for mic permission if undetermined (only when `sources` include the microphone). Throws
    /// EngineError.microphoneDenied, or `.sourceUnavailable` for Mac audio on an engine without it.
    /// Creates the Recording row (.capturing), calls coordinator.suspendForCapture(), starts the engine session.
    /// Calling it while a recording is active returns the active id; calling it while another start is in
    /// flight throws `EngineError.failed("Already starting")`. During a dictation (the capture gate is taken) it
    /// throws `EngineError.failed(CaptureGate.dictationBusyMessage)` and creates nothing.
    @discardableResult public func start(sources: CaptureSources = .microphone) async throws -> UUID {
        if let id = recordingID, isActive, state != .starting { return id }
        guard state == .idle else { throw EngineError.failed("Already starting") }
        guard !sources.includesSystemAudio || engine.systemAudioAvailable else { throw EngineError.sourceUnavailable }
        guard gate.claim(.meeting) else { throw EngineError.failed(CaptureGate.dictationBusyMessage) }
        state = .starting

        // 1. Permission (asks once when undetermined).
        if sources.includesMicrophone {
            var permission = await engine.microphonePermission()
            if permission == .undetermined {
                permission = await engine.requestMicrophonePermission() ? .granted : .denied
            }
            guard permission == .granted else {
                state = .idle
                gate.release(.meeting)
                throw EngineError.microphoneDenied
            }
        }

        // 2–5. Id, row, pre-empt processing, start the engine session.
        let id = UUID()
        let now = clock.now
        let fileName = paths.newAudioFileName(for: id)
        let live = models.isReady
        var created = false
        var suspended = false
        do {
            try paths.prepare()
            try store.createRecording(id: id, createdAt: now, audioFileName: fileName, source: .microphone,
                                      captureSources: sources)
            created = true
            await coordinator.suspendForCapture()
            suspended = true
            let request = RecordingRequest(audioURL: paths.audioURL(fileName: fileName), liveText: live,
                                           language: settings.language, sources: sources,
                                           stems: sources == .both ? paths.stems(recordingID: id) : nil)
            let session = try await engine.startRecording(request)
            self.session = session
            recordingID = id
            startedAt = now
            elapsed = 0; levels = []; systemLevels = []; liveText = LiveText(); marks = []; lastMarkAt = nil
            self.sources = sources; notice = nil
            systemEndReason = nil; systemStop = nil
            liveTextNote = live ? nil : Self.noteWithoutModels(setupFailed: models.hasFailed)
            liveTextWaitsForModels = !live
            state = .recording
            // 6. Events are consumed on the main actor from here on.
            consume(session)
        } catch {
            state = .idle
            gate.release(.meeting)
            if created { try? store.discardRecording(id: id) }
            if suspended { await coordinator.resumeAfterCapture() }
            throw error
        }
        return id
    }

    public func pause() async {
        guard state == .recording, let session else { return }
        await session.pause()
        if state == .recording { state = .paused(.user) }
    }

    public func resume() async {
        guard case .paused = state, let session else { return }
        await session.resume()
        if case .paused = state { state = .recording }
    }

    /// Records an audio-timeline offset and publishes it through `lastMarkAt` (the "Moment marked" toast).
    public func markMoment() async {
        guard state == .recording || isPaused, let session else { return }
        let t = await session.markMoment()
        marks.append(t)
        lastMarkAt = t
    }

    /// Stops capture, finishCapture(.queued), coordinator.resumeAfterCapture() + enqueue(id). Returns the id.
    @discardableResult public func stop() async throws -> UUID {
        guard let session, let id = recordingID, state != .stopping, state != .starting else {
            throw EngineError.failed("Not recording")
        }
        state = .stopping
        // 1. Finalise the WAV and live ASR.
        let audio: CapturedAudio
        do {
            audio = try await session.stop()
        } catch {
            // A session cannot be stopped twice (`LiveRecording.stop`), so capture has ended either way: never
            // leave the UI showing a recording that is not running. Salvage the audio written so far now
            // (header repair, then queue), as launch recovery would.
            eventsTask?.cancel()
            reset()
            await coordinator.resumeAfterCapture()
            await coordinator.recoverInterruptedCapture(id)
            throw error
        }
        eventsTask?.cancel()
        reset()
        // 2–4. Persist, let processing continue, queue this recording.
        do {
            try store.finishCapture(id: id, audio: audio, language: settings.language)
        } catch {
            // The row stays `.capturing`; launch recovery repairs and queues it.
            await coordinator.resumeAfterCapture()
            throw error
        }
        await coordinator.resumeAfterCapture()
        await coordinator.enqueue(id)
        return id
    }

    /// Stops capture and deletes the row and its audio.
    /// Clears `systemStop` once its alert has been shown.
    public func acknowledgeSystemStop() { systemStop = nil }

    /// Stops and saves after the system ended capture, so a minimised recording never keeps showing "Recording".
    private func stopAfterSystemEnd(_ reason: RecordingEndReason) async {
        guard session != nil, state != .stopping else { return }
        let current = recordingID
        var id = try? await stop()
        if id == nil, let current, (try? store.snapshot(of: current)) != nil { id = current }   // salvaged after a failed stop
        systemStop = SystemStop(reason: reason, recordingID: id)
    }

    public func discard() async {
        guard let session else { reset(); return }
        let id = recordingID
        eventsTask?.cancel()
        reset()
        await session.discard()
        if let id { try? store.discardRecording(id: id) }
        await coordinator.resumeAfterCapture()
    }

    private var isPaused: Bool { if case .paused = state { true } else { false } }

    /// The speech models became ready (`ModelManager.onReady`, which fires only with the app in front): a recording
    /// that started without live text gets it now (the session turns it on mid-recording).
    public func modelsBecameReady() async {
        guard let session, state == .recording || isPaused, liveTextWaitsForModels else { return }
        liveTextWaitsForModels = false
        if liveText.isEmpty { liveTextNote = nil }
        await session.setLiveTextEnabled(true)
    }

    /// setLiveTextEnabled(false)
    public func appDidEnterBackground() async {
        await session?.setLiveTextEnabled(false)
    }

    /// setLiveTextEnabled(true) if models ready
    public func appWillEnterForeground() async {
        if models.isReady { await session?.setLiveTextEnabled(true) }
    }

    // MARK: - Events

    private func consume(_ session: any LiveRecording) {
        eventsTask?.cancel()
        let events = session.events
        let sessionID = ObjectIdentifier(session)
        eventsTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                // Ignore late events from a session that has already been stopped or replaced.
                guard let current = self.session, ObjectIdentifier(current) == sessionID else { return }
                self.handle(event)
            }
        }
    }

    func handle(_ event: RecordingEvent) {
        switch event {
        case .tick(let elapsed, let level, let systemLevel):
            self.elapsed = elapsed
            levels.append(Swift.min(1, Swift.max(0, level.isFinite ? level : 0)))
            if levels.count > Self.levelHistory { levels.removeFirst(levels.count - Self.levelHistory) }
            if let systemLevel {
                systemLevels.append(Swift.min(1, Swift.max(0, systemLevel.isFinite ? systemLevel : 0)))
                if systemLevels.count > Self.levelHistory { systemLevels.removeFirst(systemLevels.count - Self.levelHistory) }
            }
        case .notice(let notice):
            self.notice = notice
        case .liveText(let text):
            liveText = text
            liveTextNote = nil
        case .liveTextUnavailable(let reason):
            switch reason {
            case .modelsNotReady: if liveText.isEmpty { liveTextNote = Self.noteWithoutModels(setupFailed: models.hasFailed) }
            case .pausedInBackground: break   // the text so far stays; it resumes in the foreground
            case .failed(let message): if liveText.isEmpty { liveTextNote = message }
            }
        case .paused(let reason):
            if state == .recording || isPaused { state = .paused(reason) }
        case .resumed:
            if isPaused { state = .recording }
        case .endedBySystem(let reason):
            guard systemEndReason == nil else { return }
            systemEndReason = reason
            Task { await self.stopAfterSystemEnd(reason) }
        }
    }

    /// Clears the session; the published values of the finished recording (elapsed, levels, live text, marks)
    /// stay until the next `start()` so a dismissing cover doesn't flash empty.
    private func reset() {
        session = nil
        liveTextWaitsForModels = false
        eventsTask = nil
        recordingID = nil
        startedAt = nil
        state = .idle
        gate.release(.meeting)
    }
}
