import Foundation
import Testing
@testable import TranscribeCore

private func sample(_ n: Int, _ vector: VoiceVector, _ origin: SampleOrigin = .confirmed, day: Int,
                    seconds: TimeInterval = 60) -> CuratedSample {
    CuratedSample(id: TV.uuid(0x100 + n), vector: vector, origin: origin,
                  addedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400), speechSeconds: seconds)
}

private func sample(_ n: Int, axis: Int, _ origin: SampleOrigin = .confirmed, day: Int,
                    seconds: TimeInterval = 60) -> CuratedSample {
    sample(n, TV.axis(axis), origin, day: day, seconds: seconds)
}

/// The cap these tests were written for; the default is now 12.
private let capEight: MatchPolicy = { var p = MatchPolicy.default; p.maxSamplesPerProfile = 8; return p }()

@Suite("SampleCurator.shouldAddSample")
struct SampleCuratorGateTests {
    static let strong = MatchDecision.autoLabel(profileID: TV.liamID, score: 0.9, margin: 0.5)

    @Test("Seconds gate per origin", arguments: SampleOrigin.allCases, [4.99, 5.0, 9.99, 10.0])
    func secondsGatePerOrigin(origin: SampleOrigin, seconds: TimeInterval) {
        let decision: MatchDecision? = origin == .strongMatch ? Self.strong : nil
        let allowed = SampleCurator.shouldAddSample(origin: origin, decision: decision, cleanSeconds: seconds)
        let expected = switch origin {
        case .merged: true
        case .confirmed, .corrected: seconds >= 5
        case .named, .addedFromRecording, .strongMatch: seconds >= 10
        }
        #expect(allowed == expected)
    }

    @Test func mergedNeedsNoSpeechOrDecision() {
        #expect(SampleCurator.shouldAddSample(origin: .merged, decision: nil, cleanSeconds: 0))
    }

    @Test("Strong-match thresholds",
          arguments: [(Float(0.6999), Float(0.30), false), (0.70, 0.20, true), (0.90, 0.1999, false),
                      (0.70, 0.1999, false), (0.6999, 0.20, false), (0.95, 0.60, true)])
    func strongMatchThresholds(score: Float, margin: Float, allowed: Bool) {
        let d = MatchDecision.autoLabel(profileID: TV.liamID, score: score, margin: margin)
        #expect(SampleCurator.shouldAddSample(origin: .strongMatch, decision: d, cleanSeconds: 30) == allowed)
    }

    @Test func strongMatchAcceptsAMarginComputedAtTheBoundary() {
        // 0.9 − 0.7 in Float32 is 0.19999999; it is meant as 0.20 and must pass.
        let best: Float = 0.9, runnerUp: Float = 0.7
        let d = MatchDecision.autoLabel(profileID: TV.liamID, score: best, margin: best - runnerUp)
        #expect(SampleCurator.shouldAddSample(origin: .strongMatch, decision: d, cleanSeconds: 30))
    }

    @Test("Strong match needs an auto-label decision",
          arguments: [MatchDecision.ask(profileID: TV.liamID, score: 0.95), .unknown(.lowScore(best: 0.9)), .unknown(.tooShort)])
    func strongMatchNeedsAutoLabel(_ decision: MatchDecision) {
        #expect(!SampleCurator.shouldAddSample(origin: .strongMatch, decision: decision, cleanSeconds: 30))
        #expect(!SampleCurator.shouldAddSample(origin: .strongMatch, decision: nil, cleanSeconds: 30))
    }
}

@Suite("SampleCurator.insert")
struct SampleCuratorTests {

    @Test("Duplicate skip at 0.95", arguments: [(Float(0.95), false), (0.97, false), (0.9499, true)])
    func duplicateSkip(cosine: Float, added: Bool) {
        let existing = [sample(0, axis: 0, .named, day: 0), sample(1, axis: 1, day: 1)]
        let new = sample(9, TV.vector([0: cosine], residual: 40), day: 9)
        let r = SampleCurator.insert(new, into: existing)
        #expect(r.added == added)
        #expect(r.evicted.isEmpty)
        #expect(r.keep.map(\.id) == (added ? existing.map(\.id) + [new.id] : existing.map(\.id)))
    }

