import Foundation

public enum VoiceMatcher {
    /// Mean of the top-min(k, n) cosine similarities between `vector` and the profile's samples. -1 if no samples.
    ///
    /// Samples whose dimension differs from `vector` cannot be compared and are ignored; if none are left the
    /// score is -1, as for a profile with no samples. A `topK` below 1 is treated as 1.
    public static func score(_ vector: VoiceVector, against profile: ProfileCandidate, topK: Int) -> Float {
        let cosines = profile.samples
            .filter { $0.dimension == vector.dimension }
            .map { vector.cosine($0) }
            .sorted(by: >)
        guard !cosines.isEmpty else { return -1 }
        let top = cosines.prefix(Swift.max(1, topK))
        // Summed in sorted order, so the result does not depend on the order of the samples.
        return top.reduce(Float(0), +) / Float(top.count)
    }

    /// §1.3 on raw cosines: the mean of the top `k` cosines, where the first must come from a trusted sample.
    ///
    /// With trusted cosines `T` and untrusted `U` (each sorted descending): `[T0] + prefix(k−1, sortDesc(T[1...] + U))`,
    /// or `prefix(k, U)` when there is no trusted cosine. Nil when both are empty. A `topK` below 1 is treated as 1.
    /// Summed in descending order, so the result does not depend on the order of the inputs.
    public static func pairScore(trusted: [Float], untrusted: [Float], topK: Int) -> Float? {
        let k = Swift.max(1, topK)
        let t = trusted.sorted(by: >)
        let top: [Float]
        if let first = t.first {
            top = [first] + (t.dropFirst() + untrusted).sorted(by: >).prefix(k - 1)
        } else if !untrusted.isEmpty {
            top = Array(untrusted.sorted(by: >).prefix(k))
        } else {
            return nil
        }
        return descendingMean(top)
    }

    /// How `vector`, heard on `probeChannel`, scores against `profile` (§1.3, §1.4, §7). Nil when the profile has no
    /// sample of the vector's dimension. A trusted sample counts as trusted only on the probe's channel (nil equals
    /// nil); negatives count from every channel. `cohortMax` is always nil here; only `decideWithTrace` knows the cohort.
    ///
    /// For a profile scored per sound group (`GroupScoring.applies`), the group fields are filled too: the auto score
    /// A, the best group score G, the winning group's size, trusted count, trusted score and centroid cosine, and the
    /// S1 shadow.
    public static func evidence(_ vector: VoiceVector, against profile: ProfileCandidate, probeChannel: String? = nil,
                                policy: MatchPolicy = .default) -> ProfileEvidence? {
        evidence(vector, against: profile, probeChannel: probeChannel, policy: policy, groups: nil)
    }

    /// `evidence` with the profile's groups on the probe's channel already made (nil: made here when they apply).
    private static func evidence(_ vector: VoiceVector, against profile: ProfileCandidate, probeChannel: String?,
                                 policy: MatchPolicy, groups: [SampleGrouping.Group]?) -> ProfileEvidence? {
        guard let s = scored(vector, against: profile, topK: policy.scoringTopK, channel: .only(probeChannel)) else { return nil }
        let negativeMax = profile.negatives
            .filter { $0.dimension == vector.dimension }
            .map { vector.cosine($0) }
            .max()
        let blocked = negativeMax.map { atLeast($0, s.score) } ?? false
        var e = ProfileEvidence(profileID: profile.id, score: s.score, trustedTop: s.trustedTop,
                                trustedScore: s.trustedScore, trustedCount: s.trustedCount,
                                untrustedCount: s.untrustedCount, askOnly: s.trustedCount == 0,
                                negativeMax: negativeMax, blocked: blocked, cohortMax: nil,
                                otherChannelTrustedCount: s.otherChannelTrustedCount)
        if GroupScoring.applies(to: profile, policy: policy),
           let g = GroupScoring.score(vector, against: profile, channel: probeChannel, groups: groups, policy: policy) {
            e.groupCount = g.groups.count
            e.groupBestScore = g.best
            e.singletonBorrowShadow = g.singletonBorrowShadow
            if let w = g.winner {
                e.autoScore = w.score
                e.groupSize = w.size
                e.groupTrustedCount = w.trustedCount
                e.autoTrustedScore = w.trustedScore ?? s.trustedScore
                e.autoCentroidCosine = w.centroidCosine
            }
        }
        return e
    }

