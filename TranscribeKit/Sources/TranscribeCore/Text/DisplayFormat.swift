import Foundation

public enum DisplayFormat {
    /// 0:07, 0:20, 12:48, 1:02:03 (rounds down to whole seconds)
    public static func duration(_ t: TimeInterval) -> String {
        let s = Swift.max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// "0 minutes 14 seconds" for VoiceOver
    public static func spokenDuration(_ t: TimeInterval) -> String {
        let s = Swift.max(0, Int(t)); return "\(s / 60) minutes \(s % 60) seconds"
    }
    /// "Wed 18 Nov · 2:29 pm" (cards, transcript subtitle, appearances)
    public static func cardDate(_ d: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        format(d, "EEE d MMM", locale, timeZone) + " · " + time(d, locale: locale, timeZone: timeZone)
    }
    /// "Wed 18 Nov 2026 · 2:24 pm" (Recording screen)
    public static func longDate(_ d: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        format(d, "EEE d MMM yyyy", locale, timeZone) + " · " + time(d, locale: locale, timeZone: timeZone)
    }
    /// "18 Nov · 2:24 pm" (processing nav title)
    public static func shortDate(_ d: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        format(d, "d MMM", locale, timeZone) + " · " + time(d, locale: locale, timeZone: timeZone)
    }
    /// "18 Nov" ("named 18 Nov")
    public static func dayMonth(_ d: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        format(d, "d MMM", locale, timeZone)
    }
    /// "Tue 17 Nov" (Voices waiting row)
    public static func dayDate(_ d: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        format(d, "EEE d MMM", locale, timeZone)
    }
    /// "2:29 pm" — lower-case am/pm regardless of locale symbols.
    public static func time(_ d: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        format(d, "h:mm a", locale, timeZone).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }
    /// "1×", "1.5×", "2×", "0.75×"
    public static func rate(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))×" : "\(String(format: "%g", r))×"
    }
    private static func format(_ d: Date, _ template: String, _ locale: Locale, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = locale; f.timeZone = tz; f.dateFormat = template
        return f.string(from: d)
    }
}
