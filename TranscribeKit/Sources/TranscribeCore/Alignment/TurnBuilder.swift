import Foundation

public enum TurnBuilder {
    /// Speaker turns from words and diarizer segments (§5.1). Turn ids = Turn.stableID(index:).
    ///
    /// 1. Words and segments are sorted by start time (segments may overlap).
    /// 2. Each word goes to the speaker with the largest union overlap; ties go to the speaker whose
    ///    segment contains the word's midpoint, then to the lower key. A word with no overlap takes the
    ///    nearest segment edge within `nearestSegmentTolerance`, else the previous word's speaker
    ///    (the first word takes the next word's). With no segments every word gets `nil`.
    /// 3. Islands of at most `islandMaxWords` words lasting under `islandMaxDuration`, with the same other
    ///    speaker on both sides, take the surrounding speaker.
    /// 4. `isOverlap` is set when a speaker other than the word's final speaker covers at least
    ///    `overlapFlagFraction` of it.
    /// 5. Turns break on a speaker change or a gap of at least `sameSpeakerGapSplit`.
    public static func speakerTurns(words: [TimedWord], segments: [SpeakerSegment],
                                    config: AlignmentConfig = .default) -> [Turn] {
        guard !words.isEmpty else { return [] }
        var sorted = sortedByTime(words)
        let index = SegmentIndex(segments)

        guard !index.isEmpty else {
            for i in sorted.indices { sorted[i].isOverlap = false }
            return group(sorted, speakers: [Int?](repeating: nil, count: sorted.count), keys: [], config: config)
        }

        var scratch = SegmentIndex.Scratch()
        var speakers = sorted.map { index.assign($0, tolerance: config.nearestSegmentTolerance, scratch: &scratch) }
        carryOver(&speakers)
        absorbIslands(&speakers, words: sorted, config: config)
        for i in sorted.indices {
            sorted[i].isOverlap = index.isOverlap(sorted[i], speaker: speakers[i],
                                                  fraction: config.overlapFlagFraction, scratch: &scratch)
        }
        return group(sorted, speakers: speakers, keys: index.keys, config: config)
    }

    /// Speaker-less paragraphs (speakers pending / identify off / no speech).
    /// A new paragraph starts after a gap longer than `paragraphGap`, or once the paragraph is at least
    /// `paragraphMaxSeconds` long and the previous word ends a sentence.
    public static func paragraphs(words: [TimedWord], config: AlignmentConfig = .default) -> [Turn] {
        guard !words.isEmpty else { return [] }
        let sorted = sortedByTime(words)
        var turns: [Turn] = []
        var current: [TimedWord] = []
        var paragraphStart: TimeInterval = 0
        for word in sorted {
            if let previous = current.last {
                let gap = word.range.start - previous.range.end
                let length = previous.range.end - paragraphStart
                if gap > config.paragraphGap + SegmentIndex.epsilon
                    || (length >= config.paragraphMaxSeconds - SegmentIndex.epsilon && endsSentence(previous.text)) {
                    turns.append(makeTurn(index: turns.count, key: nil, words: current))
                    current.removeAll(keepingCapacity: true)
                }
            }
            if current.isEmpty { paragraphStart = word.range.start }
            current.append(word)
        }
        if !current.isEmpty { turns.append(makeTurn(index: turns.count, key: nil, words: current)) }
        return turns
    }

    // MARK: - Steps

    /// Fills unassigned words with the previous word's speaker; leading ones take the first assigned speaker.
    static func carryOver(_ speakers: inout [Int?]) {
        guard let firstAssigned = speakers.firstIndex(where: { $0 != nil }) else { return }
        var previous = speakers[firstAssigned]
        for i in speakers.indices {
            if let s = speakers[i] { previous = s } else { speakers[i] = previous }
        }
    }

    /// Absorbs short runs sandwiched between the same other speaker. Runs are computed once from the
    /// pre-absorption labels, so the result does not depend on processing order.
    static func absorbIslands(_ speakers: inout [Int?], words: [TimedWord], config: AlignmentConfig) {
        guard config.islandMaxWords > 0, speakers.count >= 3 else { return }
        var runs: [(speaker: Int?, first: Int, last: Int)] = []
        for i in speakers.indices {
            if let last = runs.last, last.speaker == speakers[i] {
                runs[runs.count - 1].last = i
            } else {
                runs.append((speakers[i], i, i))
            }
        }
        guard runs.count >= 3 else { return }
        var result = speakers
        for r in 1..<(runs.count - 1) {
            let run = runs[r], before = runs[r - 1].speaker, after = runs[r + 1].speaker
            guard let surrounding = before, surrounding == after, run.speaker != nil, run.speaker != surrounding else { continue }
            let count = run.last - run.first + 1
            let duration = words[run.last].range.end - words[run.first].range.start
            if count <= config.islandMaxWords && duration < config.islandMaxDuration - SegmentIndex.epsilon {
                for i in run.first...run.last { result[i] = surrounding }
            }
        }
        speakers = result
    }

