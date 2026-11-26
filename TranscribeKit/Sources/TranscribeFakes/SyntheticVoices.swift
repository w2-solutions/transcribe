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

    /// Variant directions 56..<64 are reserved as "setting" axes (a room, a car, a phone line) for `mix`.
    public static let settingAxes = 56..<64

    /// A voice made of several people and an optional shared setting:
    /// `Σ w·base(p) + sw·variants[axis] + √(1 − Σw²)·variants[variant]`, where Σw² counts the setting weight too.
    /// Bases and variants are orthonormal, so the cosine of two mixes is the sum of the products of their shared
    /// weights (people and setting); distinct residual variants contribute nothing.
    ///
    /// Variants in use (keep each test's residual unique): 1–7, 11, 12, 20–25 (seeds, scripts and sync scenarios),
    /// 8–10, 13–19 (the `voiceGroups` seed: Tom's ten samples), 26, 27 (its Tom speakers), 30–43, 44–49 (stage-2
    /// tests; 30–47 also the group label tests), 50–55; 56–63 are setting axes (57–59 Tom's three settings).
    public static func mix(_ people: [(SyntheticPerson, Float)], setting: (axis: Int, weight: Float)? = nil,
                           variant: Int) -> VoiceVector {
        precondition((0..<settingAxes.lowerBound).contains(variant), "variant must be below the setting axes")
        if let setting { precondition(settingAxes.contains(setting.axis), "setting axis must be in 56..<64") }
        let weights = people.map { Double($0.1) } + [setting.map { Double($0.weight) } ?? 0]
        let sumSquares = weights.map { $0 * $0 }.reduce(0, +)
        precondition(sumSquares <= 1 + 1e-9, "weights must satisfy Σw² ≤ 1")
        var raw = [Double](repeating: 0, count: dimension)
        for (person, w) in people {
            let b = bases[person.rawValue]
            for i in raw.indices { raw[i] += Double(w) * b[i] }
        }
        if let setting {
            let o = variants[setting.axis]
            for i in raw.indices { raw[i] += Double(setting.weight) * o[i] }
        }
        let residual = Swift.max(0, 1 - sumSquares).squareRoot()
        let r = variants[variant]
        for i in raw.indices { raw[i] += residual * r[i] }
        return VoiceVector(raw: raw.map(Float.init))!
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
