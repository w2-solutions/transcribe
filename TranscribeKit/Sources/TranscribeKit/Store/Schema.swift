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

public typealias Recording = TranscribeSchemaV1.Recording
public typealias RecordingSpeaker = TranscribeSchemaV1.RecordingSpeaker
public typealias VoiceProfile = TranscribeSchemaV1.VoiceProfile
public typealias VoiceSample = TranscribeSchemaV1.VoiceSample
public typealias Folder = TranscribeSchemaV1.Folder

public enum TranscribeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [TranscribeSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

// MARK: - Computed accessors (skeleton, final)
public extension TranscribeSchemaV1.Recording {
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
public extension TranscribeSchemaV1.RecordingSpeaker {
    var label: SpeakerLabelState { get { SpeakerLabelState(rawValue: labelRaw) ?? .unnamed } set { labelRaw = newValue.rawValue } }
    var vector: VoiceVector? { vectorData.flatMap { VoiceVector(packed: $0) } }
    /// profile name → snapshot → "Speaker N"
    var displayName: String { profile?.name ?? nameSnapshot ?? "Speaker \(ordinal)" }
    var hasName: Bool { profile != nil || nameSnapshot != nil }
    var canBeRemembered: Bool { cleanSeconds >= MatchPolicy.default.minSampleSeconds && vectorData != nil }
}
public extension TranscribeSchemaV1.VoiceProfile {
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
public extension TranscribeSchemaV1.VoiceSample {
    var origin: SampleOrigin { SampleOrigin(rawValue: originRaw) ?? .named }
    var vector: VoiceVector? { VoiceVector(packed: vectorData) }
    var clipRange: TimeRange? { if let s = clipStart, let e = clipEnd { TimeRange(start: s, end: e) } else { nil } }
}
