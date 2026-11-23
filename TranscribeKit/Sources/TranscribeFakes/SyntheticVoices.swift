import Foundation
import TranscribeCore

public enum SyntheticPerson: Int, Sendable, CaseIterable { case liam, karan, stranger }

public enum SyntheticVoices {
    public static let dimension = 256
    /// Variant directions are precomputed for 0..<maxVariants.
    public static let maxVariants = 64

    /// Orthonormal bases: SplitMix64(seed 0x5EED + person) uniform[-1,1] vectors, Gram–Schmidt in person order.
    public static func base(_ p: SyntheticPerson) -> VoiceVector {
        VoiceVector(raw: bases[p.rawValue].map(Float.init))!
    }

    /// c·base + √(1−c²)·o, where o = SplitMix64(0xA11CE + variant) vector Gram–Schmidt'd against ALL three bases
    /// and every lower-numbered variant direction (so variants are mutually orthogonal). Exact cosine to base = c,
    /// cosine to other bases = 0, cosine between two variants of the same person = c1·c2.
    public static func vector(near p: SyntheticPerson, cosine c: Float, variant: Int) -> VoiceVector {
        precondition((0..<maxVariants).contains(variant), "variant out of range")
        let cc = Double(Swift.max(-1, Swift.min(1, c)))
        let s = (1 - cc * cc).squareRoot()
        let b = bases[p.rawValue], o = variants[variant]
        let raw = (0..<dimension).map { Float(cc * b[$0] + s * o[$0]) }
        return VoiceVector(raw: raw)!
    }

    // MARK: - Construction (Double precision so cosines are exact to ~1e-7)

    private static let bases: [[Double]] = {
        var out: [[Double]] = []
        for p in SyntheticPerson.allCases {
            var v = randomVector(seed: 0x5EED + UInt64(p.rawValue))
            v = orthogonalise(v, against: out)
            out.append(normalise(v))
        }
        return out
    }()

    private static let variants: [[Double]] = {
        var out: [[Double]] = []
        for k in 0..<maxVariants {
            var v = randomVector(seed: 0xA11CE + UInt64(k))
            v = orthogonalise(v, against: bases + out)
            out.append(normalise(v))
        }
        return out
    }()

    private static func randomVector(seed: UInt64) -> [Double] {
        var rng = SplitMix64(seed: seed)
        return (0..<dimension).map { _ in rng.nextUnit() * 2 - 1 }
    }

    private static func orthogonalise(_ v: [Double], against basis: [[Double]]) -> [Double] {
        var r = v
        for _ in 0..<2 {   // twice for numerical stability
            for u in basis {
                let d = dot(r, u)
                for i in r.indices { r[i] -= d * u[i] }
            }
        }
        return r
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }

    private static func normalise(_ v: [Double]) -> [Double] {
        let n = dot(v, v).squareRoot()
        return v.map { $0 / n }
    }
}

/// Deterministic SplitMix64.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
