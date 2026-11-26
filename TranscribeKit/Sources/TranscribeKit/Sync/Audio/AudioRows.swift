import Foundation

/// Audio sync's state in `Library.store` without a schema change (decision 8): one `SyncRecordState` row per marker
/// this device knows, with the foreign `typeRaw` "AudioState" and its facts as JSON under the key "~audio" in
/// `baseHashesJSON`. A foreign `typeRaw` gives a nil `recordID`, so every generic sync path (full scan, breaker,
/// `pendingCount`, `finishFetch`, an older build after a downgrade) skips the row, and `clearSyncState()` deletes it
/// with everything else.
///
/// Audio rows share the marker's record name (`au.<UUID>`) with what a generic `SyncRecordID(.audio, id).recordName`
/// would give, and `SyncRecordState.recordName` is unique: route every `.audio` id to `AudioSync` before any generic
/// `stateRow(named:)` lookup or insert. Never "simplify" this into the generic path.
enum AudioRows {
    /// Never a `SyncRecordType` raw value.
    static let typeRaw = "AudioState"
    static let factsKey = "~audio"
    /// This build's `AudioRowFacts.v`.
    static let factsVersion = 1

    /// "au.<UUID>"
    static func recordName(_ id: UUID) -> String { SyncRecordID(type: .audio, entityID: id).recordName }
}

/// What one audio row says. Rows are never forgotten for age.
struct AudioRowFacts: Codable, Equatable {
    enum Marker: String, Codable {
        /// The blob is up and the marker is being sent (not yet acknowledged).
        case sending
        /// The marker is on the server (fetched, or acknowledged after this device's upload).
        case onServer
        /// The blob is gone (or going) and the marker's delete is being sent.
        case deleting
    }
    var v = 1
    var descriptor: AudioDescriptor
    var marker: Marker
    /// The fetched marker's `sv`.
    var markerVersion: Int64 = 1
    /// This device has seen the marker's recording, so its later absence means a settled delete (decision 10).
    var recordingSeen: Bool
    /// Logging only; rows are never forgotten for age.
    var firstSeenAt: Date
}

/// How an audio row reads.
enum AudioRowRead {
    case facts(AudioRowFacts)
    /// `v` is higher than this build's: a newer build sharing this store wrote it. Kept untouched, never acted on.
    case newer
    /// Not parseable, or `v` ≤ this build's and malformed. Deleted by the next derive.
    case malformed
}

extension TranscribeSchemaV4.SyncRecordState {
    var isAudioRow: Bool { typeRaw == AudioRows.typeRaw }

    /// Only `.malformed` rows are deleted (next derive); `.newer` rows are kept untouched.
    var audioRead: AudioRowRead {
        guard let dict = try? JSONDecoder().decode([String: String].self, from: baseHashesJSON),
              let json = dict[AudioRows.factsKey], let data = json.data(using: .utf8) else { return .malformed }
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.v > AudioRows.factsVersion {
            return .newer
        }
        guard let facts = try? JSONDecoder().decode(AudioRowFacts.self, from: data) else { return .malformed }
        return .facts(facts)
    }

    /// The `.facts` case; nil for a newer or malformed row. Setting writes `v = AudioRows.factsVersion`; setting nil
    /// clears the facts (the row then reads `.malformed`).
    var audioFacts: AudioRowFacts? {
        get {
            if case .facts(let f) = audioRead { return f }
            return nil
        }
        set {
            guard var facts = newValue else {
                baseHashesJSON = Data("{}".utf8)
                return
            }
            facts.v = AudioRows.factsVersion
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json = (try? encoder.encode(facts)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            baseHashesJSON = SyncSchema.sortedJSON([AudioRows.factsKey: json])
        }
    }

    /// A new audio row (not inserted): record name `au.<id>`, `typeRaw` "AudioState", nothing pending, no system
    /// fields, no unresolved links.
    static func audioRow(_ facts: AudioRowFacts, now: Date) -> SyncRecordState {
        let id = facts.descriptor.recordingID
        let row = SyncRecordState(recordName: AudioRows.recordName(id), type: .audio, entityID: id, now: now)
        row.typeRaw = AudioRows.typeRaw
        row.pendingRaw = 0
        row.systemFields = nil
        row.unresolvedLinksJSON = nil
        row.audioFacts = facts
        return row
    }
}

/// Reads only `v`, so a row from a newer build is recognised even when its layout changed.
private struct VersionProbe: Decodable { var v: Int }
