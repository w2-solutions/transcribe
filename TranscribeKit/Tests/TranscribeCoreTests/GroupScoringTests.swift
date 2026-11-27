import Foundation
import Testing
@testable import TranscribeCore

/// A probe and one person's samples with chosen cosines (`GV.vectors`): vector 0 is the probe, vectors 1… the samples.
/// Samples in the same sound group are `within` apart, samples in different groups `across`; the probe's cosine to
/// sample i is `probe[i]`.
private struct World {
    let probe: VoiceVector
    let samples: [VoiceVector]

    /// `extra` are further vectors (negatives) at those cosines to the probe and `extraToSamples` to every sample.
    init(probe cosines: [Double], groups: [Int], within: Double = 0.8, across: Double = 0.2, extra: [Double] = [],
         extraToSamples: Double = 0) {
        precondition(cosines.count == groups.count)
        let n = groups.count
        let all = GV.vectors(n + 1 + extra.count) { i, j in
            if i == 0 { return j <= n ? cosines[j - 1] : extra[j - n - 1] }
            if j > n { return i <= n ? extraToSamples : 0 }
            return groups[i - 1] == groups[j - 1] ? within : across
        }
        probe = all[0]
        samples = Array(all[1...n])
        negatives = Array(all[(n + 1)...])
    }
    var negatives: [VoiceVector]

    /// Random vectors in `GV.dimension`: one centre per group, members spread around it (within-group cosines about
    /// 0.75), and a probe near a random centre or anywhere. Every cosine is real, so the matrix is always valid.
    init(random rng: inout SplitMix64, groups: [Int]) {
        func unit(_ raw: [Float]) -> VoiceVector { VoiceVector(raw: raw)! }
        func gaussian(_ sd: Float, _ rng: inout SplitMix64) -> [Float] { (0..<GV.dimension).map { _ in sd * TV.gaussian(&rng) } }
        let centres = (0..<3).map { _ in gaussian(1 / Float(GV.dimension).squareRoot(), &rng) }
        samples = groups.map { g in unit(zip(centres[g], gaussian(0.07, &rng)).map(+)) }
        let near = Int.random(in: 0..<4, using: &rng)
        let weight = Float.random(in: 0.3...1.2, using: &rng)
        let base = near < 3 ? centres[near].map { $0 * weight } : [Float](repeating: 0, count: GV.dimension)
        probe = unit(zip(base, gaussian(0.09, &rng)).map(+))
        negatives = []
    }
}

private let mac = "mac", phone = "iphone"

/// Sample ids that sort by index: `TV.uuid(0x7000 + salt * 0x100 + i)`.
private func ids(_ count: Int, salt: Int = 0) -> [UUID] { (0..<count).map { TV.uuid(0x7000 + salt * 0x100 + $0) } }

private func candidate(_ samples: [VoiceVector], id: UUID = TV.liamID, name: String = "Liam", trusted: [Bool]? = nil,
                       channels: [String?]? = nil, negatives: [VoiceVector] = [], sampleIDs: [UUID]? = nil,
                       millis: [Int64]? = nil, salt: Int = 0, autoLabel: Bool = true) -> ProfileCandidate {
    ProfileCandidate(id: id, name: name, samples: samples, trusted: trusted ?? samples.map { _ in true },
                     channels: channels ?? samples.map { _ in mac }, negatives: negatives, modelKey: TV.modelKey,
                     autoLabel: autoLabel, needsResample: false,
                     sampleIDs: sampleIDs ?? ids(samples.count, salt: salt),
                     addedAtMillis: millis ?? samples.indices.map { Int64($0) * 1_000 })
}

private func probe(_ v: VoiceVector, key: SpeakerKey = "S1", channel: String? = mac, askOnly: Bool = false) -> SpeakerProbe {
    SpeakerProbe(key: key, vector: v, cleanSeconds: 30, rejectedProfileIDs: [], channel: channel, askOnly: askOnly)
}

private let groupsOff: MatchPolicy = { var p = MatchPolicy.default; p.groupScoring = false; return p }()

