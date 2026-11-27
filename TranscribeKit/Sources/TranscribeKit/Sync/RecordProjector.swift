import Foundation
import SwiftData
import TranscribeCore

/// One local entity of a synced type.
@MainActor
enum SyncEntity {
    case recording(Recording), speaker(RecordingSpeaker), profile(VoiceProfile), sample(VoiceSample)
    case negative(VoiceNegative), folder(Folder), groupLabel(VoiceGroupLabel)

    var recordID: SyncRecordID {
        switch self {
        case .recording(let r): SyncRecordID(type: .recording, entityID: r.id)
        case .speaker(let s): SyncRecordID(type: .speaker, entityID: s.id)
        case .profile(let p): SyncRecordID(type: .profile, entityID: p.id)
        case .sample(let s): SyncRecordID(type: .sample, entityID: s.id)
        case .negative(let n): SyncRecordID(type: .negative, entityID: n.id)
        case .folder(let f): SyncRecordID(type: .folder, entityID: f.id)
        case .groupLabel(let l): SyncRecordID(type: .groupLabel, entityID: l.id)
        }
    }

    var model: any PersistentModel {
        switch self {
        case .recording(let m): m
        case .speaker(let m): m
        case .profile(let m): m
        case .sample(let m): m
        case .negative(let m): m
        case .folder(let m): m
        case .groupLabel(let m): m
        }
    }

    /// The recording this entity belongs to (a recording is its own).
    var owningRecording: Recording? {
        switch self {
        case .recording(let r): r
        case .speaker(let s): s.recording
        default: nil
        }
    }

    /// Syncable rule (§8.2): a recording only at `.ready`, a speaker only when its recording is. Every profile, sample,
    /// negative, folder and group label is syncable. Rows that are not syncable are frozen: nothing is sent for them.
    var isSyncable: Bool {
        switch self {
        case .recording(let r): r.stage == .ready
        case .speaker(let s): s.recording?.stage == .ready
        default: true
        }
    }

    /// The entity's recording is going through local processing (below `.ready`). Remote changes to it wait.
    var isProcessingLocally: Bool {
        guard let r = owningRecording else { return false }
        return r.stage < .ready
    }
}

/// Reads entities into canonical records (§8.2) and looks them up by record id.
@MainActor
struct RecordProjector {
    let context: ModelContext

    // MARK: Lookup