    /// Whether `evidence` was scored per sound group (its group count is set).
    static func usesGroups(_ e: ProfileEvidence) -> Bool { e.groupCount != nil }

    /// The score auto-labelling is decided on: A for a profile scored per group, else the whole score W.
    /// Nil when the profile is scored per group and no group on the probe's channel has a trusted member.
    static func autoScore(_ e: ProfileEvidence) -> Float? { usesGroups(e) ? e.autoScore : e.score }

    /// One decision per probe key. Pure, deterministic, order-independent. Same as `decideWithTrace(...).decisions`.
    public static func decide(probes: [SpeakerProbe], profiles: [ProfileCandidate], modelKey: String,
                              policy: MatchPolicy = .default, cohort: [VoiceVector] = []) -> [SpeakerKey: MatchDecision] {
        decideWithTrace(probes: probes, profiles: profiles, modelKey: modelKey, policy: policy, cohort: cohort).decisions
    }

    /// One decision and one trace per probe key (§1.3 to §1.6). Pure, deterministic, order-independent.
    ///
    /// Pre-filters each probe, scores it against every eligible profile with the trusted pair score, then assigns
    /// greedily from the highest score down so that one profile is offered to at most one speaker per recording.
    /// A profile blocked by a negative is never offered but still counts as runner-up, and so do `cohort` voices
    /// (unnamed voices from past recordings) that do not themselves score as that profile.
    /// Each probe is scored on its own `channel` (§7): trusted samples from another channel only fill second place,
    /// so a profile with none on the probe's channel can be asked about but never auto-labelled. With every sample
    /// and probe on one channel, the decisions are exactly those from before channels.
    ///
    /// Sound groups (decision D3, with `policy.groupScoring` and candidates that carry sample ids): auto-labelling is
    /// decided on the auto score A (`GroupScoring`), not the whole score W. It needs A ≥ `autoLabelMin`, A minus the
    /// runner-up ≥ `autoLabelMargin`, and every negative below A. The runner-up is symmetric: the best of 0, the cohort
    /// and, for every other profile, the larger of its W and its best group score G. Asking, blocking and the greedy
    /// order stay on W. An `askOnly` probe (a mixed speaker) is never auto-labelled. With groups off, or with no
    /// candidate carrying sample ids, the decisions are exactly those from before groups.
    /// Probe keys and profile ids are expected to be unique; if one repeats, its first occurrence is used.
    public static func decideWithTrace(probes: [SpeakerProbe], profiles: [ProfileCandidate], modelKey: String,
                                       policy: MatchPolicy = .default, cohort: [VoiceVector] = []) -> MatchRun {
        var decisions: [SpeakerKey: MatchDecision] = [:]
        var traces: [SpeakerKey: MatchTrace] = [:]

        // 1. Profiles that can be matched at all.
        var seenProfiles = Set<UUID>()
        let eligible = profiles.filter { p in
            p.modelKey == modelKey && !p.needsResample && !p.samples.isEmpty && seenProfiles.insert(p.id).inserted
        }

        // C_P: cohort voices that do not themselves score as P (§1.5), once per profile. The cohort is per profile,
        // not per probe, so it is scored ignoring channels, exactly as before channels.
        var cohortFor: [UUID: [VoiceVector]] = [:]
        for p in eligible {
            cohortFor[p.id] = cohort.filter { x in
                guard let s = scored(x, against: p, topK: policy.scoringTopK, channel: .any) else { return true }
                return !atLeast(s.score, policy.askMin)
            }
        }

        let traceVersion = policy.groupScoring ? MatchTrace.groupsVersion : MatchTrace.channelsVersion
        // Sound groups per (profile, channel, dimension), made once per run.
        var groupCache: [GroupCacheKey: [SampleGrouping.Group]] = [:]
        func groups(_ p: ProfileCandidate, _ channel: String?, _ dimension: Int) -> [SampleGrouping.Group]? {
            guard GroupScoring.applies(to: p, policy: policy) else { return nil }
            let key = GroupCacheKey(profileID: p.id, channel: channel, dimension: dimension)
            if let cached = groupCache[key] { return cached }
            let made = GroupScoring.groups(of: p, channel: channel, dimension: dimension, policy: policy) ?? []
            groupCache[key] = made
            return made
        }

        func trace(_ probe: SpeakerProbe, kind: TraceKind, reason: String, stats: CohortStats = .empty) -> MatchTrace {
            MatchTrace(version: traceVersion, key: probe.key, cleanSeconds: probe.cleanSeconds, kind: kind, profileID: nil, reason: reason,
                       score: nil, runnerUp: nil, margin: nil, profiles: [], cohortSize: stats.size,
                       cohortTopMean: stats.topMean, cohortTopStd: stats.topStd, autoLabelMin: policy.autoLabelMin,
                       autoLabelMargin: policy.autoLabelMargin, askMin: policy.askMin, probeChannel: probe.channel)
        }

        // 2. Per-probe pre-filter, then scoring.
        var triples: [Triple] = []
        var topScore: [SpeakerKey: Float] = [:]          // the probe's best score over all its eligible profiles
        var pending: [SpeakerKey: MatchTrace] = [:]       // traces of scored probes, completed after the walk
        var seenProbes = Set<SpeakerKey>()
        for probe in probes where seenProbes.insert(probe.key).inserted {
            guard let vector = probe.vector else {
                decisions[probe.key] = .unknown(.noVector)
                traces[probe.key] = trace(probe, kind: .unknown, reason: "noVector"); continue
            }
            let stats = cohortStats(vector, cohort: cohort, policy: policy)
            guard probe.cleanSeconds >= policy.minIdentifySeconds else {
                decisions[probe.key] = .unknown(.tooShort)
                traces[probe.key] = trace(probe, kind: .unknown, reason: "tooShort", stats: stats); continue
            }
            let candidates = eligible.filter { p in
                !probe.rejectedProfileIDs.contains(p.id) && p.samples.contains { $0.dimension == vector.dimension }
            }
            guard !candidates.isEmpty else {
                decisions[probe.key] = .unknown(.noEligibleProfiles)
                traces[probe.key] = trace(probe, kind: .unknown, reason: "noEligibleProfiles", stats: stats); continue
            }
            var evidences: [ProfileEvidence] = []
            for p in candidates {
                guard var e = evidence(vector, against: p, probeChannel: probe.channel, policy: policy,
                                       groups: groups(p, probe.channel, vector.dimension)) else { continue }
                e.cohortMax = (cohortFor[p.id] ?? [])
                    .filter { $0.dimension == vector.dimension }
                    .map { vector.cosine($0) }
                    .max()
                evidences.append(e)
                triples.append(Triple(probeKey: probe.key, profile: p, evidence: e))
                topScore[probe.key] = Swift.max(topScore[probe.key] ?? e.score, e.score)
            }
            evidences.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.profileID.uuidString < b.profileID.uuidString
            }
            var t = trace(probe, kind: .unknown, reason: "lowScore", stats: stats)
            t.profiles = evidences
            pending[probe.key] = t
        }

