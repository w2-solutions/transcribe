import Foundation
import Testing
@testable import TranscribeCore

/// Exact-cosine test vectors for the matching suites (WP1).
///
/// Profile samples are one-hot axes, so a probe's cosine with a sample is just its component on that axis.
/// Each probe puts its remaining mass on its own "residual" axis, keeping it orthogonal to everything else.
enum TV {
    static let dimension = 64
    static let modelKey = "test-model@1#64"

    static func axis(_ i: Int) -> VoiceVector {
        var raw = [Float](repeating: 0, count: dimension)
        raw[i] = 1
        return VoiceVector(raw: raw)!
    }

    /// A unit vector with the given components; the leftover mass goes on `residual`.
    static func vector(_ components: [Int: Float], residual: Int) -> VoiceVector {
        var raw = [Float](repeating: 0, count: dimension)
        var mass: Float = 0
        for (i, c) in components { raw[i] = c; mass += c * c }
        precondition(mass <= 1 + 1e-6 && components[residual] == nil, "bad test vector \(components) residual \(residual)")
        raw[residual] = Swift.max(0, 1 - mass).squareRoot()
        return VoiceVector(raw: raw)!
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", UInt64(n)))!
    }

    // People used across the suites. Their uuidStrings sort liam < karan < mei.
    static let liamID = uuid(0xA), karanID = uuid(0xB), meiID = uuid(0xC)
    // Sample axes.
    static let liamAxis = 0, karanAxis = 1, meiAxis = 2

    static func profile(_ id: UUID, name: String, axes: [Int], modelKey: String = TV.modelKey,
                        autoLabel: Bool = true, needsResample: Bool = false) -> ProfileCandidate {
        ProfileCandidate(id: id, name: name, samples: axes.map(axis), modelKey: modelKey,
                         autoLabel: autoLabel, needsResample: needsResample)
    }
    /// A profile with per-sample trust (default: all trusted) and negatives, using the full initialiser.
    static func profile(_ id: UUID, name: String, axes: [Int], trusted: [Bool]? = nil, negatives: [VoiceVector],
                        modelKey: String = TV.modelKey, autoLabel: Bool = true, needsResample: Bool = false) -> ProfileCandidate {
        ProfileCandidate(id: id, name: name, samples: axes.map(axis),
                         trusted: trusted ?? Array(repeating: true, count: axes.count), negatives: negatives,
                         modelKey: modelKey, autoLabel: autoLabel, needsResample: needsResample)
    }

    /// A standard normal draw (Box–Muller, with `u1 = 1 − unit` so the logarithm never sees 0).
    static func gaussian(_ rng: inout SplitMix64) -> Float {
        let u1 = 1 - unit(&rng), u2 = unit(&rng)
        return Float((-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * Double.pi * u2))
    }

    /// Uniform in [0, 1) from the top 53 bits.
    static func unit(_ rng: inout SplitMix64) -> Double {
        Double(rng.next() >> 11) * 0x1p-53
    }

    static var liam: ProfileCandidate { profile(liamID, name: "Liam", axes: [liamAxis]) }
    static var karan: ProfileCandidate { profile(karanID, name: "Karan", axes: [karanAxis]) }
    static var mei: ProfileCandidate { profile(meiID, name: "Mei", axes: [meiAxis]) }

    /// A probe scoring `scores[axis]` against the profile sampled on that axis.
    static func probe(_ key: SpeakerKey, _ scores: [Int: Float], residual: Int, cleanSeconds: TimeInterval = 30,
                      rejected: Set<UUID> = []) -> SpeakerProbe {
        SpeakerProbe(key: key, vector: vector(scores, residual: residual), cleanSeconds: cleanSeconds,
                     rejectedProfileIDs: rejected)
    }
}

/// A seeded generator so the shuffle tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func approx(_ a: Float, _ b: Float, _ tolerance: Float = 1e-4) -> Bool { abs(a - b) <= tolerance }

extension MatchDecision {
    var profileID: UUID? {
        switch self {
        case .autoLabel(let id, _, _), .ask(let id, _): id
        case .unknown: nil
        }
    }
    var isAuto: Bool { if case .autoLabel = self { true } else { false } }
    var isAsk: Bool { if case .ask = self { true } else { false } }
    var lowScoreBest: Float? { if case .unknown(.lowScore(let b)) = self { b } else { nil } }
}

/// Golden equivalence for capture channels (§7 test 1, D11: "one channel gives exactly today's decisions").
///
/// `VoiceMatcherTests`, `VoiceLearningMatcherTests` and `VoiceLearningSimulationTests` call the matcher through these
/// wrappers. Each call runs three times and returns the first result to the test, so the test's own assertions still
/// pin the numbers:
/// 1. the live `VoiceMatcher` on the inputs as given (every channel nil);
/// 2. the live `VoiceMatcher` with every sample and probe on channel `"c"`;
/// 3. `ChannelFreeMatcher`, the frozen copy from before channels.
/// Runs 1 and 2 must equal run 3 exactly, decisions and traces, once the version and channel fields are set back to
/// their pre-channel values. Neither run may count a trusted sample as being on another channel.
enum GoldenMatcher {
    static let channel = "c"

