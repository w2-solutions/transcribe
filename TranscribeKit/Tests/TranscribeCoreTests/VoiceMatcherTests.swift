import Foundation
import Testing
@testable import TranscribeCore

enum ExpectedOutcome: String, Sendable, CustomTestStringConvertible {
    case auto, ask, unknown
    var testDescription: String { rawValue }
}

private func outcome(_ d: MatchDecision?) -> ExpectedOutcome? {
    switch d {
    case .autoLabel?: .auto
    case .ask?: .ask
    case .unknown?: .unknown
    case nil: nil
    }
}

@Suite("VoiceMatcher.score")
struct VoiceMatcherScoreTests {
    let profile = TV.profile(TV.liamID, name: "Liam", axes: [0, 1, 2])
    let probe = TV.vector([0: 0.6, 1: 0.4, 2: 0.2], residual: 40)

    @Test(arguments: [(1, Float(0.6)), (2, 0.5), (3, 0.4), (10, 0.4), (0, 0.6)])
    func meanOfTopMinKN(topK: Int, expected: Float) {
        #expect(approx(VoiceMatcher.score(probe, against: profile, topK: topK), expected))
    }

    @Test func minusOneWithoutComparableSamples() throws {
        let empty = TV.profile(TV.liamID, name: "Liam", axes: [])
        #expect(VoiceMatcher.score(probe, against: empty, topK: 2) == -1)
        let otherDimension = ProfileCandidate(id: TV.liamID, name: "Liam", samples: [try #require(VoiceVector(raw: [1, 0]))],
                                              modelKey: TV.modelKey, autoLabel: true, needsResample: false)
        #expect(VoiceMatcher.score(probe, against: otherDimension, topK: 2) == -1)
    }

    @Test func independentOfSampleOrder() {
        let base = VoiceMatcher.score(probe, against: profile, topK: 2)
        for order in [[2, 1, 0], [1, 2, 0], [0, 2, 1]] {
            let p = TV.profile(TV.liamID, name: "Liam", axes: order)
            #expect(VoiceMatcher.score(probe, against: p, topK: 2) == base)
        }
    }
}

@Suite("VoiceMatcher.decide")
struct VoiceMatcherTests {

    // MARK: Thresholds