        // 3. Total order: score descending, then profile uuidString, then probe key. Blocked profiles included.
        triples.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.profileKey != b.profileKey { return a.profileKey < b.profileKey }
            return a.probeKey < b.probeKey
        }

        // The probe's own top-scoring profile is its first triple in that order (ties go to the lower uuidString).
        var topTriple: [SpeakerKey: Triple] = [:]
        for t in triples where topTriple[t.probeKey] == nil { topTriple[t.probeKey] = t }

        // Score per probe over each profile, used for the runner-up (taken and blocked profiles included): W, or the
        // larger of W and G for a profile scored per group, so the runner-up is as strict as the auto score.
        var scoresByProbe: [SpeakerKey: [(id: UUID, score: Float)]] = [:]
        for t in triples {
            scoresByProbe[t.probeKey, default: []].append((t.profile.id, Swift.max(t.score, t.evidence.groupBestScore ?? t.score)))
        }

        func runnerUp(_ t: Triple) -> Float {
            let others = scoresByProbe[t.probeKey, default: []].filter { $0.id != t.profile.id }.map(\.score)
            return Swift.max(0, others.max() ?? 0, t.evidence.cohortMax ?? 0)
        }
        let probeAskOnly = Dictionary(probes.map { ($0.key, $0.askOnly) }, uniquingKeysWith: { first, _ in first })

        // 4. Greedy walk.
        var taken = Set<UUID>()
        for t in triples {
            guard decisions[t.probeKey] == nil, !taken.contains(t.profile.id), !t.evidence.blocked else { continue }
            let best = t.score
            let second = runnerUp(t)
            let margin = best - second
            let downgraded = topTriple[t.probeKey]?.profile.id != t.profile.id
            let mixed = probeAskOnly[t.probeKey] ?? false
            let grouped = usesGroups(t.evidence)
            // The auto score and whether it passes the thresholds; for a profile scored without groups it is W.
            let auto = autoScore(t.evidence)
            let autoMargin = auto.map { $0 - second }
            let autoPasses = auto.map { atLeast($0, policy.autoLabelMin) && atLeast($0 - second, policy.autoLabelMargin) } ?? false
            let negativeNear = grouped && auto.map { a in t.evidence.negativeMax.map { atLeast($0, a) } ?? false } ?? false

            if !downgraded, !mixed, !t.evidence.askOnly, t.profile.autoLabel, autoPasses, !negativeNear,
               let auto, let autoMargin {
                decisions[t.probeKey] = .autoLabel(profileID: t.profile.id, score: auto, margin: autoMargin)
                taken.insert(t.profile.id)
                pending[t.probeKey]?.complete(.auto, profileID: t.profile.id, reason: "auto",
                                              score: auto, runnerUp: second, margin: autoMargin)
            } else if atLeast(best, policy.askMin) {
                let wholeWouldAuto = atLeast(best, policy.autoLabelMin) && atLeast(margin, policy.autoLabelMargin)
                let reason = downgraded ? "downgraded"
                    : mixed ? "mixedSource"
                    : t.evidence.askOnly ? ((t.evidence.otherChannelTrustedCount ?? 0) > 0 ? "otherChannel" : "askOnly")
                    : !t.profile.autoLabel ? "autoLabelOff"
                    : autoPasses && negativeNear ? "negativeNear"
                    : grouped && wholeWouldAuto ? "groupScore"
                    : !atLeast(auto ?? best, policy.autoLabelMin) ? "belowAuto"
                    : "margin"
                decisions[t.probeKey] = .ask(profileID: t.profile.id, score: best)
                taken.insert(t.profile.id)
                pending[t.probeKey]?.complete(.ask, profileID: t.profile.id, reason: reason,
                                              score: best, runnerUp: second, margin: margin)
            } else {
                decisions[t.probeKey] = .unknown(.lowScore(best: topScore[t.probeKey] ?? best))
            }
        }

        // 5. Probes whose every profile was taken by a stronger speaker or blocked.
        for (key, top) in topScore where decisions[key] == nil {
            decisions[key] = .unknown(.lowScore(best: top))
        }

        // 6. Unknown traces of scored probes: numbers for the probe's top profile, and why nothing was offered.
        for (key, var t) in pending {
            if t.kind == .unknown, let top = topTriple[key] {
                let reachedAsk = triples.contains { $0.probeKey == key && !$0.evidence.blocked && atLeast($0.score, policy.askMin) }
                let reason = top.evidence.blocked && !reachedAsk ? "blocked" : reachedAsk ? "taken" : "lowScore"
                let second = runnerUp(top)
                t.complete(.unknown, profileID: nil, reason: reason, score: topScore[key] ?? top.score,
                           runnerUp: second, margin: (topScore[key] ?? top.score) - second)
            }
            traces[key] = t
        }
        return MatchRun(decisions: decisions, traces: traces)
    }

    /// §1.10: the negatives a voice `vector` conflicts with once the user says it is `profile`, that is, those at
    /// least as close to the voice as the profile's own score on the voice's `probeChannel`. Negatives from every
    /// channel count. Pass the profile without this speaker's samples and call it before the new sample is added.
    /// Empty when the profile has no sample of the vector's dimension.
    public static func conflictingNegatives(_ vector: VoiceVector, profile: ProfileCandidate,
                                            negatives: [(id: UUID, vector: VoiceVector)], probeChannel: String? = nil,
                                            policy: MatchPolicy = .default) -> [UUID] {
        guard let s = scored(vector, against: profile, topK: policy.scoringTopK, channel: .only(probeChannel)) else { return [] }
        return negatives
            .filter { $0.vector.dimension == vector.dimension && atLeast(vector.cosine($0.vector), s.score) }
            .map(\.id)
    }

    // MARK: - Helpers

    private struct Scored {
        let score: Float
        let trustedTop: Float?
        let trustedScore: Float?
        let trustedCount: Int
        let untrustedCount: Int
        let otherChannelTrustedCount: Int
    }

    /// Which samples may count as trusted (D11).
    private enum ChannelFilter {
        /// Trust as stored, whatever the channel: the cohort filter, which is per profile, not per probe.
        case any
        /// Trusted only when heard on this channel (nil equals nil); trusted samples from another channel fall back to
        /// second place.
        case only(String?)
    }

    /// §1.3 against the samples of the vector's dimension. Nil when there are none.
    private static func scored(_ vector: VoiceVector, against profile: ProfileCandidate, topK: Int,
                               channel: ChannelFilter) -> Scored? {
        var trusted: [Float] = [], untrusted: [Float] = []
        var otherChannelTrusted = 0
        for (i, sample) in profile.samples.enumerated() where sample.dimension == vector.dimension {
            let c = vector.cosine(sample)
            let sameChannel: Bool
            switch channel {
            case .any: sameChannel = true
            case .only(let probeChannel): sameChannel = profile.channels[i] == probeChannel
            }
            if profile.trusted[i] && sameChannel {
                trusted.append(c)
            } else {
                untrusted.append(c)
                if profile.trusted[i] { otherChannelTrusted += 1 }
            }
        }
        guard let score = pairScore(trusted: trusted, untrusted: untrusted, topK: topK) else { return nil }
        let t = trusted.sorted(by: >)
        let trustedScore = t.isEmpty ? nil : descendingMean(Array(t.prefix(Swift.max(1, topK))))
        return Scored(score: score, trustedTop: t.first, trustedScore: trustedScore, trustedCount: trusted.count,
                      untrustedCount: untrusted.count, otherChannelTrustedCount: otherChannelTrusted)
    }

    /// Mean of `values`, summed in descending order so the result does not depend on their order.
    private static func descendingMean(_ values: [Float]) -> Float {
        let sorted = values.sorted(by: >)
        return sorted.reduce(Float(0), +) / Float(sorted.count)
    }

    private struct CohortStats {
        let size: Int
        let topMean: Float?
        let topStd: Float?
        static let empty = CohortStats(size: 0, topMean: nil, topStd: nil)
    }

    /// Trace-only statistics of the probe's cosines with the whole cohort (z-normalisation is log-only, D11).
    private static func cohortStats(_ vector: VoiceVector, cohort: [VoiceVector], policy: MatchPolicy) -> CohortStats {
        let cosines = cohort.filter { $0.dimension == vector.dimension }.map { Double(vector.cosine($0)) }
        guard cosines.count >= policy.cohortStatsMinCount, policy.cohortStatsTopN > 0, !cosines.isEmpty else {
            return CohortStats(size: cosines.count, topMean: nil, topStd: nil)
        }
        let top = cosines.sorted(by: >).prefix(policy.cohortStatsTopN)
        let mean = top.reduce(0, +) / Double(top.count)
        let variance = top.map { ($0 - mean) * ($0 - mean) }.sorted().reduce(0, +) / Double(top.count)
        return CohortStats(size: cosines.count, topMean: Float(mean), topStd: Float(variance.squareRoot()))
    }

    private struct GroupCacheKey: Hashable {
        let profileID: UUID
        let channel: String?
        let dimension: Int
    }

    private struct Triple {
        let probeKey: SpeakerKey
        let profile: ProfileCandidate
        let evidence: ProfileEvidence
        let profileKey: String
        var score: Float { evidence.score }
        init(probeKey: SpeakerKey, profile: ProfileCandidate, evidence: ProfileEvidence) {
            self.probeKey = probeKey; self.profile = profile; self.evidence = evidence
            self.profileKey = profile.id.uuidString
        }
    }
}

private extension MatchTrace {
    mutating func complete(_ kind: TraceKind, profileID: UUID?, reason: String, score: Float, runnerUp: Float, margin: Float) {
        self.kind = kind; self.profileID = profileID; self.reason = reason
        self.score = score; self.runnerUp = runnerUp; self.margin = margin
    }
}

/// Threshold comparisons for cosine-derived values.
///
/// Cosines of Float32 vectors carry rounding error of a few ulps (about 1e-7 at 0.5), so a value meant to sit
/// exactly on a threshold such as 0.55 can arrive as 0.54999995. `atLeast` accepts values within `epsilon`
/// below the threshold. The epsilon is far below the 1e-4 resolution at which thresholds are tuned.
enum MatchTolerance {
    static let epsilon: Float = 1e-5
}

@inline(__always)
func atLeast(_ value: Float, _ threshold: Float) -> Bool {
    value >= threshold - MatchTolerance.epsilon
}
