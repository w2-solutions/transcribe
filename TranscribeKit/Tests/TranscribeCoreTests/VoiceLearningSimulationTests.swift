import Foundation
import Testing
@testable import TranscribeCore

/// Small end-to-end stories on synthetic vectors. The numbers were checked by hand.
@Suite("Voice learning simulations")
struct VoiceLearningSimulationTests {

    private func liam(_ samples: [VoiceVector], negatives: [VoiceVector] = []) -> ProfileCandidate {
        ProfileCandidate(id: TV.liamID, name: "Liam", samples: samples, trusted: samples.map { _ in true },
                         negatives: negatives, modelKey: TV.modelKey, autoLabel: true, needsResample: false)
    }

    private func run(_ v: VoiceVector, _ profile: ProfileCandidate) throws -> (MatchDecision, MatchTrace) {
        let probe = SpeakerProbe(key: "S1", vector: v, cleanSeconds: 12, rejectedProfileIDs: [])
        let r = VoiceMatcher.decideWithTrace(probes: [probe], profiles: [profile], modelKey: TV.modelKey)
        return (try #require(r.decisions["S1"]), try #require(r.traces["S1"]))
    }

    @Test func carSettingLearnsAndStrangerNeverAutoLabels() throws {
        // Desk sample, Liam in the car (cosine 0.36 to the desk, 0.6925 to each other) and strangers in the same
        // car (0.49 to Liam's car voice, 0.6925 to each other, 0 to the desk).
        let desk = TV.vector([0: 0.8, 10: 0.4], residual: 20)
        let car = (1...4).map { TV.vector([0: 0.45, 11: 0.7], residual: 20 + $0) }
        let stranger = (1...2).map { TV.vector([2: 0.45, 11: 0.7], residual: 30 + $0) }

        // 1. Only the desk sample: the car voice is not recognised.
        let d1 = try run(car[0], liam([desk])).0
        #expect(approx(try #require(d1.lowScoreBest), 0.36))

        // 2. One car sample (named by the user): the next car recording asks.
        let d2 = try run(car[1], liam([desk, car[0]])).0
        guard case .ask(_, let s2) = d2 else { Issue.record("expected ask, got \(d2)"); return }
        #expect(approx(s2, 0.52625))

        // 3. Two car samples (the ask was confirmed): the third auto-labels.
        let d3 = try run(car[2], liam([desk, car[0], car[1]])).0
        guard case .autoLabel(_, let s3, let m3) = d3 else { Issue.record("expected auto, got \(d3)"); return }
        #expect(approx(s3, 0.6925) && approx(m3, 0.6925))

        // 4. A stranger in the same car is never auto-labelled.
        let d4a = try run(stranger[0], liam([desk, car[0]])).0
        #expect(approx(try #require(d4a.lowScoreBest), 0.245))
        let d4b = try run(stranger[0], liam([desk, car[0], car[1]])).0
        guard case .ask(_, let s4) = d4b else { Issue.record("expected ask, got \(d4b)"); return }
        #expect(approx(s4, 0.49))

        // 5. The user says No: the stranger becomes a negative. The next stranger is blocked; Liam still auto-labels.
        let learned = liam([desk, car[0], car[1]], negatives: [stranger[0]])
        let (d5, t5) = try run(stranger[1], learned)
        #expect(approx(try #require(d5.lowScoreBest), 0.49))
        #expect(t5.kind == .unknown && t5.reason == "blocked")
        let (d6, t6) = try run(car[3], learned)
        guard case .autoLabel(_, let s6, _) = d6 else { Issue.record("expected auto, got \(d6)"); return }
        #expect(approx(s6, 0.6925))
        #expect(approx(try #require(t6.profiles.first?.negativeMax), 0.49))
    }

    @Test func siblingFalseAutoRateAtTheCap() {
        // The reviewer's noise model, not data: a sibling's cosine to each of 12 trusted samples is N(0.38, 0.07),
        // independently. Counts how often the pair score reaches the auto-label threshold.
        var rng = SplitMix64(seed: 1)
        let trials = 20_000
        var falseAutos = 0
        for _ in 0..<trials {
            let cosines = (0..<12).map { _ in 0.38 + 0.07 * TV.gaussian(&rng) }
            if let s = VoiceMatcher.pairScore(trusted: cosines, untrusted: [], topK: 2), s >= 0.55 { falseAutos += 1 }
        }
        let rate = Double(falseAutos) / Double(trials)
        #expect(rate <= 0.02, "false-auto rate \(rate)")   // about 0.014 expected
    }
}
