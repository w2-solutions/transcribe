import Foundation

public enum SampleCurator {
    /// Whether a new embedding may be stored for this trigger (§1.7).
    ///
    /// - `.named`, `.addedFromRecording`: at least `minSampleSeconds` of clean speech.
    /// - `.confirmed`, `.corrected`: at least `minLearnSeconds` (the user vouched for an existing person).
    /// - `.merged`: always (the sample already passed a gate when it was first stored).
    /// - `.strongMatch`: the decision-only legacy gate: an auto-label with score ≥ `strongMatchMin` and
    ///   margin ≥ `strongMatchMargin`, and at least `minSampleSeconds` of clean speech. New code should use
    ///   `shouldAddAutomaticSample`, which measures the score on trusted samples only.
    public static func shouldAddSample(origin: SampleOrigin, decision: MatchDecision?,
                                       cleanSeconds: TimeInterval, policy: MatchPolicy = .default) -> Bool {
        switch origin {
        case .strongMatch:
            guard case .autoLabel(_, let score, let margin)? = decision else { return false }
            return cleanSeconds >= policy.minSampleSeconds
                && atLeast(score, policy.strongMatchMin) && atLeast(margin, policy.strongMatchMargin)
        case .named, .addedFromRecording:
            return cleanSeconds >= policy.minSampleSeconds
        case .confirmed, .corrected:
            return cleanSeconds >= policy.minLearnSeconds
        case .merged:
            return true
        }
    }

    /// Whether an auto-label may store an automatic (`.strongMatch`) sample (§1.7).
    ///
    /// The auto-label's margin must be ≥ `strongMatchMargin`, the profile's trusted samples alone must score
    /// ≥ `strongMatchMin` (so an automatic sample never vouches for the next one), the speaker's span coherence
    /// must be ≥ `minAutoSampleCoherence`, and there must be at least `minSampleSeconds` of clean speech.
    public static func shouldAddAutomaticSample(decision: MatchDecision?, trustedScore: Float?, coherence: Float?,
                                                cleanSeconds: TimeInterval, policy: MatchPolicy = .default) -> Bool {
        guard case .autoLabel(_, _, let margin)? = decision, atLeast(margin, policy.strongMatchMargin),
              let trustedScore, atLeast(trustedScore, policy.strongMatchMin),
              let coherence, atLeast(coherence, policy.minAutoSampleCoherence) else { return false }
        return cleanSeconds >= policy.minSampleSeconds
    }

    /// The automatic-sample gate on the matcher's evidence for the auto-labelled profile (§1.7, decision D3).
    ///
    /// For a profile scored per sound group (`evidence.groupCount` set), the trusted score is measured in the winning
    /// group (`autoTrustedScore`) and the voice must join that group: `q(autoCentroidCosine)` ≥ `q(groupJoinCosine)`.
    /// Otherwise it is `shouldAddAutomaticSample(decision:trustedScore:...)` with `evidence.trustedScore`, as before.
    /// Pass the evidence measured before the insert (`VoiceMatcher.evidence` on the probe's channel).
    public static func shouldAddAutomaticSample(decision: MatchDecision?, evidence: ProfileEvidence?, coherence: Float?,
                                                cleanSeconds: TimeInterval, policy: MatchPolicy = .default) -> Bool {
        guard let evidence else { return false }
        guard evidence.groupCount != nil else {
            return shouldAddAutomaticSample(decision: decision, trustedScore: evidence.trustedScore, coherence: coherence,
                                            cleanSeconds: cleanSeconds, policy: policy)
        }
        guard let centroid = evidence.autoCentroidCosine, GroupScoring.joins(centroidCosine: centroid, policy: policy)
        else { return false }
        return shouldAddAutomaticSample(decision: decision, trustedScore: evidence.autoTrustedScore, coherence: coherence,
                                        cleanSeconds: cleanSeconds, policy: policy)
    }

