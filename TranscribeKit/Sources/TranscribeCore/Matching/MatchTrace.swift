import Foundation

/// How one probe scored against one profile (§1.3 to §1.5). Holds numbers only: no names and no vectors.
public struct ProfileEvidence: Sendable, Codable, Equatable {
    public var profileID: UUID
    public var score: Float            // §1.3 pair score
    public var trustedTop: Float?      // best cosine to a trusted sample (T[0])
    public var trustedScore: Float?    // mean of the top k trusted cosines
    public var trustedCount: Int       // trusted samples of the probe's dimension
    public var untrustedCount: Int     // untrusted samples of the probe's dimension
    public var askOnly: Bool           // no trusted sample: the profile can be asked about, never auto-labelled
    public var negativeMax: Float?     // §1.4
    public var blocked: Bool
    public var cohortMax: Float?       // §1.5; nil outside decideWithTrace

    public init(profileID: UUID, score: Float, trustedTop: Float?, trustedScore: Float?, trustedCount: Int,
                untrustedCount: Int, askOnly: Bool, negativeMax: Float?, blocked: Bool, cohortMax: Float?) {
        self.profileID = profileID; self.score = score; self.trustedTop = trustedTop; self.trustedScore = trustedScore
        self.trustedCount = trustedCount; self.untrustedCount = untrustedCount; self.askOnly = askOnly
        self.negativeMax = negativeMax; self.blocked = blocked; self.cohortMax = cohortMax
    }
}

public enum TraceKind: String, Sendable, Codable { case auto, ask, unknown }

/// Why the matcher decided what it did for one speaker, kept for tuning the thresholds on real recordings.
///
/// `reason` is the first rule that applies:
/// - auto: `"auto"`;
/// - ask: `"downgraded"`, `"askOnly"`, `"autoLabelOff"`, `"belowAuto"`, `"margin"`;
/// - unknown: `"noVector"`, `"tooShort"`, `"noEligibleProfiles"`, `"blocked"` (the top profile was blocked and
///   nothing else reached ask), `"taken"` (every profile that reached ask was taken), `"lowScore"`.
public struct MatchTrace: Sendable, Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var key: SpeakerKey
    public var cleanSeconds: Double
    public var kind: TraceKind
    public var profileID: UUID?              // auto/ask target
    public var reason: String
    public var score: Float?                 // the target's score; for unknown, the probe's top score
    public var runnerUp: Float?
    public var margin: Float?
    public var profiles: [ProfileEvidence]   // sorted by score desc, then uuidString
    public var cohortSize: Int               // cohort vectors of matching dimension
    public var cohortTopMean: Float?         // mean of the top cohortStatsTopN cosines; nil under cohortStatsMinCount
    public var cohortTopStd: Float?          // population std of the same set
    public var autoLabelMin: Float
    public var autoLabelMargin: Float
    public var askMin: Float

    public init(version: Int = MatchTrace.currentVersion, key: SpeakerKey, cleanSeconds: Double, kind: TraceKind,
                profileID: UUID?, reason: String, score: Float?, runnerUp: Float?, margin: Float?,
                profiles: [ProfileEvidence], cohortSize: Int, cohortTopMean: Float?, cohortTopStd: Float?,
                autoLabelMin: Float, autoLabelMargin: Float, askMin: Float) {
        self.version = version; self.key = key; self.cleanSeconds = cleanSeconds; self.kind = kind
        self.profileID = profileID; self.reason = reason; self.score = score; self.runnerUp = runnerUp
        self.margin = margin; self.profiles = profiles; self.cohortSize = cohortSize
        self.cohortTopMean = cohortTopMean; self.cohortTopStd = cohortTopStd
        self.autoLabelMin = autoLabelMin; self.autoLabelMargin = autoLabelMargin; self.askMin = askMin
    }
}

/// The matcher's decisions together with one trace per probe key.
public struct MatchRun: Sendable, Equatable {
    public var decisions: [SpeakerKey: MatchDecision]
    public var traces: [SpeakerKey: MatchTrace]
    public init(decisions: [SpeakerKey: MatchDecision], traces: [SpeakerKey: MatchTrace]) {
        self.decisions = decisions; self.traces = traces
    }
}