    @Test("Score boundaries with one profile",
          arguments: [(Float(0.3999), ExpectedOutcome.unknown), (0.40, .ask), (0.5499, .ask), (0.55, .auto), (0.95, .auto)])
    func scoreBoundaries(score: Float, expected: ExpectedOutcome) throws {
        let probe = TV.probe("S1", [TV.liamAxis: score], residual: 40)
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: [TV.liam], modelKey: TV.modelKey)["S1"])
        #expect(outcome(d) == expected)
        switch d {
        case .autoLabel(let id, let s, let m):
            #expect(id == TV.liamID && approx(s, score) && approx(m, score))
        case .ask(let id, let s):
            #expect(id == TV.liamID && approx(s, score))
        case .unknown(.lowScore(let best)):
            #expect(approx(best, score))
        case .unknown(let other):
            Issue.record("unexpected \(other)")
        }
    }

    @Test("Margin boundary against a runner-up", arguments: [(Float(0.6001), ExpectedOutcome.ask), (0.60, .auto)])
    func marginBoundary(runnerUp: Float, expected: ExpectedOutcome) throws {
        let probe = TV.probe("S1", [TV.liamAxis: 0.70, TV.karanAxis: runnerUp], residual: 40)
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: [TV.liam, TV.karan], modelKey: TV.modelKey)["S1"])
        #expect(outcome(d) == expected)
        #expect(d.profileID == TV.liamID)
        if case .autoLabel(_, let s, let m) = d { #expect(approx(s, 0.70) && approx(m, 0.10)) }
    }

    @Test("Clean speech boundary", arguments: [(2.99, ExpectedOutcome.unknown), (3.0, .auto)])
    func cleanSpeechBoundary(seconds: TimeInterval, expected: ExpectedOutcome) throws {
        let probe = TV.probe("S1", [TV.liamAxis: 0.9], residual: 40, cleanSeconds: seconds)
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: [TV.liam], modelKey: TV.modelKey)["S1"])
        #expect(outcome(d) == expected)
        if expected == .unknown { #expect(d == .unknown(.tooShort)) }
    }

    @Test func singleProfileMarginIsTheScore() throws {
        let probe = TV.probe("S1", [TV.liamAxis: 0.56], residual: 40)
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: [TV.liam], modelKey: TV.modelKey)["S1"])
        guard case .autoLabel(let id, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.56) && approx(m, 0.56))
    }

    @Test func negativeRunnerUpCountsAsZero() throws {
        let probe = TV.probe("S1", [TV.liamAxis: 0.60, TV.karanAxis: -0.30], residual: 40)
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: [TV.liam, TV.karan], modelKey: TV.modelKey)["S1"])
        guard case .autoLabel(_, _, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(approx(m, 0.60))
    }

    @Test func autoLabelOffAsksInstead() throws {
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [TV.liamAxis], autoLabel: false)
        let probe = TV.probe("S1", [TV.liamAxis: 0.9], residual: 40)
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: [liam], modelKey: TV.modelKey)["S1"])
        guard case .ask(let id, let s) = d else { Issue.record("expected ask, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.9))
    }

    @Test func lowScoreReportsTheProbesTopScore() throws {
        let probe = TV.probe("S1", [TV.liamAxis: 0.30, TV.karanAxis: 0.20], residual: 40)
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: [TV.karan, TV.liam], modelKey: TV.modelKey)["S1"])
        #expect(approx(try #require(d.lowScoreBest), 0.30))
    }

    // MARK: Pre-filter and exclusions

    enum Exclusion: String, CaseIterable, Sendable { case rejected, modelMismatch, needsResample, noSamples }

    @Test("Excluded profiles are neither matched nor runner-up", arguments: Exclusion.allCases)
    func exclusions(_ exclusion: Exclusion) throws {
        var liam = TV.liam
        var rejected: Set<UUID> = []
        switch exclusion {
        case .rejected: rejected = [TV.liamID]
        case .modelMismatch: liam = TV.profile(TV.liamID, name: "Liam", axes: [TV.liamAxis], modelKey: "other@1#64")
        case .needsResample: liam = TV.profile(TV.liamID, name: "Liam", axes: [TV.liamAxis], needsResample: true)
        case .noSamples: liam = TV.profile(TV.liamID, name: "Liam", axes: [])
        }
        let probe = TV.probe("S1", [TV.liamAxis: 0.70, TV.karanAxis: 0.65], residual: 40, rejected: rejected)

        let alone = GoldenMatcher.decide(probes: [probe], profiles: [liam], modelKey: TV.modelKey)
        #expect(alone["S1"] == .unknown(.noEligibleProfiles))

        let withKaran = try #require(GoldenMatcher.decide(probes: [probe], profiles: [liam, TV.karan], modelKey: TV.modelKey)["S1"])
        guard case .autoLabel(let id, _, let m) = withKaran else { Issue.record("expected auto, got \(withKaran)"); return }
        #expect(id == TV.karanID && approx(m, 0.65))
    }

    @Test func preFilterOrder() throws {
        let short = SpeakerProbe(key: "S1", vector: nil, cleanSeconds: 1, rejectedProfileIDs: [])
        #expect(GoldenMatcher.decide(probes: [short], profiles: [TV.liam], modelKey: TV.modelKey)["S1"] == .unknown(.noVector))

        let shortNoProfiles = TV.probe("S1", [TV.liamAxis: 0.9], residual: 40, cleanSeconds: 1)
        #expect(GoldenMatcher.decide(probes: [shortNoProfiles], profiles: [], modelKey: TV.modelKey)["S1"] == .unknown(.tooShort))

        let ok = TV.probe("S1", [TV.liamAxis: 0.9], residual: 40)
        #expect(GoldenMatcher.decide(probes: [ok], profiles: [], modelKey: TV.modelKey)["S1"] == .unknown(.noEligibleProfiles))

        let threeD: VoiceVector = try #require(VoiceVector(raw: [1, 0, 0]))
        let wrongDimension = SpeakerProbe(key: "S1", vector: threeD, cleanSeconds: 30, rejectedProfileIDs: [])
        #expect(GoldenMatcher.decide(probes: [wrongDimension], profiles: [TV.liam], modelKey: TV.modelKey)["S1"]
                == .unknown(.noEligibleProfiles))
    }

    @Test func emptyInputs() {
        #expect(GoldenMatcher.decide(probes: [], profiles: [TV.liam], modelKey: TV.modelKey).isEmpty)
    }

    // MARK: Scoring

    @Test func topTwoVersusTopOneScoring() throws {
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0, 3])
        let karan = TV.profile(TV.karanID, name: "Karan", axes: [1, 4])
        let probe = TV.probe("S1", [0: 0.60, 3: 0.10, 1: 0.45, 4: 0.45], residual: 40)

        var top1 = MatchPolicy.default
        top1.scoringTopK = 1
        let d1 = try #require(GoldenMatcher.decide(probes: [probe], profiles: [liam, karan], modelKey: TV.modelKey, policy: top1)["S1"])
        guard case .autoLabel(let id1, let s1, let m1) = d1 else { Issue.record("expected auto, got \(d1)"); return }
        #expect(id1 == TV.liamID && approx(s1, 0.60) && approx(m1, 0.15))

        #expect(MatchPolicy.default.scoringTopK == 2)
        let d2 = try #require(GoldenMatcher.decide(probes: [probe], profiles: [liam, karan], modelKey: TV.modelKey)["S1"])
        guard case .ask(let id2, let s2) = d2 else { Issue.record("expected ask, got \(d2)"); return }
        #expect(id2 == TV.karanID && approx(s2, 0.45))
    }

    // MARK: Greedy assignment

    @Test func knownVoicesBothAutoLabel() {
        let s1 = TV.probe("S1", [TV.liamAxis: 0.82, TV.karanAxis: 0.05], residual: 40)
        let s2 = TV.probe("S2", [TV.karanAxis: 0.78, TV.liamAxis: 0.10], residual: 41)
        let d = GoldenMatcher.decide(probes: [s1, s2], profiles: [TV.liam, TV.karan], modelKey: TV.modelKey)
        #expect(d["S1"]?.isAuto == true && d["S1"]?.profileID == TV.liamID)
        #expect(d["S2"]?.isAuto == true && d["S2"]?.profileID == TV.karanID)
    }

    @Test func greedyUniquenessTwoProbesCloseToKaran() throws {
        let s1 = TV.probe("S1", [TV.karanAxis: 0.80], residual: 40)
        let s2 = TV.probe("S2", [TV.karanAxis: 0.75], residual: 41)
        let d = GoldenMatcher.decide(probes: [s2, s1], profiles: [TV.karan], modelKey: TV.modelKey)
        #expect(d["S1"]?.isAuto == true && d["S1"]?.profileID == TV.karanID)
        // Karan is taken: S2 is left undecided and closes as lowScore with its own top score.
        #expect(approx(try #require(d["S2"]?.lowScoreBest), 0.75))

        // With Liam available, S2 falls back to an ask for Liam (downgraded, never auto).
        let s2b = TV.probe("S2", [TV.karanAxis: 0.75, TV.liamAxis: 0.45], residual: 41)
        let d2 = GoldenMatcher.decide(probes: [s1, s2b], profiles: [TV.karan, TV.liam], modelKey: TV.modelKey)
        #expect(d2["S1"]?.isAuto == true && d2["S1"]?.profileID == TV.karanID)
        #expect(d2["S2"]?.isAsk == true && d2["S2"]?.profileID == TV.liamID)

        let karanClaims = d2.values.filter { $0.profileID == TV.karanID }
        #expect(karanClaims.count == 1)
    }

    @Test func downgradeCapsAtAsk() throws {
        // Margin disabled so only the downgrade rule can stop an auto-label.
        var policy = MatchPolicy.default
        policy.autoLabelMargin = -1
        let s1 = TV.probe("S1", [TV.karanAxis: 0.80], residual: 40)
        let s2 = TV.probe("S2", [TV.karanAxis: 0.70, TV.liamAxis: 0.65], residual: 41)

        let alone = GoldenMatcher.decide(probes: [s2], profiles: [TV.karan, TV.liam], modelKey: TV.modelKey, policy: policy)
        #expect(alone["S2"]?.isAuto == true && alone["S2"]?.profileID == TV.karanID)

        let d = GoldenMatcher.decide(probes: [s1, s2], profiles: [TV.karan, TV.liam], modelKey: TV.modelKey, policy: policy)
        guard case .ask(let id, let s)? = d["S2"] else { Issue.record("expected ask, got \(String(describing: d["S2"]))"); return }
        #expect(id == TV.liamID && approx(s, 0.65))
    }

    @Test func downgradedBelowAskReportsTopScore() throws {
        let s1 = TV.probe("S1", [TV.karanAxis: 0.80], residual: 40)
        let s2 = TV.probe("S2", [TV.karanAxis: 0.75, TV.liamAxis: 0.30], residual: 41)
        let d = GoldenMatcher.decide(probes: [s1, s2], profiles: [TV.karan, TV.liam], modelKey: TV.modelKey)
        #expect(approx(try #require(d["S2"]?.lowScoreBest), 0.75))
    }

    @Test func askTakesTheProfile() {
        // S1 is only an ask for Karan; S2, lower, must not also be offered Karan.
        let s1 = TV.probe("S1", [TV.karanAxis: 0.50], residual: 40)
        let s2 = TV.probe("S2", [TV.karanAxis: 0.45], residual: 41)
        let d = GoldenMatcher.decide(probes: [s1, s2], profiles: [TV.karan], modelKey: TV.modelKey)
        #expect(d["S1"]?.isAsk == true)
        #expect(d["S2"]?.lowScoreBest != nil)
    }

    // MARK: Determinism

    @Test("Equal scores for one probe go to the lower uuidString", arguments: [false, true])
    func profileTieBreak(reversed: Bool) throws {
        let probe = TV.probe("S1", [TV.liamAxis: 0.60, TV.karanAxis: 0.60], residual: 40)
        let profiles = reversed ? [TV.karan, TV.liam] : [TV.liam, TV.karan]
        let d = try #require(GoldenMatcher.decide(probes: [probe], profiles: profiles, modelKey: TV.modelKey)["S1"])
        // Margin 0 means no auto-label; the ask goes to Liam, whose uuidString sorts first.
        guard case .ask(let id, let s) = d else { Issue.record("expected ask, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.60))
    }

    @Test("Equal scores for one profile go to the lower probe key", arguments: [false, true])
    func probeTieBreak(reversed: Bool) throws {
        let s1 = TV.probe("S1", [TV.karanAxis: 0.80], residual: 40)
        let s2 = TV.probe("S2", [TV.karanAxis: 0.80], residual: 41)
        let d = GoldenMatcher.decide(probes: reversed ? [s2, s1] : [s1, s2], profiles: [TV.karan], modelKey: TV.modelKey)
        #expect(d["S1"]?.isAuto == true)
        #expect(approx(try #require(d["S2"]?.lowScoreBest), 0.80))
    }

    @Test func shuffleInvariance() {
        let liam = TV.profile(TV.liamID, name: "Liam", axes: [0, 3, 6])
        let karan = TV.profile(TV.karanID, name: "Karan", axes: [1, 4])
        let mei = TV.profile(TV.meiID, name: "Mei", axes: [2, 5, 7], autoLabel: false)
        let stale = TV.profile(TV.uuid(0xD), name: "Old", axes: [8], needsResample: true)
        let probes = [
            TV.probe("S1", [0: 0.7, 3: 0.5, 1: 0.2], residual: 40),
            TV.probe("S2", [1: 0.6, 4: 0.55, 0: 0.3, 3: 0.3], residual: 41),
            TV.probe("S3", [2: 0.5, 5: 0.5, 7: 0.4], residual: 42),
            TV.probe("S4", [1: 0.6, 4: 0.55], residual: 43),
            TV.probe("S5", [0: 0.9], residual: 44, cleanSeconds: 2),
            TV.probe("S6", [0: 0.6, 1: 0.6], residual: 45, rejected: [TV.karanID]),
            SpeakerProbe(key: "S7", vector: nil, cleanSeconds: 20, rejectedProfileIDs: []),
            TV.probe("S8", [8: 0.9, 2: 0.2], residual: 46),
        ]
        let profiles = [liam, karan, mei, stale]
        let baseline = GoldenMatcher.decide(probes: probes, profiles: profiles, modelKey: TV.modelKey)
        #expect(baseline.count == probes.count)

        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<200 {
            let shuffledProfiles = profiles.shuffled(using: &rng).map { p in
                ProfileCandidate(id: p.id, name: p.name, samples: p.samples.shuffled(using: &rng), modelKey: p.modelKey,
                                 autoLabel: p.autoLabel, needsResample: p.needsResample)
            }
            let d = GoldenMatcher.decide(probes: probes.shuffled(using: &rng), profiles: shuffledProfiles, modelKey: TV.modelKey)
            #expect(d == baseline)
        }
    }

    @Test func repeatedProbeKeyUsesFirstOccurrence() {
        let first = TV.probe("S1", [TV.liamAxis: 0.9], residual: 40)
        let again = SpeakerProbe(key: "S1", vector: nil, cleanSeconds: 30, rejectedProfileIDs: [])
        let d = GoldenMatcher.decide(probes: [first, again], profiles: [TV.liam], modelKey: TV.modelKey)
        #expect(d.count == 1 && d["S1"]?.isAuto == true)
    }

    @Test func repeatedProfileIDUsesFirstOccurrence() {
        let probe = TV.probe("S1", [TV.liamAxis: 0.9], residual: 40)
        let liamNoAuto = TV.profile(TV.liamID, name: "Liam", axes: [TV.liamAxis], autoLabel: false)
        let d = GoldenMatcher.decide(probes: [probe], profiles: [TV.liam, liamNoAuto], modelKey: TV.modelKey)
        // The copy is not a runner-up for itself, so the margin is the full score.
        guard case .autoLabel(let id, _, let m)? = d["S1"] else { Issue.record("expected auto"); return }
        #expect(id == TV.liamID && approx(m, 0.9))
    }
}
