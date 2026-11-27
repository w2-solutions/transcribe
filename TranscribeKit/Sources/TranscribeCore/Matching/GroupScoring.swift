import Foundation

/// Per-sound-group scoring of one probe against one profile (decision D3, 2026-11-26).
///
/// A person's samples on the probe's channel are grouped by how they sound with `SampleGrouping` (the voice screen's
/// clustering, at `MatchPolicy.groupJoinCosine`), so the same person close to the microphone, far away and through a
/// loudspeaker are scored separately. Each group g scores `pairScore(T_g, U_g)` with its own members only: its
/// trusted cosines `T_g` and the rest `U_g`. A one-sample group therefore scores its own cosine (rule S2).
///
/// - The auto score A is the best score over the groups with a trusted member. The winning group g* is chosen by
///   `(q(score) descending, key.uuidString ascending)`.
/// - The best group score G is the best over every group, trusted or not; it feeds the symmetric runner-up of the
///   other profiles.
/// - The S1 shadow (logged only) is A under the rule it replaced: a one-sample group borrows its second place from
///   every other sample of the profile with the probe's dimension.
///
/// Groups are derived from the samples every time, never stored. The result does not depend on the order of the
/// samples: the groups come from `SampleGrouping` (canonical order, quantised comparisons, id tie-breaks), every
/// score is a `pairScore` (summed in descending order), and the winner is chosen by quantised score and key.
public enum GroupScoring {
    /// How the probe scores against one sound group.
    public struct GroupScore: Sendable, Equatable {
        public let key: UUID
        public let size: Int
        public let trustedCount: Int
        /// `pairScore(T_g, U_g)` over the group's own members.
        public let score: Float
        /// Mean of the top `scoringTopK` trusted cosines in the group; nil when it has fewer than two trusted members.
        public let trustedScore: Float?
        /// The probe's cosine to the group's centroid.
        public let centroidCosine: Float
    }

    public struct Result: Sendable, Equatable {
        /// Groups on the probe's channel of the probe's dimension, in `SampleGrouping` order.
        public let groups: [GroupScore]
        /// The winning group g* among the groups with a trusted member; nil when there is none.
        public let winner: GroupScore?
        /// The best score over every group; nil when there are no groups.
        public let best: Float?
        /// A under rule S1 (shadow only); nil when no group has a trusted member.
        public let singletonBorrowShadow: Float?
        /// The auto score A; nil when no group has a trusted member.
        public var autoScore: Float? { winner?.score }
    }

    /// The `SampleGroupPolicy` the matcher and the curator group with.
    public static func groupPolicy(_ policy: MatchPolicy) -> SampleGroupPolicy {
        var p = SampleGroupPolicy()
        p.joinCosine = policy.groupJoinCosine
        return p
    }

    /// Whether `profile` is scored per group under `policy`: groups are on and the candidate carries sample ids.
    /// A candidate without ids (legacy callers and fixtures) is scored without groups, exactly as before.
    public static func applies(to profile: ProfileCandidate, policy: MatchPolicy) -> Bool {
        policy.groupScoring && profile.sampleIDs != nil
    }

    /// The sound groups of `profile`'s samples heard on exactly `channel` (nil equals nil) with `dimension`, as
    /// `SampleGrouping` makes them. Nil when the profile carries no sample ids.
    public static func groups(of profile: ProfileCandidate, channel: String?, dimension: Int,
                              policy: MatchPolicy = .default) -> [SampleGrouping.Group]? {
        guard let ids = profile.sampleIDs else { return nil }
        var items: [SampleGrouping.Item] = []
        for i in profile.samples.indices where profile.channels[i] == channel && profile.samples[i].dimension == dimension {
            items.append(SampleGrouping.Item(id: ids[i], vector: profile.samples[i], channel: channel ?? "",
                                             addedAtMillis: profile.addedAtMillis?[i] ?? 0))
        }
        return SampleGrouping.group(items, dimension: dimension, policy: groupPolicy(policy))
    }

    /// How `vector`, heard on `channel`, scores against each sound group of `profile` (rules above). `groups` are
    /// `groups(of:channel:dimension:policy:)` for the vector's dimension, passed in so a caller can reuse them.
    /// Nil when the profile carries no sample ids.
    public static func score(_ vector: VoiceVector, against profile: ProfileCandidate, channel: String?,
                             groups: [SampleGrouping.Group]? = nil, policy: MatchPolicy = .default) -> Result? {
        guard let ids = profile.sampleIDs,
              let groups = groups ?? self.groups(of: profile, channel: channel, dimension: vector.dimension, policy: policy)
        else { return nil }
        var index: [UUID: Int] = [:]
        for (i, id) in ids.enumerated() where index[id] == nil { index[id] = i }
        let k = Swift.max(1, policy.scoringTopK)

        var scores: [GroupScore] = []
        var shadow: Float?
        for g in groups {
            var trusted: [Float] = [], untrusted: [Float] = []
            for id in g.memberIDs {
                guard let i = index[id] else { continue }
                let c = vector.cosine(profile.samples[i])
                if profile.trusted[i] { trusted.append(c) } else { untrusted.append(c) }
            }
            guard let s = VoiceMatcher.pairScore(trusted: trusted, untrusted: untrusted, topK: k) else { continue }
            let t = trusted.sorted(by: >)
            let trustedScore = t.count >= 2 ? descendingMean(Array(t.prefix(k))) : nil
            scores.append(GroupScore(key: g.key, size: g.memberIDs.count, trustedCount: trusted.count, score: s,
                                     trustedScore: trustedScore, centroidCosine: vector.cosine(g.centroid)))

            // S1 shadow: a one-sample trusted group borrows its second place from every other sample of the dimension.
            guard let top = t.first else { continue }
            var borrowed = s
            if g.memberIDs.count == 1 {
                let member = Set(g.memberIDs)
                var others: [Float] = []
                for i in profile.samples.indices where profile.samples[i].dimension == vector.dimension && !member.contains(ids[i]) {
                    others.append(vector.cosine(profile.samples[i]))
                }
                borrowed = VoiceMatcher.pairScore(trusted: [top], untrusted: others, topK: k) ?? top
            }
            shadow = Swift.max(shadow ?? borrowed, borrowed)
        }

        let winner = scores.filter { $0.trustedCount > 0 }.min { a, b in
            let qa = SampleGrouping.q(Double(a.score)), qb = SampleGrouping.q(Double(b.score))
            return qa != qb ? qa > qb : a.key.uuidString < b.key.uuidString
        }
        return Result(groups: scores, winner: winner, best: scores.map(\.score).max(), singletonBorrowShadow: shadow)
    }

    /// Whether an automatic sample of `vector` would join the winning group: `q(cosine to its centroid)` at least
    /// `q(groupJoinCosine)`, the value two groups join at.
    public static func joins(centroidCosine: Float, policy: MatchPolicy = .default) -> Bool {
        SampleGrouping.q(Double(centroidCosine)) >= SampleGrouping.q(Double(policy.groupJoinCosine))
    }

    private static func descendingMean(_ values: [Float]) -> Float {
        let sorted = values.sorted(by: >)
        return sorted.reduce(Float(0), +) / Float(sorted.count)
    }
}
