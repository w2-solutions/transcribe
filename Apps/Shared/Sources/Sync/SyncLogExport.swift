import Foundation
import OSLog

/// The app's own sync, iCloud and push log lines since it was launched, as text for Settings → Copy sync log.
/// These lines carry record types, record ids, counts and error codes only (never names, text or voice data), so
/// the text may go through the normal clipboard, including to another of the user's devices.
enum SyncLogExport {
    static let categories: Set<String> = ["sync", "cloudkit", "push"]

    static func text(now: Date = .now) -> String {
        var lines = ["Transcribe sync log, \(platform), \(now.formatted(.iso8601))",
                     "Bundle \(Bundle.main.bundleIdentifier ?? "?") \(version)"]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: now.addingTimeInterval(-12 * 3600))
            let predicate = NSPredicate(format: "subsystem == %@", "ai.w2solutions.transcribe")
            let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            var entries: [String] = []
            for case let entry as OSLogEntryLog in try store.getEntries(at: since, matching: predicate)
            where categories.contains(entry.category) {
                entries.append("\(entry.date.formatted(time)) \(entry.category): \(entry.composedMessage)")
            }
            lines.append("\(entries.count) lines since launch (last 2000 shown)")
            lines.append(contentsOf: entries.suffix(2000))
        } catch {
            lines.append("Could not read the log: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    private static var platform: String {
        #if os(iOS)
        "iPhone"
        #else
        "Mac"
        #endif
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