    @Test func capOfEight() {
        let seven = (0..<7).map { sample($0, axis: $0, day: $0) }
        let r7 = SampleCurator.insert(sample(9, axis: 9, day: 9), into: seven, policy: capEight)
        #expect(r7.added && r7.keep.count == 8 && r7.evicted.isEmpty)

        let eight = (0..<8).map { sample($0, axis: $0, day: $0) }
        let r8 = SampleCurator.insert(sample(9, axis: 9, day: 9), into: eight, policy: capEight)
        #expect(r8.added && r8.keep.count == 8 && r8.evicted.count == 1)
        #expect(Set(r8.keep.map(\.id)).isDisjoint(with: r8.evicted))
    }

    @Test func customCap() {
        var policy = MatchPolicy.default
        policy.maxSamplesPerProfile = 3
        let three = (0..<3).map { sample($0, axis: $0, day: $0) }
        let r = SampleCurator.insert(sample(9, axis: 9, day: 9), into: three, policy: policy)
        #expect(r.keep.count == 3 && r.evicted == [TV.uuid(0x100)])   // all equally redundant → oldest
    }

    @Test func strongMatchSamplesAreEvictedFirst() {
        // X is the most redundant sample, but the strong-match sample (e7, not redundant at all) goes first.
        let x = sample(1, TV.vector([3: 0.5, 4: 0.5], residual: 40), day: 7)
        let existing = [sample(0, axis: 0, .named, day: 0), x,
                        sample(3, axis: 3, day: 3), sample(4, axis: 4, day: 4), sample(5, axis: 5, day: 5),
                        sample(6, axis: 6, day: 6), sample(7, axis: 7, .strongMatch, day: 8), sample(8, axis: 8, day: 2)]
        let r = SampleCurator.insert(sample(9, axis: 9, .addedFromRecording, day: 9), into: existing, policy: capEight)
        #expect(r.evicted == [TV.uuid(0x107)])
    }

    @Test func mostRedundantStrongMatchGoesWithinTheClass() {
        let existing = [sample(0, axis: 0, .named, day: 0),
                        sample(1, TV.vector([3: 0.5, 4: 0.5], residual: 40), .strongMatch, day: 9),
                        sample(2, axis: 2, .strongMatch, day: 1),
                        sample(3, axis: 3, day: 3), sample(4, axis: 4, day: 4), sample(5, axis: 5, day: 5),
                        sample(6, axis: 6, day: 6), sample(7, axis: 7, day: 7)]
        let r = SampleCurator.insert(sample(9, axis: 9, day: 10), into: existing, policy: capEight)
        #expect(r.evicted == [TV.uuid(0x101)])
    }

    @Test func firstNamedSampleIsNeverEvicted() {
        // A (earliest named) is the most redundant; it stays and the tie between e1 and e2 goes to the older e1.
        let a = sample(0, TV.vector([1: 0.6, 2: 0.6], residual: 40), .named, day: 0)
        let existing = [a, sample(1, axis: 1, day: 1), sample(2, axis: 2, day: 2)]
            + (3..<8).map { sample($0, axis: $0, day: $0) }
        let r = SampleCurator.insert(sample(9, axis: 9, day: 9), into: existing, policy: capEight)
        #expect(r.keep.contains { $0.id == a.id })
        #expect(r.evicted == [TV.uuid(0x101)])
    }

    @Test func laterNamedSampleCanBeEvicted() {
        let a = sample(0, TV.vector([1: 0.6, 2: 0.6], residual: 40), .named, day: 0)
        let b = sample(3, TV.vector([1: 0.6, 2: 0.6], residual: 41), .named, day: 3)
        let existing = [a, sample(1, axis: 1, day: 1), sample(2, axis: 2, day: 2), b]
            + (4..<8).map { sample($0, axis: $0, day: $0) }
        let r = SampleCurator.insert(sample(9, axis: 9, day: 9), into: existing, policy: capEight)
        #expect(r.evicted == [b.id])
    }

