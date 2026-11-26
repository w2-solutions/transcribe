import Foundation

public struct SampleGroupPolicy: Sendable, Equatable {
    /// UNTESTED starting value: two clusters join while their average pairwise cosine is at least this. A group
    /// label also stays on a group whose members average at least this to the label's saved samples
    /// (`GroupLabelResolver`). Tune from real close, far and speakerphone samples.
    public var joinCosine: Float = 0.65
    public init() {}
    public static let `default` = SampleGroupPolicy()
}

/// Groups one person's voice samples by how they sound, separately for each capture channel.
///
/// Membership is derived: it is recomputed from the samples every time and never stored or synced, so it never
/// changes matching. Only the screen and the group labels (`GroupLabelResolver`) use it.
///
/// Average-linkage agglomerative clustering at `SampleGroupPolicy.joinCosine`, per channel:
/// 1. Items whose vector is not of `dimension` are dropped (a synced sample's placeholder vector, for one).
/// 2. Within a channel, items are put in canonical order (`id.uuidString`); every later step works on that order.
/// 3. Each item starts as its own cluster. Repeatedly, the pair of clusters with the highest quantised average
///    linkage (`q` of the mean cosine over every cross pair) joins while it is at least `q(joinCosine)`; ties go to the
///    pair with the lowest (smallest index of the first, smallest index of the second).
/// 4. A group's key is its oldest member, by (`addedAtMillis`, `id.uuidString`); its members are listed oldest
///    first; its centroid is the normalised mean of its members in canonical order; its representatives are the
///    members by `q(cosine to the centroid)`, highest first, then by `id.uuidString`.
/// 5. Groups are ordered by channel string, then by the key's age (`addedAtMillis`, then `key.uuidString`).
///
/// The result does not depend on the order of `items`: every sum of cosines is taken over its terms sorted
/// ascending, every comparison uses integer-quantised scores (`q`) with id tie-breaks, and every vector sum runs in
/// canonical order. So two devices holding the same synced samples show the same groups. `VoiceVector.cosine` must
/// stay a fixed-order scalar loop; moving it to vDSP or simd would make results depend on the build.
///
/// Item ids are expected to be unique (they are sample ids).
public enum SampleGrouping {
    public struct Item: Sendable, Equatable {
        public let id: UUID
        public let vector: VoiceVector
        /// Resolved by the caller: the sample's capture channel, or this device's when it has none.
        public let channel: String
        /// Milliseconds since 1970, as synced, so every device agrees on the age order.
        public let addedAtMillis: Int64
        public init(id: UUID, vector: VoiceVector, channel: String, addedAtMillis: Int64) {
            self.id = id; self.vector = vector; self.channel = channel; self.addedAtMillis = addedAtMillis
        }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        /// The oldest member, by (`addedAtMillis`, `id.uuidString`).
        public let key: UUID
        public let channel: String
        /// Oldest first, by (`addedAtMillis`, `id.uuidString`); the key is first.
        public let memberIDs: [UUID]
        /// The normalised mean of the members, summed in canonical order.
        public let centroid: VoiceVector
        /// Members by `q(cosine to the centroid)`, highest first, then by `id.uuidString`. The first is the most
        /// typical sample of the group.
        public let representativeIDs: [UUID]
        public var id: UUID { key }
        public init(key: UUID, channel: String, memberIDs: [UUID], centroid: VoiceVector, representativeIDs: [UUID]) {
            self.key = key; self.channel = channel; self.memberIDs = memberIDs
            self.centroid = centroid; self.representativeIDs = representativeIDs
        }
    }

    /// The groups of `items`, ordered by channel string, then by the age of their key.
    public static func group(_ items: [Item], dimension: Int, policy: SampleGroupPolicy = .default) -> [Group] {
        let usable = items.filter { $0.vector.dimension == dimension }
        let channels = Dictionary(grouping: usable, by: \.channel)
        return channels.keys.sorted().flatMap { group(channel: $0, channels[$0]!, policy: policy) }
    }

