import Foundation

public enum SampleCurator {
    /// Whether a new embedding may be stored for this trigger.
    ///
    /// - `.strongMatch`: only for an auto-label with score ≥ `strongMatchMin` and margin ≥ `strongMatchMargin`,
    ///   and at least `minSampleSeconds` of clean speech.
    /// - `.named`, `.confirmed`, `.addedFromRecording`: at least `minSampleSeconds` of clean speech.
    /// - `.merged`: always (the sample already passed a gate when it was first stored).
    public static func shouldAddSample(origin: SampleOrigin, decision: MatchDecision?,
                                       cleanSeconds: TimeInterval, policy: MatchPolicy = .default) -> Bool {
        let enoughSpeech = cleanSeconds >= policy.minSampleSeconds
        switch origin {
        case .strongMatch:
            guard case .autoLabel(_, let score, let margin)? = decision else { return false }
            return enoughSpeech && atLeast(score, policy.strongMatchMin) && atLeast(margin, policy.strongMatchMargin)
        case .named, .confirmed, .addedFromRecording:
            return enoughSpeech
        case .merged:
            return true
        }
    }

    /// Adds `new` to a profile's samples (§5.3).
    ///
    /// 1. Skipped (`added == false`, `keep == existing`) when its cosine with any existing sample is ≥ `duplicateCosine`.
    /// 2. Otherwise appended. While the set exceeds `maxSamplesPerProfile`, one sample is evicted. The new sample and
    ///    the earliest `.named` sample are never evicted. `.strongMatch` samples go first; within the class the most
    ///    redundant one (highest mean cosine to the other samples) goes, ties to the oldest.
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
            let strong = evictable.filter { $0.origin == .strongMatch }
            let pool = strong.isEmpty ? evictable : strong
            guard let victim = mostRedundant(pool, within: keep) else { break }
            keep.removeAll { $0.id == victim.id }
            evicted.append(victim.id)
        }
        return SampleInsertResult(keep: keep, evicted: evicted, added: true)
    }

    // MARK: - Helpers

    private static func earliestNamed(in samples: [CuratedSample]) -> UUID? {
        samples.filter { $0.origin == .named }.min(by: isOlder)?.id
    }

    /// Oldest first; equal dates fall back to the id string so the choice never depends on input order.
    private static func isOlder(_ a: CuratedSample, _ b: CuratedSample) -> Bool {
        if a.addedAt != b.addedAt { return a.addedAt < b.addedAt }
        return a.id.uuidString < b.id.uuidString
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
