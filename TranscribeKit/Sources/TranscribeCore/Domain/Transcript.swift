import Foundation

/// Diarizer key ("S1", "S2", …) or a user-created key ("U1", …) for turn reassignment.
public typealias SpeakerKey = String

public struct TimedWord: Sendable, Hashable, Codable {
    public var text: String            // includes attached punctuation, e.g. "Karan."
    public var range: TimeRange
    public var isOverlap: Bool         // set by TurnBuilder; excluded from embeddings/clean speech
    public init(text: String, range: TimeRange, isOverlap: Bool = false) {
        self.text = text; self.range = range; self.isOverlap = isOverlap
    }
}

public struct Turn: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var speakerKey: SpeakerKey?          // nil = no speaker info (pending / identify off / no speech)
    public var speakerKeyOverride: SpeakerKey?  // "Just this turn" correction; never feeds embeddings
    public var range: TimeRange
    public var words: [TimedWord]
    public var hasOverlap: Bool
    public init(id: UUID, speakerKey: SpeakerKey?, range: TimeRange, words: [TimedWord],
                hasOverlap: Bool = false, speakerKeyOverride: SpeakerKey? = nil) {
        self.id = id; self.speakerKey = speakerKey; self.range = range; self.words = words
        self.hasOverlap = hasOverlap; self.speakerKeyOverride = speakerKeyOverride
    }
    public var effectiveSpeakerKey: SpeakerKey? { speakerKeyOverride ?? speakerKey }
    public var text: String { words.map(\.text).joined(separator: " ") }
    /// Deterministic per-document id: index 0 -> 00000000-0000-4000-8000-000000000000.
    public static func stableID(index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", UInt64(index)))!
    }
}

public struct TranscriptDocument: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var words: [TimedWord]       // every word in time order (step-1 checkpoint)
    public var turns: [Turn]            // paragraphs after step 1; speaker turns after step 2
    public var language: String?
    public var asrModelID: String
    public init(words: [TimedWord], turns: [Turn], language: String? = nil,
                asrModelID: String, version: Int = TranscriptDocument.currentVersion) {
        self.words = words; self.turns = turns; self.language = language
        self.asrModelID = asrModelID; self.version = version
    }
    public var hasSpeakers: Bool { turns.contains { $0.speakerKey != nil } }
    public var plainText: String { turns.map(\.text).joined(separator: "\n") }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> TranscriptDocument {
        try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }
}
