import Foundation
import TranscribeCore

/// A scripted capture session (§7.3). Ticks every 50 ms of real time; live text follows the script timeline.
/// `stop()` always writes exactly `script.duration` seconds of SyntheticAudio.
public actor FakeLiveRecording: LiveRecording {
    public nonisolated let events: AsyncStream<RecordingEvent>
    private let continuation: AsyncStream<RecordingEvent>.Continuation
    private let script: FakeScript
    private let speed: FakeSpeed
    private let url: URL
    private var liveTextEnabled: Bool
    private var elapsed: TimeInterval = 0
    private var tickIndex = 0
    private var isPaused = false
    private var isFinished = false
    private var marks: [TimeInterval] = []
    private var lastLiveText: LiveText?
    private var ticker: Task<Void, Never>?

    static let tickInterval: TimeInterval = 0.05
    static let frozenElapsed: TimeInterval = 14.0
    /// Deterministic noise table for the level meter.
    static let noise: [Float] = [0.12, -0.05, 0.20, -0.14, 0.03, 0.17, -0.09, 0.08, -0.18, 0.15, 0.01, -0.11, 0.19, -0.02, 0.10, -0.16]

    public init(script: FakeScript, speed: FakeSpeed, request: RecordingRequest) {
        self.script = script
        self.speed = speed
        self.url = request.audioURL
        self.liveTextEnabled = request.liveText
        (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Starts emitting events. Called by FakeSpeechEngine.startRecording.
    public func begin() {
        if !liveTextEnabled { continuation.yield(.liveTextUnavailable(.modelsNotReady)) }
        if speed == .frozen {
            // A static screenshot state: elapsed 14.0 s with a full meter history (56 bars), then nothing more.
            elapsed = Self.frozenElapsed
            for i in 0..<56 { continuation.yield(.tick(elapsed: elapsed, level: Self.level(at: i))) }
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
        continuation.yield(.tick(elapsed: elapsed, level: Self.level(at: tickIndex)))
        guard liveTextEnabled else { return }
        let scriptTime = speed == .instant ? elapsed * 10 : elapsed
        if let text = script.liveText(at: scriptTime), text != lastLiveText {
            lastLiveText = text
            continuation.yield(.liveText(text))
        }
    }

    static func level(at i: Int) -> Float {
        let base = 0.4 + 0.25 * sin(Double(i) * 0.37) + 0.1 * sin(Double(i) * 1.3)
        return Swift.max(0, Swift.min(1, Float(base) + noise[i % noise.count]))
    }

    public func pause() {
        guard !isPaused, !isFinished else { return }
        isPaused = true
        continuation.yield(.paused(.user))
    }

    public func resume() {
        guard isPaused, !isFinished else { return }
        isPaused = false
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
        return CapturedAudio(url: url, duration: script.duration, marks: marks, peaks: peaks)
    }

    public func discard() {
        finish()
        try? FileManager.default.removeItem(at: url)
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        ticker?.cancel()
        ticker = nil
        continuation.finish()
    }
}
