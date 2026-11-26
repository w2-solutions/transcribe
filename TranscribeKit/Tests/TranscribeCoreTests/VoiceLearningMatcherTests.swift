import Foundation
import Testing
@testable import TranscribeCore

/// `approx` for an optional value; false when it is nil.
private func near(_ a: Float?, _ b: Float) -> Bool { a.map { approx($0, b) } ?? false }

/// Trust, negatives, the cohort runner-up and match traces (§1.3 to §1.6, §1.10).
@Suite("VoiceMatcher with voice learning")
struct VoiceLearningMatcherTests {

    private func decide(_ probe: SpeakerProbe, _ profiles: [ProfileCandidate], cohort: [VoiceVector] = []) throws -> MatchDecision {
        try #require(GoldenMatcher.decide(probes: [probe], profiles: profiles, modelKey: TV.modelKey, cohort: cohort)[probe.key])
    }

    private func run(_ probe: SpeakerProbe, _ profiles: [ProfileCandidate], cohort: [VoiceVector] = []) throws -> (MatchDecision, MatchTrace) {
        let r = GoldenMatcher.decideWithTrace(probes: [probe], profiles: profiles, modelKey: TV.modelKey, cohort: cohort)
        return (try #require(r.decisions[probe.key]), try #require(r.traces[probe.key]))
    }

    // MARK: Equivalence with the old matcher

    @Test func legacyCandidatesDecideExactlyAsBefore() throws {
        var rng = SplitMix64(seed: 7)
        let ids = [TV.liamID, TV.karanID, TV.meiID, TV.uuid(0xD)]
        var seen: [String: Int] = [:]
        /// A random 3-d unit vector: another embedding dimension, which `cosine` must never see beside a 64-d one.
        func threeD(_ rng: inout SplitMix64) throws -> VoiceVector {
            try #require(VoiceVector(raw: [Float.random(in: 0.2...1, using: &rng), Float.random(in: -1...1, using: &rng),
                                           Float.random(in: -1...1, using: &rng)]))
        }
        for _ in 0..<300 {
            let profiles = try (0..<Int.random(in: 1...4, using: &rng)).map { i -> ProfileCandidate in
                var samples = (0..<Int.random(in: 1...5, using: &rng)).map { _ in TV.axis(Int.random(in: 0..<10, using: &rng)) }
                // Mixed dimensions: some profiles also hold a 3-d sample, a few hold only 3-d samples.
                switch Int.random(in: 0..<8, using: &rng) {
                case 0, 1: samples.append(try threeD(&rng))
                case 2: samples = [try threeD(&rng)]
                default: break
                }
                // Another model, and a repeated profile id (the first one wins), now and then.
                let modelKey = Int.random(in: 0..<12, using: &rng) == 0 ? "other-model@1#64" : TV.modelKey
                let id = i > 0 && Int.random(in: 0..<10, using: &rng) == 0 ? ids[i - 1] : ids[i]
                return ProfileCandidate(id: id, name: "P\(i)", samples: samples, modelKey: modelKey,
                                        autoLabel: Int.random(in: 0..<5, using: &rng) > 0,
                                        needsResample: Int.random(in: 0..<10, using: &rng) == 0)
            }
            var threeDProbes = Set<SpeakerKey>()
            let probes = try (0..<Int.random(in: 1...4, using: &rng)).map { j -> SpeakerProbe in
                var components: [Int: Float] = [:]
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    components[Int.random(in: 0..<10, using: &rng)] = Float.random(in: -0.2...0.9, using: &rng)
                }
                let mass = components.values.reduce(0) { $0 + $1 * $1 }
                if mass > 0.95 { components = components.mapValues { $0 * (0.95 / mass).squareRoot() } }
                let rejected = Set(ids.filter { _ in Int.random(in: 0..<5, using: &rng) == 0 })
                let hasVector = Int.random(in: 0..<20, using: &rng) > 0
                let isThreeD = Int.random(in: 0..<6, using: &rng) == 0
                if isThreeD { threeDProbes.insert("S\(j + 1)") }
                let vector = isThreeD ? try threeD(&rng) : TV.vector(components, residual: 40 + j)
                return SpeakerProbe(key: "S\(j + 1)", vector: hasVector ? vector : nil,
                                    cleanSeconds: [2.0, 3.0, 4.6, 30][Int.random(in: 0..<4, using: &rng)],
                                    rejectedProfileIDs: rejected)
            }
            // Both sides get the frozen policy, so a change to `MatchPolicy.default` cannot hide a difference.
            let new = GoldenMatcher.decide(probes: probes, profiles: profiles, modelKey: TV.modelKey,
                                          policy: LegacyMatcher.frozenPolicy)
            let old = LegacyMatcher.decide(probes: probes, profiles: profiles, modelKey: TV.modelKey,
                                           policy: LegacyMatcher.frozenPolicy)
            #expect(new == old)
            for (key, d) in new {
                let kind = switch d {
                case .autoLabel: "auto"
                case .ask: "ask"
                case .unknown(.lowScore): "lowScore"
                case .unknown: "preFiltered"
                }
                seen[kind, default: 0] += 1
                if threeDProbes.contains(key), kind != "preFiltered" { seen["threeDScored", default: 0] += 1 }
            }
        }
        // The random cases cover every outcome, and 3-d probes that were really scored, so the comparison is not vacuous.
        #expect((seen["auto"] ?? 0) > 20 && (seen["ask"] ?? 0) > 20 && (seen["lowScore"] ?? 0) > 20)
        #expect((seen["threeDScored"] ?? 0) > 5)
    }

    // MARK: Trust

    @Test func untrustedCannotBeTop() throws {
        let probe = TV.probe("S1", [1: 0.7, 2: 0.7], residual: 40)
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0, 1, 2], trusted: [true, false, false], negatives: [])
        let d = try decide(probe, [liam])
        #expect(approx(try #require(d.lowScoreBest), 0.35))
        // Under the legacy initialiser (all trusted) the same voice scores 0.70 and would be auto-labelled.
        let legacy = try decide(probe, [TV.profile(TV.liamID, name: "Liam", axes: [0, 1, 2])])
        guard case .autoLabel(_, let s, _) = legacy else { Issue.record("expected auto, got \(legacy)"); return }
        #expect(approx(s, 0.70))
    }

    @Test func untrustedFillsSecondPlace() throws {
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0, 1], trusted: [true, false], negatives: [])
        let d = try decide(TV.probe("S1", [0: 0.6, 1: 0.5], residual: 40), [liam])
        guard case .autoLabel(let id, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.55) && approx(m, 0.55))
    }

    /// By design (D1, D4), and worth knowing: a setting where the person only ever speaks 5 to 10 s stays an ask
    /// however often it is confirmed, because short samples can only fill second place. The trusted desk sample
    /// (0.35) stays on top, so every later car recording scores (0.35 + 0.6125) / 2 = 0.48125. Learning that
    /// setting completes only once a recording there has 10 s or more.
    @Test func shortConfirmationsAlonePlateauAtAnAsk() throws {
        let probe = TV.probe("S1", [0: 0.35, 1: 0.6125], residual: 40)
        for shortSamples in [1, 4, 11] {
            let liam = ProfileCandidate(id: TV.liamID, name: "Liam",
                                        samples: [TV.axis(0)] + Array(repeating: TV.axis(1), count: shortSamples),
                                        trusted: [true] + Array(repeating: false, count: shortSamples), negatives: [],
                                        modelKey: TV.modelKey, autoLabel: true, needsResample: false)
            let d = try decide(probe, [liam])
            guard case .ask(let id, let s) = d else { Issue.record("expected ask, got \(d)"); return }
            #expect(id == TV.liamID && approx(s, 0.48125), "\(shortSamples) short samples")
        }
    }

    @Test func noTrustedSamplesOnlyAsks() throws {
        // Two untrusted samples, each at cosine 0.8 to the probe. (Two one-hot axes cannot both be 0.8 for a
        // unit probe, so the samples are 0.8 along axis 0 instead.)
        let samples = [TV.vector([0: 0.8], residual: 41), TV.vector([0: 0.8], residual: 42)]
        let liam = ProfileCandidate(id: TV.liamID, name: "Liam", samples: samples, trusted: [false, false], negatives: [],
                                    modelKey: TV.modelKey, autoLabel: true, needsResample: false)
        let (d, trace) = try run(TV.probe("S1", [0: 1], residual: 40), [liam])
        guard case .ask(let id, let s) = d else { Issue.record("expected ask, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.8))
        #expect(trace.reason == "askOnly" && trace.profiles.first?.askOnly == true)
    }

    @Test func singleSampleScoresItself() throws {
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0], trusted: [true], negatives: [])
        let d = try decide(TV.probe("S1", [0: 0.6], residual: 40), [liam])
        guard case .autoLabel(_, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(approx(s, 0.6) && approx(m, 0.6))
    }

    @Test func poisonedTrustedSampleAsksNotAuto() throws {
        let liam = TV.profile(TV.liamID, name: "Liam", axes: Array(0...6), negatives: [])
        let d = try decide(SpeakerProbe(key: "S1", vector: TV.vector([6: 0.72, 0: 0.3, 1: 0.3], residual: 40),
                                        cleanSeconds: 30, rejectedProfileIDs: []), [liam])
        guard case .ask(_, let s) = d else { Issue.record("expected ask, got \(d)"); return }
        #expect(approx(s, 0.51))
    }

    @Test func automaticSampleCannotSustainImpostor() throws {
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0, 1, 2], trusted: [true, false, false], negatives: [])
        let vector = TV.vector([1: 0.75, 2: 0.55, 0: 0.3], residual: 40)
        let d = try decide(SpeakerProbe(key: "S1", vector: vector, cleanSeconds: 30, rejectedProfileIDs: []), [liam])
        guard case .ask(_, let s) = d else { Issue.record("expected ask, got \(d)"); return }
        #expect(approx(s, 0.525))
        let e = try #require(GoldenMatcher.evidence(vector, against: liam))
        #expect(approx(try #require(e.trustedScore), 0.3))
        #expect(!SampleCurator.shouldAddAutomaticSample(decision: .autoLabel(profileID: TV.liamID, score: 0.9, margin: 0.9),
                                                        trustedScore: e.trustedScore, coherence: 1, cleanSeconds: 30))
    }

    // MARK: Negatives

    @Test func negativeBlocksAutoAndAsk() throws {
        // The probe is (0: 0.6, 40: 0.8); the negative sits at cosine 0.8 to it, above the score 0.6.
        let negative = TV.vector([0: 0.48, 40: 0.64], residual: 45)
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0], negatives: [negative])
        let probe = TV.probe("S1", [0: 0.6], residual: 40)
        #expect(approx(try #require(probe.vector).cosine(negative), 0.8))
        let (d, trace) = try run(probe, [liam])
        #expect(approx(try #require(d.lowScoreBest), 0.6))
        #expect(trace.kind == .unknown && trace.reason == "blocked" && trace.profileID == nil)
        #expect(trace.profiles.first?.blocked == true)
    }

    @Test func negativeBelowScoreIgnored() throws {
        let negative = TV.vector([0: 0.3], residual: 45)
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0], negatives: [negative])
        let (d, trace) = try run(TV.probe("S1", [0: 0.8], residual: 40), [liam])
        guard case .autoLabel(_, let s, _) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(approx(s, 0.8))
        #expect(approx(try #require(trace.profiles.first?.negativeMax), 0.24))
        #expect(trace.profiles.first?.blocked == false)
    }

    @Test func blockedProfileStillRunnerUp() throws {
        let negative = TV.vector([0: 0.6, 1: 0.56], residual: 44)
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0], negatives: [negative])
        let karan = TV.profile(TV.karanID, name: "Karan", axes: [1], negatives: [])
        let vector = TV.vector([0: 0.6, 1: 0.56], residual: 40)
        #expect(approx(vector.cosine(negative), 0.6736))
        let (d, trace) = try run(SpeakerProbe(key: "S1", vector: vector, cleanSeconds: 30, rejectedProfileIDs: []), [liam, karan])
        guard case .ask(let id, let s) = d else { Issue.record("expected ask, got \(d)"); return }
        #expect(id == TV.karanID && approx(s, 0.56))
        #expect(trace.reason == "downgraded")
    }

    @Test func negativeOfOtherDimensionIsIgnored() throws {
        let odd = try #require(VoiceVector(raw: [1, 0, 0]))
        let probe = TV.probe("S1", [0: 0.6], residual: 40)
        let with = try decide(probe, [TV.profile(TV.liamID, name: "Liam", axes: [0], negatives: [odd])])
        let without = try decide(probe, [TV.profile(TV.liamID, name: "Liam", axes: [0], negatives: [])])
        #expect(with == without && with.isAuto)
    }

    // MARK: Cohort runner-up

    private var strangerProbe: SpeakerProbe {
        SpeakerProbe(key: "S1", vector: TV.vector([0: 0.56, 3: 0.6], residual: 41), cleanSeconds: 30, rejectedProfileIDs: [])
    }

    @Test func cohortRunnerUpStopsRecurringStranger() throws {
        let cohort = [TV.vector([3: 0.8], residual: 42)]
        let (d, trace) = try run(strangerProbe, [TV.liam], cohort: cohort)
        guard case .ask(let id, let s) = d else { Issue.record("expected ask, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.56))
        #expect(approx(try #require(trace.profiles.first?.cohortMax), 0.48))
        #expect(near(trace.margin, 0.08) && near(trace.runnerUp, 0.48))
        #expect(trace.reason == "margin" && trace.cohortSize == 1)

        #expect(try decide(strangerProbe, [TV.liam]).isAuto)
    }

    @Test func cohortVoiceThatMightBeTheProfileIsIgnored() throws {
        let cohort = [TV.vector([0: 0.5, 3: 0.8], residual: 43)]
        let (d, trace) = try run(strangerProbe, [TV.liam], cohort: cohort)
        guard case .autoLabel(_, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(approx(s, 0.56) && approx(m, 0.56))
        #expect(trace.profiles.first?.cohortMax == nil && trace.cohortSize == 1)
    }

    @Test func genuineProbeUnaffectedByOrthogonalCohort() throws {
        let cohort = [TV.vector([3: 0.8], residual: 42), TV.vector([0: 0.5, 3: 0.8], residual: 43)]
        let d = try decide(TV.probe("S1", [0: 0.8], residual: 40), [TV.liam], cohort: cohort)
        guard case .autoLabel(_, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(approx(s, 0.8) && approx(m, 0.8))
    }

    // MARK: Conflicting negatives

    @Test func conflictingNegativesUseScoreBeforeAdding() throws {
        let vector = TV.vector([0: 0.5, 3: 0.7], residual: 40)
        let a = (id: TV.uuid(0x2A), vector: TV.vector([3: 0.75], residual: 44))
        let b = (id: TV.uuid(0x2B), vector: TV.vector([3: 0.6], residual: 45))
        #expect(approx(vector.cosine(a.vector), 0.525) && approx(vector.cosine(b.vector), 0.42))
        #expect(GoldenMatcher.conflictingNegatives(vector, profile: TV.liam, negatives: [a, b]) == [a.id])
        // A profile with no comparable sample conflicts with nothing.
        let empty = TV.profile(TV.liamID, name: "Liam", axes: [], negatives: [])
        #expect(GoldenMatcher.conflictingNegatives(vector, profile: empty, negatives: [a, b]).isEmpty)
    }

    // MARK: Traces

    @Test func traceRecordsEvidence() throws {
        let liamNegative = TV.vector([5: 0.8], residual: 45)
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0, 1, 2], trusted: [true, true, false], negatives: [liamNegative])
        let karan = TV.profile(TV.karanID, name: "Karan", axes: [3], negatives: [])
        let probe = TV.probe("S1", [0: 0.7, 1: 0.4, 2: 0.5, 3: 0.2, 5: 0.1], residual: 40, cleanSeconds: 12.5)
        let cohort = [TV.vector([0: 0.2, 6: 0.9], residual: 46)]   // scores 0.1 against Liam, 0 against Karan: kept for both
        let (d, t) = try run(probe, [karan, liam], cohort: cohort)

        guard case .autoLabel(let id, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.6) && approx(m, 0.4))

        #expect(t.version == MatchTrace.currentVersion && t.key == "S1" && t.cleanSeconds == 12.5)
        #expect(t.kind == .auto && t.profileID == TV.liamID && t.reason == "auto")
        #expect(near(t.score, 0.6) && near(t.runnerUp, 0.2) && near(t.margin, 0.4))
        #expect(t.autoLabelMin == 0.55 && t.autoLabelMargin == 0.10 && t.askMin == 0.40)
        #expect(t.cohortSize == 1 && t.cohortTopMean == nil && t.cohortTopStd == nil)
        #expect(t.profiles.map(\.profileID) == [TV.liamID, TV.karanID])

        let l = t.profiles[0]
        #expect(approx(l.score, 0.6) && near(l.trustedTop, 0.7) && near(l.trustedScore, 0.55))
        #expect(l.trustedCount == 2 && l.untrustedCount == 1 && !l.askOnly)
        #expect(near(l.negativeMax, 0.08) && !l.blocked)
        #expect(approx(try #require(l.cohortMax), 0.14))

        let k = t.profiles[1]
        #expect(approx(k.score, 0.2) && near(k.trustedTop, 0.2) && near(k.trustedScore, 0.2))
        #expect(k.trustedCount == 1 && k.untrustedCount == 0 && !k.askOnly)
        #expect(k.negativeMax == nil && !k.blocked)
        #expect(approx(try #require(k.cohortMax), 0.14))

        // `evidence` alone gives the same numbers without the cohort.
        var alone = l
        alone.cohortMax = nil
        #expect(GoldenMatcher.evidence(try #require(probe.vector), against: liam) == alone)

        // Pre-filtered probes still get a trace, with no profiles.
        let silent = SpeakerProbe(key: "S2", vector: nil, cleanSeconds: 30, rejectedProfileIDs: [])
        let r = GoldenMatcher.decideWithTrace(probes: [silent], profiles: [liam], modelKey: TV.modelKey)
        let st = try #require(r.traces["S2"])
        #expect(st.kind == .unknown && st.reason == "noVector" && st.profiles.isEmpty && st.score == nil)

        // Cohort statistics: nil under 30 vectors; with 30 equal cosines c, the mean is c and the std 0.
        let statsProbe = TV.probe("S3", [6: 0.6], residual: 40)
        let cohort30 = (0..<30).map { TV.vector([6: 0.5], residual: 10 + $0) }
        let c = try #require(statsProbe.vector).cosine(cohort30[0])
        let t29 = try run(statsProbe, [liam], cohort: Array(cohort30.prefix(29))).1
        #expect(t29.cohortSize == 29 && t29.cohortTopMean == nil && t29.cohortTopStd == nil)
        let t30 = try run(statsProbe, [liam], cohort: cohort30).1
        #expect(t30.cohortSize == 30 && t30.cohortTopMean == c && t30.cohortTopStd == 0)
        #expect(approx(c, 0.3))

        // The trace round-trips through JSON.
        let decoded = try JSONDecoder().decode(MatchTrace.self, from: JSONEncoder().encode(t))
        #expect(decoded == t)
    }

    @Test func traceReasons() throws {
        let liam = TV.liam, karan = TV.karan
        func reason(_ probe: SpeakerProbe, _ profiles: [ProfileCandidate]) throws -> String { try run(probe, profiles).1.reason }

        #expect(try reason(TV.probe("S1", [0: 0.5], residual: 40), [liam]) == "belowAuto")
        #expect(try reason(TV.probe("S1", [0: 0.7, 1: 0.65], residual: 40), [liam, karan]) == "margin")
        let off = TV.profile(TV.liamID, name: "Liam", axes: [0], autoLabel: false)
        #expect(try reason(TV.probe("S1", [0: 0.9], residual: 40), [off]) == "autoLabelOff")
        #expect(try reason(TV.probe("S1", [0: 0.3], residual: 40), [liam]) == "lowScore")
        #expect(try reason(TV.probe("S1", [0: 0.9], residual: 40, cleanSeconds: 1), [liam]) == "tooShort")
        #expect(try reason(TV.probe("S1", [0: 0.9], residual: 40, rejected: [TV.liamID]), [liam]) == "noEligibleProfiles")

        // Two speakers want Liam; the weaker one is left with nothing that reaches ask.
        let r = GoldenMatcher.decideWithTrace(probes: [TV.probe("S1", [0: 0.9], residual: 40),
                                                     TV.probe("S2", [0: 0.6], residual: 41)],
                                             profiles: [liam], modelKey: TV.modelKey)
        #expect(r.traces["S1"]?.reason == "auto" && r.traces["S2"]?.reason == "taken")
        #expect(r.decisions["S2"]?.lowScoreBest.map { approx($0, 0.6) } == true)
    }

    @Test func shuffleInvarianceWithTrustNegativesAndCohort() {
        let profiles = [
            ProfileCandidate(id: TV.liamID, name: "Liam", samples: [0, 1, 2].map(TV.axis), trusted: [true, true, false],
                             negatives: [TV.vector([7: 0.8], residual: 50), TV.vector([8: 0.6], residual: 51)],
                             modelKey: TV.modelKey, autoLabel: true, needsResample: false),
            ProfileCandidate(id: TV.karanID, name: "Karan", samples: [3, 4].map(TV.axis), trusted: [true, false],
                             negatives: [TV.vector([0: 0.3, 3: 0.3], residual: 52)],
                             modelKey: TV.modelKey, autoLabel: true, needsResample: false),
            ProfileCandidate(id: TV.meiID, name: "Mei", samples: [5, 6].map(TV.axis), trusted: [false, false],
                             negatives: [], modelKey: TV.modelKey, autoLabel: true, needsResample: false),
        ]
        let probes = [
            TV.probe("S1", [0: 0.7, 1: 0.4, 2: 0.3], residual: 40),
            TV.probe("S2", [3: 0.6, 4: 0.5, 9: 0.4], residual: 41),
            TV.probe("S3", [5: 0.6, 6: 0.6], residual: 42),
            TV.probe("S4", [7: 0.7, 0: 0.5], residual: 43),
            TV.probe("S5", [2: 0.45, 4: 0.45, 9: 0.3], residual: 44),
            SpeakerProbe(key: "S6", vector: nil, cleanSeconds: 30, rejectedProfileIDs: []),
        ]
        let cohort = [TV.vector([9: 0.8], residual: 53), TV.vector([3: 0.5], residual: 54), TV.vector([0: 0.2], residual: 55),
                      TV.vector([4: 0.3, 9: 0.5], residual: 56), TV.vector([6: 0.7], residual: 57)]
        let baseline = GoldenMatcher.decideWithTrace(probes: probes, profiles: profiles, modelKey: TV.modelKey, cohort: cohort)
        #expect(baseline.decisions.values.contains { $0.isAuto } && baseline.decisions.values.contains { $0.isAsk })
        #expect(baseline.traces.values.contains { $0.reason == "blocked" })

        var rng = SplitMix64(seed: 42)
        for _ in 0..<100 {
            let shuffledProfiles = profiles.shuffled(using: &rng).map { p in
                let pairs = Array(zip(p.samples, p.trusted)).shuffled(using: &rng)
                return ProfileCandidate(id: p.id, name: p.name, samples: pairs.map(\.0), trusted: pairs.map(\.1),
                                        negatives: p.negatives.shuffled(using: &rng), modelKey: p.modelKey,
                                        autoLabel: p.autoLabel, needsResample: p.needsResample)
            }
            let r = GoldenMatcher.decideWithTrace(probes: probes.shuffled(using: &rng), profiles: shuffledProfiles,
                                                 modelKey: TV.modelKey, cohort: cohort.shuffled(using: &rng))
            #expect(r == baseline)
        }
    }
}
