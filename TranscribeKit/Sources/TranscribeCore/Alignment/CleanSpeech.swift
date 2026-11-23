import Foundation

public enum CleanSpeech {
    /// Speaker's segments minus all other speakers' segments, trimmed by spanEdgeTrim each side, pieces ≥ minCleanSpan.
    public static func spans(for key: SpeakerKey, in segments: [SpeakerSegment],
                             config: AlignmentConfig = .default) -> [TimeRange] {
        let own = union(segments.lazy.filter { $0.speakerKey == key }.map(\.range))
        guard !own.isEmpty else { return [] }
        let others = union(segments.lazy.filter { $0.speakerKey != key }.map(\.range))
        let trim = Swift.max(0, config.spanEdgeTrim)
        return subtract(own, others).compactMap { piece in
            let start = piece.start + trim, end = piece.end - trim
            guard end - start >= config.minCleanSpan - 1e-9, end > start else { return nil }
            return TimeRange(start: start, end: end)
        }
    }

    public static func seconds(_ spans: [TimeRange]) -> TimeInterval { spans.reduce(0) { $0 + $1.duration } }

    /// Longest spans first until maxEmbedSeconds is reached, then re-sorted by start.
    public static func embeddingSpans(_ spans: [TimeRange], config: AlignmentConfig = .default) -> [TimeRange] {
        let byLength = spans.enumerated().sorted {
            ($1.element.duration, $0.element.start, $0.offset) < ($0.element.duration, $1.element.start, $1.offset)
        }.map(\.element)
        var chosen: [TimeRange] = []
        var total: TimeInterval = 0
        for span in byLength {
            guard total < config.maxEmbedSeconds else { break }
            chosen.append(span)
            total += span.duration
        }
        return chosen.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Total segment time (union) for a speaker — "spoke for 0:13".
    public static func totalSeconds(for key: SpeakerKey, in segments: [SpeakerSegment]) -> TimeInterval {
        seconds(union(segments.lazy.filter { $0.speakerKey == key }.map(\.range)))
    }

    /// Up to `max` "Listen" clips: the speaker's longest non-overlap turns, each cut to its first sentence
    /// (words up to the first . ? !), clamped to listenClipMin...listenClipMax. Returns (range, quote).
    ///
    /// Turns are matched by effective key. If the speaker has fewer than `max` non-overlap turns, the longest
    /// overlapping turns fill the remaining places, starting at their first non-overlap word. A sentence shorter
    /// than `listenClipMin` takes following words of the same turn; if the turn is still too short, the range is
    /// padded to `listenClipMin`. A clip longer than `listenClipMax` is cut there and its quote ends with "…".
    /// Clips are returned in time order.
    public static func listenClips(for key: SpeakerKey, turns: [Turn], max: Int = 2,
                                   config: AlignmentConfig = .default) -> [(range: TimeRange, quote: String)] {
        guard max > 0 else { return [] }
        let own = turns.filter { $0.effectiveSpeakerKey == key && !$0.words.isEmpty }
        func longestFirst(_ list: [Turn]) -> [Turn] {
            list.enumerated().sorted {
                ($1.element.range.duration, $0.element.range.start, $0.offset)
                    < ($0.element.range.duration, $1.element.range.start, $1.offset)
            }.map(\.element)
        }
        let picked = (longestFirst(own.filter { !$0.hasOverlap }) + longestFirst(own.filter(\.hasOverlap)))
            .compactMap { clip(from: $0, config: config) }
            .prefix(max)
        return picked.sorted { $0.range.start < $1.range.start }
    }

    private static func clip(from turn: Turn, config: AlignmentConfig) -> (range: TimeRange, quote: String)? {
        var words = turn.words[...]
        if turn.hasOverlap { words = words.drop(while: \.isOverlap) }
        guard let first = words.first else { return nil }
        let start = first.range.start
        // First sentence, then extend within the turn up to the minimum length.
        var count = (words.firstIndex { TurnBuilder.endsSentence($0.text) }.map { $0 - words.startIndex + 1 }) ?? words.count
        var end = words[words.startIndex + count - 1].range.end
        while end - start < config.listenClipMin && count < words.count {
            count += 1
            end = Swift.max(end, words[words.startIndex + count - 1].range.end)
        }
        var chosen = Array(words.prefix(count))
        var truncated = false
        if end - start > config.listenClipMax {
            let limit = start + config.listenClipMax
            let fitting = chosen.prefix { $0.range.end <= limit + 1e-9 }
            chosen = fitting.isEmpty ? [chosen[0]] : Array(fitting)
            truncated = true
            end = limit
        }
        if end - start < config.listenClipMin { end = start + config.listenClipMin }
        var quote = chosen.map(\.text).joined(separator: " ")
        if truncated {
            while let last = quote.last, last == "," || last == ";" || last == ":" { quote.removeLast() }
            quote += "…"
        }
        return (TimeRange(start: start, end: end), quote)
    }

    // MARK: - Interval helpers

    /// Sorted, merged, positive-length ranges (touching ranges merge).
    static func union<S: Sequence>(_ ranges: S) -> [TimeRange] where S.Element == TimeRange {
        let sorted = ranges.filter { $0.duration > 0 }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var merged: [TimeRange] = []
        for r in sorted {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1].end = Swift.max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// `a` minus `b`, both sorted and merged (as returned by `union`).
    static func subtract(_ a: [TimeRange], _ b: [TimeRange]) -> [TimeRange] {
        var result: [TimeRange] = []
        var j = 0
        for r in a {
            var cursor = r.start
            while j < b.count && b[j].end <= cursor { j += 1 }
            var k = j
            while k < b.count && b[k].start < r.end {
                if b[k].start > cursor { result.append(TimeRange(start: cursor, end: b[k].start)) }
                cursor = Swift.max(cursor, b[k].end)
                k += 1
            }
            if cursor < r.end { result.append(TimeRange(start: cursor, end: r.end)) }
        }
        return result
    }
}
