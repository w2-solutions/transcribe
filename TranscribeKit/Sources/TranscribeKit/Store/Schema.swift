import Foundation
import SwiftData
import TranscribeCore

public enum TranscribeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Recording.self, RecordingSpeaker.self, VoiceProfile.self, VoiceSample.self, Folder.self]
    }

    @Model public final class Recording {
        @Attribute(.unique) public var id: UUID
        public var createdAt: Date
        public var title: String?                 // nil → DisplayFormat.cardDate(createdAt)
        public var duration: Double
        public var audioFileName: String          // relative to AppPaths.audioDirectory ("<id>.wav")
        public var sourceRaw: String              // RecordingSource
        public var stageRaw: Int                  // RecordingStage
        public var queueReasonRaw: String?        // QueueReason
        public var failureMessage: String?
        public var attemptCount: Int
        public var isFavourite: Bool
        public var hasUnseenResult: Bool          // "Voices recognised" pill on the card
        public var noSpeech: Bool
        public var languageRaw: String?           // nil = automatic, else ISO code
        public var marks: [Double]
        public var peaks: [Float]                 // ≤ 200 bins, 0…1
        public var previewText: String            // first ~200 chars of the transcript
        public var searchText: String             // lowercased title + transcript + speaker names
        public var transcriptData: Data?          // TranscriptDocument JSON
        public var asrModelID: String?
        public var embeddingModelKey: String?
        public var folder: Folder?
        @Relationship(deleteRule: .cascade, inverse: \RecordingSpeaker.recording)
        public var speakers: [RecordingSpeaker] = []

        public init(id: UUID, createdAt: Date, audioFileName: String, source: RecordingSource) {
            self.id = id; self.createdAt = createdAt; self.audioFileName = audioFileName
            self.sourceRaw = source.rawValue; self.stageRaw = RecordingStage.capturing.rawValue
            self.duration = 0; self.attemptCount = 0; self.isFavourite = false; self.hasUnseenResult = false
            self.noSpeech = false; self.marks = []; self.peaks = []; self.previewText = ""; self.searchText = ""
        }
    }

    @Model public final class RecordingSpeaker {
        @Attribute(.unique) public var id: UUID
        public var key: String                    // "S1"… / "U1"…
        public var ordinal: Int                   // "Speaker N"
        public var colourSlot: Int                // frozen per recording; see ColourAssigner
        public var cleanSeconds: Double
        public var totalSeconds: Double           // "spoke for"
        public var turnCount: Int
        public var vectorData: Data?              // VoiceVector.packed
        public var embeddingModelKey: String?
        public var labelRaw: String               // SpeakerLabelState
        public var profile: VoiceProfile?         // assigned person (autoLabelled / named)
        public var suggestedProfileID: UUID?      // when suggested
        public var nameSnapshot: String?          // name kept after Forget, or remember-off naming
        public var matchScore: Double?
        public var matchMargin: Double?
        public var rejectedProfileIDs: [UUID]
        public var recording: Recording?

        public init(id: UUID = UUID(), key: String, ordinal: Int, colourSlot: Int) {
            self.id = id; self.key = key; self.ordinal = ordinal; self.colourSlot = colourSlot
            self.cleanSeconds = 0; self.totalSeconds = 0; self.turnCount = 0
            self.labelRaw = SpeakerLabelState.unnamed.rawValue; self.rejectedProfileIDs = []
        }
    }

    @Model public final class VoiceProfile {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var isMe: Bool
        public var colourSlot: Int
        public var createdAt: Date
        public var namedAt: Date
        public var autoLabel: Bool
        public var embeddingModelKey: String
        public var needsResample: Bool
        @Relationship(deleteRule: .cascade, inverse: \VoiceSample.profile)
        public var samples: [VoiceSample] = []
        @Relationship(deleteRule: .nullify, inverse: \RecordingSpeaker.profile)
        public var speakers: [RecordingSpeaker] = []

        public init(id: UUID = UUID(), name: String, colourSlot: Int, embeddingModelKey: String, now: Date) {
            self.id = id; self.name = name; self.isMe = false; self.colourSlot = colourSlot
            self.createdAt = now; self.namedAt = now; self.autoLabel = true
            self.embeddingModelKey = embeddingModelKey; self.needsResample = false
        }
    }

    @Model public final class VoiceSample {
        @Attribute(.unique) public var id: UUID
        public var vectorData: Data
        public var embeddingModelKey: String
        public var originRaw: String              // SampleOrigin
        public var addedAt: Date
        public var speechSeconds: Double
        public var sourceRecordingID: UUID?       // plain ids: deleting a recording keeps the vector
        public var sourceSpeakerID: UUID?         // RecordingSpeaker.id — lets a correction roll back
        public var clipStart: Double?
        public var clipEnd: Double?
        public var quote: String?
        public var profile: VoiceProfile?

        public init(id: UUID = UUID(), vector: VoiceVector, embeddingModelKey: String, origin: SampleOrigin,
                    addedAt: Date, speechSeconds: Double) {
            self.id = id; self.vectorData = vector.packed; self.embeddingModelKey = embeddingModelKey
            self.originRaw = origin.rawValue; self.addedAt = addedAt; self.speechSeconds = speechSeconds
        }
    }

    @Model public final class Folder {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var createdAt: Date
        @Relationship(deleteRule: .nullify, inverse: \Recording.folder)
        public var recordings: [Recording] = []
        public init(id: UUID = UUID(), name: String, createdAt: Date) { self.id = id; self.name = name; self.createdAt = createdAt }
    }
}

