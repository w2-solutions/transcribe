import Foundation
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
