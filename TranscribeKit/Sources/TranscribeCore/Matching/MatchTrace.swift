import Foundation

/// How one probe scored against one profile (§1.3 to §1.5). Holds numbers only: no names and no vectors.
public struct ProfileEvidence: Sendable, Codable, Equatable {
    public var profileID: UUID
    public var score: Float            // §1.3 pair score
    public var trustedTop: Float?      // best cosine to a trusted sample (T[0])
    public var trustedScore: Float?    // mean of the top k trusted cosines
    public var trustedCount: Int       // trusted samples of the probe's dimension on the probe's channel
    public var untrustedCount: Int     // other samples of the probe's dimension (other-channel trusted ones included)
    public var askOnly: Bool           // no trusted sample: the profile can be asked about, never auto-labelled
    public var negativeMax: Float?     // §1.4
    public var blocked: Bool
    public var cohortMax: Float?       // §1.5; nil outside decideWithTrace
    /// Trusted samples of the probe's dimension heard on another channel (§7): they only fill second place.
    /// Nil in v1 traces.
    public var otherChannelTrustedCount: Int?

    // Version 3 (sound-group scoring, decision D3). All nil in v1 and v2 traces and when groups are off.
    /// The auto score A: the best group score over the groups on the probe's channel with a trusted member.
    public var autoScore: Float?
    /// Sound groups of the probe's dimension on the probe's channel.
    public var groupCount: Int?
    /// Members of the winning group (the one that gave `autoScore`).
    public var groupSize: Int?
    /// Trusted members of the winning group.
    public var groupTrustedCount: Int?
    /// Shadow only, never used to decide: A under rule S1, where a one-sample group borrows its second place from
    /// every other sample of the profile, logged so S2 (the rule in use) can be compared on real data.
    public var singletonBorrowShadow: Float?
    /// G: the best score over every group on the probe's channel, trusted or not. It feeds the symmetric runner-up
    /// of the other profiles.
    public var groupBestScore: Float?
    /// The trusted score an automatic sample is gated on: the mean of the top trusted cosines in the winning group
    /// when it has two or more trusted members, else `trustedScore`.
    public var autoTrustedScore: Float?
    /// The probe's cosine to the winning group's centroid; an automatic sample must join the group (at least
    /// `MatchPolicy.groupJoinCosine`).
    public var autoCentroidCosine: Float?

    public init(profileID: UUID, score: Float, trustedTop: Float?, trustedScore: Float?, trustedCount: Int,
                untrustedCount: Int, askOnly: Bool, negativeMax: Float?, blocked: Bool, cohortMax: Float?,
                otherChannelTrustedCount: Int? = nil, autoScore: Float? = nil, groupCount: Int? = nil,
                groupSize: Int? = nil, groupTrustedCount: Int? = nil, singletonBorrowShadow: Float? = nil,
                groupBestScore: Float? = nil, autoTrustedScore: Float? = nil, autoCentroidCosine: Float? = nil) {
        self.profileID = profileID; self.score = score; self.trustedTop = trustedTop; self.trustedScore = trustedScore
        self.trustedCount = trustedCount; self.untrustedCount = untrustedCount; self.askOnly = askOnly
        self.negativeMax = negativeMax; self.blocked = blocked; self.cohortMax = cohortMax
        self.otherChannelTrustedCount = otherChannelTrustedCount
        self.autoScore = autoScore; self.groupCount = groupCount; self.groupSize = groupSize
        self.groupTrustedCount = groupTrustedCount; self.singletonBorrowShadow = singletonBorrowShadow
        self.groupBestScore = groupBestScore; self.autoTrustedScore = autoTrustedScore
        self.autoCentroidCosine = autoCentroidCosine
    }
}

public enum TraceKind: String, Sendable, Codable { case auto, ask, unknown }

/// Why the matcher decided what it did for one speaker, kept for tuning the thresholds on real recordings.
///
/// `reason` is the first rule that applies:
/// - auto: `"auto"`;
/// - ask: `"downgraded"`, `"mixedSource"` (the probe is ask-only: heard on both the microphone and Mac audio),
///   `"otherChannel"` (no trusted sample on the probe's channel, but some on another), `"askOnly"` (no trusted sample
///   at all), `"autoLabelOff"`, `"negativeNear"` (the auto score passed but a negative is at least as close),
///   `"groupScore"` (the matcher without groups would have auto-labelled: W passes against the runner-up it used, the
///   cohort and other profiles' W; with groups, A or the symmetric runner-up stops it), `"belowAuto"`, `"margin"`
///   (with groups, both on A);
/// - unknown: `"noVector"`, `"tooShort"`, `"noEligibleProfiles"`, `"blocked"` (the top profile was blocked and
///   nothing else reached ask), `"taken"` (every profile that reached ask was taken), `"lowScore"`.
///
/// Version 2 (§7) adds `probeChannel` and `ProfileEvidence.otherChannelTrustedCount`; both are optional, so v1 JSON
/// still decodes.
///
/// Version 3 (sound groups and Mac audio, 2026-11-26) adds `speakerSource`, `systemShare` and the group fields of
/// `ProfileEvidence`; all optional and left out of the JSON when nil, so v1 and v2 JSON still decode and a trace
/// without them encodes as before. The matcher writes version 3 while `MatchPolicy.groupScoring` is on, and version 2
/// with it off (the matcher from before groups). The group fields are filled only for a profile scored per group
/// (one whose candidate carries sample ids).
public struct MatchTrace: Sendable, Codable, Equatable {
    public static let currentVersion = groupsVersion
    /// The version written with capture channels and without groups (`MatchPolicy.groupScoring` off).
    public static let channelsVersion = 2
    /// The version with sound-group scoring.
    public static let groupsVersion = 3

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
    /// The capture channel of the probe's recording (v2); nil when unknown and in v1 traces.
    public var probeChannel: String?
    /// The speaker's `SpeakerSource` raw value ("mic", "system", "mixed") (v3); nil in older traces and for a
    /// microphone-only recording.
    public var speakerSource: String?
    /// The share of the speaker's clean speech heard on Mac audio, rounded to 2 places (v3); nil unless attributed.
    public var systemShare: Float?

    public init(version: Int = MatchTrace.currentVersion, key: SpeakerKey, cleanSeconds: Double, kind: TraceKind,
                profileID: UUID?, reason: String, score: Float?, runnerUp: Float?, margin: Float?,
                profiles: [ProfileEvidence], cohortSize: Int, cohortTopMean: Float?, cohortTopStd: Float?,
                autoLabelMin: Float, autoLabelMargin: Float, askMin: Float, probeChannel: String? = nil,
                speakerSource: String? = nil, systemShare: Float? = nil) {
        self.version = version; self.key = key; self.cleanSeconds = cleanSeconds; self.kind = kind
        self.profileID = profileID; self.reason = reason; self.score = score; self.runnerUp = runnerUp
        self.margin = margin; self.profiles = profiles; self.cohortSize = cohortSize
        self.cohortTopMean = cohortTopMean; self.cohortTopStd = cohortTopStd
        self.autoLabelMin = autoLabelMin; self.autoLabelMargin = autoLabelMargin; self.askMin = askMin
        self.probeChannel = probeChannel
        self.speakerSource = speakerSource; self.systemShare = systemShare
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