    func entity(_ id: SyncRecordID) -> SyncEntity? {
        let uuid = id.entityID
        switch id.type {
        case .recording:
            return first(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == uuid })).map(SyncEntity.recording)
        case .speaker:
            return first(FetchDescriptor<RecordingSpeaker>(predicate: #Predicate { $0.id == uuid })).map(SyncEntity.speaker)
        case .profile:
            return first(FetchDescriptor<VoiceProfile>(predicate: #Predicate { $0.id == uuid })).map(SyncEntity.profile)
        case .sample:
            return first(FetchDescriptor<VoiceSample>(predicate: #Predicate { $0.id == uuid })).map(SyncEntity.sample)
        case .negative:
            return first(FetchDescriptor<VoiceNegative>(predicate: #Predicate { $0.id == uuid })).map(SyncEntity.negative)
        case .folder:
            return first(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == uuid })).map(SyncEntity.folder)
        case .groupLabel:
            return first(FetchDescriptor<VoiceGroupLabel>(predicate: #Predicate { $0.id == uuid })).map(SyncEntity.groupLabel)
        case .audio:
            return nil   // an audio marker has no entity (AudioSync keeps its own rows)
        }
    }

    private func first<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> T? {
        var d = descriptor
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Every entity of a type.
    func all(_ type: SyncRecordType) throws -> [SyncEntity] {
        switch type {
        case .recording: try context.fetch(FetchDescriptor<Recording>()).map(SyncEntity.recording)
        case .speaker: try context.fetch(FetchDescriptor<RecordingSpeaker>()).map(SyncEntity.speaker)
        case .profile: try context.fetch(FetchDescriptor<VoiceProfile>()).map(SyncEntity.profile)
        case .sample: try context.fetch(FetchDescriptor<VoiceSample>()).map(SyncEntity.sample)
        case .negative: try context.fetch(FetchDescriptor<VoiceNegative>()).map(SyncEntity.negative)
        case .folder: try context.fetch(FetchDescriptor<Folder>()).map(SyncEntity.folder)
        case .groupLabel: try context.fetch(FetchDescriptor<VoiceGroupLabel>()).map(SyncEntity.groupLabel)
        case .audio: []
        }
    }

    /// The ids of every entity of a type.
    func allIDs(_ type: SyncRecordType) throws -> Set<UUID> {
        switch type {
        case .recording: Set(try context.fetch(FetchDescriptor<Recording>()).map(\.id))
        case .speaker: Set(try context.fetch(FetchDescriptor<RecordingSpeaker>()).map(\.id))
        case .profile: Set(try context.fetch(FetchDescriptor<VoiceProfile>()).map(\.id))
        case .sample: Set(try context.fetch(FetchDescriptor<VoiceSample>()).map(\.id))
        case .negative: Set(try context.fetch(FetchDescriptor<VoiceNegative>()).map(\.id))
        case .folder: Set(try context.fetch(FetchDescriptor<Folder>()).map(\.id))
        case .groupLabel: Set(try context.fetch(FetchDescriptor<VoiceGroupLabel>()).map(\.id))
        case .audio: []
        }
    }

    /// Maps a saved model to its entity, for the `didSave` fast path. Sync bookkeeping models map to nil.
    static func entity(for model: any PersistentModel) -> SyncEntity? {
        switch model {
        case let r as Recording: .recording(r)
        case let s as RecordingSpeaker: .speaker(s)
        case let p as VoiceProfile: .profile(p)
        case let s as VoiceSample: .sample(s)
        case let n as VoiceNegative: .negative(n)
        case let f as Folder: .folder(f)
        case let l as VoiceGroupLabel: .groupLabel(l)
        default: nil
        }
    }

    /// The record type of a SwiftData entity name (`PersistentIdentifier.entityName`).
    static func type(entityName: String) -> SyncRecordType? {
        switch entityName {
        case "Recording": .recording
        case "RecordingSpeaker": .speaker
        case "VoiceProfile": .profile
        case "VoiceSample": .sample
        case "VoiceNegative": .negative
        case "Folder": .folder
        case "VoiceGroupLabel": .groupLabel
        default: nil
        }
    }

    // MARK: Projection

    /// The canonical record for an entity. `unresolved` ([field: uuidString]) stands in for a link whose target has
    /// not arrived, so a missing link is reported by its id and never as cleared.
    static func record(_ e: SyncEntity, unresolved: [String: String] = [:], systemFields: Data? = nil) -> SyncRecord {
        SyncRecord(id: e.recordID, fields: fields(e, unresolved: unresolved), systemFields: systemFields)
    }

    static func hashes(_ e: SyncEntity, unresolved: [String: String] = [:]) -> [String: String] {
        SyncSchema.hashes(fields(e, unresolved: unresolved), type: e.recordID.type)
    }

    static func fields(_ e: SyncEntity, unresolved: [String: String] = [:]) -> [String: SyncValue] {
        func link(_ field: String, _ id: UUID?) -> SyncValue {
            if let id { return .string(id.uuidString) }
            if let pending = unresolved[field] { return .string(pending) }
            return .null
        }
        var f: [String: SyncValue]
        switch e {
        case .recording(let r):
            f = ["createdAt": .date(r.createdAt), "source": .string(r.sourceRaw),
                 "captureChannel": .string(r.captureChannel), "captureDetail": .string(r.captureDetailJSON),
                 "language": .string(r.languageRaw),
                 "title": .string(r.title),
                 "isFavourite": .bool(r.isFavourite),
                 "folderID": link("folderID", r.folder?.id),
                 "duration": .double(r.duration), "noSpeech": .bool(r.noSpeech), "marks": .doubles(r.marks),
                 "peaks": .floats(r.peaks), "asrModelID": .string(r.asrModelID),
                 "embeddingModelKey": .string(r.embeddingModelKey),
                 "transcript": r.transcriptData.map(SyncValue.asset) ?? .null]
        case .speaker(let s):
            f = ["recordingID": link("recordingID", s.recording?.id), "key": .string(s.key), "ordinal": .int(s.ordinal),
                 "colourSlot": .int(s.colourSlot), "cleanSeconds": .double(s.cleanSeconds), "vector": .bytes(s.vectorData),
                 "embeddingModelKey": .string(s.embeddingModelKey), "vectorCoherence": .double(s.vectorCoherence),
                 "turnCount": .int(s.turnCount), "totalSeconds": .double(s.totalSeconds),
                 "captureSource": .string(s.captureSource),
                 "label": .string(s.labelRaw), "profileID": link("profileID", s.profile?.id),
                 "suggestedProfileID": .uuid(s.suggestedProfileID), "nameSnapshot": .string(s.nameSnapshot),
                 "matchScore": .double(s.matchScore), "matchMargin": .double(s.matchMargin),
                 "rejectedProfileIDs": .uuids(s.rejectedProfileIDs)]
        case .profile(let p):
            f = ["name": .string(p.name), "namedAt": .date(p.namedAt), "isMe": .bool(p.isMe), "autoLabel": .bool(p.autoLabel),
                 "colourSlot": .int(p.colourSlot), "createdAt": .date(p.createdAt),
                 "embeddingModelKey": .string(p.embeddingModelKey)]
        case .sample(let s):
            f = ["profileID": link("profileID", s.profile?.id), "vector": .bytes(s.vectorData),
                 "embeddingModelKey": .string(s.embeddingModelKey), "origin": .string(s.originRaw),
                 "addedAt": .date(s.addedAt), "speechSeconds": .double(s.speechSeconds),
                 "sourceRecordingID": .uuid(s.sourceRecordingID), "sourceSpeakerID": .uuid(s.sourceSpeakerID),
                 "clipStart": .double(s.clipStart), "clipEnd": .double(s.clipEnd), "quote": .string(s.quote),
                 "captureChannel": .string(s.captureChannel), "captureInput": .string(s.captureInput)]
        case .negative(let n):
            f = ["profileID": link("profileID", n.profile?.id), "vector": .bytes(n.vectorData),
                 "embeddingModelKey": .string(n.embeddingModelKey), "addedAt": .date(n.addedAt),
                 "speechSeconds": .double(n.speechSeconds), "sourceRecordingID": .uuid(n.sourceRecordingID),
                 "sourceSpeakerID": .uuid(n.sourceSpeakerID), "captureChannel": .string(n.captureChannel),
                 "captureInput": .string(n.captureInput)]
        case .folder(let fd):
            f = ["name": .string(fd.name), "createdAt": .date(fd.createdAt)]
        case .groupLabel(let l):
            // The anchor travels as its stored bytes, never decoded and packed again: the resolver compares it with
            // the samples' vectors bit for bit, and a sample's `vector` travels as its stored bytes too.
            f = ["profileID": link("profileID", l.profile?.id), "text": .string(l.text),
                 "createdAt": .date(l.createdAt), "editedAt": .date(l.editedAt),
                 "embeddingModelKey": .string(l.embeddingModelKey), "captureChannel": .string(l.captureChannel),
                 "anchor": .bytes(l.anchorVectorData), "anchorDimension": .int(l.anchorDimension)]
        }
        f[SyncSchema.versionField] = .int(SyncSchema.version)
        return f
    }
}
