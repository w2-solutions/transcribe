import Foundation

public struct MatchPolicy: Sendable, Equatable {
    public var autoLabelMin: Float = 0.55
    public var autoLabelMargin: Float = 0.10
    public var askMin: Float = 0.40
    public var minIdentifySeconds: TimeInterval = 3
    public var minSampleSeconds: TimeInterval = 10
    public var strongMatchMin: Float = 0.70
    public var strongMatchMargin: Float = 0.20
    public var maxSamplesPerProfile = 8
    public var duplicateCosine: Float = 0.95
    public var scoringTopK = 2
    public init() {}
    public static let `default` = MatchPolicy()
}

public struct ProfileCandidate: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let samples: [VoiceVector]
    public let modelKey: String          // EmbeddingModelID.key
    public let autoLabel: Bool
    public let needsResample: Bool
    public init(id: UUID, name: String, samples: [VoiceVector], modelKey: String, autoLabel: Bool, needsResample: Bool) {
        self.id = id; self.name = name; self.samples = samples; self.modelKey = modelKey
        self.autoLabel = autoLabel; self.needsResample = needsResample
    }
}

public struct SpeakerProbe: Sendable, Equatable {
    public let key: SpeakerKey
    public let vector: VoiceVector?
    public let cleanSeconds: TimeInterval
    public let rejectedProfileIDs: Set<UUID>
    public init(key: SpeakerKey, vector: VoiceVector?, cleanSeconds: TimeInterval, rejectedProfileIDs: Set<UUID>) {
        self.key = key; self.vector = vector; self.cleanSeconds = cleanSeconds; self.rejectedProfileIDs = rejectedProfileIDs
    }
}

public enum UnknownReason: Sendable, Equatable {
    case noVector, tooShort, noEligibleProfiles
    case lowScore(best: Float)
}

public enum MatchDecision: Sendable, Equatable {
    case autoLabel(profileID: UUID, score: Float, margin: Float)
    case ask(profileID: UUID, score: Float)
    case unknown(UnknownReason)
}

public enum SampleOrigin: String, Sendable, Codable, CaseIterable {
    case named, confirmed, strongMatch, addedFromRecording, merged
}

public struct CuratedSample: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let vector: VoiceVector
    public let origin: SampleOrigin
    public let addedAt: Date
    public init(id: UUID, vector: VoiceVector, origin: SampleOrigin, addedAt: Date) {
        self.id = id; self.vector = vector; self.origin = origin; self.addedAt = addedAt
    }
}

public struct SampleInsertResult: Sendable, Equatable {
    public var keep: [CuratedSample]    // the full resulting set (≤ max)
    public var evicted: [UUID]
    public var added: Bool              // false when skipped as a near-duplicate
    public init(keep: [CuratedSample], evicted: [UUID], added: Bool) { self.keep = keep; self.evicted = evicted; self.added = added }
}

public struct ColourRequest: Sendable, Equatable {
    public let key: SpeakerKey
    public let ordinal: Int
    public let profileSlot: Int?        // slot of the matched/named profile, if any
    public init(key: SpeakerKey, ordinal: Int, profileSlot: Int?) { self.key = key; self.ordinal = ordinal; self.profileSlot = profileSlot }
}
