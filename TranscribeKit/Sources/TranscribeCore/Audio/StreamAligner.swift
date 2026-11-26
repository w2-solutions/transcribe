import Foundation

/// Puts the microphone and Mac audio of a Both recording on one timeline (Mac audio, decided 2026-11-26). Pure: it
/// has no clock of its own and is driven only by the chunks and the host times it is given.
///
/// Both streams arrive as 16 kHz mono chunks, each stamped with the host time of its first sample (seconds on the
/// host clock; nil when the source could not say). The microphone's first stamped chunk anchors the timeline: it is
/// placed at the current position, and every later stamped chunk at `base + round((hostSeconds − anchor) ×
/// sampleRate)`. Mac audio that arrives before the microphone's first chunk is held until it does (or, past
/// `maxLagFrames` of it, anchors the timeline itself), so which stream's callback ran first never changes the result.
/// Compared with where that stream's previous chunk ended:
/// - within `toleranceFrames` (20 ms): appended as it is, so resampler delay and callback jitter never move audio;
/// - later than that: the gap is filled with zeros first (a late start, a dropped buffer, a rebuilt tap);
/// - earlier than that: that many leading samples are dropped (the stream ran ahead of the clock, or its audio
///   overlaps zeros already put in for it).
/// A chunk without a host time is appended as it is.
///
/// A stream more than `maxLagFrames` (500 ms) behind the other is filled with zeros up to it, so one stream that
/// stalls or stops never holds the other back; audio it sends later for that stretch is dropped as early. A stream
/// marked lost is filled at once, on every push, until `markRestored`.
///
/// Output is the stretch both streams now cover, as two arrays of equal length (`mic`, `system`), in order. Nothing
/// is ever emitted twice or out of order. `rebase()` (a pause) and `finish()` (stop) pad the shorter stream with zeros
/// to the longer and emit everything; after `rebase()` the next stamped chunk anchors the timeline again, so a pause
/// is never filled with zeros.
public struct StreamAligner: Sendable {
    /// Frames newly covered by both streams, of equal length.
    public struct Output: Sendable, Equatable {
        public var mic: [Float]
        public var system: [Float]
        public init(mic: [Float] = [], system: [Float] = []) {
            precondition(mic.count == system.count, "StreamAligner.Output: streams of different lengths")
            self.mic = mic; self.system = system
        }
        public var count: Int { mic.count }
        public var isEmpty: Bool { mic.isEmpty }
        /// `clamp(mic + system, −1, 1)`: what the recording's main file gets.
        public func mixed() -> [Float] {
            var out = [Float](repeating: 0, count: mic.count)
            for i in 0..<mic.count {
                let a = mic[i].isFinite ? mic[i] : 0
                let b = system[i].isFinite ? system[i] : 0
                out[i] = Swift.min(1, Swift.max(-1, a + b))
            }
            return out
        }
        public mutating func append(_ other: Output) {
            mic.append(contentsOf: other.mic)
            system.append(contentsOf: other.system)
        }
    }

    public static let defaultSampleRate = 16_000
    /// 20 ms at 16 kHz: offsets up to this are left alone.
    public static let defaultToleranceFrames = 320
    /// 500 ms at 16 kHz: a stream further behind than this is filled with zeros.
    public static let defaultMaxLagFrames = 8_000

    public let sampleRate: Int
    public let toleranceFrames: Int
    public let maxLagFrames: Int

    /// Host time (seconds) of the timeline's anchor, and the timeline position it stands for.
    private var anchor: Double?
    private var base = 0
    /// Per stream (0 mic, 1 system): the absolute position where its next sample goes, and the samples from
    /// `emitted` up to there that are not emitted yet.
    private var written = [0, 0]
    private var pending: [[Float]] = [[], []]
    private var lost = [false, false]
    /// Stamped Mac audio that came before the microphone anchored the timeline.
    private var held: [(samples: [Float], host: Double)] = []
    private var heldFrames = 0
    public private(set) var emitted = 0

    /// Zeros put in for gaps (not counting lag fills and the padding at `rebase()` and `finish()`), and samples
    /// dropped as early. Log-only.
    public private(set) var insertedFrames = 0
    public private(set) var droppedFrames = 0
    /// Zeros put in because a stream lagged by more than `maxLagFrames`, or was lost.
    public private(set) var lagFilledFrames = 0

    public init(sampleRate: Int = StreamAligner.defaultSampleRate,
                toleranceFrames: Int = StreamAligner.defaultToleranceFrames,
                maxLagFrames: Int = StreamAligner.defaultMaxLagFrames) {
        self.sampleRate = sampleRate
        self.toleranceFrames = toleranceFrames
        self.maxLagFrames = maxLagFrames
    }

    private static func index(_ stream: CaptureStream) -> Int { stream == .mic ? 0 : 1 }

