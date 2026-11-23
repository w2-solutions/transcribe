import Foundation

public enum SpeakerTimeline {
    /// For waveform colouring: which speaker's (effective) turn covers the centre of each bar. nil = none.
    public static func speakerKeys(barCount: Int, duration: TimeInterval, turns: [Turn]) -> [SpeakerKey?] {
        guard barCount > 0, duration > 0 else { return [] }
        return (0..<barCount).map { i in
            let t = (Double(i) + 0.5) / Double(barCount) * duration
            return turns.first(where: { $0.range.contains(t) })?.effectiveSpeakerKey
        }
    }
    /// Turn whose range contains t, else the last turn starting before t.
    public static func turnIndex(at t: TimeInterval, in turns: [Turn]) -> Int? {
        if let i = turns.firstIndex(where: { $0.range.contains(t) }) { return i }
        return turns.lastIndex(where: { $0.range.start <= t })
    }
}
