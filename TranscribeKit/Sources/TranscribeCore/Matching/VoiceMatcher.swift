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

    /// One decision per probe key. Pure, deterministic, order-independent.
    ///
    /// Implements §5.2: pre-filter each probe, score it against every eligible profile, then assign greedily
    /// from the highest score down so that one profile is offered to at most one speaker per recording.
    /// Probe keys and profile ids are expected to be unique; if one repeats, its first occurrence is used.
    public static func decide(probes: [SpeakerProbe], profiles: [ProfileCandidate],
                              modelKey: String, policy: MatchPolicy = .default) -> [SpeakerKey: MatchDecision] {
        var decisions: [SpeakerKey: MatchDecision] = [:]

        // 1. Profiles that can be matched at all.
        var seenProfiles = Set<UUID>()
        let eligible = profiles.filter { p in
            p.modelKey == modelKey && !p.needsResample && !p.samples.isEmpty && seenProfiles.insert(p.id).inserted
        }

        // 2. Per-probe pre-filter, then scoring.
        var triples: [Triple] = []
        var topScore: [SpeakerKey: Float] = [:]          // the probe's best score over all its eligible profiles
        var seenProbes = Set<SpeakerKey>()
        for probe in probes where seenProbes.insert(probe.key).inserted {
            guard let vector = probe.vector else {
                decisions[probe.key] = .unknown(.noVector); continue
            }
            guard probe.cleanSeconds >= policy.minIdentifySeconds else {
                decisions[probe.key] = .unknown(.tooShort); continue
            }
            let candidates = eligible.filter { p in
                !probe.rejectedProfileIDs.contains(p.id) && p.samples.contains { $0.dimension == vector.dimension }
            }
            guard !candidates.isEmpty else {
                decisions[probe.key] = .unknown(.noEligibleProfiles); continue
            }
            for p in candidates {
                let s = score(vector, against: p, topK: policy.scoringTopK)
                triples.append(Triple(probeKey: probe.key, profile: p, score: s))
                topScore[probe.key] = Swift.max(topScore[probe.key] ?? s, s)
            }
        }

        // 3. Total order: score descending, then profile uuidString, then probe key.
        triples.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.profileKey != b.profileKey { return a.profileKey < b.profileKey }
            return a.probeKey < b.probeKey
        }

        // The probe's own top-scoring profile is its first triple in that order (ties go to the lower uuidString).
        var topProfile: [SpeakerKey: UUID] = [:]
        for t in triples where topProfile[t.probeKey] == nil { topProfile[t.probeKey] = t.profile.id }

        // Best score per probe over each profile, used for the runner-up (taken profiles included).
        var scoresByProbe: [SpeakerKey: [(id: UUID, score: Float)]] = [:]
        for t in triples { scoresByProbe[t.probeKey, default: []].append((t.profile.id, t.score)) }

        // 4. Greedy walk.
        var taken = Set<UUID>()
        for t in triples {
            guard decisions[t.probeKey] == nil, !taken.contains(t.profile.id) else { continue }
            let best = t.score
            let others = scoresByProbe[t.probeKey, default: []].filter { $0.id != t.profile.id }.map(\.score)
            let runnerUp = Swift.max(0, others.max() ?? 0)
            let margin = best - runnerUp
            let downgraded = topProfile[t.probeKey] != t.profile.id

            if !downgraded, atLeast(best, policy.autoLabelMin), atLeast(margin, policy.autoLabelMargin),
               t.profile.autoLabel {
                decisions[t.probeKey] = .autoLabel(profileID: t.profile.id, score: best, margin: margin)
                taken.insert(t.profile.id)
            } else if atLeast(best, policy.askMin) {
                decisions[t.probeKey] = .ask(profileID: t.profile.id, score: best)
                taken.insert(t.profile.id)
            } else {
                decisions[t.probeKey] = .unknown(.lowScore(best: topScore[t.probeKey] ?? best))
            }
        }

        // 5. Probes whose every profile was taken by a stronger speaker.
        for (key, top) in topScore where decisions[key] == nil {
            decisions[key] = .unknown(.lowScore(best: top))
        }
        return decisions
    }

    private struct Triple {
        let probeKey: SpeakerKey
        let profile: ProfileCandidate
        let score: Float
        let profileKey: String
        init(probeKey: SpeakerKey, profile: ProfileCandidate, score: Float) {
            self.probeKey = probeKey; self.profile = profile; self.score = score
            self.profileKey = profile.id.uuidString
        }
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
