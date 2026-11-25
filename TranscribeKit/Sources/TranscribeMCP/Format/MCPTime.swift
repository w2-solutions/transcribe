import Foundation
import TranscribeCore

/// Times in tool output.
enum MCPTime {
    /// A time from the start of a recording, rounded down: "3:12", or "0:03:12" with `longForm` (recordings of an
    /// hour or more use the long form on every line, so times line up).
    static func stamp(_ s: Double, longForm: Bool) -> String {
        let total = max(0, Int(s.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return longForm ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", total / 60, sec)
    }

    /// "2026-11-18T14:31:00+11:00": seconds precision, always a numeric offset (never "Z").
    static func iso(_ d: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return f.string(from: d)
    }

    /// A recording's length: "12:48", "1:02:03".
    static func length(_ s: Double) -> String { DisplayFormat.duration(s) }
}
