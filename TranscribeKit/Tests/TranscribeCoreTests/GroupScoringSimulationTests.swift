import Foundation
import Testing
@testable import TranscribeCore

/// Sibling false-auto rates before and after per-group scoring (decision D3), on synthetic data. These are noise
/// models, not measurements of real voices: they show the direction and size of the change, and the printed lines
/// (`SIMULATION …`) are the numbers reported to Liam. The bounds only catch a change in the matcher; they are not
/// targets, and the thresholds are not tuned from them (CLAUDE.md: thresholds change only from real numbers).
@Suite("Group scoring simulations")
struct GroupScoringSimulationTests {

    // MARK: The reviewer's noise model: independent cosines

    /// A sibling's cosine to each trusted sample is N(0.38, 0.07), independently (the model of
    /// `siblingFalseAutoRateAtTheCap`). With no runner-up, the rate is how often the auto score reaches 0.55.
    /// Groups are imposed (the model has no sample-to-sample cosines): `sizes` lists the group sizes.
    ///
    /// `today` is the matcher before groups with today's cap: it never holds more than `todayCap` (12) samples per
    /// (profile, channel), so a library over 12 is scored on 12 of them (review 2026-11-26: the earlier table compared
    /// 20 singletons against a groupless score over 20 samples, a library only D4's ceiling makes). `uncapped` is that
    /// groupless score over every sample, the hypothetical "groups off with the ceiling of 20".
    private func independentRate(sizes: [Int], todayCap: Int = 12, trials: Int = 20_000,
                                 seed: UInt64 = 1) -> (today: Double, groups: Double, shadow: Double, uncapped: Double) {
        var rng = SplitMix64(seed: seed)
        var today = 0, grouped = 0, shadow = 0, uncapped = 0
        for _ in 0..<trials {
            let cosines = sizes.map { n in (0..<n).map { _ in 0.38 + 0.07 * TV.gaussian(&rng) } }
            let all = cosines.flatMap { $0 }
            if let w = VoiceMatcher.pairScore(trusted: Array(all.prefix(todayCap)), untrusted: [], topK: 2),
               atLeast(w, 0.55) { today += 1 }
            if let w = VoiceMatcher.pairScore(trusted: all, untrusted: [], topK: 2), atLeast(w, 0.55) { uncapped += 1 }
            let a = cosines.compactMap { VoiceMatcher.pairScore(trusted: $0, untrusted: [], topK: 2) }.max()!
            if atLeast(a, 0.55) { grouped += 1 }
            // S1: a one-sample group borrows its second place from the rest.
            let s1 = cosines.enumerated().compactMap { i, g -> Float? in
                g.count >= 2 ? VoiceMatcher.pairScore(trusted: g, untrusted: [], topK: 2)
                    : VoiceMatcher.pairScore(trusted: g, untrusted: cosines.enumerated().filter { $0.offset != i }.flatMap(\.element), topK: 2)
            }.max()!
            if atLeast(s1, 0.55) { shadow += 1 }
        }
        let t = Double(trials)
        return (Double(today) / t, Double(grouped) / t, Double(shadow) / t, Double(uncapped) / t)
    }