    @Test func newSampleIsNeverEvicted() {
        let existing = [sample(0, axis: 0, .named, day: 0)] + (1..<8).map { sample($0, axis: $0, day: $0) }
        let new = sample(9, TV.vector([1: 0.6, 2: 0.6, 3: 0.3], residual: 40), .confirmed, day: 9)
        let r = SampleCurator.insert(new, into: existing, policy: capEight)
        #expect(r.added && r.keep.last?.id == new.id)
        #expect(r.evicted == [TV.uuid(0x101)])    // e1 and e2 tie at 0.6/8; e1 is older
    }

    @Test func redundancyChoosesHighestMeanCosine() {
        // X is the newest existing sample but the most redundant, so it goes.
        let x = sample(1, TV.vector([3: 0.5, 4: 0.5], residual: 40), day: 7)
        let existing = [sample(0, axis: 0, .named, day: 0), x]
            + [3, 4, 5, 6, 7, 8].map { sample($0, axis: $0, day: $0 - 3) }
        let r = SampleCurator.insert(sample(9, axis: 9, day: 9), into: existing, policy: capEight)
        #expect(r.evicted == [x.id])
    }

    @Test func tieGoesToTheOldest() {
        let days = [5, 3, 7, 1, 6, 2, 4]
        let existing = [sample(0, axis: 0, .named, day: 10)]
            + days.enumerated().map { i, d in sample(i + 1, axis: i + 1, day: d) }
        let r = SampleCurator.insert(sample(9, axis: 9, day: 11), into: existing, policy: capEight)
        #expect(r.evicted == [TV.uuid(0x104)])   // day 1
    }

    @Test func resultIsIndependentOfInputOrder() {
        let existing = [sample(0, TV.vector([1: 0.6, 2: 0.6], residual: 40), .named, day: 0),
                        sample(1, axis: 1, .strongMatch, day: 1), sample(2, axis: 2, .strongMatch, day: 1),
                        sample(3, TV.vector([4: 0.5, 5: 0.5], residual: 41), day: 3)]
            + (4..<8).map { sample($0, axis: $0, day: $0) }
        let new = sample(9, axis: 9, day: 9)
        let baseline = SampleCurator.insert(new, into: existing, policy: capEight)
        var rng = SplitMix64(seed: 42)
        for _ in 0..<100 {
            let r = SampleCurator.insert(new, into: existing.shuffled(using: &rng), policy: capEight)
            #expect(r.evicted == baseline.evicted && Set(r.keep.map(\.id)) == Set(baseline.keep.map(\.id)))
        }
    }

    @Test func mergingEightIntoEightStaysAtEight() {
        var keep = [sample(0, axis: 0, .named, day: 0)] + (1..<8).map { sample($0, axis: $0, day: $0) }
        for i in 0..<8 {
            let r = SampleCurator.insert(sample(20 + i, axis: 20 + i, .merged, day: 20 + i), into: keep, policy: capEight)
            #expect(r.added && r.keep.count == 8 && r.evicted.count == 1)
            keep = r.keep
        }
        #expect(keep.contains { $0.id == TV.uuid(0x100) })
    }

    @Test func protectedSamplesCanExceedATinyCap() {
        // With a cap of 1 the earliest named sample and the new one are both protected; nothing is evicted.
        var policy = MatchPolicy.default
        policy.maxSamplesPerProfile = 1
        let r = SampleCurator.insert(sample(9, axis: 9, day: 9), into: [sample(0, axis: 0, .named, day: 0)], policy: policy)
        #expect(r.added && r.keep.count == 2 && r.evicted.isEmpty)
    }

