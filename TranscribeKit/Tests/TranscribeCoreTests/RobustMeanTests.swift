import Foundation
import Testing
@testable import TranscribeCore

@Suite("VoiceVector.robustMean")
struct RobustMeanTests {
    let policy = MatchPolicy.default

    private func robust(_ items: [(vector: VoiceVector, weight: Double)]) -> (vector: VoiceVector, coherence: Float)? {
        VoiceVector.robustMean(items, dropBelow: policy.spanDropBelow, minKeptFraction: policy.spanMinKeptFraction)
    }

    /// Three spans of A (pairwise cosine 0.64) and two of B, all weight 2: B is 40% of the speech and is dropped.
    private var mixed: [(vector: VoiceVector, weight: Double)] {
        (0..<3).map { (TV.vector([0: 0.8], residual: 40 + $0), 2.0) }
            + (0..<2).map { (TV.vector([1: 0.8], residual: 50 + $0), 2.0) }
    }

    @Test func dropsMinoritySpeakerSpans() throws {
        let r = try #require(robust(mixed))
        // Mean of the A spans: 4.8 on axis 0 and 1.2 on each residual, norm √27.36.
        #expect(approx(r.vector.cosine(TV.axis(0)), Float(4.8 / 27.36.squareRoot())))     // 0.9177
        #expect(approx(r.vector.cosine(TV.axis(0)), 0.9177))
        #expect(r.vector.cosine(TV.axis(1)) == 0)
        #expect(approx(r.coherence, Float(4.56 / 27.36.squareRoot())))                    // 0.8718
        #expect(approx(r.coherence, 0.8718))
    }

    @Test func keepsAllWhenDropWouldLeaveUnderHalf() throws {
        let items: [(vector: VoiceVector, weight: Double)] = [(TV.axis(0), 2), (TV.axis(1), 1), (TV.axis(2), 1), (TV.axis(3), 1)]
        let r = try #require(robust(items))
        #expect(approx(r.coherence, Float(7.0.squareRoot() / 5)))   // 0.5292
        for axis in 0..<4 { #expect(r.vector.cosine(TV.axis(axis)) > 0, "axis \(axis)") }
    }

    @Test func orthogonalSpansKeepAll() throws {
        let r = try #require(robust((0..<5).map { (TV.axis($0), 1.0) }))
        #expect(approx(r.coherence, 1 / Float(5).squareRoot()))     // 0.4472
        #expect(approx(r.coherence, 0.4472))
    }

    @Test func singleSpanIsItself() throws {
        let v = TV.vector([0: 0.6, 1: 0.3], residual: 40)
        let r = try #require(robust([(v, 3)]))
        #expect(r.vector == v && r.coherence == 1)
    }

    @Test func emptyOrMixedDimensionsIsNil() throws {
        #expect(robust([]) == nil)
        let odd = try #require(VoiceVector(raw: [1, 0, 0]))
        #expect(robust([(TV.axis(0), 1), (odd, 1)]) == nil)
    }

    @Test func independentOfOrderWithoutTies() throws {
        let baseline = try #require(robust(mixed))
        var rng = SplitMix64(seed: 42)
        for _ in 0..<100 {
            let r = try #require(robust(mixed.shuffled(using: &rng)))
            #expect(zip(r.vector.values, baseline.vector.values).allSatisfy { abs($0 - $1) <= 1e-6 })
            #expect(abs(r.coherence - baseline.coherence) <= 1e-6)
        }
    }
}