    @Test func independentCosinesModel() {
        let rows: [(String, [Int])] = [
            ("1 group of 12", [12]),
            ("3 groups of 4", [4, 4, 4]),
            ("12 + 1 singleton", [11, 1]),
            ("12 singletons", Array(repeating: 1, count: 12)),
            ("20 singletons (ceiling)", Array(repeating: 1, count: 20)),
        ]
        var results: [String: (today: Double, groups: Double, shadow: Double, uncapped: Double)] = [:]
        for (name, sizes) in rows {
            let r = independentRate(sizes: sizes)
            results[name] = r
            print(String(format: "SIMULATION independent %@: today (at most 12 samples) %.4f, groups (S2) %.4f, S1 shadow %.4f, groupless over all %d samples %.4f",
                         name, r.today, r.groups, r.shadow, sizes.reduce(0, +), r.uncapped))
        }
        // One group of 12 is exactly today's score; S1 is never looser than the groupless score over the same samples.
        #expect(results["1 group of 12"]!.today == results["1 group of 12"]!.groups)
        for (_, r) in results { #expect(r.shadow <= r.uncapped + 1e-9) }
        // Today's rate at the cap (about 0.014, as the existing simulation says), and today never holds 20 samples:
        // its rate for a person with 20 singletons is the rate at 12.
        #expect(abs(results["1 group of 12"]!.today - 0.014) < 0.005)
        #expect(abs(results["20 singletons (ceiling)"]!.today - 0.014) < 0.005)
        #expect(results["20 singletons (ceiling)"]!.uncapped > results["20 singletons (ceiling)"]!.today)
        // S2's worst cases: about 1 − Φ(2.43)^n per probe with no runner-up (n singletons).
        #expect(abs(results["12 singletons"]!.groups - 0.087) < 0.01)
        #expect(abs(results["20 singletons (ceiling)"]!.groups - 0.141) < 0.012)
    }

    // MARK: A vector model with sound environments

    /// Voices as `a·identity + b·environment + n·noise` in 128 dimensions (random unit directions), with a² = 0.55,
    /// b² = 0.15, n² = 0.30. The same person in the same environment is about 0.70 (one sound group), in another
    /// environment about 0.55 (another group), and a sibling (identity cosine 0.45) about 0.40 in the same
    /// environment and 0.25 in another. Random directions in 128 dimensions give every cosine a spread of about
    /// 0.07, the spread of the independent model.
    private struct Voices {
        static let dimension = 128
        static let a = Float(0.55).squareRoot(), b = Float(0.15).squareRoot(), n = Float(0.30).squareRoot()
        static let siblingIdentity: Float = 0.45

        static func unit(_ rng: inout SplitMix64) -> [Float] {
            let raw = (0..<dimension).map { _ in TV.gaussian(&rng) }
            let norm = raw.map { $0 * $0 }.reduce(0, +).squareRoot()
            return raw.map { $0 / norm }
        }

        static func voice(_ identity: [Float], _ environment: [Float], _ rng: inout SplitMix64) -> VoiceVector {
            let noise = unit(&rng)
            return VoiceVector(raw: (0..<dimension).map { a * identity[$0] + b * environment[$0] + n * noise[$0] })!
        }

        static func sibling(of identity: [Float], _ rng: inout SplitMix64) -> [Float] {
            let other = unit(&rng)
            let s = siblingIdentity, r = (1 - s * s).squareRoot()
            let raw = (0..<dimension).map { s * identity[$0] + r * other[$0] }
            let norm = raw.map { $0 * $0 }.reduce(0, +).squareRoot()
            return raw.map { $0 / norm }
        }
    }

    struct Outcome {
        var auto = 0, ask = 0, trials = 0
        var autoRate: Double { Double(auto) / Double(Swift.max(1, trials)) }
        var askRate: Double { Double(ask) / Double(Swift.max(1, trials)) }
    }

    enum SiblingSetting: String, CaseIterable { case unknown = "unnamed", cohort = "unnamed, 3 in the cohort", named = "named (2 samples)" }

    /// One library layout: `perEnvironment[k]` trusted samples of P recorded in environment k, all on one channel.
    /// Probes, each decided alone: the sibling in P's environment 0, and P in environment 0 and in the last
    /// environment. The sibling is unnamed, or unnamed with 3 earlier recordings in the cohort, or a named profile
    /// with 2 trusted samples in environment 0.
    private func simulate(perEnvironment: [Int], sibling setting: SiblingSetting, trials: Int,
                          seed: UInt64) -> (sibling: [Bool: Outcome], person: [Bool: Outcome], personLast: [Bool: Outcome]) {
        var rng = SplitMix64(seed: seed)
        var sibling: [Bool: Outcome] = [false: Outcome(), true: Outcome()]
        var person = sibling, personLast = sibling
        for _ in 0..<trials {
            let identity = Voices.unit(&rng)
            let environments = perEnvironment.map { _ in Voices.unit(&rng) }
            var samples: [VoiceVector] = []
            for (k, count) in perEnvironment.enumerated() {
                for _ in 0..<count { samples.append(Voices.voice(identity, environments[k], &rng)) }
            }
            let siblingIdentity = Voices.sibling(of: identity, &rng)
            let siblingProbe = Voices.voice(siblingIdentity, environments[0], &rng)
            let personProbe = Voices.voice(identity, environments[0], &rng)
            let personLastProbe = Voices.voice(identity, environments[environments.count - 1], &rng)
            let cohort = setting == .cohort ? (0..<3).map { _ in Voices.voice(siblingIdentity, environments[0], &rng) } : []
            func candidate(_ id: UUID, _ samples: [VoiceVector], salt: Int) -> ProfileCandidate {
                ProfileCandidate(id: id, name: "P", samples: samples, trusted: samples.map { _ in true },
                                 channels: samples.map { _ in "mac" }, negatives: [], modelKey: "sim", autoLabel: true,
                                 needsResample: false, sampleIDs: samples.indices.map { TV.uuid(0x5000 + salt * 0x100 + $0) },
                                 addedAtMillis: samples.indices.map { Int64($0) })
            }
            let namedSibling = setting == .named
                ? candidate(TV.karanID, (0..<2).map { _ in Voices.voice(siblingIdentity, environments[0], &rng) }, salt: 1)
                : nil
            for groups in [false, true] {
                var policy = MatchPolicy.default
                policy.groupScoring = groups
                // Today's matcher never holds more than 12 samples per (profile, channel): over 12 it is scored on the
                // first 12 (those include the probes' environment 0). With groups, the ceiling of 20 keeps them all.
                let held = groups ? samples : Array(samples.prefix(12))
                let profiles = [candidate(TV.liamID, held, salt: 0)] + (namedSibling.map { [$0] } ?? [])
                for (key, vector) in [("S", siblingProbe), ("P", personProbe), ("L", personLastProbe)] {
                    let probe = SpeakerProbe(key: key, vector: vector, cleanSeconds: 30, rejectedProfileIDs: [], channel: "mac")
                    let d = VoiceMatcher.decide(probes: [probe], profiles: profiles, modelKey: "sim", policy: policy,
                                                cohort: cohort)[key]!
                    let toP = d.profileID == TV.liamID
                    func count(_ o: inout Outcome) {
                        o.trials += 1
                        if toP && d.isAuto { o.auto += 1 }
                        if toP && d.isAsk { o.ask += 1 }
                    }
                    switch key {
                    case "S": count(&sibling[groups]!)
                    case "P": count(&person[groups]!)
                    default: count(&personLast[groups]!)
                    }
                }
            }
        }
        return (sibling, person, personLast)
    }

    static let layouts: [(String, [Int])] = [
        ("12 in one environment", [12]),
        ("3 environments x 4", [4, 4, 4]),
        ("11 + 1 in a second environment", [11, 1]),
        ("12 environments x 1", Array(repeating: 1, count: 12)),
        ("20 environments x 1 (ceiling)", Array(repeating: 1, count: 20)),
    ]

    /// The full table takes minutes in a Debug build, so it runs only with `TRANSCRIBE_SIMULATIONS=full`. By default a
    /// shorter run (fixed seeds) covers one environment and 12 environments × 1, with the sibling unnamed and named,
    /// and bounds the rates loosely, so a regression either way fails `swift test` (review 2026-11-26). The named
    /// sibling here wins its own probe outright, so the symmetric runner-up itself is pinned by
    /// `GroupScoringTests.theRunnerUpIsSymmetric` and `theRunnerUpIsSymmetricOverRandomScores`.
    @Test func environmentModel() {
        let full = ProcessInfo.processInfo.environment["TRANSCRIBE_SIMULATIONS"] == "full"
        let trials = full ? 1_000 : 200
        let picked = full ? Array(Self.layouts.indices) : [0, 3]
        for i in picked {
            let (name, layout) = Self.layouts[i]
            for (j, setting) in SiblingSetting.allCases.enumerated() where full || setting != .cohort {
                let r = simulate(perEnvironment: layout, sibling: setting, trials: trials, seed: UInt64(100 + i * 10 + j))
                print(String(format: "SIMULATION environments %@, sibling %@ (%d trials): sibling auto-labelled as P today %.4f groups %.4f, asked today %.4f groups %.4f; P in environment 1 auto today %.4f groups %.4f; P in the last environment auto today %.4f groups %.4f",
                             name, setting.rawValue, trials,
                             r.sibling[false]!.autoRate, r.sibling[true]!.autoRate,
                             r.sibling[false]!.askRate, r.sibling[true]!.askRate,
                             r.person[false]!.autoRate, r.person[true]!.autoRate,
                             r.personLast[false]!.autoRate, r.personLast[true]!.autoRate))
                #expect(r.sibling[false]!.trials == trials && r.sibling[true]!.trials == trials)
                if setting == .named {
                    // The symmetric runner-up: a named sibling's own score stops P's one-sample groups too.
                    #expect(r.sibling[true]!.autoRate <= r.sibling[false]!.autoRate + 0.01)
                }
                // Loose bounds (the full table: at most 3.4% for an unnamed sibling, 0% named, 99.3–100% for P).
                #expect(r.sibling[true]!.autoRate <= 0.06, "\(name), \(setting.rawValue): sibling auto with groups")
                #expect(r.sibling[false]!.autoRate <= 0.06, "\(name), \(setting.rawValue): sibling auto without groups")
                #expect(r.person[true]!.autoRate >= 0.95, "\(name), \(setting.rawValue): P auto with groups")
                #expect(r.person[false]!.autoRate >= 0.95, "\(name), \(setting.rawValue): P auto without groups")
            }
        }
    }
}