    /// Adds `new` to a profile's samples on one channel (§1.8, decision D4).
    ///
    /// 1. Skipped (`added == false`, `keep == existing`) when its cosine with any existing sample is ≥ `duplicateCosine`.
    /// 2. Otherwise appended. With `policy.groupScoring` off, while the set exceeds `maxSamplesPerProfile` one sample
    ///    is evicted: never the new sample or the earliest `.named` one; automatic samples go first, then short
    ///    (untrusted user) samples, then trusted ones; within the class the most redundant one (highest mean cosine
    ///    to the other samples) goes, ties to the oldest.
    /// 3. With groups on, eviction keeps every sound group: see `curate` below. The groups G₀ are taken from
    ///    `existing`, before the insert.
    ///
    /// `keep` preserves the input order with `new` last. Samples of a different dimension are never treated as
    /// duplicates and contribute nothing to redundancy.
    public static func insert(_ new: CuratedSample, into existing: [CuratedSample],
                              policy: MatchPolicy = .default) -> SampleInsertResult {
        let isDuplicate = existing.contains { s in
            s.vector.dimension == new.vector.dimension && atLeast(s.vector.cosine(new.vector), policy.duplicateCosine)
        }
        if isDuplicate { return SampleInsertResult(keep: existing, evicted: [], added: false) }

        if policy.groupScoring {
            let keep = existing + [new]
            guard keep.count > Swift.max(0, policy.maxSamplesPerProfile) else {
                return SampleInsertResult(keep: keep, evicted: [], added: true)
            }
            let g0 = groups(existing, policy: policy)
            let neverEvict = Set([new.id] + [earliestNamed(in: existing)].compactMap { $0 })
            let protected = neverEvict.union(representatives(g0, in: existing, policy: policy))
            let r = curate(keep, groups: g0, protected: protected, neverEvict: neverEvict, policy: policy)
            return SampleInsertResult(keep: r.keep, evicted: r.evicted, added: true)
        }

        var keep = existing + [new]
        var evicted: [UUID] = []
        let cap = Swift.max(0, policy.maxSamplesPerProfile)
        let protectedNamed = earliestNamed(in: existing)

        while keep.count > cap {
            let evictable = keep.filter { $0.id != new.id && $0.id != protectedNamed }
            guard let lowest = evictable.map({ evictionClass($0, policy) }).min() else { break }
            let pool = evictable.filter { evictionClass($0, policy) == lowest }
            guard let victim = mostRedundant(pool, within: keep) else { break }
            keep.removeAll { $0.id == victim.id }
            evicted.append(victim.id)
        }
        return SampleInsertResult(keep: keep, evicted: evicted, added: true)
    }

    /// Adds several samples to one profile's samples on one channel at once: the samples of a profile merged into
    /// this one (decision D4).
    ///
    /// `incoming` is taken in canonical order (`addedAtMillis`, then `id.uuidString`); each is skipped when it is a
    /// near-duplicate (≥ `duplicateCosine`) of a sample already kept or accepted. With groups off, the result is
    /// `insert` applied to each in that order. With groups on, G₀ is the groups of `existing` and the groups of the
    /// accepted incoming samples, made separately, and both sets of representatives are protected, as are the
    /// earliest `.named` sample of each side; then `curate` evicts.
    ///
    /// `keep` is `existing` (less evictions) in input order followed by the kept incoming samples in canonical order.
    public static func insertMany(_ incoming: [CuratedSample], into existing: [CuratedSample],
                                  policy: MatchPolicy = .default) -> SampleMergeResult {
        let ordered = incoming.sorted { isOlder($0, $1) }
        let existingIDs = Set(existing.map(\.id))

        guard policy.groupScoring else {
            var keep = existing
            var evicted: [UUID] = []
            for s in ordered {
                let r = insert(s, into: keep, policy: policy)
                guard r.added else { continue }
                keep = r.keep
                evicted += r.evicted
            }
            return mergeResult(keep: keep, existingIDs: existingIDs, incoming: ordered, evictedAll: evicted)
        }

        var accepted: [CuratedSample] = []
        for s in ordered {
            let isDuplicate = (existing + accepted).contains { k in
                k.vector.dimension == s.vector.dimension && atLeast(k.vector.cosine(s.vector), policy.duplicateCosine)
            }
            if !isDuplicate { accepted.append(s) }
        }
        let keep = existing + accepted
        guard keep.count > Swift.max(0, policy.maxSamplesPerProfile) else {
            return mergeResult(keep: keep, existingIDs: existingIDs, incoming: ordered, evictedAll: [])
        }
        let g0 = groups(existing, policy: policy) + groups(accepted, policy: policy)
        let neverEvict = Set([earliestNamed(in: existing), earliestNamed(in: accepted)].compactMap { $0 })
        let protected = neverEvict
            .union(representatives(g0, in: existing + accepted, policy: policy))
        let r = curate(keep, groups: g0, protected: protected, neverEvict: neverEvict, policy: policy)
        return mergeResult(keep: r.keep, existingIDs: existingIDs, incoming: ordered, evictedAll: r.evicted)
    }

    private static func mergeResult(keep: [CuratedSample], existingIDs: Set<UUID>, incoming: [CuratedSample],
                                    evictedAll: [UUID]) -> SampleMergeResult {
        let kept = Set(keep.map(\.id))
        return SampleMergeResult(keep: keep,
                                 evicted: evictedAll.filter { existingIDs.contains($0) },
                                 addedIDs: incoming.map(\.id).filter { kept.contains($0) },
                                 skippedIDs: incoming.map(\.id).filter { !kept.contains($0) })
    }

