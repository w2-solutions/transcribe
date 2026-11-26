import Foundation
import TranscribeCore

/// A scripted capture session (§7.3). Ticks every 50 ms of real time; live text follows the script timeline.
/// `stop()` always writes exactly `script.duration` seconds of SyntheticAudio.
///
/// Mac audio (`request.sources`, with `FakeMacAudio` from `TRANSCRIBE_MAC_AUDIO`):
/// - Both: each tick also carries Mac audio's level (a second deterministic table), and `stop()` writes the stems:
///   the system stem is non-zero exactly over the segments of the script's `remoteSpeakers`, the microphone stem over
///   the others (when Mac audio is `silent`, the system stem is all zeros and the microphone stem holds everyone, as
///   when the far side plays through the speakers with access off). So the real source attribution runs on them.
/// - Mac audio only: one meter, Mac audio's level; no stems.
/// - `silent`: Mac audio's level stays 0 and `.notice(.systemAudioSilent)` comes once after 5 s.
///   `lost`: after 3 s, a Both recording gets `.notice(.systemAudioLost)` and Mac audio's level drops to 0; a Mac-audio-
///   only recording pauses with `.routeLost` (resuming brings it back).
/// - The capture detail is `input = fakeMacAudio`, `sources` as recorded and `outputRoute = headphones`; a microphone
///   recording's is `input = fake`, as before.
public actor FakeLiveRecording: LiveRecording {
    public nonisolated let events: AsyncStream<RecordingEvent>
    private let continuation: AsyncStream<RecordingEvent>.Continuation
    private let script: FakeScript
    private let speed: FakeSpeed
    private let url: URL
    private let sources: CaptureSources
    private let stems: CaptureStems
    private let macAudio: FakeMacAudio
    private var liveTextEnabled: Bool
    private var elapsed: TimeInterval = 0
    private var tickIndex = 0
    private var isPaused = false
    private var isFinished = false
    private var marks: [TimeInterval] = []
    private var lastLiveText: LiveText?
    private var ticker: Task<Void, Never>?
    private var silentNoticeSent = false
    private var systemLost = false

    static let tickInterval: TimeInterval = 0.05
    static let frozenElapsed: TimeInterval = 14.0
    /// Seconds of recording before a `silent` Mac audio gives its notice, and before a `lost` one stops.
    public static let silentAfter: TimeInterval = 5.0
    public static let lostAfter: TimeInterval = 3.0
    /// `CaptureDetail.input` of a fake recording that captured Mac audio.
    public static let macAudioInput = "fakeMacAudio"
    /// Deterministic noise table for the level meter.
    static let noise: [Float] = [0.12, -0.05, 0.20, -0.14, 0.03, 0.17, -0.09, 0.08, -0.18, 0.15, 0.01, -0.11, 0.19, -0.02, 0.10, -0.16]

    public init(script: FakeScript, speed: FakeSpeed, request: RecordingRequest, macAudio: FakeMacAudio = .granted) {
        self.script = script
        self.speed = speed
        self.url = request.audioURL
        self.sources = request.sources
        self.stems = request.stems ?? CaptureStems.beside(audioURL: request.audioURL)
        self.macAudio = macAudio
        self.liveTextEnabled = request.liveText
        (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Starts emitting events. Called by FakeSpeechEngine.startRecording.
    public func begin() {
        if !liveTextEnabled { continuation.yield(.liveTextUnavailable(.modelsNotReady)) }
        if speed == .frozen {
            // A static screenshot state: elapsed 14.0 s with a full meter history (56 bars), then nothing more.
            elapsed = Self.frozenElapsed
            for i in 0..<56 { continuation.yield(tick(at: i)) }
            macAudioEvents()
            if liveTextEnabled, let text = script.liveText(at: elapsed) { continuation.yield(.liveText(text)) }
            return
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await self?.step()
            }
        }
    }

    private func step() {
        guard !isFinished, !isPaused else { return }
        elapsed += Self.tickInterval
        tickIndex += 1
        macAudioEvents()
        guard !isPaused else { return }
        continuation.yield(tick(at: tickIndex))
        guard liveTextEnabled else { return }
        let scriptTime = speed == .instant ? elapsed * 10 : elapsed
        if let text = script.liveText(at: scriptTime), text != lastLiveText {
            lastLiveText = text
            continuation.yield(.liveText(text))
        }
    }

    /// The `silent` notice and the `lost` stop, once each, when the recording reaches their time.
    private func macAudioEvents() {
        guard sources.includesSystemAudio else { return }
        if macAudio == .silent, !silentNoticeSent, elapsed >= Self.silentAfter {
            silentNoticeSent = true
            continuation.yield(.notice(.systemAudioSilent))
        }
        if macAudio == .lost, !systemLost, elapsed >= Self.lostAfter {
            systemLost = true
            if sources == .macAudio {
                isPaused = true
                continuation.yield(.paused(.routeLost))
            } else {
                continuation.yield(.notice(.systemAudioLost))
            }
        }
    }

    private var macAudioAudible: Bool { macAudio != .silent && !systemLost }

    private func tick(at i: Int) -> RecordingEvent {
        switch sources {
        case .microphone:
            .tick(elapsed: elapsed, level: Self.level(at: i))
        case .both:
            .tick(elapsed: elapsed, level: Self.level(at: i), systemLevel: macAudioAudible ? Self.systemLevel(at: i) : 0)
        case .macAudio:
            .tick(elapsed: elapsed, level: macAudioAudible ? Self.systemLevel(at: i) : 0)
        }
    }

    static func level(at i: Int) -> Float {
        let base = 0.4 + 0.25 * sin(Double(i) * 0.37) + 0.1 * sin(Double(i) * 1.3)
        return Swift.max(0, Swift.min(1, Float(base) + noise[i % noise.count]))
    }

    /// Mac audio's level: a second table, out of phase with the microphone's, so two meters never look the same.
    static func systemLevel(at i: Int) -> Float {
        let base = 0.35 + 0.3 * sin(Double(i) * 0.23 + 1.7) + 0.08 * sin(Double(i) * 0.9)
        return Swift.max(0, Swift.min(1, Float(base) + noise[(i + 7) % noise.count]))
    }

    public func pause() {
        guard !isPaused, !isFinished else { return }
        isPaused = true
        continuation.yield(.paused(.user))
    }

    public func resume() {
        guard isPaused, !isFinished else { return }
        isPaused = false
        // A Mac-audio-only recording that lost Mac audio gets it back on resume (the real tap is rebuilt).
        if sources == .macAudio { systemLost = false }
        continuation.yield(.resumed)
    }

    public func markMoment() -> TimeInterval {
        marks.append(elapsed)
        return elapsed
    }

    public func setLiveTextEnabled(_ enabled: Bool) {
        guard enabled != liveTextEnabled else { return }
        liveTextEnabled = enabled
        if !enabled { continuation.yield(.liveTextUnavailable(.pausedInBackground)) }
    }

    public func stop() async throws -> CapturedAudio {
        finish()
        let peaks = try SyntheticAudio.write(to: url, duration: script.duration, segments: script.audioSegments)
        var writtenStems: CaptureStems?
        if sources == .both {
            let parts = Self.stemSegments(script, macAudio: macAudio)
            _ = try SyntheticAudio.write(to: stems.mic, duration: script.duration, segments: parts.mic)
            _ = try SyntheticAudio.write(to: stems.system, duration: script.duration, segments: parts.system)
            writtenStems = stems
        }
        return CapturedAudio(url: url, duration: script.duration, marks: marks, peaks: peaks,
                             detail: Self.detail(sources), stems: writtenStems)
    }

    /// Which segments each stem holds: the script's remote speakers on the system stem, everyone else on the
    /// microphone's; with Mac audio `silent`, nothing on the system stem and everyone on the microphone's.
    static func stemSegments(_ script: FakeScript, macAudio: FakeMacAudio)
        -> (mic: [(TimeRange, SyntheticPerson)], system: [(TimeRange, SyntheticPerson)]) {
        var mic: [(TimeRange, SyntheticPerson)] = []
        var system: [(TimeRange, SyntheticPerson)] = []
        for segment in script.segments {
            let part = (segment.range, script.persons[segment.speakerKey] ?? .stranger)
            if macAudio != .silent, script.remoteSpeakers.contains(segment.speakerKey) {
                system.append(part)
            } else {
                mic.append(part)
            }
        }
        return (mic, system)
    }

    static func detail(_ sources: CaptureSources) -> CaptureDetail {
        guard sources != .microphone else {
            return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: CaptureDetail.Input.fake)
        }
        return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: macAudioInput,
                             sources: sources.detailValue, outputRoute: CaptureDetail.OutputRoute.headphones)
    }

    public func discard() {
        finish()
        try? FileManager.default.removeItem(at: url)
        if sources == .both {
            try? FileManager.default.removeItem(at: stems.mic)
            try? FileManager.default.removeItem(at: stems.system)
        }
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        ticker?.cancel()
        ticker = nil
        continuation.finish()
    }
}