    static func group(_ words: [TimedWord], speakers: [Int?], keys: [SpeakerKey], config: AlignmentConfig) -> [Turn] {
        var turns: [Turn] = []
        var start = 0
        for i in 1...words.count {
            let isBoundary = i == words.count
                || speakers[i] != speakers[i - 1]
                || words[i].range.start - words[i - 1].range.end >= config.sameSpeakerGapSplit - SegmentIndex.epsilon
            guard isBoundary else { continue }
            let key = speakers[start].map { keys[$0] }
            turns.append(makeTurn(index: turns.count, key: key, words: Array(words[start..<i])))
            start = i
        }
        return turns
    }

    static func makeTurn(index: Int, key: SpeakerKey?, words: [TimedWord]) -> Turn {
        let start = words.first?.range.start ?? 0
        let end = words.reduce(start) { Swift.max($0, $1.range.end) }
        return Turn(id: Turn.stableID(index: index), speakerKey: key, range: TimeRange(start: start, end: end),
                    words: words, hasOverlap: words.contains { $0.isOverlap })
    }

    /// Stable sort by (start, end); skips the sort when the input is already ordered.
    static func sortedByTime(_ words: [TimedWord]) -> [TimedWord] {
        let ordered = zip(words, words.dropFirst()).allSatisfy {
            ($0.range.start, $0.range.end) <= ($1.range.start, $1.range.end)
        }
        if ordered { return words }
        return words.enumerated().sorted {
            ($0.element.range.start, $0.element.range.end, $0.offset) < ($1.element.range.start, $1.element.range.end, $1.offset)
        }.map(\.element)
    }

    /// True when the word ends a sentence (`.`, `?`, `!`, `…`, ignoring closing quotes and brackets).
    static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
        guard let last = text.reversed().first(where: { !closers.contains($0) && !$0.isWhitespace }) else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }
}

/// Segments sorted by start with a running maximum of ends, for fast "which segments touch [a, b]" queries.
struct SegmentIndex {
    let keys: [SpeakerKey]          // naturally ordered; index order = key order for tie-breaks
    private let starts: [Double]
    private let ends: [Double]
    private let speakers: [Int]
    private let prefixMaxEnd: [Double]

    /// Reusable buffers so per-word queries do not allocate.
    struct Scratch {
        var pieces: [(speaker: Int, start: Double, end: Double)] = []
        var totals: [(speaker: Int, length: Double)] = []
    }

    /// Tolerance for time comparisons, so boundaries like 2.4 − 2.0 behave as exactly 0.4 s.
    static let epsilon = 1e-9

    init(_ segments: [SpeakerSegment]) {
        let keys = Array(Set(segments.map(\.speakerKey))).sorted(by: SpeakerKeyOrder.less)
        let keyIndex = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        let sorted = segments.sorted {
            ($0.range.start, $0.range.end, keyIndex[$0.speakerKey]!) < ($1.range.start, $1.range.end, keyIndex[$1.speakerKey]!)
        }
        self.keys = keys
        starts = sorted.map(\.range.start)
        ends = sorted.map(\.range.end)
        speakers = sorted.map { keyIndex[$0.speakerKey]! }
        var running = -Double.infinity
        prefixMaxEnd = sorted.map { running = Swift.max(running, $0.range.end); return running }
    }

    var isEmpty: Bool { starts.isEmpty }

    /// Indices of segments that may intersect [lo, hi]: those with a running max end ≥ lo and start ≤ hi.
    private func candidates(_ lo: Double, _ hi: Double) -> Range<Int> {
        let first = partition(prefixMaxEnd) { $0 >= lo }
        let end = partition(starts) { $0 > hi }
        return first..<Swift.max(first, end)
    }

