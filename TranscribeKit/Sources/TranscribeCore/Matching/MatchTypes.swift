import Foundation

public struct MatchPolicy: Sendable, Equatable {
    public var autoLabelMin: Float = 0.55
    public var autoLabelMargin: Float = 0.10
    public var askMin: Float = 0.40
    public var minIdentifySeconds: TimeInterval = 3
    /// New profile, `addedFromRecording`, trust, automatic samples.
    public var minSampleSeconds: TimeInterval = 10
    /// Adding to an existing person by naming or confirming; negatives; negative clean-up; cohort members.
    public var minLearnSeconds: TimeInterval = 5
    /// Applied to the trusted-only score of an auto-label before an automatic sample is stored.
    public var strongMatchMin: Float = 0.70
    public var strongMatchMargin: Float = 0.20
    public var minAutoSampleCoherence: Float = 0.5
    public var maxSamplesPerProfile = 12
    public var duplicateCosine: Float = 0.95
    public var scoringTopK = 2
    public var maxNegativesPerProfile = 8
    /// Robust speaker vector: spans under this cosine to the weighted medoid are dropped...
    public var spanDropBelow: Float = 0.35
    /// ...as long as at least this fraction of the speech duration remains.
    public var spanMinKeptFraction: Double = 0.5
    /// Cohort collection by the store: newest recordings and vectors considered.
    public var cohortMaxRecordings = 100
    public var cohortMaxVectors = 300
    /// Trace only: cohort score statistics over the top N cosines, once the cohort has at least this many vectors.
    public var cohortStatsTopN = 20
    public var cohortStatsMinCount = 30
    public init() {}
    public static let `default` = MatchPolicy()
}

public struct ProfileCandidate: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let samples: [VoiceVector]
    /// Same count as `samples`: whether each sample is trusted (§1.2). Untrusted samples only fill second place.
    public let trusted: [Bool]
    /// Same count as `samples`: the capture channel each sample was heard on (§7, D8); nil = unknown.
    /// A trusted sample counts as trusted only for a probe on the same channel (nil equals nil, D11).
    public let channels: [String?]
    /// Voices the user said are not this person (§1.4). They count for probes on every channel.
    public let negatives: [VoiceVector]
    public let modelKey: String          // EmbeddingModelID.key
    public let autoLabel: Bool
    public let needsResample: Bool

    /// Legacy: every sample trusted, no negatives. `channels` nil means every sample's channel is nil.
    public init(id: UUID, name: String, samples: [VoiceVector], channels: [String?]? = nil, modelKey: String,
                autoLabel: Bool, needsResample: Bool) {
        self.init(id: id, name: name, samples: samples, trusted: Array(repeating: true, count: samples.count),
                  channels: channels, negatives: [], modelKey: modelKey, autoLabel: autoLabel, needsResample: needsResample)
    }

    public init(id: UUID, name: String, samples: [VoiceVector], trusted: [Bool], channels: [String?]? = nil,
                negatives: [VoiceVector], modelKey: String, autoLabel: Bool, needsResample: Bool) {
        precondition(trusted.count == samples.count, "one trust flag per sample")
        let channels = channels ?? Array(repeating: nil, count: samples.count)
        precondition(channels.count == samples.count, "one channel per sample")
        self.id = id; self.name = name; self.samples = samples; self.trusted = trusted; self.channels = channels
        self.negatives = negatives
        self.modelKey = modelKey; self.autoLabel = autoLabel; self.needsResample = needsResample
    }
}

public struct SpeakerProbe: Sendable, Equatable {
    public let key: SpeakerKey
    public let vector: VoiceVector?
    public let cleanSeconds: TimeInterval
    public let rejectedProfileIDs: Set<UUID>
    /// The capture channel of the probe's recording (§7); nil = unknown.
    public let channel: String?
    public init(key: SpeakerKey, vector: VoiceVector?, cleanSeconds: TimeInterval, rejectedProfileIDs: Set<UUID>,
                channel: String? = nil) {
        self.key = key; self.vector = vector; self.cleanSeconds = cleanSeconds; self.rejectedProfileIDs = rejectedProfileIDs
        self.channel = channel
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
    case named, confirmed, strongMatch, addedFromRecording, merged, corrected
    /// Stored without the user vouching for this voice. `.merged` exists only on legacy rows.
    public var isAutomatic: Bool { self == .strongMatch || self == .merged }
}

/// Trust is derived from a sample's origin and length, never stored (§1.2).
public enum SampleTrust {
    /// Not automatic and at least `minSampleSeconds` of clean speech. Anything else is untrusted: automatic,
    /// or a short user sample.
    public static func isTrusted(origin: SampleOrigin, speechSeconds: TimeInterval, policy: MatchPolicy = .default) -> Bool {
        !origin.isAutomatic && speechSeconds >= policy.minSampleSeconds
    }
}

public struct CuratedSample: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let vector: VoiceVector
    public let origin: SampleOrigin
    public let addedAt: Date
    public let speechSeconds: TimeInterval
    public init(id: UUID, vector: VoiceVector, origin: SampleOrigin, addedAt: Date, speechSeconds: TimeInterval = 60) {
        self.id = id; self.vector = vector; self.origin = origin; self.addedAt = addedAt; self.speechSeconds = speechSeconds
    }
    public var isTrusted: Bool { SampleTrust.isTrusted(origin: origin, speechSeconds: speechSeconds) }
}

public struct CuratedNegative: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let vector: VoiceVector
    public let addedAt: Date
    public let sourceSpeakerID: UUID?
    public init(id: UUID, vector: VoiceVector, addedAt: Date, sourceSpeakerID: UUID?) {
        self.id = id; self.vector = vector; self.addedAt = addedAt; self.sourceSpeakerID = sourceSpeakerID
    }
}

public struct NegativeInsertResult: Sendable, Equatable {
    public var keep: [CuratedNegative]    // the full resulting set (≤ max)
    public var evicted: [UUID]
    public var added: Bool                // false when skipped as a duplicate
    public init(keep: [CuratedNegative], evicted: [UUID], added: Bool) { self.keep = keep; self.evicted = evicted; self.added = added }
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
