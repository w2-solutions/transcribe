import Foundation
import Testing
@testable import TranscribeCore

/// Capture channels in the matcher (§7, D11): a trusted sample is trusted for first place only on its own channel.
/// The golden equivalence (one channel gives exactly the decisions from before channels) runs inside every scenario of
/// `VoiceMatcherTests`, `VoiceLearningMatcherTests` and `VoiceLearningSimulationTests`, through `GoldenMatcher`.
@Suite("Channel-aware matcher")
struct ChannelAwareMatcherTests {
    static let phone = "iphone", mac = "mac"

    static func profile(_ id: UUID, _ name: String, axes: [Int], trusted: [Bool]? = nil, channels: [String?],
                        negatives: [VoiceVector] = [], autoLabel: Bool = true) -> ProfileCandidate {
        ProfileCandidate(id: id, name: name, samples: axes.map(TV.axis),
                         trusted: trusted ?? Array(repeating: true, count: axes.count), channels: channels,
                         negatives: negatives, modelKey: TV.modelKey, autoLabel: autoLabel, needsResample: false)
    }

    static func probe(_ scores: [Int: Float], residual: Int = 40, on channel: String?, key: SpeakerKey = "S1") -> SpeakerProbe {
        SpeakerProbe(key: key, vector: TV.vector(scores, residual: residual), cleanSeconds: 30, rejectedProfileIDs: [],
                     channel: channel)
    }