    /// Adds `new` to a profile's negatives (§1.9).
    ///
    /// Skipped when an existing negative is a near-duplicate (same dimension, cosine ≥ `duplicateCosine`) or comes
    /// from the same speaker. Otherwise appended; while the set exceeds `maxNegativesPerProfile` the oldest
    /// (by `addedAt`, then id) is evicted, never the new one. `keep` preserves the input order with `new` last.
    public static func insertNegative(_ new: CuratedNegative, into existing: [CuratedNegative],
                                      policy: MatchPolicy = .default) -> NegativeInsertResult {
        let isDuplicate = existing.contains { n in
            if let source = new.sourceSpeakerID, n.sourceSpeakerID == source { return true }
            return n.vector.dimension == new.vector.dimension && atLeast(n.vector.cosine(new.vector), policy.duplicateCosine)
        }
        if isDuplicate { return NegativeInsertResult(keep: existing, evicted: [], added: false) }

        var keep = existing + [new]
        var evicted: [UUID] = []
        let cap = Swift.max(0, policy.maxNegativesPerProfile)
        while keep.count > cap {
            guard let victim = keep.filter({ $0.id != new.id }).min(by: { isOlder($0.addedAt, $0.id, $1.addedAt, $1.id) })
            else { break }
            keep.removeAll { $0.id == victim.id }
            evicted.append(victim.id)
        }
        return NegativeInsertResult(keep: keep, evicted: evicted, added: true)
    }

    // MARK: - Group-preserving curation (decision D4)

    /// The sound groups G₀ of `samples` (every dimension present, each grouped on its own), at `groupJoinCosine`.
    /// Curation is per channel, so every sample is put on one channel.
    static func groups(_ samples: [CuratedSample], policy: MatchPolicy) -> [SampleGrouping.Group] {
        let items = samples.map { SampleGrouping.Item(id: $0.id, vector: $0.vector, channel: "", addedAtMillis: $0.addedAtMillis) }
        let dimensions = Set(samples.map(\.vector.dimension)).sorted()
        return dimensions.flatMap { SampleGrouping.group(items, dimension: $0, policy: GroupScoring.groupPolicy(policy)) }
    }

    /// One representative per group with a non-automatic member: its first trusted member in `representativeIDs`
    /// order, else its first short (untrusted user) member. Groups made only of automatic samples have none.
    static func representatives(_ groups: [SampleGrouping.Group], in samples: [CuratedSample],
                                policy: MatchPolicy) -> Set<UUID> {
        let byID = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out = Set<UUID>()
        for g in groups {
            let members = g.representativeIDs.compactMap { byID[$0] }
            if let t = members.first(where: { evictionClass($0, policy) == 2 }) ?? members.first(where: { evictionClass($0, policy) == 1 }) {
                out.insert(t.id)
            }
        }
        return out
    }

