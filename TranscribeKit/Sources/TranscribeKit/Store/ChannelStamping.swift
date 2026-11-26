import Foundation
import SwiftData
import TranscribeCore

/// The launch backfill of capture channels (§6.4, decision D16). It replaces the old device wipe.
///
/// Before V3 every voice row was made on this device (the old wipe guaranteed that), so a row with no channel was
/// heard through this device's microphone. A sample or negative takes its source recording's channel when that
/// recording still exists, so a voice learned from an imported or older recording keeps the recording's channel.
/// A seeded group label (text, no channel) takes this device's channel.
extension LibraryStore {
    @discardableResult
    public func stampCaptureChannels() throws -> Int {
        recordDeviceOnFirstLaunch()
        let channel = localChannel

        let recordings = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.captureChannel == nil }))
        for r in recordings { r.captureChannel = channel }

        let samples = try context.fetch(FetchDescriptor<VoiceSample>(predicate: #Predicate { $0.captureChannel == nil }))
        let negatives = try context.fetch(FetchDescriptor<VoiceNegative>(predicate: #Predicate { $0.captureChannel == nil }))
        let sourceChannels = try channels(of: Set(samples.compactMap(\.sourceRecordingID) + negatives.compactMap(\.sourceRecordingID)))
        for s in samples { s.captureChannel = s.sourceRecordingID.flatMap { sourceChannels[$0] } ?? channel }
        for n in negatives { n.captureChannel = n.sourceRecordingID.flatMap { sourceChannels[$0] } ?? channel }

        // A group label with text but no channel can only come from a seed, which does not know the run's channel: it
        // takes this device's. (A label the user saves always has its group's channel.)
        let labels = try context.fetch(FetchDescriptor<VoiceGroupLabel>(predicate: #Predicate {
            $0.captureChannel == "" && $0.text != ""
        }))
        for l in labels { l.captureChannel = channel }

        let stamped = recordings.count + samples.count + negatives.count + labels.count
        if stamped > 0 { try context.save() }
        return stamped
    }

    /// The capture channel of each existing recording in `ids` (recordings stamped above included).
    private func channels(of ids: Set<UUID>) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Array(ids)
        let sources = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { wanted.contains($0.id) }))
        var result: [UUID: String] = [:]
        for r in sources { if let c = r.captureChannel { result[r.id] = c } }
        return result
    }

    /// Writes `StoreDevice.plist` the first time this store is opened with a readable install id. It is informational
    /// only (harmless if it fails) and is never compared to delete anything.
    private func recordDeviceOnFirstLaunch() {
        let current = deviceIdentity.installID()
        guard !current.isEmpty, storedDeviceID() == nil else { return }
        try? writeDeviceID(current)
    }
}