    /// First index where `predicate` holds, for a predicate that is monotone over the sorted array.
    private func partition(_ values: [Double], _ predicate: (Double) -> Bool) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(values[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// Union overlap length per speaker with [a, b], into `scratch.totals` (speaker order).
    private func overlapTotals(_ a: Double, _ b: Double, scratch: inout Scratch) {
        scratch.pieces.removeAll(keepingCapacity: true)
        scratch.totals.removeAll(keepingCapacity: true)
        guard b > a else { return }
        for i in candidates(a, b) {
            let s = Swift.max(a, starts[i]), e = Swift.min(b, ends[i])
            if e > s { scratch.pieces.append((speakers[i], s, e)) }
        }
        guard !scratch.pieces.isEmpty else { return }
        scratch.pieces.sort { ($0.speaker, $0.start) < ($1.speaker, $1.start) }
        var speaker = scratch.pieces[0].speaker, curStart = scratch.pieces[0].start, curEnd = scratch.pieces[0].end
        var total = 0.0
        for piece in scratch.pieces.dropFirst() {
            if piece.speaker != speaker {
                total += curEnd - curStart
                scratch.totals.append((speaker, total))
                speaker = piece.speaker; curStart = piece.start; curEnd = piece.end; total = 0
            } else if piece.start > curEnd {
                total += curEnd - curStart
                curStart = piece.start; curEnd = piece.end
            } else {
                curEnd = Swift.max(curEnd, piece.end)
            }
        }
        total += curEnd - curStart
        scratch.totals.append((speaker, total))
    }

    /// Lowest speaker index with a segment containing `t` (start ≤ t < end), restricted to `allowed` if given.
    private func lowestSpeakerContaining(_ t: Double, allowed: ((Int) -> Bool)? = nil) -> Int? {
        var best: Int?
        for i in candidates(t, t) where starts[i] <= t && t < ends[i] {
            let s = speakers[i]
            if let allowed, !allowed(s) { continue }
            if best == nil || s < best! { best = s }
        }
        return best
    }

    func assign(_ word: TimedWord, tolerance: Double, scratch: inout Scratch) -> Int? {
        let a = word.range.start, b = word.range.end, mid = word.range.mid
        overlapTotals(a, b, scratch: &scratch)
        if let maxLength = scratch.totals.map(\.length).max(), maxLength > Self.epsilon {
            let tied = scratch.totals.filter { $0.length >= maxLength - Self.epsilon }.map(\.speaker)
            if tied.count == 1 { return tied[0] }
            if let containing = lowestSpeakerContaining(mid, allowed: { tied.contains($0) }) { return containing }
            return tied.min()
        }
        // Zero-length word inside a segment, or no positive overlap.
        if let containing = lowestSpeakerContaining(mid) { return containing }
        var best: (distance: Double, speaker: Int)?
        for i in candidates(a - tolerance, b + tolerance) {
            let distance: Double
            if ends[i] <= a { distance = a - ends[i] }
            else if starts[i] >= b { distance = starts[i] - b }
            else { distance = 0 }
            guard distance <= tolerance + Self.epsilon else { continue }
            if best == nil || distance < best!.distance - Self.epsilon
                || (abs(distance - best!.distance) <= Self.epsilon && speakers[i] < best!.speaker) {
                best = (distance, speakers[i])
            }
        }
        return best?.speaker
    }

    /// True when a speaker other than `speaker` covers at least `fraction` of the word
    /// (for a zero-length word: when another speaker's segment contains it).
    func isOverlap(_ word: TimedWord, speaker: Int?, fraction: Double, scratch: inout Scratch) -> Bool {
        let duration = word.range.duration
        guard duration > 0 else {
            return lowestSpeakerContaining(word.range.start, allowed: { $0 != speaker }) != nil
        }
        overlapTotals(word.range.start, word.range.end, scratch: &scratch)
        let threshold = fraction * duration - Self.epsilon
        return scratch.totals.contains { $0.speaker != speaker && $0.length >= threshold }
    }
}

/// Natural ordering of speaker keys: alphabetic prefix, then the numeric suffix ("S2" < "S10" < "U1").
enum SpeakerKeyOrder {
    static func less(_ a: SpeakerKey, _ b: SpeakerKey) -> Bool {
        let (pa, na) = split(a), (pb, nb) = split(b)
        if pa != pb { return pa < pb }
        switch (na, nb) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return true
        case (_?, nil): return false
        default: return a < b
        }
    }

    private static func split(_ key: SpeakerKey) -> (prefix: Substring, number: Int?) {
        let digits = key.reversed().prefix { $0.isASCII && $0.isNumber }.count
        let prefix = key.dropLast(digits)
        return (prefix, digits > 0 ? Int(key.suffix(digits)) : nil)
    }
}
