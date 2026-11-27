import Foundation

/// Puts the microphone and Mac audio of a Both recording on one timeline (Mac audio, decided 2026-11-26; placement
/// rule changed 2026-11-27). Pure and deterministic: it has no clock of its own and is driven only by the chunks and the
/// host times it is given.
///
/// Both streams arrive as 16 kHz mono chunks, each stamped with the host time of its first sample (seconds on the
/// host clock; nil when the source could not say). The microphone's first stamped chunk anchors the timeline: it is
/// placed at the current position, and host time `h` stands for position `base + round((h − anchor) × sampleRate)`
/// (where host time says a chunk belongs). Mac audio that arrives before the microphone's first chunk is held until it
/// does (or, past `maxLagFrames` of it, anchors the timeline itself), so which stream's callback ran first never
/// changes the result.
///
/// Per stream:
/// - Its first stamped chunk (after the anchor, `rebase()`, `markRestored`, a lag fill, a correction that could not
///   drop enough, or a jump in its own host times) is placed where host time says: within `toleranceFrames` (20 ms)
///   it is appended as it is; later, the gap is filled with zeros first (a late start); earlier, that many leading
///   samples are dropped.
/// - A jump in the stream's own host times, a chunk starting more than `discontinuityFrames` (80 ms) after where its
///   previous stamped chunk ended, is a restart (Mac audio's aggregate rebuilt, the microphone's engine restarted, a
///   gap the capture could not fill): that chunk is placed by host time at once, so the zeros go where the gap was
///   (review 2026-11-27). A stream's own consecutive stamps are steady within a run, so jitter never trips it; a
///   jump backwards does not, and is left to the median.
/// - Every later chunk is appended straight after the one before, whatever its host time. Its offset (where host time
///   says it belongs minus where the stream's write position is) is only recorded, over the last `correctionWindowFrames`
///   (2 s) of that stream's stamped chunks.
/// - The stream is moved back to host time only when the offset is persistently large: once the window is full and
///   the median offset (weighted by frames) is beyond `correctionFrames` (80 ms) either way (slow drift between the
///   two clocks), the median is corrected in steps of at most `correctionStepFrames` (20 ms), one at the start of a
///   chunk and at most one per `correctionStepIntervalFrames` (250 ms) of the stream (zeros inserted when late,
///   leading samples dropped when early), so one chunk's jitter never moves audio and no single cut or hole is longer
///   than 20 ms (review 2026-11-27); offsets are not recorded until it is paid. A single chunk's offset beyond
///   `hardCorrectionFrames` (500 ms: a real stall or restart) is corrected at once, by that offset. Either way the
///   window starts again.
/// - A chunk without a host time is appended as it is and not recorded.
/// Why (2026-11-27): the old rule placed every stamped chunk by host time with a 20 ms tolerance, which is exactly one
/// IO cycle of Bluetooth headphones in call mode (16 kHz), so ordinary late cycles and host-time jitter became holes of
/// zeros and dropped samples, and Mac audio was choppy. The capture now fills the frames the device skipped itself
/// (`TapGapFill`), so each stream arrives contiguous, and only a lasting offset is a real one.
///
/// A stream more than `maxLagFrames` (500 ms) behind the other is filled with zeros up to it, so one stream that
/// stalls or stops never holds the other back; its next stamped chunk is placed by host time again, so audio it sends
/// later for that stretch is dropped as early. A stream marked lost is filled at once, on every push, until
/// `markRestored`.
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

    /// One stream's corrections so far (log-only).
    public struct Counters: Sendable, Equatable {
        /// Zeros put in to move the stream later (placement and corrections; not lag fills or padding).
        public var inserted = 0
        /// Leading samples dropped to move the stream earlier.
        public var dropped = 0
        /// Zeros put in because the stream lagged by more than `maxLagFrames`, or was lost.
        public var filled = 0
        /// Times the stream was moved (a placement or correction that inserted or dropped anything).
        public var corrections = 0
        public init(inserted: Int = 0, dropped: Int = 0, filled: Int = 0, corrections: Int = 0) {
            self.inserted = inserted; self.dropped = dropped; self.filled = filled; self.corrections = corrections
        }
    }

    public static let defaultSampleRate = 16_000
    /// 20 ms at 16 kHz: a first placement this close to host time is left alone.
    public static let defaultToleranceFrames = 320
    /// 500 ms at 16 kHz: a stream further behind than this is filled with zeros.
    public static let defaultMaxLagFrames = 8_000
    /// 80 ms at 16 kHz: a median offset beyond this is corrected (four call-mode IO cycles of 20 ms).
    public static let defaultCorrectionFrames = 1_280
    /// 2 s at 16 kHz: the stretch of a stream's chunks whose median offset is taken.
    public static let defaultCorrectionWindowFrames = 32_000
    /// 250 ms at 16 kHz: at most one median correction step per this much of a stream.
    public static let defaultCorrectionStepIntervalFrames = 4_000

    public let sampleRate: Int
    public let toleranceFrames: Int
    public let maxLagFrames: Int
    public let correctionFrames: Int
    public let correctionWindowFrames: Int
    /// A single chunk offset beyond this is corrected at once (default `maxLagFrames`).
    public let hardCorrectionFrames: Int
    /// A median correction moves the stream by at most this much at once (default `toleranceFrames`).
    public let correctionStepFrames: Int
    public let correctionStepIntervalFrames: Int
    /// A stream's chunk starting this much after its previous chunk's end (host time) is placed again (default
    /// `correctionFrames`).
    public let discontinuityFrames: Int

    /// Host time (seconds) of the timeline's anchor, and the timeline position it stands for.
    private var anchor: Double?
    private var base = 0
    /// Per stream (0 mic, 1 system): the absolute position where its next sample goes, and the samples from
    /// `emitted` up to there that are not emitted yet.
    private var written = [0, 0]
    private var pending: [[Float]] = [[], []]
    private var lost = [false, false]
    /// Per stream: whether its next stamped chunk is placed by host time (rather than appended).
    private var needsPlacement = [true, true]
    /// Per stream: the offsets (frames) of its recent stamped chunks with their lengths, oldest first, and their total
    /// length.
    private var window: [[(offset: Int, frames: Int)]] = [[], []]
    private var windowFrames = [0, 0]
    /// Per stream: the median correction still to make (frames; positive inserts zeros), and the stream's frames since
    /// its last step.
    private var debt = [0, 0]
    private var framesSinceStep = [0, 0]
    /// Per stream: the host time (seconds) where its last chunk ended, by its own stamps.
    private var hostEnd: [Double?] = [nil, nil]
    private var counters = [Counters(), Counters()]
    /// Stamped Mac audio that came before the microphone anchored the timeline.
    private var held: [(samples: [Float], host: Double)] = []
    private var heldFrames = 0
    public private(set) var emitted = 0

    /// Both streams' zeros put in to move them later, and samples dropped to move them earlier. Log-only.
    public var insertedFrames: Int { counters[0].inserted + counters[1].inserted }
    public var droppedFrames: Int { counters[0].dropped + counters[1].dropped }
    /// Zeros put in because a stream lagged by more than `maxLagFrames`, or was lost.
    public var lagFilledFrames: Int { counters[0].filled + counters[1].filled }
    /// Times either stream was moved.
    public var corrections: Int { counters[0].corrections + counters[1].corrections }

    public init(sampleRate: Int = StreamAligner.defaultSampleRate,
                toleranceFrames: Int = StreamAligner.defaultToleranceFrames,
                maxLagFrames: Int = StreamAligner.defaultMaxLagFrames,
                correctionFrames: Int = StreamAligner.defaultCorrectionFrames,
                correctionWindowFrames: Int = StreamAligner.defaultCorrectionWindowFrames,
                hardCorrectionFrames: Int? = nil,
                correctionStepFrames: Int? = nil,
                correctionStepIntervalFrames: Int = StreamAligner.defaultCorrectionStepIntervalFrames,
                discontinuityFrames: Int? = nil) {
        self.sampleRate = sampleRate
        self.toleranceFrames = toleranceFrames
        self.maxLagFrames = maxLagFrames
        self.correctionFrames = correctionFrames
        self.correctionWindowFrames = correctionWindowFrames
        self.hardCorrectionFrames = hardCorrectionFrames ?? maxLagFrames
        self.correctionStepFrames = Swift.max(1, correctionStepFrames ?? toleranceFrames)
        self.correctionStepIntervalFrames = correctionStepIntervalFrames
        self.discontinuityFrames = discontinuityFrames ?? correctionFrames
    }

    private static func index(_ stream: CaptureStream) -> Int { stream == .mic ? 0 : 1 }

    /// Where `stream`'s next sample goes on the timeline (tests and logs).
    public func position(of stream: CaptureStream) -> Int { written[Self.index(stream)] }

    /// Whether `stream` was marked lost (it is filled with zeros from then on).
    public func isLost(_ stream: CaptureStream) -> Bool { lost[Self.index(stream)] }

    /// `stream`'s corrections so far (logs).
    public func counters(of stream: CaptureStream) -> Counters { counters[Self.index(stream)] }

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

    /// Places one chunk of stream `i`: by its host time when it is the first since a placement was asked for (or its
    /// own host times jumped), else straight after the one before, correcting a persistent or very large offset first
    /// (see the type's doc).
    private mutating func place(_ i: Int, _ samples: [Float], host: Double?) {
        var chunk = samples[...]
        let duration = Double(samples.count) / Double(sampleRate)
        if let host {
            if let end = hostEnd[i], host - end > Double(discontinuityFrames) / Double(sampleRate) {
                needsPlacement[i] = true
            }
            hostEnd[i] = host + duration
        } else if let end = hostEnd[i] {
            hostEnd[i] = end + duration
        }
        if let host, let anchor {
            let target = base + Int(((host - anchor) * Double(sampleRate)).rounded())
            let offset = target - written[i]
            if needsPlacement[i] {
                needsPlacement[i] = false
                resetWindow(i)
                if abs(offset) > toleranceFrames { move(i, by: offset, chunk: &chunk) }
            } else if abs(offset) > hardCorrectionFrames {
                move(i, by: offset, chunk: &chunk)
                resetWindow(i)
            } else if debt[i] != 0 {
                payDebt(i, chunk: &chunk)
            } else if let median = record(i, offset: offset, frames: chunk.count), abs(median) > correctionFrames {
                resetWindow(i)
                debt[i] = median
                framesSinceStep[i] = correctionStepIntervalFrames
                payDebt(i, chunk: &chunk)
            }
        }
        if !chunk.isEmpty {
            pending[i].append(contentsOf: chunk)
            written[i] += chunk.count
        }
        framesSinceStep[i] += chunk.count
    }

    /// One step of a median correction, at most `correctionStepFrames`, once `correctionStepIntervalFrames` of the
    /// stream have passed since the last.
    private mutating func payDebt(_ i: Int, chunk: inout ArraySlice<Float>) {
        guard debt[i] != 0, framesSinceStep[i] >= correctionStepIntervalFrames else { return }
        let step = Swift.max(-correctionStepFrames, Swift.min(correctionStepFrames, debt[i]))
        debt[i] -= step
        framesSinceStep[i] = 0
        move(i, by: step, chunk: &chunk)
    }

    /// Moves stream `i` by `offset` frames at the start of `chunk`: zeros first when positive, leading samples dropped
    /// when negative. A drop longer than the chunk leaves the next stamped chunk to be placed by host time.
    private mutating func move(_ i: Int, by offset: Int, chunk: inout ArraySlice<Float>) {
        if offset > 0 {
            appendZeros(offset, to: i)
            counters[i].inserted += offset
            counters[i].corrections += 1
        } else if offset < 0 {
            let drop = Swift.min(-offset, chunk.count)
            chunk = chunk.dropFirst(drop)
            counters[i].dropped += drop
            if drop > 0 { counters[i].corrections += 1 }
            if drop < -offset { needsPlacement[i] = true }
        }
    }

    /// Records one chunk's offset for stream `i`. Returns the median offset (weighted by frames) once the window holds
    /// `correctionWindowFrames` of chunks, else nil.
    private mutating func record(_ i: Int, offset: Int, frames: Int) -> Int? {
        guard frames > 0 else { return nil }
        window[i].append((offset, frames))
        windowFrames[i] += frames
        var drop = 0
        while drop < window[i].count - 1, windowFrames[i] - window[i][drop].frames >= correctionWindowFrames {
            windowFrames[i] -= window[i][drop].frames
            drop += 1
        }
        if drop > 0 { window[i].removeFirst(drop) }
        guard windowFrames[i] >= correctionWindowFrames else { return nil }
        let sorted = window[i].sorted { $0.offset < $1.offset }
        var covered = 0
        for entry in sorted {
            covered += entry.frames
            if 2 * covered >= windowFrames[i] { return entry.offset }
        }
        return sorted.last?.offset
    }

    /// Starts the stream's offset window again, and drops any median correction still to make.
    private mutating func resetWindow(_ i: Int) {
        window[i].removeAll(keepingCapacity: true)
        windowFrames[i] = 0
        debt[i] = 0
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
        let i = Self.index(stream)
        lost[i] = false
        needsPlacement[i] = true
        resetWindow(i)
        return fillLagging()
    }

    /// Before a pause ends: pads the shorter stream to the longer, emits everything, and clears the anchor so the
    /// next stamped chunk starts the timeline again where it stands (the pause leaves no zeros).
    public mutating func rebase() -> Output {
        let out = padAndDrain()
        anchor = nil
        base = emitted
        for i in 0..<2 {
            needsPlacement[i] = true
            resetWindow(i)
            hostEnd[i] = nil
        }
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

    /// Fills a lost stream, or one more than `maxLagFrames` behind, up to the other; then drains. A stream filled
    /// this way is placed by host time again at its next stamped chunk.
    private mutating func fillLagging() -> Output {
        let leader = Swift.max(written[0], written[1])
        for i in 0..<2 {
            let lag = leader - written[i]
            if lag > 0, lost[i] || lag > maxLagFrames {
                appendZeros(lag, to: i)
                counters[i].filled += lag
                needsPlacement[i] = true
                resetWindow(i)
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
