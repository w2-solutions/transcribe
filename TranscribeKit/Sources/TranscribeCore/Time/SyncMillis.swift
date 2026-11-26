import Foundation

/// The one millisecond rule shared by sync and the matcher: milliseconds since 1970, rounded to the nearest
/// millisecond, so `date(millis:)` of `millis(_:)` round-trips exactly and two devices compare the same dates the
/// same way (a synced `Date` comes back as whole milliseconds). `SyncValue.millis` delegates here.
public enum SyncMillis {
    public static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    public static func date(millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}