    @Test func samplesOfAnotherDimensionAreNeverDuplicatesOrRedundant() throws {
        let odd = CuratedSample(id: TV.uuid(0x1FF), vector: try #require(VoiceVector(raw: [1, 0, 0])), origin: .confirmed,
                                addedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let r1 = SampleCurator.insert(sample(9, axis: 9, day: 9), into: [odd])
        #expect(r1.added && r1.keep.count == 2)

        // Seven 64-d samples plus the odd one: all have zero redundancy, so the oldest (the odd one) goes.
        let existing = [odd] + (1..<8).map { sample($0, axis: $0, day: $0) }
        let r2 = SampleCurator.insert(sample(9, axis: 9, day: 9), into: existing, policy: capEight)
        #expect(r2.evicted == [odd.id])
    }
}

@Suite("SampleCurator.shouldAddAutomaticSample")
struct AutomaticSampleGateTests {
    enum DecisionKind: String, CaseIterable, Sendable { case auto, ask, unknown, none }

    struct Case: Sendable, CustomTestStringConvertible {
        let trustedScore: Float, margin: Float, coherence: Float?, seconds: TimeInterval, decision: DecisionKind
        var allowed: Bool {
            decision == .auto && trustedScore >= 0.70 && margin >= 0.20 && (coherence ?? 0) >= 0.5 && seconds >= 10
        }
        var testDescription: String {
            "trusted \(trustedScore) margin \(margin) coherence \(coherence.map { "\($0)" } ?? "nil") \(seconds) s \(decision)"
        }
    }

    static let cases: [Case] = {
        var out: [Case] = []
        for t: Float in [0.70, 0.6999] {
            for m: Float in [0.20, 0.1999] {
                for c: Float? in [0.5, 0.4999, nil] {
                    for s: TimeInterval in [10, 9.99] {
                        for d in DecisionKind.allCases {
                            out.append(Case(trustedScore: t, margin: m, coherence: c, seconds: s, decision: d))
                        }
                    }
                }
            }
        }
        return out
    }()

    @Test(arguments: cases)
    func automaticSampleGate(_ c: Case) {
        let decision: MatchDecision? = switch c.decision {
        case .auto: .autoLabel(profileID: TV.liamID, score: 0.9, margin: c.margin)
        case .ask: .ask(profileID: TV.liamID, score: 0.9)
        case .unknown: .unknown(.lowScore(best: 0.9))
        case .none: nil
        }
        let allowed = SampleCurator.shouldAddAutomaticSample(decision: decision, trustedScore: c.trustedScore,
                                                             coherence: c.coherence, cleanSeconds: c.seconds)
        #expect(allowed == c.allowed)
    }
}

@Suite("SampleCurator trust and eviction classes")
struct SampleCuratorTrustTests {

    @Test func sampleTrustTable() {
        let rows: [(SampleOrigin, TimeInterval, Bool)] = [
            (.named, 10, true), (.named, 9.99, false), (.corrected, 6, false), (.corrected, 12, true),
            (.strongMatch, 30, false), (.merged, 30, false),
        ]
        for (origin, seconds, trusted) in rows {
            #expect(SampleTrust.isTrusted(origin: origin, speechSeconds: seconds) == trusted, "\(origin) at \(seconds) s")
            #expect(sample(0, axis: 0, origin, day: 0, seconds: seconds).isTrusted == trusted, "\(origin) at \(seconds) s")
        }
    }

    @Test func evictionOrderAutomaticThenShortThenTrusted() {
        var policy = MatchPolicy.default
        policy.maxSamplesPerProfile = 3
        let named = sample(0, axis: 0, .named, day: 0)
        let short = sample(1, axis: 1, .confirmed, day: 1, seconds: 6)
        let strong = sample(2, axis: 2, .strongMatch, day: 2)
        // T1 is the most redundant sample both times (it shares axis 0 with the named sample and axis 5 with T2).
        let t1 = sample(3, TV.vector([0: 0.6, 5: 0.5], residual: 40), .confirmed, day: 3)
        let t2 = sample(4, TV.vector([5: 0.6], residual: 41), .addedFromRecording, day: 4)

        let r1 = SampleCurator.insert(t1, into: [named, short, strong], policy: policy)
        #expect(r1.added && r1.evicted == [strong.id])
        #expect(r1.keep.map(\.id) == [named.id, short.id, t1.id])

        let r2 = SampleCurator.insert(t2, into: r1.keep, policy: policy)
        #expect(r2.added && r2.evicted == [short.id])
        #expect(r2.keep.map(\.id) == [named.id, t1.id, t2.id])
    }