public enum TranscribeSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Recording.self, RecordingSpeaker.self, VoiceProfile.self, VoiceSample.self, Folder.self, VoiceNegative.self]
    }

    @Model public final class Recording {
        @Attribute(.unique) public var id: UUID
        public var createdAt: Date
        public var title: String?                 // nil → DisplayFormat.cardDate(createdAt)
        public var duration: Double
        public var audioFileName: String          // relative to AppPaths.audioDirectory ("<id>.wav")
        public var sourceRaw: String              // RecordingSource
        public var stageRaw: Int                  // RecordingStage
        public var queueReasonRaw: String?        // QueueReason
        public var failureMessage: String?
        public var attemptCount: Int
        public var isFavourite: Bool
        public var hasUnseenResult: Bool          // "Voices recognised" pill on the card
        public var noSpeech: Bool
        public var languageRaw: String?           // nil = automatic, else ISO code
        public var marks: [Double]
        public var peaks: [Float]                 // ≤ 200 bins, 0…1
        public var previewText: String            // first ~200 chars of the transcript
        public var searchText: String             // lowercased title + transcript + speaker names
        public var transcriptData: Data?          // TranscriptDocument JSON
        public var asrModelID: String?
        public var embeddingModelKey: String?
        public var folder: Folder?
        @Relationship(deleteRule: .cascade, inverse: \TranscribeSchemaV2.RecordingSpeaker.recording)
        public var speakers: [RecordingSpeaker] = []
        public var movedSpeakerTracesData: Data?  // [MovedSpeakerTrace] JSON: traces of speakers "Same as" removed

        public init(id: UUID, createdAt: Date, audioFileName: String, source: RecordingSource) {
            self.id = id; self.createdAt = createdAt; self.audioFileName = audioFileName
            self.sourceRaw = source.rawValue; self.stageRaw = RecordingStage.capturing.rawValue
            self.duration = 0; self.attemptCount = 0; self.isFavourite = false; self.hasUnseenResult = false
            self.noSpeech = false; self.marks = []; self.peaks = []; self.previewText = ""; self.searchText = ""
        }
    }

    @Model public final class RecordingSpeaker {
        @Attribute(.unique) public var id: UUID
        public var key: String                    // "S1"… / "U1"…
        public var ordinal: Int                   // "Speaker N"
        public var colourSlot: Int                // frozen per recording; see ColourAssigner
        public var cleanSeconds: Double
        public var totalSeconds: Double           // "spoke for"
        public var turnCount: Int
        public var vectorData: Data?              // VoiceVector.packed
        public var embeddingModelKey: String?
        public var labelRaw: String               // SpeakerLabelState
        public var profile: VoiceProfile?         // assigned person (autoLabelled / named)
        public var suggestedProfileID: UUID?      // when suggested
        public var nameSnapshot: String?          // name kept after Forget, or remember-off naming
        public var matchScore: Double?
        public var matchMargin: Double?
        public var rejectedProfileIDs: [UUID]
        public var recording: Recording?
        public var vectorCoherence: Double?      // span coherence of the speaker vector (§1.11); nil before V2 or on fallback
        public var matchTraceData: Data?          // MatchTrace JSON, written once by applyMatches

        public init(id: UUID = UUID(), key: String, ordinal: Int, colourSlot: Int) {
            self.id = id; self.key = key; self.ordinal = ordinal; self.colourSlot = colourSlot
            self.cleanSeconds = 0; self.totalSeconds = 0; self.turnCount = 0
            self.labelRaw = SpeakerLabelState.unnamed.rawValue; self.rejectedProfileIDs = []
        }
    }

    @Model public final class VoiceProfile {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var isMe: Bool
        public var colourSlot: Int
        public var createdAt: Date
        public var namedAt: Date
        public var autoLabel: Bool
        public var embeddingModelKey: String
        public var needsResample: Bool
        @Relationship(deleteRule: .cascade, inverse: \TranscribeSchemaV2.VoiceSample.profile)
        public var samples: [VoiceSample] = []
        @Relationship(deleteRule: .cascade, inverse: \TranscribeSchemaV2.VoiceNegative.profile)
        public var negatives: [VoiceNegative] = []
        @Relationship(deleteRule: .nullify, inverse: \TranscribeSchemaV2.RecordingSpeaker.profile)
        public var speakers: [RecordingSpeaker] = []

        public init(id: UUID = UUID(), name: String, colourSlot: Int, embeddingModelKey: String, now: Date) {
            self.id = id; self.name = name; self.isMe = false; self.colourSlot = colourSlot
            self.createdAt = now; self.namedAt = now; self.autoLabel = true
            self.embeddingModelKey = embeddingModelKey; self.needsResample = false
        }
    }

    @Model public final class VoiceSample {
        @Attribute(.unique) public var id: UUID
        public var vectorData: Data
        public var embeddingModelKey: String
        public var originRaw: String              // SampleOrigin
        public var addedAt: Date
        public var speechSeconds: Double
        public var sourceRecordingID: UUID?       // plain ids: deleting a recording keeps the vector
        public var sourceSpeakerID: UUID?         // RecordingSpeaker.id — lets a correction roll back
        public var clipStart: Double?
        public var clipEnd: Double?
        public var quote: String?
        public var profile: VoiceProfile?

        public init(id: UUID = UUID(), vector: VoiceVector, embeddingModelKey: String, origin: SampleOrigin,
                    addedAt: Date, speechSeconds: Double) {
            self.id = id; self.vectorData = vector.packed; self.embeddingModelKey = embeddingModelKey
            self.originRaw = origin.rawValue; self.addedAt = addedAt; self.speechSeconds = speechSeconds
        }
    }

    @Model public final class Folder {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var createdAt: Date
        @Relationship(deleteRule: .nullify, inverse: \TranscribeSchemaV2.Recording.folder)
        public var recordings: [Recording] = []
        public init(id: UUID = UUID(), name: String, createdAt: Date) { self.id = id; self.name = name; self.createdAt = createdAt }
    }

    /// A voice the user said is not this person (§1.4). Same model key rules as `VoiceSample`.
    @Model public final class VoiceNegative {
        @Attribute(.unique) public var id: UUID
        public var vectorData: Data               // VoiceVector.packed
        public var embeddingModelKey: String
        public var addedAt: Date
        public var speechSeconds: Double
        public var sourceRecordingID: UUID?
        public var sourceSpeakerID: UUID?         // RecordingSpeaker.id the negative was taken from
        public var profile: VoiceProfile?

        public init(id: UUID = UUID(), vector: VoiceVector, embeddingModelKey: String, addedAt: Date, speechSeconds: Double) {
            self.id = id; self.vectorData = vector.packed; self.embeddingModelKey = embeddingModelKey
            self.addedAt = addedAt; self.speechSeconds = speechSeconds
        }
    }
}