    /// Integer quantisation used for every comparison: `Int((x * 10_000).rounded())`.
    ///
    /// Integer scores make every ordering a strict total order (with id tie-breaks); a comparison within an epsilon
    /// is not transitive.
    public static func q(_ x: Double) -> Int { Int((x * 10_000).rounded()) }

    /// The mean cosine over every pair of `a` × `b`, each term as Double, summed in ascending order so the result
    /// does not depend on the order of either list. Nil when either list is empty or any dimension differs.
    public static func averageLinkage(_ a: [VoiceVector], _ b: [VoiceVector]) -> Double? {
        guard let d = a.first?.dimension, !b.isEmpty,
              a.allSatisfy({ $0.dimension == d }), b.allSatisfy({ $0.dimension == d }) else { return nil }
        var terms: [Double] = []
        terms.reserveCapacity(a.count * b.count)
        for x in a { for y in b { terms.append(Double(x.cosine(y))) } }
        return terms.sorted().reduce(0, +) / Double(terms.count)
    }

    // MARK: - One channel

    /// One channel's groups, oldest key first.
    private static func group(channel: String, _ items: [Item], policy: SampleGroupPolicy) -> [Group] {
        let canonical = items.sorted { $0.id.uuidString < $1.id.uuidString }
        let n = canonical.count
        var cosines = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in i..<n {
                let c = Double(canonical[i].vector.cosine(canonical[j].vector))
                cosines[i][j] = c; cosines[j][i] = c
            }
        }

        // Each cluster holds canonical indexes in ascending order; clusters stay ordered by their smallest index.
        var clusters: [[Int]] = (0..<n).map { [$0] }
        let joinScore = q(Double(policy.joinCosine))
        while clusters.count > 1 {
            var best: (score: Int, a: Int, b: Int)?
            for a in 0..<clusters.count {
                for b in (a + 1)..<clusters.count {
                    let score = q(linkage(clusters[a], clusters[b], cosines))
                    // Pairs are visited in (min index of A, min index of B) order, so only a higher score replaces.
                    if best == nil || score > best!.score { best = (score, a, b) }
                }
            }
            guard let join = best, join.score >= joinScore else { break }
            clusters[join.a] = (clusters[join.a] + clusters[join.b]).sorted()
            clusters.remove(at: join.b)
        }

        let byAge = clusters.map { cluster in
            cluster.map { canonical[$0] }.sorted { isOlder($0.id, $0.addedAtMillis, than: $1.id, $1.addedAtMillis) }
        }.sorted { isOlder($0[0].id, $0[0].addedAtMillis, than: $1[0].id, $1[0].addedAtMillis) }

        return byAge.map { members in
            let inCanonicalOrder = members.sorted { $0.id.uuidString < $1.id.uuidString }
            // The fallback is unreachable at the default policy: joined members have a positive mean, so their sum
            // is never zero.
            let centroid = VoiceVector.weightedMean(inCanonicalOrder.map { ($0.vector, 1) }) ?? inCanonicalOrder[0].vector
            let representatives = members
                .map { (id: $0.id, score: q(Double($0.vector.cosine(centroid)))) }
                .sorted { a, b in a.score != b.score ? a.score > b.score : a.id.uuidString < b.id.uuidString }
                .map(\.id)
            return Group(key: members[0].id, channel: channel, memberIDs: members.map(\.id), centroid: centroid,
                         representativeIDs: representatives)
        }
    }

    /// Mean of the cross cosines, terms sorted ascending before summing.
    private static func linkage(_ a: [Int], _ b: [Int], _ cosines: [[Double]]) -> Double {
        var terms: [Double] = []
        terms.reserveCapacity(a.count * b.count)
        for i in a { for j in b { terms.append(cosines[i][j]) } }
        return terms.sorted().reduce(0, +) / Double(terms.count)
    }

    private static func isOlder(_ a: UUID, _ aMillis: Int64, than b: UUID, _ bMillis: Int64) -> Bool {
        aMillis != bMillis ? aMillis < bMillis : a.uuidString < b.uuidString
    }
}