    @Test func capIsTwelve() {
        #expect(MatchPolicy.default.maxSamplesPerProfile == 12)
        let eleven = (0..<11).map { sample($0, axis: $0, day: $0) }
        let r11 = SampleCurator.insert(sample(20, axis: 20, day: 20), into: eleven)
        #expect(r11.added && r11.keep.count == 12 && r11.evicted.isEmpty)

        let twelve = (0..<12).map { sample($0, axis: $0, day: $0) }
        let r12 = SampleCurator.insert(sample(20, axis: 20, day: 20), into: twelve)
        #expect(r12.added && r12.keep.count == 12 && r12.evicted.count == 1)
        #expect(Set(r12.keep.map(\.id)).isDisjoint(with: r12.evicted))
    }
}

@Suite("SampleCurator.insertNegative")
struct NegativeCuratorTests {
    private func negative(_ n: Int, _ vector: VoiceVector, day: Int, source: Int? = nil) -> CuratedNegative {
        CuratedNegative(id: TV.uuid(0x200 + n), vector: vector,
                        addedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400),
                        sourceSpeakerID: source.map { TV.uuid(0x300 + $0) })
    }

    @Test func negativeCuratorDedupesCapsAndEvictsOldest() {
        // A near-duplicate (cosine 0.96) is skipped.
        let a = negative(0, TV.axis(0), day: 0, source: 1)
        let nearDuplicate = negative(1, TV.vector([0: 0.96], residual: 40), day: 1, source: 2)
        let dup = SampleCurator.insertNegative(nearDuplicate, into: [a])
        #expect(!dup.added && dup.keep == [a] && dup.evicted.isEmpty)

        // A negative from the same speaker is skipped, however different its vector.
        let sameSpeaker = negative(2, TV.axis(1), day: 2, source: 1)
        let same = SampleCurator.insertNegative(sameSpeaker, into: [a])
        #expect(!same.added && same.keep == [a])

        // A distinct one is appended.
        let distinct = negative(3, TV.vector([0: 0.94], residual: 41), day: 3, source: 3)
        let ok = SampleCurator.insertNegative(distinct, into: [a])
        #expect(ok.added && ok.keep == [a, distinct] && ok.evicted.isEmpty)

        // A 9th negative evicts the oldest (day 1, at index 3 here).
        let days = [5, 3, 7, 1, 6, 2, 4, 8]
        let eight = days.enumerated().map { i, d in negative(10 + i, TV.axis(10 + i), day: d, source: 10 + i) }
        let ninth = negative(30, TV.axis(30), day: 9, source: 30)
        let r = SampleCurator.insertNegative(ninth, into: eight)
        #expect(r.added && r.keep.count == 8 && r.evicted == [TV.uuid(0x200 + 13)])
        #expect(r.keep.last == ninth)

        // The new one is never evicted, even when it is the oldest.
        let oldest = negative(31, TV.axis(31), day: -1, source: 31)
        let r2 = SampleCurator.insertNegative(oldest, into: eight)
        #expect(r2.added && r2.keep.contains(oldest) && r2.evicted == [TV.uuid(0x200 + 13)])

        // Independent of input order.
        var rng = SplitMix64(seed: 42)
        for _ in 0..<100 {
            let shuffled = SampleCurator.insertNegative(ninth, into: eight.shuffled(using: &rng))
            #expect(shuffled.evicted == r.evicted && Set(shuffled.keep.map(\.id)) == Set(r.keep.map(\.id)))
        }
    }
}
