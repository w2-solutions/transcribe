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

    /// Adds `new` to a profile's samples (§1.8).
    ///
    /// 1. Skipped (`added == false`, `keep == existing`) when its cosine with any existing sample is ≥ `duplicateCosine`.
    /// 2. Otherwise appended. While the set exceeds `maxSamplesPerProfile`, one sample is evicted. The new sample and
    ///    the earliest `.named` sample are never evicted. Automatic samples go first, then short (untrusted user)
    ///    samples, then trusted ones; within the class the most redundant one (highest mean cosine to the other
    ///    samples) goes, ties to the oldest.
    ///
    /// `keep` preserves the input order with `new` last. Samples of a different dimension are never treated as
    /// duplicates and contribute nothing to redundancy.
    public static func insert(_ new: CuratedSample, into existing: [CuratedSample],
                              policy: MatchPolicy = .default) -> SampleInsertResult {
        let isDuplicate = existing.contains { s in
            s.vector.dimension == new.vector.dimension && atLeast(s.vector.cosine(new.vector), policy.duplicateCosine)
        }
        if isDuplicate { return SampleInsertResult(keep: existing, evicted: [], added: false) }

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