    static func run(_ probe: SpeakerProbe, _ profiles: [ProfileCandidate], policy: MatchPolicy = .default) throws
        -> (MatchDecision, MatchTrace) {
        let r = VoiceMatcher.decideWithTrace(probes: [probe], profiles: profiles, modelKey: TV.modelKey, policy: policy)
        return (try #require(r.decisions[probe.key]), try #require(r.traces[probe.key]))
    }

    // MARK: Inputs

    @Test func channelsDefaultToNilAndTravelWithTheCandidate() {
        #expect(TV.liam.channels == [nil])
        let p = Self.profile(TV.liamID, "Liam", axes: [0, 1], channels: [Self.mac, nil])
        #expect(p.channels == [Self.mac, nil])
        #expect(SpeakerProbe(key: "S1", vector: nil, cleanSeconds: 1, rejectedProfileIDs: []).channel == nil)
    }

    /// The golden wrapper is not vacuous: a split profile does differ from the matcher before channels.
    @Test func theFrozenMatcherIgnoresChannels() throws {
        let karan = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis], channels: [Self.phone])
        let probe = Self.probe([TV.karanAxis: 0.9], on: Self.mac)
        let frozen = ChannelFreeMatcher.decide(probes: [probe], profiles: [karan], modelKey: TV.modelKey)
        let live = VoiceMatcher.decide(probes: [probe], profiles: [karan], modelKey: TV.modelKey)
        #expect(frozen["S1"]?.isAuto == true)
        #expect(live["S1"]?.isAsk == true)
    }

    // MARK: Test 2: foreign trusted samples only

    @Test("Foreign trusted samples only: ask with reason otherChannel, never auto",
          arguments: [(Float(0.3999), false), (0.40, true), (0.5499, true), (0.55, true), (0.95, true)])
    func foreignTrustedOnlyAsks(score: Float, asks: Bool) throws {
        let karan = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis, TV.karanAxis], channels: [Self.phone, Self.phone])
        let (d, t) = try Self.run(Self.probe([TV.karanAxis: score], on: Self.mac), [karan])
        #expect(t.probeChannel == Self.mac && t.version == 2)
        let e = try #require(t.profiles.first)
        #expect(e.trustedCount == 0 && e.otherChannelTrustedCount == 2 && e.untrustedCount == 2 && e.askOnly)
        #expect(e.trustedScore == nil && e.trustedTop == nil && approx(e.score, score))
        if asks {
            guard case .ask(let id, let s) = d else { Issue.record("expected ask, got \(d)"); return }
            #expect(id == TV.karanID && approx(s, score))
            #expect(t.kind == .ask && t.reason == "otherChannel")
        } else {
            #expect(approx(try #require(d.lowScoreBest), score))
            #expect(t.kind == .unknown && t.reason == "lowScore")
        }
        // The same voice on Karan's own channel is auto-labelled from 0.55.
        let home = try Self.run(Self.probe([TV.karanAxis: score], on: Self.phone), [karan]).0
        #expect(home.isAuto == (score >= 0.55))
    }

    @Test func foreignTrustedOnlyNeverAutoLabelsEvenWithNoMarginRule() throws {
        var policy = MatchPolicy.default
        policy.autoLabelMargin = -1
        let karan = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis], channels: [Self.phone])
        let (d, t) = try Self.run(Self.probe([TV.karanAxis: 0.99], on: Self.mac), [karan], policy: policy)
        #expect(d.isAsk && t.reason == "otherChannel")
    }

    @Test func nilEqualsNilOnly() throws {
        // A sample with no channel is foreign to a probe on a channel, and the other way round.
        let unknown = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis], channels: [nil])
        let onMac = try Self.run(Self.probe([TV.karanAxis: 0.8], on: Self.mac), [unknown])
        #expect(onMac.0.isAsk && onMac.1.reason == "otherChannel")
        let phone = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis], channels: [Self.phone])
        let noChannel = try Self.run(Self.probe([TV.karanAxis: 0.8], on: nil), [phone])
        #expect(noChannel.0.isAsk && noChannel.1.reason == "otherChannel" && noChannel.1.probeChannel == nil)
        #expect(try Self.run(Self.probe([TV.karanAxis: 0.8], on: nil), [unknown]).0.isAuto)
    }

    @Test func shortSamplesOnTheProbesChannelStillSayAskOnly() throws {
        // No trusted sample anywhere: the existing reason, not otherChannel.
        let karan = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis], trusted: [false], channels: [Self.mac])
        let (d, t) = try Self.run(Self.probe([TV.karanAxis: 0.8], on: Self.mac), [karan])
        #expect(d.isAsk && t.reason == "askOnly" && t.profiles.first?.otherChannelTrustedCount == 0)
        // Short samples on the probe's channel plus trusted ones elsewhere: otherChannel.
        let mixed = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis, TV.karanAxis], trusted: [false, true],
                                 channels: [Self.mac, Self.phone])
        let (d2, t2) = try Self.run(Self.probe([TV.karanAxis: 0.8], on: Self.mac), [mixed])
        #expect(d2.isAsk && t2.reason == "otherChannel" && t2.profiles.first?.otherChannelTrustedCount == 1)
    }

    @Test func downgradedStaysTheFirstReason() throws {
        // S1 takes Karan; S2's next best is Liam, known only on the iPhone: still "downgraded", as before channels.
        let karan = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis], channels: [Self.mac])
        let liam = Self.profile(TV.liamID, "Liam", axes: [TV.liamAxis], channels: [Self.phone])
        let r = VoiceMatcher.decideWithTrace(
            probes: [Self.probe([TV.karanAxis: 0.8], on: Self.mac),
                     Self.probe([TV.karanAxis: 0.7, TV.liamAxis: 0.6], residual: 41, on: Self.mac, key: "S2")],
            profiles: [karan, liam], modelKey: TV.modelKey)
        #expect(r.decisions["S1"]?.isAuto == true)
        #expect(r.decisions["S2"]?.isAsk == true && r.decisions["S2"]?.profileID == TV.liamID)
        #expect(r.traces["S2"]?.reason == "downgraded")
    }

    // MARK: Test 3: one same-channel trusted sample

    @Test func oneSameChannelTrustedSamplePlusForeignOnesAutoLabels() throws {
        // Trusted on the Mac at 0.45, trusted on the iPhone at 0.7 and 0.5. The Mac sample takes first place; the
        // iPhone ones only fill second: (0.45 + 0.7) / 2 = 0.575. Before channels it was (0.7 + 0.5) / 2 = 0.6.
        let karan = Self.profile(TV.karanID, "Karan", axes: [1, 2, 3], channels: [Self.mac, Self.phone, Self.phone])
        let probe = Self.probe([1: 0.45, 2: 0.7, 3: 0.5], on: Self.mac)
        let (d, t) = try Self.run(probe, [karan])
        guard case .autoLabel(let id, let s, let m) = d else { Issue.record("expected auto, got \(d)"); return }
        #expect(id == TV.karanID && approx(s, 0.575) && approx(m, 0.575))
        let e = try #require(t.profiles.first)
        #expect(e.trustedCount == 1 && e.otherChannelTrustedCount == 2 && e.untrustedCount == 2 && !e.askOnly)
        #expect(near(e.trustedTop, 0.45) && near(e.trustedScore, 0.45))
        let before = ChannelFreeMatcher.decide(probes: [probe], profiles: [karan], modelKey: TV.modelKey)
        guard case .autoLabel(_, let old, _)? = before["S1"] else { Issue.record("expected auto before channels"); return }
        #expect(approx(old, 0.6))
    }

    @Test("Auto-label threshold with one same-channel sample",
          arguments: [(Float(0.65), true), (0.6499, false)])
    func autoThreshold(foreign: Float, auto: Bool) throws {
        // (0.45 + foreign) / 2: 0.55 auto-labels, 0.54995 asks.
        let karan = Self.profile(TV.karanID, "Karan", axes: [1, 2], channels: [Self.mac, Self.phone])
        let (d, t) = try Self.run(Self.probe([1: 0.45, 2: foreign], on: Self.mac), [karan])
        #expect(d.isAuto == auto)
        if !auto { #expect(d.isAsk && t.reason == "belowAuto") }
    }

    @Test("Margin with one same-channel sample", arguments: [(Float(0.50), true), (0.5001, false)])
    func autoMargin(runnerUp: Float, auto: Bool) throws {
        let karan = Self.profile(TV.karanID, "Karan", axes: [1, 2], channels: [Self.mac, Self.phone])
        let liam = Self.profile(TV.liamID, "Liam", axes: [TV.liamAxis], channels: [Self.mac])
        let (d, t) = try Self.run(Self.probe([1: 0.5, 2: 0.7, TV.liamAxis: runnerUp], on: Self.mac), [karan, liam])
        #expect(d.profileID == TV.karanID && d.isAuto == auto)
        if auto {
            guard case .autoLabel(_, let s, let m) = d else { return }
            #expect(approx(s, 0.6) && approx(m, 0.1))
        } else {
            #expect(t.reason == "margin")
        }
    }

    // MARK: Test 4: negatives from every channel

    @Test func aForeignNegativeBlocks() throws {
        // Liam is known on the Mac; the negative was learned from an iPhone recording. Negatives carry no channel in
        // the candidate: they count for probes on every channel.
        let negative = TV.vector([0: 0.48, 40: 0.64], residual: 45)
        let liam = Self.profile(TV.liamID, "Liam", axes: [0], channels: [Self.mac], negatives: [negative])
        for channel in [Self.mac, Self.phone] {
            let (d, t) = try Self.run(Self.probe([0: 0.6], on: channel), [liam])
            #expect(approx(try #require(d.lowScoreBest), 0.6))
            #expect(t.kind == .unknown && t.reason == "blocked" && t.profiles.first?.blocked == true)
        }
    }

    @Test func conflictingNegativesScoreOnTheVoicesChannel() {
        // Liam: two trusted iPhone samples (axes 0 and 3) and one trusted Mac sample (axis 4).
        let liam = Self.profile(TV.liamID, "Liam", axes: [0, 3, 4], channels: [Self.phone, Self.phone, Self.mac])
        let vector = TV.vector([0: 0.6, 3: 0.6, 4: 0.1], residual: 40)
        let negative = (id: TV.uuid(0x2A), vector: TV.vector([3: 0.75], residual: 44))   // cosine 0.45 to the voice
        // On the iPhone the voice scores (0.6 + 0.6) / 2 = 0.6: the negative is further away and stays.
        #expect(VoiceMatcher.conflictingNegatives(vector, profile: liam, negatives: [negative], probeChannel: Self.phone).isEmpty)
        // On the Mac it scores (0.1 + 0.6) / 2 = 0.35: the negative is at least as close and conflicts.
        #expect(VoiceMatcher.conflictingNegatives(vector, profile: liam, negatives: [negative], probeChannel: Self.mac)
                == [negative.id])
    }

    // MARK: Test 5: the automatic sample

    @Test("The automatic sample needs a same-channel trusted score of 0.70",
          arguments: [(Float(0.70), true), (0.6999, false)])
    func automaticSampleGate(sameChannel: Float, stored: Bool) throws {
        // Liam: trusted on the Mac (axis 0) and on the iPhone (axis 1, at 0.71, which alone would pass).
        let liam = Self.profile(TV.liamID, "Liam", axes: [0, 1], channels: [Self.mac, Self.phone])
        let probe = Self.probe([0: sameChannel, 1: 0.71], on: Self.mac)
        let (d, _) = try Self.run(probe, [liam])
        #expect(d.isAuto)
        let vector = try #require(probe.vector)
        let e = try #require(VoiceMatcher.evidence(vector, against: liam, probeChannel: Self.mac))
        #expect(near(e.trustedScore, sameChannel) && e.trustedCount == 1 && e.otherChannelTrustedCount == 1)
        #expect(SampleCurator.shouldAddAutomaticSample(decision: d, trustedScore: e.trustedScore, coherence: 1,
                                                       cleanSeconds: 30) == stored)
    }

    @Test func noAutomaticSampleFromForeignTrustOnly() throws {
        // Every trusted sample is on the iPhone: no trusted score on the Mac at all, however close the voice.
        let liam = Self.profile(TV.liamID, "Liam", axes: [0, 1], channels: [Self.phone, Self.phone])
        let vector = TV.vector([0: 0.7, 1: 0.7], residual: 40)
        let onMac = try #require(VoiceMatcher.evidence(vector, against: liam, probeChannel: Self.mac))
        #expect(onMac.trustedScore == nil && onMac.askOnly)
        let onPhone = try #require(VoiceMatcher.evidence(vector, against: liam, probeChannel: Self.phone))
        #expect(near(onPhone.trustedScore, 0.7))
    }

    // MARK: Cohort

    @Test func theCohortFilterIgnoresChannels() throws {
        // The cohort voice scores 0.5 against Liam's iPhone sample, so it might be Liam and is left out of his
        // cohort on every probe channel, exactly as before channels.
        let liam = Self.profile(TV.liamID, "Liam", axes: [0], channels: [Self.phone])
        let cohort = [TV.vector([0: 0.5, 3: 0.8], residual: 43)]
        let probe = Self.probe([0: 0.56, 3: 0.6], residual: 41, on: Self.mac)
        let r = VoiceMatcher.decideWithTrace(probes: [probe], profiles: [liam], modelKey: TV.modelKey, cohort: cohort)
        #expect(r.traces["S1"]?.profiles.first?.cohortMax == nil && r.traces["S1"]?.cohortSize == 1)
    }

    // MARK: Trace format

    @Test func traceV2RoundTripsAndV1StillDecodes() throws {
        let karan = Self.profile(TV.karanID, "Karan", axes: [TV.karanAxis], channels: [Self.phone])
        let (_, t) = try Self.run(Self.probe([TV.karanAxis: 0.8], on: Self.mac), [karan])
        #expect(MatchTrace.currentVersion == 2 && t.version == 2)
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(MatchTrace.self, from: data) == t)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"probeChannel\":\"mac\"") && json.contains("\"otherChannelTrustedCount\":1"))

        // A v1 trace (written before channels) has neither field.
        var v1 = GoldenMatcher.preChannel(t)
        v1.version = 1
        let v1JSON = try JSONEncoder().encode(v1)
        let v1Text = try #require(String(data: v1JSON, encoding: .utf8))
        #expect(!v1Text.contains("probeChannel") && !v1Text.contains("otherChannelTrustedCount"))
        let decoded = try JSONDecoder().decode(MatchTrace.self, from: v1JSON)
        #expect(decoded.version == 1 && decoded.probeChannel == nil && decoded.profiles.first?.otherChannelTrustedCount == nil)
    }
}

private func near(_ a: Float?, _ b: Float) -> Bool { a.map { approx($0, b) } ?? false }