    /// The same profile with every sample heard on `channel`.
    static func onChannel(_ p: ProfileCandidate, _ channel: String?) -> ProfileCandidate {
        ProfileCandidate(id: p.id, name: p.name, samples: p.samples, trusted: p.trusted,
                         channels: Array(repeating: channel, count: p.samples.count), negatives: p.negatives,
                         modelKey: p.modelKey, autoLabel: p.autoLabel, needsResample: p.needsResample)
    }

    /// The same probe heard on `channel`.
    static func onChannel(_ probe: SpeakerProbe, _ channel: String?) -> SpeakerProbe {
        SpeakerProbe(key: probe.key, vector: probe.vector, cleanSeconds: probe.cleanSeconds,
                     rejectedProfileIDs: probe.rejectedProfileIDs, channel: channel)
    }

    /// A trace as the pre-channel matcher wrote it: version 1, no channel fields.
    static func preChannel(_ t: MatchTrace) -> MatchTrace {
        var t = t
        t.version = 1
        t.probeChannel = nil
        t.profiles = t.profiles.map(preChannel)
        return t
    }

    static func preChannel(_ e: ProfileEvidence) -> ProfileEvidence {
        var e = e
        e.otherChannelTrustedCount = nil
        return e
    }

    static func decideWithTrace(probes: [SpeakerProbe], profiles: [ProfileCandidate], modelKey: String,
                                policy: MatchPolicy = .default, cohort: [VoiceVector] = [],
                                sourceLocation: SourceLocation = #_sourceLocation) -> MatchRun {
        let frozen = ChannelFreeMatcher.decideWithTrace(probes: probes, profiles: profiles, modelKey: modelKey,
                                                        policy: policy, cohort: cohort)
        let asGiven = VoiceMatcher.decideWithTrace(probes: probes, profiles: profiles, modelKey: modelKey,
                                                   policy: policy, cohort: cohort)
        let oneChannel = VoiceMatcher.decideWithTrace(probes: probes.map { onChannel($0, channel) },
                                                      profiles: profiles.map { onChannel($0, channel) },
                                                      modelKey: modelKey, policy: policy, cohort: cohort)
        for (run, expectedChannel) in [(asGiven, nil), (oneChannel, Optional(channel))] {
            #expect(run.decisions == frozen.decisions, "decisions on channel \(expectedChannel ?? "nil")", sourceLocation: sourceLocation)
            #expect(run.traces.mapValues(preChannel) == frozen.traces, "traces on channel \(expectedChannel ?? "nil")",
                    sourceLocation: sourceLocation)
            for t in run.traces.values {
                #expect(t.version == MatchTrace.currentVersion && t.probeChannel == expectedChannel, sourceLocation: sourceLocation)
                #expect(t.profiles.allSatisfy { $0.otherChannelTrustedCount == 0 }, sourceLocation: sourceLocation)
            }
        }
        return asGiven
    }

    static func decide(probes: [SpeakerProbe], profiles: [ProfileCandidate], modelKey: String,
                       policy: MatchPolicy = .default, cohort: [VoiceVector] = [],
                       sourceLocation: SourceLocation = #_sourceLocation) -> [SpeakerKey: MatchDecision] {
        let run = decideWithTrace(probes: probes, profiles: profiles, modelKey: modelKey, policy: policy, cohort: cohort,
                                  sourceLocation: sourceLocation)
        let decisions = VoiceMatcher.decide(probes: probes, profiles: profiles, modelKey: modelKey, policy: policy, cohort: cohort)
        #expect(decisions == run.decisions, sourceLocation: sourceLocation)
        return decisions
    }

    static func evidence(_ vector: VoiceVector, against profile: ProfileCandidate, policy: MatchPolicy = .default,
                         sourceLocation: SourceLocation = #_sourceLocation) -> ProfileEvidence? {
        let frozen = ChannelFreeMatcher.evidence(vector, against: profile, policy: policy)
        let asGiven = VoiceMatcher.evidence(vector, against: profile, policy: policy)
        let oneChannel = VoiceMatcher.evidence(vector, against: onChannel(profile, channel), probeChannel: channel, policy: policy)
        for e in [asGiven, oneChannel] {
            #expect(e.map(preChannel) == frozen, sourceLocation: sourceLocation)
            #expect(e == nil || e?.otherChannelTrustedCount == 0, sourceLocation: sourceLocation)
        }
        return asGiven
    }

    static func conflictingNegatives(_ vector: VoiceVector, profile: ProfileCandidate,
                                     negatives: [(id: UUID, vector: VoiceVector)], policy: MatchPolicy = .default,
                                     sourceLocation: SourceLocation = #_sourceLocation) -> [UUID] {
        let frozen = ChannelFreeMatcher.conflictingNegatives(vector, profile: profile, negatives: negatives, policy: policy)
        let asGiven = VoiceMatcher.conflictingNegatives(vector, profile: profile, negatives: negatives, policy: policy)
        let oneChannel = VoiceMatcher.conflictingNegatives(vector, profile: onChannel(profile, channel), negatives: negatives,
                                                           probeChannel: channel, policy: policy)
        #expect(asGiven == frozen && oneChannel == frozen, sourceLocation: sourceLocation)
        return asGiven
    }
}