public enum TranscribeSchemaV3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [Recording.self, RecordingSpeaker.self, VoiceProfile.self, VoiceSample.self, Folder.self, VoiceNegative.self,
         SyncRecordState.self, SyncAccountState.self]
    }

    @Model public final class Recording {
        @Attribute(.unique) public var id: UUID
        public var createdAt: Date
        public var title: String?                 // nil → DisplayFormat.cardDate(createdAt)
        public var duration: Double
        public var audioFileName: String          // relative to AppPaths.audioDirectory ("<id>.wav")
        public var sourceRaw: String              // RecordingSource
        public var stageRaw: Int                  // RecordingStage
        public var queueReasonRaw: String?        // QueueReason
        public var failureMessage: String?
        public var attemptCount: Int
        public var isFavourite: Bool
        public var hasUnseenResult: Bool          // "Voices recognised" pill on the card
        public var noSpeech: Bool
        public var languageRaw: String?           // nil = automatic, else ISO code
        public var marks: [Double]
        public var peaks: [Float]                 // ≤ 200 bins, 0…1
        public var previewText: String            // first ~200 chars of the transcript
        public var searchText: String             // lowercased title + transcript + speaker names
        public var transcriptData: Data?          // TranscriptDocument JSON
        public var asrModelID: String?
        public var embeddingModelKey: String?
        public var folder: Folder?
        @Relationship(deleteRule: .cascade, inverse: \TranscribeSchemaV3.RecordingSpeaker.recording)
        public var speakers: [RecordingSpeaker] = []
        public var movedSpeakerTracesData: Data?  // [MovedSpeakerTrace] JSON: traces of speakers "Same as" removed
        public var captureChannel: String?        // CaptureChannel of the device that captured or imported it (§6)
        public var captureDetailJSON: String?     // CaptureDetail JSON (hardware model and input route; log-only)

        public init(id: UUID, createdAt: Date, audioFileName: String, source: RecordingSource) {
            self.id = id; self.createdAt = createdAt; self.audioFileName = audioFileName
            self.sourceRaw = source.rawValue; self.stageRaw = RecordingStage.capturing.rawValue
            self.duration = 0; self.attemptCount = 0; self.isFavourite = false; self.hasUnseenResult = false
            self.noSpeech = false; self.marks = []; self.peaks = []; self.previewText = ""; self.searchText = ""
        }
    }

    @Model public final class RecordingSpeaker {
        @Attribute(.unique) public var id: UUID
        public var key: String                    // "S1"… / "U1"…
        public var ordinal: Int                   // "Speaker N"
        public var colourSlot: Int                // frozen per recording; see ColourAssigner
        public var cleanSeconds: Double
        public var totalSeconds: Double           // "spoke for"
        public var turnCount: Int
        public var vectorData: Data?              // VoiceVector.packed
        public var embeddingModelKey: String?
        public var labelRaw: String               // SpeakerLabelState
        public var profile: VoiceProfile?         // assigned person (autoLabelled / named)
        public var suggestedProfileID: UUID?      // when suggested
        public var nameSnapshot: String?          // name kept after Forget, or remember-off naming
        public var matchScore: Double?
        public var matchMargin: Double?
        public var rejectedProfileIDs: [UUID]
        public var recording: Recording?
        public var vectorCoherence: Double?      // span coherence of the speaker vector (§1.11); nil before V2 or on fallback
        public var matchTraceData: Data?          // MatchTrace JSON, written once by applyMatches

        public init(id: UUID = UUID(), key: String, ordinal: Int, colourSlot: Int) {
            self.id = id; self.key = key; self.ordinal = ordinal; self.colourSlot = colourSlot
            self.cleanSeconds = 0; self.totalSeconds = 0; self.turnCount = 0
            self.labelRaw = SpeakerLabelState.unnamed.rawValue; self.rejectedProfileIDs = []
        }
    }

    @Model public final class VoiceProfile {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var isMe: Bool
        public var colourSlot: Int
        public var createdAt: Date
        public var namedAt: Date
        public var autoLabel: Bool
        public var embeddingModelKey: String
        public var needsResample: Bool
        @Relationship(deleteRule: .cascade, inverse: \TranscribeSchemaV3.VoiceSample.profile)
        public var samples: [VoiceSample] = []
        @Relationship(deleteRule: .cascade, inverse: \TranscribeSchemaV3.VoiceNegative.profile)
        public var negatives: [VoiceNegative] = []
        @Relationship(deleteRule: .nullify, inverse: \TranscribeSchemaV3.RecordingSpeaker.profile)
        public var speakers: [RecordingSpeaker] = []

        public init(id: UUID = UUID(), name: String, colourSlot: Int, embeddingModelKey: String, now: Date) {
            self.id = id; self.name = name; self.isMe = false; self.colourSlot = colourSlot
            self.createdAt = now; self.namedAt = now; self.autoLabel = true
            self.embeddingModelKey = embeddingModelKey; self.needsResample = false
        }
    }

    @Model public final class VoiceSample {
        @Attribute(.unique) public var id: UUID
        public var vectorData: Data
        public var embeddingModelKey: String
        public var originRaw: String              // SampleOrigin
        public var addedAt: Date
        public var speechSeconds: Double
        public var sourceRecordingID: UUID?       // plain ids: deleting a recording keeps the vector
        public var sourceSpeakerID: UUID?         // RecordingSpeaker.id — lets a correction roll back
        public var clipStart: Double?
        public var clipEnd: Double?
        public var quote: String?
        public var profile: VoiceProfile?
        public var captureChannel: String?        // the source recording's channel, never the device that clicked
        public var captureInput: String?          // the source recording's CaptureDetail.input (log-only)

        public init(id: UUID = UUID(), vector: VoiceVector, embeddingModelKey: String, origin: SampleOrigin,
                    addedAt: Date, speechSeconds: Double) {
            self.id = id; self.vectorData = vector.packed; self.embeddingModelKey = embeddingModelKey
            self.originRaw = origin.rawValue; self.addedAt = addedAt; self.speechSeconds = speechSeconds
        }
    }

    @Model public final class Folder {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var createdAt: Date
        @Relationship(deleteRule: .nullify, inverse: \TranscribeSchemaV3.Recording.folder)
        public var recordings: [Recording] = []
        public init(id: UUID = UUID(), name: String, createdAt: Date) { self.id = id; self.name = name; self.createdAt = createdAt }
    }

    /// A voice the user said is not this person (§1.4). Same model key rules as `VoiceSample`.
    @Model public final class VoiceNegative {
        @Attribute(.unique) public var id: UUID
        public var vectorData: Data               // VoiceVector.packed
        public var embeddingModelKey: String
        public var addedAt: Date
        public var speechSeconds: Double
        public var sourceRecordingID: UUID?
        public var sourceSpeakerID: UUID?         // RecordingSpeaker.id the negative was taken from
        public var profile: VoiceProfile?
        public var captureChannel: String?        // the source recording's channel
        public var captureInput: String?          // the source recording's CaptureDetail.input (log-only)

        public init(id: UUID = UUID(), vector: VoiceVector, embeddingModelKey: String, addedAt: Date, speechSeconds: Double) {
            self.id = id; self.vectorData = vector.packed; self.embeddingModelKey = embeddingModelKey
            self.addedAt = addedAt; self.speechSeconds = speechSeconds
        }
    }

    /// Sync bookkeeping for one record (§6.2, decision D2). It lives in this store so that applying a remote change,
    /// recording its base hashes and saving the engine state happen in one `context.save()`.
    @Model public final class SyncRecordState {
        @Attribute(.unique) public var recordName: String   // "rec.<UUID>", "spk.", "vp.", "vs.", "vn.", "fd."
        public var typeRaw: String                           // SyncRecordType.rawValue
        public var entityID: UUID
        public var systemFields: Data?                       // CKRecord.encodeSystemFields; nil until the first server ack
        public var baseHashesJSON: Data                      // [group: hex sha256] as last agreed with the server; "{}" = never synced
        public var pendingRaw: Int                           // 0 none, 1 save, 2 delete, 3 parkedDelete (remote delete waiting for local processing)
        public var unresolvedLinksJSON: Data?                // [field: uuidString] links whose target has not arrived
        public var updatedAt: Date

        public init(recordName: String, type: SyncRecordType, entityID: UUID, now: Date) {
            self.recordName = recordName; self.typeRaw = type.rawValue; self.entityID = entityID
            self.baseHashesJSON = Data("{}".utf8); self.pendingRaw = 0; self.updatedAt = now
        }
    }

    /// The sync engine's account-wide state: one row, key "default".
    @Model public final class SyncAccountState {
        @Attribute(.unique) public var key: String          // always "default"
        public var accountHash: String?                     // sha256(userRecordID.recordName)
        public var engineState: Data?                       // CKSyncEngine.State.Serialization (opaque)
        public var zoneReady: Bool
        public var pausedReasonRaw: String?                 // SyncPauseReason
        public var lastFetchAt: Date?
        public var lastSendAt: Date?

        public init() { self.key = "default"; self.zoneReady = false }
    }
}

