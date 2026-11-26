import Foundation
import os
import TranscribeCore

/// A Both recording's capture (Mac audio, decided 2026-11-26): the microphone and Mac audio, each stamped with host
/// time, put on one timeline by a `StreamAligner` and delivered as one ordinary stream of
/// `clamp(mic + system, −1, 1)` chunks. So `FluidLiveRecording`, the recording's `<id>.wav`, live text, playback, clips
/// and speaker separation are the same as for a microphone recording.
///
/// Beside the mix it writes each aligned stream to its stem (`CaptureStems`: `Audio/Stems/<id>.mic.wav` and
/// `<id>.system.wav`) through `WAVFileWriter`, flushing their headers every 5 s of audio like the main file, so a crash
/// leaves stems that salvage can read. Both stems and the mix have exactly the same length: sample n of each is the
/// same moment. Stems are temporary; the store deletes them when the recording is ready.
///
/// - The microphone starts first (so the tap can exclude this process's own audio object). If it cannot start, the
///   recording does not start. If Mac audio cannot start, the recording goes on with the microphone and delivers
///   `.systemAudioLost` at once.
/// - Mac audio lost later (`.systemAudioLost`, or its own route lost or failure) is filled with zeros from then on, and
///   the event is passed on once; the microphone carries on. `.systemAudioSilent` is passed on. The microphone's own
///   events are passed on as they are (an interruption or a lost microphone pauses the whole recording).
/// - A pause pauses both; on resume the timeline is anchored again, so the pause leaves no zeros.
/// - `streamLevels()` gives each stream's level (the recording window's two meters); `captureDetail()` the
///   microphone's detail with `input = micAndSystem`, `sources = both` and Mac audio's output route.
actor MixedCaptureSource: CaptureSource {
    private enum Item: Sendable {
        case audio(CaptureStream, [Float], Double?)
        case event(CaptureStream, CaptureSourceEvent)
        case rebase
    }

    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "MixedCaptureSource")
    private let mic: any StampedCaptureSource
    private let system: any StampedCaptureSource
    let stems: CaptureStems

    private var deliver: (@Sendable (CaptureInput) -> Void)?
    private var aligner: StreamAligner
    private var micWriter: WAVFileWriter?
    private var systemWriter: WAVFileWriter?
    private var stemWriteFailed = false
    private var framesSinceFlush = 0
    private var micMeter = LevelMeter()
    private var systemMeter = LevelMeter()
    private var levels = StreamLevels(mic: 0, system: 0)
    private var systemLost = false
    private var started = false
    private var stopped = false

    private let items: AsyncStream<Item>
    private let itemContinuation: AsyncStream<Item>.Continuation
    private var consumer: Task<Void, Never>?

    init(mic: any StampedCaptureSource, system: any StampedCaptureSource, stems: CaptureStems,
         aligner: StreamAligner = StreamAligner()) {
        self.mic = mic
        self.system = system
        self.stems = stems
        self.aligner = aligner
        (items, itemContinuation) = AsyncStream.makeStream(of: Item.self, bufferingPolicy: .unbounded)
    }

    func start(_ deliver: @escaping @Sendable (CaptureInput) -> Void) async throws {
        guard !started, !stopped else { throw EngineError.failed("Capture already started") }
        started = true
        self.deliver = deliver
        do {
            micWriter = try WAVFileWriter(url: stems.mic)
            systemWriter = try WAVFileWriter(url: stems.system)
        } catch {
            closeWriters(remove: true)
            throw EngineError.failed("Could not create the audio file: \(FluidErrorMapping.describe(error))")
        }
        let stream = items
        consumer = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                await self.handle(item)
            }
        }
        let continuation = itemContinuation
        do {
            try await mic.startStamped { continuation.yield(Self.item(.mic, $0)) }
        } catch {
            stopped = true
            continuation.finish()
            await consumer?.value
            closeWriters(remove: true)
            throw error
        }
        do {
            try await system.startStamped { continuation.yield(Self.item(.system, $0)) }
        } catch {
            log.error("Mac audio did not start; recording the microphone only: \(FluidErrorMapping.describe(error), privacy: .public)")
            continuation.yield(.event(.system, .systemAudioLost))
        }
    }

    private static func item(_ stream: CaptureStream, _ input: StampedInput) -> Item {
        switch input {
        case .audio(let samples, let host): .audio(stream, samples, host)
        case .event(let event): .event(stream, event)
        }
    }

    func pause() async {
        guard started, !stopped else { return }
        await mic.pause()
        if !systemLost { await system.pause() }
    }

    func resume() async throws {
        guard started, !stopped else { return }
        // Queued behind everything delivered before the pause, so the pause never becomes zeros.
        itemContinuation.yield(.rebase)
        try await mic.resume()
        guard !systemLost else { return }
        do {
            try await system.resume()
        } catch {
            log.error("Mac audio did not resume; recording the microphone only: \(FluidErrorMapping.describe(error), privacy: .public)")
            itemContinuation.yield(.event(.system, .systemAudioLost))
        }
    }

    func stop() async {
        guard started, !stopped else { return }
        stopped = true
        await mic.stop()
        await system.stop()
        itemContinuation.finish()
        await consumer?.value
        consumer = nil
        emit(aligner.finish())
        if aligner.insertedFrames + aligner.droppedFrames + aligner.lagFilledFrames > 0 {
            log.info("Aligned Mac audio: \(self.aligner.insertedFrames) inserted, \(self.aligner.droppedFrames) dropped, \(self.aligner.lagFilledFrames) filled")
        }
        closeWriters(remove: false)
        deliver = nil
    }

    func captureDetail() async -> CaptureDetail? {
        let micDetail = await mic.captureDetail()
        let systemDetail = await system.captureDetail()
        var detail = micDetail ?? CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: nil)
        detail.input = CaptureSources.both.detailInput
        detail.sources = CaptureSources.both.detailValue
        detail.outputRoute = systemDetail?.outputRoute
        detail.routeChanged = (micDetail?.routeChanged ?? false) || (systemDetail?.routeChanged ?? false)
        return detail
    }

    func streamLevels() async -> StreamLevels? { levels }

    /// Whether Mac audio was lost (tests).
    var isSystemLost: Bool { systemLost }

    // MARK: Consumer

    private func handle(_ item: Item) {
        switch item {
        case .audio(let stream, let samples, let host):
            guard !samples.isEmpty else { return }
            emit(aligner.push(stream, samples, hostSeconds: host))
        case .rebase:
            emit(aligner.rebase())
        case .event(.mic, let event):
            deliver?(.event(event))
        case .event(.system, let event):
            switch event {
            case .systemAudioSilent:
                deliver?(.event(.systemAudioSilent))
            case .systemAudioLost, .routeLost, .failed, .mediaServicesReset:
                guard !systemLost else { return }
                systemLost = true
                emit(aligner.markLost(.system))
                deliver?(.event(.systemAudioLost))
            case .interrupted, .interruptionEnded:
                break   // only the microphone's session is interrupted
            }
        }
    }

    private func emit(_ out: StreamAligner.Output) {
        guard !out.isEmpty else { return }
        if !stemWriteFailed {
            do {
                try micWriter?.append(out.mic)
                try systemWriter?.append(out.system)
            } catch {
                stemWriteFailed = true
                log.error("Stem write failed; the recording goes on without stems: \(FluidErrorMapping.describe(error), privacy: .public)")
            }
        }
        if let last = micMeter.ingest(out.mic).last { levels.mic = last.level }
        if let last = systemMeter.ingest(out.system).last { levels.system = last.level }
        framesSinceFlush += out.count
        if framesSinceFlush >= FluidLiveRecording.flushFrames, !stemWriteFailed {
            framesSinceFlush = 0
            do {
                try micWriter?.flushHeader()
                try systemWriter?.flushHeader()
            } catch {
                log.error("Stem header flush failed: \(FluidErrorMapping.describe(error), privacy: .public)")
            }
        }
        deliver?(.audio(out.mixed()))
    }

    private func closeWriters(remove: Bool) {
        _ = try? micWriter?.finish()
        _ = try? systemWriter?.finish()
        micWriter = nil
        systemWriter = nil
        if remove {
            try? FileManager.default.removeItem(at: stems.mic)
            try? FileManager.default.removeItem(at: stems.system)
        }
    }
}