    /// Where `stream`'s next sample goes on the timeline (tests and logs).
    public func position(of stream: CaptureStream) -> Int { written[Self.index(stream)] }

    /// Whether `stream` was marked lost (it is filled with zeros from then on).
    public func isLost(_ stream: CaptureStream) -> Bool { lost[Self.index(stream)] }

    /// Places one chunk of `stream` and returns what both streams now cover.
    public mutating func push(_ stream: CaptureStream, _ samples: [Float], hostSeconds: Double?) -> Output {
        let i = Self.index(stream)
        guard !lost[i] else { return fillLagging() }
        let host = hostSeconds.flatMap { $0.isFinite ? $0 : nil }
        if let host, anchor == nil {
            if i == 0 {
                anchorAndReplay(host, on: 0)
            } else {
                held.append((samples, host))
                heldFrames += samples.count
                // The microphone is this late: Mac audio anchors the timeline itself.
                if heldFrames > maxLagFrames { anchorAndReplay(held[0].host, on: 1) }
                return fillLagging()
            }
        }
        place(i, samples, host: host)
        return fillLagging()
    }

    /// Anchors the timeline at `host` (the position of stream `i`), then places the held Mac audio.
    private mutating func anchorAndReplay(_ host: Double, on i: Int) {
        anchor = host
        base = written[i]
        let early = held
        held = []
        heldFrames = 0
        for chunk in early { place(1, chunk.samples, host: chunk.host) }
    }

    /// Places one chunk of stream `i` by its host time (or straight after the last one without a host time).
    private mutating func place(_ i: Int, _ samples: [Float], host: Double?) {
        var chunk = samples[...]
        if let host, anchor != nil {
            let target = base + Int(((host - (anchor ?? host)) * Double(sampleRate)).rounded())
            let offset = target - written[i]
            if offset > toleranceFrames {
                appendZeros(offset, to: i)
                insertedFrames += offset
            } else if offset < -toleranceFrames {
                let drop = Swift.min(-offset, chunk.count)
                chunk = chunk.dropFirst(drop)
                droppedFrames += drop
            }
        }
        if !chunk.isEmpty {
            pending[i].append(contentsOf: chunk)
            written[i] += chunk.count
        }
    }

    /// `stream` stopped for good (Mac audio lost): it is filled with zeros up to the other from now on, and its
    /// later chunks are ignored.
    public mutating func markLost(_ stream: CaptureStream) -> Output {
        lost[Self.index(stream)] = true
        if stream == .system { held = []; heldFrames = 0 }
        return fillLagging()
    }

    /// `stream` came back after `markLost` (Mac audio rebuilt after a device change). It was filled with zeros up to
    /// the other stream, so its next stamped chunk is placed by its host time against the same anchor, as after any
    /// gap. Returns what both streams now cover.
    public mutating func markRestored(_ stream: CaptureStream) -> Output {
        lost[Self.index(stream)] = false
        return fillLagging()
    }

    /// Before a pause ends: pads the shorter stream to the longer, emits everything, and clears the anchor so the
    /// next stamped chunk starts the timeline again where it stands (the pause leaves no zeros).
    public mutating func rebase() -> Output {
        let out = padAndDrain()
        anchor = nil
        base = emitted
        return out
    }

    /// At stop: pads the shorter stream to the longer and emits everything.
    public mutating func finish() -> Output { padAndDrain() }

    // MARK: Internals

    private mutating func appendZeros(_ n: Int, to i: Int) {
        guard n > 0 else { return }
        pending[i].append(contentsOf: repeatElement(Float(0), count: n))
        written[i] += n
    }

    /// Fills a lost stream, or one more than `maxLagFrames` behind, up to the other; then drains.
    private mutating func fillLagging() -> Output {
        let leader = Swift.max(written[0], written[1])
        for i in 0..<2 {
            let lag = leader - written[i]
            if lag > 0, lost[i] || lag > maxLagFrames {
                appendZeros(lag, to: i)
                lagFilledFrames += lag
            }
        }
        return drain()
    }

    private mutating func padAndDrain() -> Output {
        // Mac audio still waiting for a microphone that never came: it anchors the timeline itself.
        if let first = held.first { anchorAndReplay(first.host, on: 1) }
        let leader = Swift.max(written[0], written[1])
        for i in 0..<2 { appendZeros(leader - written[i], to: i) }
        return drain()
    }

    private mutating func drain() -> Output {
        let ready = Swift.min(written[0], written[1]) - emitted
        guard ready > 0 else { return Output() }
        let out = Output(mic: Array(pending[0].prefix(ready)), system: Array(pending[1].prefix(ready)))
        pending[0].removeFirst(ready)
        pending[1].removeFirst(ready)
        emitted += ready
        return out
    }
}
