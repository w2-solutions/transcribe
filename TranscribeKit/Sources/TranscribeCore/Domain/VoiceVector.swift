import Foundation

public struct EmbeddingModelID: Sendable, Hashable, Codable {
    public let name: String
    public let revision: String
    public let dimension: Int
    public init(name: String, revision: String, dimension: Int) {
        self.name = name; self.revision = revision; self.dimension = dimension
    }
    /// Persisted string; profiles/samples whose key differs from the engine's are invisible to matching.
    public var key: String { "\(name)@\(revision)#\(dimension)" }
    public static let communityOneResNet34 = EmbeddingModelID(
        name: "pyannote-community-1/wespeaker-resnet34",
        revision: "speaker-diarization-coreml@df2625ac;FluidAudio-0.18.4", dimension: 256)
    public static let fake = EmbeddingModelID(name: "fake-synthetic", revision: "1", dimension: 256)
}

/// Always L2-normalised and finite.
public struct VoiceVector: Sendable, Hashable {
    public let values: [Float]

    public init?(raw: [Float], expectedDimension: Int? = nil) {
        if let d = expectedDimension, raw.count != d { return nil }
        guard !raw.isEmpty, raw.allSatisfy({ $0.isFinite }) else { return nil }
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm >= 1e-6 else { return nil }
        values = raw.map { $0 / norm }
    }

    public var dimension: Int { values.count }

    public func cosine(_ other: VoiceVector) -> Float {
        precondition(dimension == other.dimension, "dimension mismatch")
        var dot: Float = 0
        for i in values.indices { dot += values[i] * other.values[i] }
        return Swift.min(1, Swift.max(-1, dot))
    }

    /// Little-endian Float32, explicit byte order.
    public var packed: Data {
        var data = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    public init?(packed data: Data, expectedDimension: Int? = nil) {
        guard data.count % 4 == 0, !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        var raw: [Float] = []
        raw.reserveCapacity(bytes.count / 4)
        var i = 0
        while i < bytes.count {
            let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            raw.append(Float(bitPattern: bits)); i += 4
        }
        self.init(raw: raw, expectedDimension: expectedDimension)
    }

    /// Values already normalised; used only to read back `packed(_:)` bytes bit for bit.
    private init(normalised values: [Float]) { self.values = values }

    /// Several vectors back to back, each as `packed`, in the given order (a group label's anchor).
    public static func packed(_ vectors: [VoiceVector]) -> Data {
        var data = Data(capacity: vectors.reduce(0) { $0 + $1.dimension * 4 })
        for v in vectors { data.append(v.packed) }
        return data
    }

    /// Reads `packed(_:)` bytes back as vectors of `dimension`.
    ///
    /// Each vector keeps the exact values it was packed with, so it is bit-for-bit equal to the vector that was
    /// packed (same `packed` bytes). `init(packed:)` cannot promise that: it normalises again, and normalising a unit
    /// vector a second time changes the last bit of some values. Empty when the bytes are empty, `dimension` is not
    /// positive, the bytes do not divide into whole vectors, or any vector is not finite with unit length (within 1e-4).
    public static func unpacked(_ data: Data, dimension: Int) -> [VoiceVector] {
        guard dimension > 0, !data.isEmpty, data.count % (dimension * 4) == 0 else { return [] }
        let bytes = [UInt8](data)
        var result: [VoiceVector] = []
        result.reserveCapacity(bytes.count / (dimension * 4))
        var i = 0
        while i < bytes.count {
            var values: [Float] = []
            values.reserveCapacity(dimension)
            for _ in 0..<dimension {
                let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                values.append(Float(bitPattern: bits)); i += 4
            }
            guard values.allSatisfy({ $0.isFinite }) else { return [] }
            let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            guard abs(norm - 1) <= 1e-4 else { return [] }
            result.append(VoiceVector(normalised: values))
        }
        return result
    }

    /// Duration-weighted mean, re-normalised. Nil if empty or dimensions differ.
    public static func weightedMean(_ items: [(vector: VoiceVector, weight: Double)]) -> VoiceVector? {
        guard let d = items.first?.vector.dimension, items.allSatisfy({ $0.vector.dimension == d }) else { return nil }
        var acc = [Float](repeating: 0, count: d)
        for (v, w) in items { for i in 0..<d { acc[i] += v.values[i] * Float(w) } }
        return VoiceVector(raw: acc)
    }

    /// A speaker vector that resists spans of another voice (§1.11).
    ///
    /// Finds the weighted medoid (the item with the highest weighted cosine sum to all items, itself included;
    /// ties to the lowest index), drops items under `dropBelow` cosine to it as long as at least `minKeptFraction`
    /// of the total weight remains (otherwise keeps all), and returns the weighted mean of what is left with its
    /// coherence: the weighted mean cosine of the used items to that vector. Nil if empty, the dimensions differ,
    /// or the weighted mean is degenerate. Weights are expected to be positive.
    public static func robustMean(_ items: [(vector: VoiceVector, weight: Double)], dropBelow: Float,
                                  minKeptFraction: Double) -> (vector: VoiceVector, coherence: Float)? {
        guard let d = items.first?.vector.dimension, items.allSatisfy({ $0.vector.dimension == d }) else { return nil }
        if items.count == 1 { return (items[0].vector, 1) }

        // Weighted medoid. Terms are summed in sorted order so the choice does not depend on the input order.
        var medoid = 0
        var bestSupport = -Double.infinity
        for (i, a) in items.enumerated() {
            let support = items.map { b in b.weight * Double(a.vector.cosine(b.vector)) }.sorted().reduce(0, +)
            if support > bestSupport { bestSupport = support; medoid = i }
        }

        let centre = items[medoid].vector
        let kept = items.filter { atLeast($0.vector.cosine(centre), dropBelow) }
        let total = items.map(\.weight).sorted().reduce(0, +)
        let keptWeight = kept.map(\.weight).sorted().reduce(0, +)
        let used = keptWeight >= minKeptFraction * total - 1e-9 ? kept : items

        guard let vector = weightedMean(used) else { return nil }
        let usedWeight = used.map(\.weight).sorted().reduce(0, +)
        guard usedWeight > 0 else { return nil }
        let agreement = used.map { $0.weight * Double($0.vector.cosine(vector)) }.sorted().reduce(0, +)
        return (vector, Float(agreement / usedWeight))
    }
}
