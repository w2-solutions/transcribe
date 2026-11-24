import Foundation
import TranscribeCore

/// One saved voice on the Voices screen (§6.7).
public struct SavedVoiceRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var initial: String
    public var isMe: Bool
    public var slot: Int
    public var recordingCount: Int
    public var needsResample: Bool
    /// "In 3 recordings", "In 2 recordings · named 18 Nov", or "Needs a new sample on this iPhone" (or Mac).
    public var subtitle: String
    /// 9 bar heights, 0…1 (from the newest sample's clip, else a fixed pattern).
    public var bars: [Float]
}

/// One speaker that still needs a name (§6.7 "Waiting for a name").
public struct WaitingVoiceRow: Sendable, Equatable, Identifiable {
    public var id: UUID                 // RecordingSpeaker.id
    public var recordingID: UUID
    public var key: SpeakerKey
    public var ordinal: Int
    public var slot: Int
    public var name: String             // "Speaker 2"
    public var isSuggested: Bool
    public var dateText: String         // "Tue 17 Nov"
    public var durationText: String     // "12:48"
    public var duration: TimeInterval
    public var recordingDate: Date
}

/// Builds the Voices screen rows from SwiftData objects. Main-actor only, because it reads `@Model` objects.
@MainActor
public struct VoicesListModel {
    public static let maxWaiting = 20
    public static let barCount = 9
    /// Bar pattern used when no sample audio is available (mockup rhythm, in 18ths).
    public static let fallbackBars: [Float] = [6, 12, 16, 9, 14, 18, 10, 5, 13].map { $0 / 18 }

    public let saved: [SavedVoiceRow]
    public let waiting: [WaitingVoiceRow]

    public var isEmpty: Bool { saved.isEmpty && waiting.isEmpty }

    public init(profiles: [VoiceProfile], recordings: [Recording],
                locale: Locale = .current, timeZone: TimeZone = .current, platform: DevicePlatform = .current) {
        let byID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        saved = Self.sortedProfiles(profiles).map {
            Self.savedRow($0, recordingsByID: byID, locale: locale, timeZone: timeZone, platform: platform)
        }
        waiting = Self.waitingRows(recordings, locale: locale, timeZone: timeZone)
    }

    /// "me" first, then by name (case- and diacritic-insensitive), then by creation date.
    public static func sortedProfiles(_ profiles: [VoiceProfile]) -> [VoiceProfile] {
        profiles.sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            let order = a.name.localizedStandardCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.createdAt < b.createdAt
        }
    }

    static func savedRow(_ p: VoiceProfile, recordingsByID: [UUID: Recording],
                         locale: Locale, timeZone: TimeZone, platform: DevicePlatform) -> SavedVoiceRow {
        let count = p.recordingCount
        return SavedVoiceRow(
            id: p.id, name: p.name, initial: p.initial, isMe: p.isMe, slot: p.colourSlot,
            recordingCount: count, needsResample: p.needsResample,
            subtitle: subtitle(recordingCount: count, isMe: p.isMe, namedAt: p.namedAt, needsResample: p.needsResample,
                               locale: locale, timeZone: timeZone, platform: platform),
            bars: bars(for: p, recordingsByID: recordingsByID))
    }

    public static func subtitle(recordingCount: Int, isMe: Bool, namedAt: Date, needsResample: Bool,
                                locale: Locale = .current, timeZone: TimeZone = .current,
                                platform: DevicePlatform = .current) -> String {
        if needsResample { return DeviceCopy(platform: platform).needsSample }
        var text = "In \(recordingCount) \(recordingCount == 1 ? "recording" : "recordings")"
        if !isMe { text += " · named " + DisplayFormat.dayMonth(namedAt, locale: locale, timeZone: timeZone) }
        return text
    }

    /// Voice detail caption under a sample: where it came from, plus " · short sample" for a user sample under 10 s.
    public static func sampleCaption(origin: SampleOrigin, speechSeconds: Double) -> String {
        let base = switch origin {
        case .named: "Named by you"
        case .confirmed: "Confirmed by you"
        case .corrected: "Added when not recognised"
        case .addedFromRecording: "Added by you"
        case .strongMatch: "Added automatically"
        case .merged: "Merged from another voice"
        }
        let isShort = !origin.isAutomatic && speechSeconds < MatchPolicy.default.minSampleSeconds
        return isShort ? base + " · short sample" : base
    }

    /// Bars from the newest sample whose source recording still exists and has peaks.
    static func bars(for profile: VoiceProfile, recordingsByID: [UUID: Recording]) -> [Float] {
        for sample in profile.sortedSamples.reversed() {
            guard let rid = sample.sourceRecordingID, let rec = recordingsByID[rid], !rec.peaks.isEmpty,
                  let range = sample.clipRange else { continue }
            let bars = clipPeaks(rec.peaks, duration: rec.duration, range: range, count: barCount)
            if !bars.isEmpty { return bars }
        }
        return fallbackBars
    }

    /// Waveform bars for `range` of a recording whose `peaks` cover `duration` evenly: point-sampled at each bar's
    /// centre (keeps the syllable rhythm that max-pooling flattens), then contrast-stretched to 0.25…1.
    public static func clipPeaks(_ peaks: [Float], duration: TimeInterval, range: TimeRange, count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty, duration > 0 else { return [] }
        let start = max(0, min(range.start, duration)), end = max(start, min(range.end, duration))
        guard end > start else { return [] }
        let binSeconds = duration / Double(peaks.count)
        var out: [Float] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let t = start + (Double(i) + 0.5) / Double(count) * (end - start)
            let bin = min(peaks.count - 1, max(0, Int(t / binSeconds)))
            out.append(max(0, peaks[bin]))
        }
        let top = out.max() ?? 0, low = out.min() ?? 0
        guard top > 0 else { return [] }
        // Stretch the contrast so quiet syllables read as short bars even when a clip is evenly loud.
        guard top - low > 0.01 else { return out.map { _ in 0.6 } }
        return out.map { 0.25 + 0.75 * ($0 - low) / (top - low) }
    }

    /// Unnamed or suggested speakers with ≥ 3 s clean speech in finished recordings, newest recording first
    /// (speakers in ordinal order within a recording), at most 20.
    public static func waitingRows(_ recordings: [Recording], locale: Locale = .current,
                                   timeZone: TimeZone = .current) -> [WaitingVoiceRow] {
        let finished = recordings.filter { $0.stage == .ready }.sorted { $0.createdAt > $1.createdAt }
        var rows: [WaitingVoiceRow] = []
        for rec in finished {
            for s in rec.speakersNeedingName {
                rows.append(WaitingVoiceRow(
                    id: s.id, recordingID: rec.id, key: s.key, ordinal: s.ordinal, slot: s.colourSlot,
                    name: "Speaker \(s.ordinal)", isSuggested: s.label == .suggested,
                    dateText: DisplayFormat.dayDate(rec.createdAt, locale: locale, timeZone: timeZone),
                    durationText: DisplayFormat.duration(rec.duration), duration: rec.duration, recordingDate: rec.createdAt))
                if rows.count == maxWaiting { return rows }
            }
        }
        return rows
    }
}