    /// Evicts from `keep` down to the soft cap and the ceiling, keeping every group of `groups` (G₀).
    ///
    /// 1. While the set exceeds `maxSamplesPerProfile` and an unprotected sample remains, the first unprotected
    ///    sample by: lowest class (automatic, short, trusted); member of the largest group (members still kept; a
    ///    sample in no group of G₀ is a group of its own); smaller group key `uuidString`; highest
    ///    `q(mean cosine to the other kept members of its group)`; oldest (`addedAtMillis`, then id).
    /// 2. While it still exceeds `sampleCeilingPerChannel` (at least the soft cap), a protected sample not in
    ///    `neverEvict` by: lowest class; highest `q(average linkage of its group to the nearest other group)`, members
    ///    still kept; oldest.
    ///
    /// So every group of G₀ with a non-automatic member keeps at least one member unless step 2 runs. Every comparison
    /// is on quantised scores with id tie-breaks, so the result does not depend on the order of `keep`.
    static func curate(_ keep: [CuratedSample], groups: [SampleGrouping.Group], protected: Set<UUID>,
                       neverEvict: Set<UUID>, policy: MatchPolicy) -> (keep: [CuratedSample], evicted: [UUID]) {
        var keep = keep
        var evicted: [UUID] = []
        var groupOf: [UUID: UUID] = [:]
        for g in groups { for m in g.memberIDs { groupOf[m] = g.key } }
        func key(_ s: CuratedSample) -> UUID { groupOf[s.id] ?? s.id }
        func members(_ k: UUID) -> [CuratedSample] { keep.filter { key($0) == k } }

        let soft = Swift.max(0, policy.maxSamplesPerProfile)
        while keep.count > soft {
            let pool = keep.filter { !protected.contains($0.id) }
            guard !pool.isEmpty else { break }
            let sizes = Dictionary(keep.map { (key($0), 1) }, uniquingKeysWith: +)
            let ranked = pool.map { s -> (sample: CuratedSample, cls: Int, size: Int, key: String, redundancy: Int) in
                let others = members(key(s)).filter { $0.id != s.id }.map(\.vector)
                let redundancy = SampleGrouping.averageLinkage([s.vector], others).map(SampleGrouping.q) ?? Int.min
                return (s, evictionClass(s, policy), sizes[key(s)] ?? 1, key(s).uuidString, redundancy)
            }
            let victim = ranked.min { a, b in
                if a.cls != b.cls { return a.cls < b.cls }
                if a.size != b.size { return a.size > b.size }
                if a.key != b.key { return a.key < b.key }
                if a.redundancy != b.redundancy { return a.redundancy > b.redundancy }
                return isOlderMillis(a.sample, b.sample)
            }!.sample
            keep.removeAll { $0.id == victim.id }
            evicted.append(victim.id)
        }

        let ceiling = Swift.max(soft, policy.sampleCeilingPerChannel)
        while keep.count > ceiling {
            let pool = keep.filter { !neverEvict.contains($0.id) }
            guard !pool.isEmpty else { break }
            let keys = Set(keep.map(key)).sorted { $0.uuidString < $1.uuidString }
            let ranked = pool.map { s -> (sample: CuratedSample, cls: Int, nearest: Int) in
                let own = members(key(s)).map(\.vector)
                let nearest = keys.filter { $0 != key(s) }
                    .compactMap { SampleGrouping.averageLinkage(own, members($0).map(\.vector)).map(SampleGrouping.q) }
                    .max() ?? Int.min
                return (s, evictionClass(s, policy), nearest)
            }
            let victim = ranked.min { a, b in
                if a.cls != b.cls { return a.cls < b.cls }
                if a.nearest != b.nearest { return a.nearest > b.nearest }
                return isOlderMillis(a.sample, b.sample)
            }!.sample
            keep.removeAll { $0.id == victim.id }
            evicted.append(victim.id)
        }
        return (keep, evicted)
    }

    /// Oldest first by synced milliseconds, then the id string.
    private static func isOlderMillis(_ a: CuratedSample, _ b: CuratedSample) -> Bool {
        a.addedAtMillis != b.addedAtMillis ? a.addedAtMillis < b.addedAtMillis : a.id.uuidString < b.id.uuidString
    }

    // MARK: - Helpers

    private static func earliestNamed(in samples: [CuratedSample]) -> UUID? {
        samples.filter { $0.origin == .named }.min(by: isOlder)?.id
    }

    /// 0 automatic, 1 short (untrusted user sample), 2 trusted: the lowest non-empty class is evicted first.
    private static func evictionClass(_ s: CuratedSample, _ policy: MatchPolicy) -> Int {
        if s.origin.isAutomatic { return 0 }
        return SampleTrust.isTrusted(origin: s.origin, speechSeconds: s.speechSeconds, policy: policy) ? 2 : 1
    }

    /// Oldest first; equal dates fall back to the id string so the choice never depends on input order.
    private static func isOlder(_ a: CuratedSample, _ b: CuratedSample) -> Bool {
        isOlder(a.addedAt, a.id, b.addedAt, b.id)
    }

    private static func isOlder(_ aDate: Date, _ aID: UUID, _ bDate: Date, _ bID: UUID) -> Bool {
        if aDate != bDate { return aDate < bDate }
        return aID.uuidString < bID.uuidString
    }

    /// The candidate with the highest mean cosine to the rest of `set`; near-equal means go to the oldest.
    private static func mostRedundant(_ candidates: [CuratedSample], within set: [CuratedSample]) -> CuratedSample? {
        var best: (sample: CuratedSample, redundancy: Float)?
        for c in candidates {
            let r = redundancy(of: c, within: set)
            guard let current = best else { best = (c, r); continue }
            if r > current.redundancy + MatchTolerance.epsilon {
                best = (c, r)
            } else if abs(r - current.redundancy) <= MatchTolerance.epsilon, isOlder(c, current.sample) {
                best = (c, r)
            }
        }
        return best?.sample
    }

    private static func redundancy(of sample: CuratedSample, within set: [CuratedSample]) -> Float {
        let others = set.filter { $0.id != sample.id }
        guard !others.isEmpty else { return 0 }
        // Sorted before summing so the mean does not depend on the order of the samples.
        let cosines = others.map { o -> Float in
            o.vector.dimension == sample.vector.dimension ? sample.vector.cosine(o.vector) : 0
        }.sorted()
        return cosines.reduce(Float(0), +) / Float(cosines.count)
    }
}
