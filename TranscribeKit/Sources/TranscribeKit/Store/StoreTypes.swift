import Foundation
import TranscribeCore

public enum RecordingStage: Int, Sendable, Codable, Comparable, CaseIterable {
    case capturing = 0, queued, transcribing, transcribed, separating, separated, matching, ready, failed
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var isProcessing: Bool { self >= .queued && self < .ready }
}
public enum RecordingSource: String, Sendable, Codable { case microphone, imported }

public enum NameTarget: Sendable, Equatable {
    case newPerson(name: String)
    case existing(profileID: UUID)
}
public enum TurnTarget: Sendable, Equatable {
    case speaker(SpeakerKey)          // another speaker already in this recording
    case profile(UUID)                // saved voice not (yet) in this recording → new "U<n>" speaker linked to it
    case newName(String)              // new "U<n>" speaker with nameSnapshot only (never remembered)
}
public enum SampleSkipReason: Sendable, Equatable {
    case rememberOff
    case tooLittleSpeech(seconds: Double)
    case noVector
    case duplicate
}
public struct NameResult: Sendable, Equatable {
    public var profileID: UUID?
    public var sampleStored: Bool
    public var skipReason: SampleSkipReason?
    public init(profileID: UUID?, sampleStored: Bool, skipReason: SampleSkipReason?) {
        self.profileID = profileID; self.sampleStored = sampleStored; self.skipReason = skipReason
    }
}
public struct SpeakerDraft: Sendable, Equatable {
    public var key: SpeakerKey
    public var ordinal: Int
    public var cleanSeconds: Double
    public var totalSeconds: Double
    public var turnCount: Int
    public var vector: VoiceVector?
    public var embeddingModel: EmbeddingModelID
    /// Span coherence of `vector` (§1.11); nil when the vector is a fallback or missing.
    public var coherence: Float?
    public init(key: SpeakerKey, ordinal: Int, cleanSeconds: Double, totalSeconds: Double, turnCount: Int,
                vector: VoiceVector?, embeddingModel: EmbeddingModelID, coherence: Float? = nil) {
        self.key = key; self.ordinal = ordinal; self.cleanSeconds = cleanSeconds; self.totalSeconds = totalSeconds
        self.turnCount = turnCount; self.vector = vector; self.embeddingModel = embeddingModel; self.coherence = coherence
    }
}
public struct RecordingSnapshot: Sendable, Equatable {
    public var id: UUID
    public var audioFileName: String
    public var duration: Double
    public var stage: RecordingStage
    public var language: LanguageHint
    public var transcript: TranscriptDocument?
    public var attemptCount: Int
    public init(id: UUID, audioFileName: String, duration: Double, stage: RecordingStage,
                language: LanguageHint, transcript: TranscriptDocument?, attemptCount: Int) {
        self.id = id; self.audioFileName = audioFileName; self.duration = duration; self.stage = stage
        self.language = language; self.transcript = transcript; self.attemptCount = attemptCount
    }
}
public struct RecoverySnapshot: Sendable, Equatable {
    public var id: UUID
    public var stage: RecordingStage
    public var audioFileName: String
    public var attemptCount: Int
    public var hasTranscript: Bool
    public var audioExists: Bool
    public init(id: UUID, stage: RecordingStage, audioFileName: String, attemptCount: Int, hasTranscript: Bool, audioExists: Bool) {
        self.id = id; self.stage = stage; self.audioFileName = audioFileName
        self.attemptCount = attemptCount; self.hasTranscript = hasTranscript; self.audioExists = audioExists
    }
}
public struct SampleCandidate: Sendable, Equatable, Identifiable {
    public var id: UUID                 // RecordingSpeaker.id
    public var recordingID: UUID
    public var key: SpeakerKey
    public var speakerName: String      // displayName
    public var recordingTitle: String   // displayTitle
    public var cleanSeconds: Double
    public init(id: UUID, recordingID: UUID, key: SpeakerKey, speakerName: String, recordingTitle: String, cleanSeconds: Double) {
        self.id = id; self.recordingID = recordingID; self.key = key; self.speakerName = speakerName
        self.recordingTitle = recordingTitle; self.cleanSeconds = cleanSeconds
    }
}
public enum StoreError: Error, Sendable, Equatable {
    case notFound(String)
    case invalidName
    case invariant(String)
    case notImplemented(String)
}