public typealias Recording = TranscribeSchemaV3.Recording
public typealias RecordingSpeaker = TranscribeSchemaV3.RecordingSpeaker
public typealias VoiceProfile = TranscribeSchemaV3.VoiceProfile
public typealias VoiceSample = TranscribeSchemaV3.VoiceSample
public typealias Folder = TranscribeSchemaV3.Folder
public typealias VoiceNegative = TranscribeSchemaV3.VoiceNegative
public typealias SyncRecordState = TranscribeSchemaV3.SyncRecordState
public typealias SyncAccountState = TranscribeSchemaV3.SyncAccountState

public enum TranscribeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [TranscribeSchemaV1.self, TranscribeSchemaV2.self, TranscribeSchemaV3.self]
    }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: TranscribeSchemaV1.self, toVersion: TranscribeSchemaV2.self),
         .lightweight(fromVersion: TranscribeSchemaV2.self, toVersion: TranscribeSchemaV3.self)]
    }
}

// MARK: - Computed accessors (skeleton, final)
public extension TranscribeSchemaV3.Recording {
    var stage: RecordingStage { get { RecordingStage(rawValue: stageRaw) ?? .failed } set { stageRaw = newValue.rawValue } }
    var source: RecordingSource { RecordingSource(rawValue: sourceRaw) ?? .microphone }
    var queueReason: QueueReason? { queueReasonRaw.flatMap(QueueReason.init(rawValue:)) }
    var language: LanguageHint { languageRaw.map(LanguageHint.language) ?? .automatic }
    var transcript: TranscriptDocument? { transcriptData.flatMap { try? TranscriptDocument.decode($0) } }
    var displayTitle: String { title ?? DisplayFormat.cardDate(createdAt) }
    var sortedSpeakers: [RecordingSpeaker] { speakers.sorted { $0.ordinal < $1.ordinal } }
    func speaker(_ key: SpeakerKey) -> RecordingSpeaker? { speakers.first { $0.key == key } }
    /// Speakers that still need a name (unnamed or suggested) with ≥ 3 s clean speech.
    var speakersNeedingName: [RecordingSpeaker] {
        sortedSpeakers.filter { ($0.label == .unnamed || $0.label == .suggested) && $0.cleanSeconds >= MatchPolicy.default.minIdentifySeconds }
    }
}
public extension TranscribeSchemaV3.RecordingSpeaker {
    var label: SpeakerLabelState { get { SpeakerLabelState(rawValue: labelRaw) ?? .unnamed } set { labelRaw = newValue.rawValue } }
    var vector: VoiceVector? { vectorData.flatMap { VoiceVector(packed: $0) } }
    /// profile name → snapshot → "Speaker N"
    var displayName: String { profile?.name ?? nameSnapshot ?? "Speaker \(ordinal)" }
    var hasName: Bool { profile != nil || nameSnapshot != nil }
    var canBeRemembered: Bool { cleanSeconds >= MatchPolicy.default.minSampleSeconds && vectorData != nil }
    var coherence: Float? { vectorCoherence.map(Float.init) }
}
public extension TranscribeSchemaV3.VoiceProfile {
    var initial: String { String(name.prefix(1)).uppercased() }
    /// Whether a typed name names this saved voice: case-insensitive only, so "Jose" and "José" stay two people.
    /// The name sheet and the store both use this rule.
    nonisolated static func nameMatches(_ saved: String, _ typed: String) -> Bool {
        saved.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(typed.trimmingCharacters(in: .whitespacesAndNewlines), options: .caseInsensitive) == .orderedSame
    }
    var recordingCount: Int { Set(speakers.compactMap { $0.recording?.id }).count }
    var sortedSamples: [VoiceSample] { samples.sorted { $0.addedAt < $1.addedAt } }
}
public extension TranscribeSchemaV3.VoiceSample {
    var origin: SampleOrigin { SampleOrigin(rawValue: originRaw) ?? .strongMatch }   // unknown → least privileged
    /// Derived, never stored (§1.2): not automatic and at least `minSampleSeconds` long.
    var isTrusted: Bool { SampleTrust.isTrusted(origin: origin, speechSeconds: speechSeconds) }
    var vector: VoiceVector? { VoiceVector(packed: vectorData) }
    var clipRange: TimeRange? { if let s = clipStart, let e = clipEnd { TimeRange(start: s, end: e) } else { nil } }
}
public extension TranscribeSchemaV3.VoiceNegative {
    var vector: VoiceVector? { VoiceVector(packed: vectorData) }
}