private func run(_ probes: [SpeakerProbe], _ profiles: [ProfileCandidate], policy: MatchPolicy = .default,
                 cohort: [VoiceVector] = []) -> MatchRun {
    VoiceMatcher.decideWithTrace(probes: probes, profiles: profiles, modelKey: TV.modelKey, policy: policy, cohort: cohort)
}

private func one(_ p: SpeakerProbe, _ profiles: [ProfileCandidate], policy: MatchPolicy = .default,
                 cohort: [VoiceVector] = []) throws -> (MatchDecision, MatchTrace) {
    let r = run([p], profiles, policy: policy, cohort: cohort)
    return (try #require(r.decisions[p.key]), try #require(r.traces[p.key]))
}

private func near(_ a: Float?, _ b: Float) -> Bool { a.map { approx($0, b) } ?? false }

/// Per-group scoring (decision D3): one-sample groups score on their own (S2), the symmetric runner-up, negatives
/// below A, ask and greedy on W, and groups off reproducing the matcher from before groups.
@Suite("Group scoring")
struct GroupScoringTests {

    // MARK: Scores

    @Test func aOneSampleGroupScoresItsOwnCosine() throws {
        // A desk sample at 0.60 and a call sample at 0.25 (different groups). Before groups the call sample filled
        // second place and pulled the desk voice down to 0.425; now the desk group scores 0.60 on its own.
        let w = World(probe: [0.60, 0.25], groups: [0, 1])
        let liam = candidate(w.samples)
        let (d, t) = try one(probe(w.probe), [liam])
        guard case .autoLabel(let id, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(id == TV.liamID && approx(s, 0.60) && approx(m, 0.60))
        let e = try #require(t.profiles.first)
        #expect(approx(e.score, 0.425) && near(e.autoScore, 0.60) && e.groupCount == 2)
        #expect(e.groupSize == 1 && e.groupTrustedCount == 1 && near(e.groupBestScore, 0.60))
        #expect(near(e.singletonBorrowShadow, 0.425))   // S1 would have borrowed the call sample
        #expect(t.version == MatchTrace.groupsVersion && t.kind == .auto && near(t.score, 0.60) && near(t.margin, 0.60))

        // Groups off: today's ask on 0.425.
        let (off, offTrace) = try one(probe(w.probe), [liam], policy: groupsOff)
        guard case .ask(_, let offScore) = off else { Issue.record("expected ask, got \(off)"); return }
        #expect(approx(offScore, 0.425))
        #expect(offTrace.reason == "belowAuto" && offTrace.version == 2 && offTrace.profiles.first?.groupCount == nil)
    }

    @Test func aTightPairScoresInsideItsGroupOnly() throws {
        // Group 0: two trusted samples at 0.70 and 0.40 → 0.55. A trusted outsider at 0.62 (group 1) scores 0.62.
        // W = (0.70 + 0.62) / 2 = 0.66; A = max(0.55, 0.62) = 0.62.
        let w = World(probe: [0.70, 0.40, 0.62], groups: [0, 0, 1])
        let e = try #require(VoiceMatcher.evidence(w.probe, against: candidate(w.samples), probeChannel: mac))
        #expect(approx(e.score, 0.66) && near(e.autoScore, 0.62) && e.groupCount == 2 && e.groupSize == 1)
        #expect(near(e.groupBestScore, 0.62) && near(e.singletonBorrowShadow, 0.66))
        #expect(near(e.autoTrustedScore, 0.66))   // a one-sample winner: today's top two trusted on the channel
        #expect(near(e.autoCentroidCosine, 0.62))

        let g = try #require(GroupScoring.score(w.probe, against: candidate(w.samples), channel: mac))
        #expect(g.groups.count == 2 && approx(g.groups[0].score, 0.55) && approx(g.groups[1].score, 0.62))
        #expect(near(g.groups[0].trustedScore, 0.55) && g.groups[1].trustedScore == nil)
    }

    @Test func untrustedMembersFillSecondPlaceOnlyInTheirGroup() throws {
        // Group 0: trusted 0.72 with an automatic 0.30 → 0.51. Group 1: an automatic 0.68, alone.
        // W = (0.72 + 0.68) / 2 = 0.70 would auto-label; A = 0.51 (group 1 has no trusted member) only asks.
        let w = World(probe: [0.72, 0.30, 0.68], groups: [0, 0, 1], within: 0.75, across: 0.3)
        let liam = candidate(w.samples, trusted: [true, false, false])
        let (d, t) = try one(probe(w.probe), [liam])
        #expect(d == .ask(profileID: TV.liamID, score: t.profiles[0].score))
        #expect(t.reason == "groupScore" && near(t.profiles[0].autoScore, 0.51) && approx(t.profiles[0].score, 0.70))
        #expect(near(t.profiles[0].groupBestScore, 0.68))
        #expect(try one(probe(w.probe), [liam], policy: groupsOff).0.isAuto)
    }

    @Test func groupsOnlyComeFromTheProbesChannel() throws {
        // A trusted phone sample at 0.90 never enters the mac groups: it only fills second place of W, as today.
        let w = World(probe: [0.60, 0.30, 0.90], groups: [0, 1, 2])
        let liam = candidate(w.samples, channels: [mac, mac, phone])
        let e = try #require(VoiceMatcher.evidence(w.probe, against: liam, probeChannel: mac))
        #expect(e.groupCount == 2 && near(e.autoScore, 0.60) && approx(e.score, 0.75))
        let macOnly = candidate(Array(w.samples.prefix(2)), channels: [mac, mac])
        let e2 = try #require(VoiceMatcher.evidence(w.probe, against: macOnly, probeChannel: mac))
        #expect(e2.autoScore == e.autoScore && e2.groupCount == e.groupCount && e2.groupBestScore == e.groupBestScore)

        // A probe on a channel with no samples is asked about only, with no groups.
        let (d, t) = try one(probe(w.probe, channel: "ipad"), [liam])
        #expect(d.isAsk && t.reason == "otherChannel")
        #expect(t.profiles[0].groupCount == 0 && t.profiles[0].autoScore == nil && t.profiles[0].groupBestScore == nil)
    }

    @Test func aGroupOfShortSamplesNeverWins() throws {
        // A short sample alone at 0.80: not trusted, so it is no group with a trusted member; the trusted 0.50 wins.
        let w = World(probe: [0.50, 0.80], groups: [0, 1])
        let liam = candidate(w.samples, trusted: [true, false])
        let (d, t) = try one(probe(w.probe), [liam])
        #expect(d.isAsk && t.reason == "groupScore")   // W = 0.65 would auto, A = 0.50 does not
        #expect(near(t.profiles[0].autoScore, 0.50) && near(t.profiles[0].groupBestScore, 0.80))
    }

    // MARK: Runner-up, negatives, mixed probes

    @Test func theRunnerUpIsSymmetric() throws {
        // Liam: desk pair at 0.75 and 0.71 → A = W = 0.73. Karan: a trusted pair far off (0.10, 0.10) and one sample
        // alone at 0.66 → W_K = (0.66 + 0.10) / 2 = 0.38, G_K = 0.66. The runner-up is G_K, so the margin is
        // 0.07: ask, not auto. Groups off, the runner-up is W_K = 0.38: auto.
        // Vector 0 is the probe, 1 and 2 Liam's, 3 to 5 Karan's.
        let all = GV.vectors(6) { i, j in
            switch (i, j) {
            case (0, 1): return 0.75
            case (0, 2): return 0.71
            case (1, 2): return 0.8
            case (0, 3), (0, 4): return 0.10
            case (0, 5): return 0.66
            case (3, 4): return 0.8
            default: return 0.2
            }
        }
        let liam2 = candidate([all[1], all[2]])
        let karan = candidate([all[3], all[4], all[5]], id: TV.karanID, name: "Karan", salt: 1)
        let (d, t) = try one(probe(all[0]), [liam2, karan])
        // Review 2026-11-26: W alone (against the groupless runner-up 0.38) would auto-label, so the trace says grouping
        // caused the ask ("groupScore"), not an ordinary margin.
        #expect(d.isAsk && t.reason == "groupScore" && t.profileID == TV.liamID)
        #expect(near(t.runnerUp, 0.66) && near(t.score, 0.73))
        let k = try #require(t.profiles.first { $0.profileID == TV.karanID })
        #expect(approx(k.score, 0.38) && near(k.groupBestScore, 0.66))

        let (off, offTrace) = try one(probe(all[0]), [liam2, karan], policy: groupsOff)
        #expect(off.isAuto && near(offTrace.runnerUp, 0.38))
    }

    /// The symmetric runner-up over random scores of `theRunnerUpIsSymmetric`'s shape (review 2026-11-26: the default
    /// simulations never exercise it, because a named sibling there wins its own probe outright). Liam: one group of
    /// two at a1, a2 → A = W = (a1 + a2) / 2. Karan: a far pair at k1, k2 and a sample alone at g → W_K = (g + max k) / 2,
    /// G_K = g. With groups the runner-up is g; without, W_K.
    @Test func theRunnerUpIsSymmetricOverRandomScores() throws {
        var rng = SplitMix64(seed: 0x5E11)
        var checked = 0, groupCaused = 0
        for _ in 0..<200 {
            let a1 = Double.random(in: 0.55...0.78, using: &rng), a2 = Double.random(in: 0.55...0.78, using: &rng)
            let k1 = Double.random(in: 0.05...0.2, using: &rng), k2 = Double.random(in: 0.05...0.2, using: &rng)
            let g = Double.random(in: 0.35...0.66, using: &rng)
            let a = (a1 + a2) / 2, wK = (g + Swift.max(k1, k2)) / 2
            // Skip draws within rounding of a threshold.
            guard abs(a - 0.55) > 0.01, abs(a - g - 0.10) > 0.01, abs(a - wK - 0.10) > 0.01 else { continue }
            let all = GV.vectors(6) { i, j in
                switch (i, j) {
                case (0, 1): return a1
                case (0, 2): return a2
                case (1, 2), (3, 4): return 0.8
                case (0, 3): return k1
                case (0, 4): return k2
                case (0, 5): return g
                default: return 0.2
                }
            }
            let liam2 = candidate([all[1], all[2]])
            let karan = candidate([all[3], all[4], all[5]], id: TV.karanID, name: "Karan", salt: 1)
            let (d, t) = try one(probe(all[0]), [liam2, karan])
            let (off, _) = try one(probe(all[0]), [liam2, karan], policy: groupsOff)
            let groupsAuto = a >= 0.55 && a - g >= 0.10
            let wholeAuto = a >= 0.55 && a - wK >= 0.10
            #expect(d.isAuto == groupsAuto, "a \(a), g \(g), W_K \(wK)")
            #expect(off.isAuto == wholeAuto, "a \(a), W_K \(wK)")
            #expect(near(t.runnerUp, Float(g)), "runner-up \(String(describing: t.runnerUp)) against g \(g)")
            if !groupsAuto && wholeAuto {
                #expect(t.reason == "groupScore")
                groupCaused += 1
            }
            checked += 1
        }
        #expect(checked > 120 && groupCaused > 10)
    }

    @Test func aNegativeAtOrAboveTheAutoScoreAsks() throws {
        // Group 0: 0.80 and 0.40 → A = 0.60. An untrusted sample at 0.60 alone: W = (0.80 + 0.60) / 2 = 0.70.
        // A negative at 0.65 does not block (below W) but is at least A: ask, reason negativeNear.
        let w = World(probe: [0.80, 0.40, 0.60], groups: [0, 0, 1], within: 0.75, across: 0.3, extra: [0.65],
                      extraToSamples: 0.5)
        let withNegative = candidate(w.samples, trusted: [true, true, false], negatives: w.negatives)
        let (d, t) = try one(probe(w.probe), [withNegative])
        #expect(d.isAsk && t.reason == "negativeNear")
        #expect(near(t.profiles[0].autoScore, 0.60) && approx(t.profiles[0].score, 0.70) && !t.profiles[0].blocked)

        let without = candidate(w.samples, trusted: [true, true, false])
        let (d2, _) = try one(probe(w.probe), [without])
        guard case .autoLabel(_, let s, _) = d2 else { Issue.record("expected auto, got \(d2)"); return }
        #expect(approx(s, 0.60))

        // Groups off, the same negative is below W and ignored: auto on W.
        #expect(try one(probe(w.probe), [withNegative], policy: groupsOff).0.isAuto)
    }

    @Test func aNegativeAtOrAboveWStillBlocks() throws {
        let w = World(probe: [0.70, 0.25], groups: [0, 1], extra: [0.50])
        // W = 0.475, A = 0.70: the negative at 0.50 blocks (≥ W) although A is above it.
        let (d, t) = try one(probe(w.probe), [candidate(w.samples, negatives: w.negatives)])
        #expect(d.lowScoreBest != nil && t.reason == "blocked")
    }

    @Test(arguments: [true, false])
    func aMixedProbeIsNeverAutoLabelled(groups: Bool) throws {
        var policy = MatchPolicy.default
        policy.groupScoring = groups
        let w = World(probe: [0.90, 0.88], groups: [0, 0])
        let liam = candidate(w.samples)
        let (d, t) = try one(probe(w.probe, askOnly: true), [liam], policy: policy)
        #expect(d.isAsk && t.reason == "mixedSource")
        #expect(try one(probe(w.probe), [liam], policy: policy).0.isAuto)
        // Below the ask threshold it stays unknown.
        let far = World(probe: [0.30, 0.20], groups: [0, 0])
        #expect(try one(probe(far.probe, askOnly: true), [candidate(far.samples)], policy: policy).0.lowScoreBest != nil)
    }

    @Test func downgradedStaysTheFirstReason() throws {
        // S1 and S2 are both closest to Liam; S1 takes him, so S2 is offered Karan, downgraded. Being a mixed probe
        // too, its first reason is still "downgraded".
        let all = GV.vectors(4) { i, j in
            switch (i, j) {
            case (0, 2): return 0.90   // S1 – Liam
            case (1, 2): return 0.80   // S2 – Liam
            case (1, 3): return 0.60   // S2 – Karan
            case (0, 3): return 0.10   // S1 – Karan
            case (0, 1): return 0.70
            default: return 0.3
            }
        }
        let liam = candidate([all[2]])
        let karan = candidate([all[3]], id: TV.karanID, name: "Karan", salt: 1)
        let r = run([probe(all[0], key: "S1"), probe(all[1], key: "S2", askOnly: true)], [liam, karan])
        #expect(r.decisions["S1"]?.isAuto == true)
        #expect(r.decisions["S2"] == .ask(profileID: TV.karanID, score: try #require(r.traces["S2"]?.score)))
        #expect(r.traces["S2"]?.reason == "downgraded")
    }

    // MARK: Winner and invariance

    @Test(arguments: [false, true])
    func theWinnerTieGoesToTheLowerKey(pairFirst: Bool) throws {
        // A trusted pair at 0.60 and 0.60 (0.60) ties with a trusted sample alone at 0.60. The winner is the group
        // whose key (its oldest member) has the lower uuidString.
        let w = World(probe: [0.60, 0.60, 0.60], groups: [0, 0, 1])
        let pairIDs = pairFirst ? [TV.uuid(0x7001), TV.uuid(0x7002)] : [TV.uuid(0x7011), TV.uuid(0x7012)]
        let soloID = pairFirst ? TV.uuid(0x7010) : TV.uuid(0x7000)
        let liam = candidate(w.samples, sampleIDs: pairIDs + [soloID], millis: [0, 0, 0])
        let e = try #require(VoiceMatcher.evidence(w.probe, against: liam, probeChannel: mac))
        #expect(e.groupSize == (pairFirst ? 2 : 1) && near(e.autoScore, 0.60))
    }

    @Test func theMatchersGroupsAreTheScreens() throws {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<50 {
            let n = Int.random(in: 2...10, using: &rng)
            let blocks = (0..<n).map { _ in Int.random(in: 0..<3, using: &rng) }
            let vectors = GV.blocks(blocks, within: [0.8, 0.7, 0.75], across: 0.3)
            let channels = (0..<n).map { _ in Bool.random(using: &rng) ? mac : phone }
            let p = candidate(vectors, channels: channels, millis: (0..<n).map { _ in Int64.random(in: 0..<5, using: &rng) })
            for channel in [mac, phone] {
                let items = (0..<n).filter { channels[$0] == channel }.map {
                    SampleGrouping.Item(id: p.sampleIDs![$0], vector: vectors[$0], channel: channel,
                                        addedAtMillis: p.addedAtMillis![$0])
                }
                let screen = SampleGrouping.group(items, dimension: GV.dimension)
                let matcher = try #require(GroupScoring.groups(of: p, channel: channel, dimension: GV.dimension))
                #expect(matcher.map(\.memberIDs) == screen.map(\.memberIDs) && matcher.map(\.key) == screen.map(\.key))
            }
        }
    }

    @Test func resultsDoNotDependOnOrder() {
        var rng = SplitMix64(seed: 5)
        for _ in 0..<60 {
            let n = Int.random(in: 2...9, using: &rng)
            let w = World(random: &rng, groups: (0..<n).map { _ in Int.random(in: 0..<3, using: &rng) })
            let trusted = (0..<n).map { _ in Int.random(in: 0..<4, using: &rng) > 0 }
            let base = candidate(w.samples, trusted: trusted, millis: (0..<n).map { _ in Int64.random(in: 0..<3, using: &rng) })
            let baseline = run([probe(w.probe)], [base, TV.karan])
            for _ in 0..<5 {
                let order = Array(0..<n).shuffled(using: &rng)
                let shuffled = ProfileCandidate(
                    id: base.id, name: base.name, samples: order.map { base.samples[$0] }, trusted: order.map { base.trusted[$0] },
                    channels: order.map { base.channels[$0] }, negatives: base.negatives, modelKey: base.modelKey,
                    autoLabel: true, needsResample: false, sampleIDs: order.map { base.sampleIDs![$0] },
                    addedAtMillis: order.map { base.addedAtMillis![$0] })
                #expect(run([probe(w.probe)], [TV.karan, shuffled]) == baseline)
            }
        }
    }

    // MARK: Groups off and legacy candidates

    @Test func groupsOffEqualsTheMatcherFromBeforeGroupsOnGroupedProfiles() {
        var rng = SplitMix64(seed: 23)
        for _ in 0..<200 {
            // Each profile is built around its own probe (`World`); the vectors share coordinates, so every probe
            // also scores against the other profiles. The runs auto-label, ask and leave unknown.
            var probes: [SpeakerProbe] = []
            let profiles = (0..<Int.random(in: 1...3, using: &rng)).map { i -> ProfileCandidate in
                let n = Int.random(in: 1...6, using: &rng)
                let w = World(random: &rng, groups: (0..<n).map { _ in Int.random(in: 0..<3, using: &rng) })
                probes.append(probe(w.probe, key: "S\(i)", channel: Int.random(in: 0..<4, using: &rng) == 0 ? phone : mac,
                                    askOnly: false))
                return candidate(w.samples, id: [TV.liamID, TV.karanID, TV.meiID][i], name: "P\(i)",
                                 trusted: (0..<n).map { _ in Int.random(in: 0..<3, using: &rng) > 0 },
                                 channels: (0..<n).map { _ in Int.random(in: 0..<4, using: &rng) == 0 ? phone : mac }, salt: i)
            }
            GroupsOff.check(probes: probes, profiles: profiles, modelKey: TV.modelKey, policy: .default,
                            cohort: [], groupsOn: nil)
        }
    }

    @Test func legacyCandidatesScoreWithoutGroups() throws {
        let w = World(probe: [0.60, 0.25], groups: [0, 1])
        let legacy = ProfileCandidate(id: TV.liamID, name: "Liam", samples: w.samples, trusted: [true, true],
                                      channels: [mac, mac], negatives: [], modelKey: TV.modelKey, autoLabel: true,
                                      needsResample: false)
        let (d, t) = try one(probe(w.probe), [legacy])
        #expect(d.isAsk && t.reason == "belowAuto" && t.profiles[0].groupCount == nil && t.profiles[0].autoScore == nil)
        #expect(t.version == MatchTrace.groupsVersion)
    }

    // MARK: Automatic samples

    @Test func theAutomaticSampleIsGatedInTheWinningGroup() throws {
        // Desk pair at 0.80 and 0.76 (trusted score 0.78 in the group); a far trusted sample at 0.20 elsewhere.
        let w = World(probe: [0.80, 0.76, 0.20], groups: [0, 0, 1])
        let liam = candidate(w.samples)
        let (d, t) = try one(probe(w.probe), [liam])
        let e = try #require(t.profiles.first)
        #expect(near(e.autoTrustedScore, 0.78) && near(e.trustedScore, 0.78))
        #expect(try #require(e.autoCentroidCosine) > 0.80)
        #expect(SampleCurator.shouldAddAutomaticSample(decision: d, evidence: e, coherence: 0.8, cleanSeconds: 12))
        #expect(!SampleCurator.shouldAddAutomaticSample(decision: d, evidence: e, coherence: 0.8, cleanSeconds: 9))
        #expect(!SampleCurator.shouldAddAutomaticSample(decision: d, evidence: nil, coherence: 0.8, cleanSeconds: 12))
    }

    @Test("The voice must join the winning group: q(centroid cosine) ≥ q(0.65)",
          arguments: [(Float(0.65), true), (0.64996, true), (0.64994, false), (0.64, false), (0.90, true)])
    func theCentroidRule(centroid: Float, allowed: Bool) {
        let e = ProfileEvidence(profileID: TV.liamID, score: 0.8, trustedTop: 0.8, trustedScore: 0.8, trustedCount: 2,
                                untrustedCount: 0, askOnly: false, negativeMax: nil, blocked: false, cohortMax: nil,
                                otherChannelTrustedCount: 0, autoScore: 0.8, groupCount: 1, groupSize: 2,
                                groupTrustedCount: 2, groupBestScore: 0.8, autoTrustedScore: 0.8, autoCentroidCosine: centroid)
        let d = MatchDecision.autoLabel(profileID: TV.liamID, score: 0.8, margin: 0.8)
        #expect(SampleCurator.shouldAddAutomaticSample(decision: d, evidence: e, coherence: 0.9, cleanSeconds: 20) == allowed)
    }

    @Test func aGroupedTrustedScoreBelowSeventyStoresNothing() {
        let d = MatchDecision.autoLabel(profileID: TV.liamID, score: 0.8, margin: 0.5)
        let e = ProfileEvidence(profileID: TV.liamID, score: 0.8, trustedTop: 0.9, trustedScore: 0.85, trustedCount: 3,
                                untrustedCount: 0, askOnly: false, negativeMax: nil, blocked: false, cohortMax: nil,
                                otherChannelTrustedCount: 0, autoScore: 0.69, groupCount: 2, groupSize: 2,
                                groupTrustedCount: 2, groupBestScore: 0.69, autoTrustedScore: 0.6999,
                                autoCentroidCosine: 0.8)
        // The channel's trusted score (0.85) does not count once the profile is scored per group.
        #expect(!SampleCurator.shouldAddAutomaticSample(decision: d, evidence: e, coherence: 0.9, cleanSeconds: 20))
        var legacy = e
        legacy.groupCount = nil
        #expect(SampleCurator.shouldAddAutomaticSample(decision: d, evidence: legacy, coherence: 0.9, cleanSeconds: 20))
    }

    // MARK: Trace

    @Test func traceV3RoundTripsWithTheGroupFields() throws {
        let w = World(probe: [0.60, 0.25], groups: [0, 1])
        let (_, t) = try one(probe(w.probe), [candidate(w.samples)])
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(MatchTrace.self, from: data) == t)
        let json = try #require(String(data: data, encoding: .utf8))
        for key in ["autoScore", "groupCount", "groupSize", "groupTrustedCount", "singletonBorrowShadow", "groupBestScore",
                    "autoTrustedScore", "autoCentroidCosine"] {
            #expect(json.contains("\"\(key)\""), "\(key)")
        }
        #expect(json.contains("\"version\":3"))
    }
}
