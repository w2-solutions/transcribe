@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os
import TranscribeCore

/// One real capture session (§5.9).
///
/// A `CaptureSource` (the microphone) delivers 16 kHz mono Float32 chunks and events into one
/// `AsyncStream`. A single consumer, this actor:
/// - writes the WAV through `WAVFileWriter`, flushing the header every 5 s;
/// - turns RMS into a 0...1 level and emits `.tick` about 20 times a second (elapsed excludes pauses);
/// - accumulates 200 waveform peak bins;
/// - feeds `SlidingWindowAsrManager` (sharing the engine's loaded `AsrModels`) when live text is on,
///   rebuilding an `AVAudioPCMBuffer` inside the actor. `liveConfig` sets how soon words appear.
public actor FluidLiveRecording: LiveRecording {
    public nonisolated let events: AsyncStream<RecordingEvent>
    private let eventContinuation: AsyncStream<RecordingEvent>.Continuation

    /// Free space under which capture ends with `.lowStorage`.
    static let minimumFreeBytes: Int64 = 150_000_000
    /// Header flush and free-space check interval: 5 s of audio.
    static let flushFrames = 5 * 16_000

    /// Window layout for live text: a new 2 s of speech is decoded as soon as 1 s of audio after it has
    /// arrived, so words show about 1 to 3 s after they are spoken (plus one model run).
    ///
    /// FluidAudio's `.streaming` preset decodes 11 s at a time with 2 s of lookahead: the first words take
    /// 13 s and the rest arrive in 11 s blocks (its `hypothesisChunkSeconds` is not read by the library).
    /// Every window is padded to the model's fixed 15 s input, so a shorter step means more model runs (one
    /// per 2 s here), not bigger ones; the long left context is free and steadies each fresh decode.
    /// Live text is display-only. The transcript is made by the batch pass after Stop.
    static let liveConfig = SlidingWindowAsrConfig(
        chunkSeconds: 2.0, hypothesisChunkSeconds: 1.0, leftContextSeconds: 10.0, rightContextSeconds: 1.0,
        minContextForConfirmation: 4.0, confirmationThreshold: 0.80)

    private enum State: Equatable { case idle, recording, paused(PauseReason), ended, finished }

    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "FluidLiveRecording")
    private let source: any CaptureSource
    private let url: URL
    private let language: Language?
    private let liveModels: @Sendable () async -> AsrModels?
    private let liveConfig: SlidingWindowAsrConfig
    private let freeBytes: @Sendable (URL) -> Int64?

    private var state: State = .idle
    /// `stop()` is draining the last chunks: no more pause/resume/system-end transitions.
    private var isStopping = false
    private var writer: WAVFileWriter?
    private var writeError: String?
    private var framesSinceFlush = 0
    private var meter = LevelMeter()
    private var peaks = PeakBins()
    private var marks: [TimeInterval] = []

    private let inputs: AsyncStream<CaptureInput>
    private let inputContinuation: AsyncStream<CaptureInput>.Continuation
    private var consumer: Task<Void, Never>?

    // Live text
    private var liveTextWanted: Bool
    private var live: SlidingWindowAsrManager?
    private var liveUpdates: Task<Void, Never>?
    private var liveGeneration = 0
    /// Confirmed text from earlier live sessions (live ASR restarts after the app returns to the foreground).
    private var confirmedPrefix = ""
    private var lastLiveText = LiveText()

    /// - Parameters:
    ///   - liveModels: the engine's loaded ASR models, or nil when they are not ready.
    ///   - freeBytes: free space on the volume holding the URL (injectable for tests).
    init(request: RecordingRequest, source: any CaptureSource,
         liveModels: @escaping @Sendable () async -> AsrModels?,
         liveConfig: SlidingWindowAsrConfig = FluidLiveRecording.liveConfig,
         freeBytes: @escaping @Sendable (URL) -> Int64? = FluidLiveRecording.volumeFreeBytes) {
        self.url = request.audioURL
        self.source = source
        self.language = LanguageMapping.fluid(request.language)
        self.liveModels = liveModels
        self.liveConfig = liveConfig
        self.freeBytes = freeBytes
        self.liveTextWanted = request.liveText
        (events, eventContinuation) = AsyncStream.makeStream(of: RecordingEvent.self, bufferingPolicy: .bufferingNewest(512))
        (inputs, inputContinuation) = AsyncStream.makeStream(of: CaptureInput.self, bufferingPolicy: .unbounded)
    }

    /// Opens the WAV, starts the consumer and the source, then live text if requested.
    func start() async throws {
        guard state == .idle else { return }
        do {
            writer = try WAVFileWriter(url: url)
        } catch {
            throw EngineError.failed("Could not create the audio file: \(FluidErrorMapping.describe(error))")
        }
        let stream = inputs
        consumer = Task { [weak self] in
            for await input in stream {
                guard let self else { return }
                await self.handle(input)
            }
        }
        state = .recording
        let continuation = inputContinuation
        do {
            try await source.start { continuation.yield($0) }
        } catch {
            state = .finished
            inputContinuation.finish()
            consumer?.cancel()
            _ = try? writer?.finish()
            writer = nil
            try? FileManager.default.removeItem(at: url)
            eventContinuation.finish()
            throw FluidErrorMapping.engineError(error)
        }
        checkFreeSpace()
        if liveTextWanted {
            await startLive()
        } else {
            eventContinuation.yield(.liveTextUnavailable(.modelsNotReady))
        }
    }

    // MARK: LiveRecording

    public func pause() async {
        guard state == .recording, !isStopping else { return }
        await source.pause()
        guard state == .recording else { return }
        state = .paused(.user)
        eventContinuation.yield(.paused(.user))
    }

    public func resume() async {
        guard isPausedState, !isStopping else { return }
        do {
            try await source.resume()
        } catch {
            await end(.failed(FluidErrorMapping.describe(error)))
            return
        }
        guard case .paused = state else { return }
        state = .recording
        eventContinuation.yield(.resumed)
    }

    public func markMoment() async -> TimeInterval {
        let t = elapsed
        marks.append(t)
        return t
    }

    public func setLiveTextEnabled(_ enabled: Bool) async {
        guard state != .finished, enabled != liveTextWanted else { return }
        liveTextWanted = enabled
        if enabled {
            await startLive()
        } else {
            await stopLive(finish: false)
            eventContinuation.yield(.liveTextUnavailable(.pausedInBackground))
        }
    }

    public func stop() async throws -> CapturedAudio {
        guard state != .finished, !isStopping else { throw EngineError.failed("Recording already stopped") }
        isStopping = true
        await source.stop()
        // Drain every chunk the source delivered before it stopped (the state still accepts audio).
        inputContinuation.finish()
        await consumer?.value
        consumer = nil
        // Live text: finish, then release its memory before batch processing starts.
        await stopLive(finish: true)
        state = .finished
        eventContinuation.finish()

        guard let writer else { throw EngineError.failed("No audio was written") }
        self.writer = nil
        let duration: TimeInterval
        do {
            duration = try writer.finish()
        } catch {
            throw EngineError.failed("Could not finish the audio file: \(FluidErrorMapping.describe(error))")
        }
        if let writeError { log.error("Audio write error during capture: \(writeError, privacy: .public)") }
        return CapturedAudio(url: url, duration: duration, marks: marks, peaks: peaks.result(),
                             detail: await source.captureDetail())
    }

    public func discard() async {
        guard state != .finished, !isStopping else { return }
        isStopping = true
        state = .ended
        await source.stop()
        inputContinuation.finish()
        consumer?.cancel()
        await consumer?.value
        consumer = nil
        await stopLive(finish: false)
        state = .finished
        eventContinuation.finish()
        _ = try? writer?.finish()
        writer = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Consumer

    private var elapsed: TimeInterval { Double(meter.totalFrames) / Double(LevelMeter.sampleRate) }

    /// Audio the consumer has written so far (pauses excluded).
    var capturedDuration: TimeInterval { elapsed }

    private func handle(_ input: CaptureInput) async {
        switch input {
        case .audio(let samples):
            await handleAudio(samples)
        case .event(let event):
            await handleSourceEvent(event)
        }
    }

    private func handleAudio(_ samples: [Float]) async {
        guard !samples.isEmpty, state == .recording || isPausedState else { return }
        if let writer, writeError == nil {
            do {
                try writer.append(samples)
            } catch {
                writeError = FluidErrorMapping.describe(error)
                await end(.failed("Could not write audio: \(writeError ?? "")"))
                return
            }
        }
        for tick in meter.ingest(samples) {
            eventContinuation.yield(.tick(elapsed: Double(tick.endFrame) / Double(LevelMeter.sampleRate), level: tick.level))
        }
        peaks.ingest(samples)
        framesSinceFlush += samples.count
        if framesSinceFlush >= Self.flushFrames {
            framesSinceFlush = 0
            do { try writer?.flushHeader() } catch { log.error("WAV header flush failed: \(FluidErrorMapping.describe(error), privacy: .public)") }
            checkFreeSpace()
        }
        if let live, let buffer = Self.makeBuffer(samples) {
            await live.streamAudio(buffer)
        }
    }

    private var isPausedState: Bool { if case .paused = state { true } else { false } }

    private func handleSourceEvent(_ event: CaptureSourceEvent) async {
        guard !isStopping else { return }
        switch event {
        case .interrupted:
            guard state == .recording else { return }
            await source.pause()
            state = .paused(.interruption)
            eventContinuation.yield(.paused(.interruption))
        case .interruptionEnded(let shouldResume):
            guard state == .paused(.interruption), shouldResume else { return }
            await resume()
        case .routeLost:
            guard state == .recording else { return }
            await source.pause()
            state = .paused(.routeLost)
            eventContinuation.yield(.paused(.routeLost))
        case .mediaServicesReset:
            await end(.mediaServicesReset)
        case .failed(let message):
            await end(.failed(message))
        case .systemAudioSilent:
            eventContinuation.yield(.notice(.systemAudioSilent))
        case .systemAudioLost:
            // Both mode: the microphone carries on. (A Mac-audio-only source reports `.routeLost` instead.)
            eventContinuation.yield(.notice(.systemAudioLost))
        }
    }

    /// Capture stopped for a system reason. The file stays open; the caller must still call `stop()`.
    private func end(_ reason: RecordingEndReason) async {
        guard state == .recording || isPausedState, !isStopping else { return }
        state = .ended
        await source.stop()
        eventContinuation.yield(.endedBySystem(reason))
    }

    private func checkFreeSpace() {
        guard state == .recording || isPausedState, !isStopping,
              let free = freeBytes(url), free < Self.minimumFreeBytes else { return }
        log.error("Free space \(free) bytes is under the minimum; ending capture")
        state = .ended
        let source = self.source
        Task { await source.stop() }
        eventContinuation.yield(.endedBySystem(.lowStorage))
    }

    // MARK: Live text

    private func startLive() async {
        guard live == nil, state != .finished, state != .ended else { return }
        liveGeneration += 1
        let generation = liveGeneration
        guard let models = await liveModels() else {
            eventContinuation.yield(.liveTextUnavailable(.modelsNotReady))
            return
        }
        let manager = SlidingWindowAsrManager(config: liveConfig.applying(language: language))
        do {
            try await manager.loadModels(models)
            let updates = await manager.transcriptionUpdates
            try await manager.startStreaming(source: .microphone)
            guard generation == liveGeneration, liveTextWanted, state != .finished, state != .ended else {
                await manager.cleanup()
                return
            }
            live = manager
            liveUpdates = Task { [weak self] in
                for await update in updates {
                    guard let self else { return }
                    await self.handleLiveUpdate(confirmed: update.confirmedTranscript, volatile: update.volatileTranscript)
                }
            }
        } catch {
            await manager.cleanup()
            log.error("Live text failed to start: \(FluidErrorMapping.describe(error), privacy: .public)")
            eventContinuation.yield(.liveTextUnavailable(.failed("Live text is unavailable")))
        }
    }

    /// `finish == true` (stop): let the window manager decode what it has. Otherwise cancel straight away.
    /// Either way `cleanup()` releases the live manager's model references.
    private func stopLive(finish: Bool) async {
        liveGeneration += 1
        guard let manager = live else { return }
        live = nil
        if finish {
            do { _ = try await manager.finish() } catch {
                log.info("Live text finish: \(FluidErrorMapping.describe(error), privacy: .public)")
            }
        }
        await manager.cleanup()
        await liveUpdates?.value
        liveUpdates = nil
        // Keep what was confirmed so a later live session continues the text.
        confirmedPrefix = Self.join(lastLiveText.confirmed, lastLiveText.volatile)
    }

    private func handleLiveUpdate(confirmed: String, volatile: String) {
        guard state != .finished else { return }
        let text = LiveText(confirmed: Self.join(confirmedPrefix, confirmed),
                            volatile: volatile.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text != lastLiveText else { return }
        lastLiveText = text
        eventContinuation.yield(.liveText(text))
    }

    static func join(_ a: String, _ b: String) -> String {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { return y }
        if y.isEmpty { return x }
        return x + " " + y
    }

    /// A 16 kHz mono Float32 buffer holding `samples` (built inside the actor; buffers are not Sendable).
    static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// `volumeAvailableCapacityForImportantUsage` of the volume holding `url`.
    static let volumeFreeBytes: @Sendable (URL) -> Int64? = { url in
        let dir = url.deletingLastPathComponent()
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
