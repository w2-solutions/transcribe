import Foundation
import Testing
@testable import TranscribeCore

/// Test vectors with chosen pairwise cosines, for the grouping and label suites.
///
/// `vectors` takes the Gram matrix (the cosine of every pair) and returns unit vectors with exactly those cosines,
/// up to Float rounding (about 1e-7), from its Cholesky factor. The matrix must be positive semi-definite.
enum GV {
    static let dimension = 64

    static func vectors(_ count: Int, dimension: Int = GV.dimension,
                        cosine: (Int, Int) -> Double) -> [VoiceVector] {
        precondition(count <= dimension, "too many vectors for the dimension")
        var l = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        for i in 0..<count {
            for j in 0...i {
                let g = i == j ? 1 : cosine(Swift.min(i, j), Swift.max(i, j))
                var sum = g
                for k in 0..<j { sum -= l[i][k] * l[j][k] }
                if i == j {
                    precondition(sum > -1e-12, "not a valid set of cosines at \(i)")
                    l[i][i] = Swift.max(0, sum).squareRoot()
                } else {
                    l[i][j] = l[j][j] > 1e-12 ? sum / l[j][j] : 0
                }
            }
        }
        return l.map { row in
            VoiceVector(raw: row.map(Float.init) + [Float](repeating: 0, count: dimension - count))!
        }
    }

    /// Vectors in blocks: `within[b]` inside block b, `across` between blocks. `blocks[i]` is item i's block.
    static func blocks(_ blocks: [Int], within: [Double], across: Double) -> [VoiceVector] {
        vectors(blocks.count) { i, j in blocks[i] == blocks[j] ? within[blocks[i]] : across }
    }

    /// One shared factor: item i is `a[i]·u + √(1 − a[i]²)·eᵢ`, so the cosine of i and j is `a[i]·a[j]`.
    static func oneFactor(_ a: [Double]) -> [VoiceVector] {
        vectors(a.count) { i, j in a[i] * a[j] }
    }

    static func item(_ n: Int, _ vector: VoiceVector, channel: String = "iphone", millis: Int64? = nil) -> SampleGrouping.Item {
        SampleGrouping.Item(id: TV.uuid(n), vector: vector, channel: channel, addedAtMillis: millis ?? Int64(1_000 * n))
    }

    static func items(_ vectors: [VoiceVector], channel: String = "iphone", first: Int = 0) -> [SampleGrouping.Item] {
        vectors.enumerated().map { item(first + $0.offset, $0.element, channel: channel) }
    }

    static func members(_ groups: [SampleGrouping.Group]) -> [[UUID]] { groups.map(\.memberIDs) }
    static func ids(_ ns: [Int]) -> [UUID] { ns.map(TV.uuid) }
}

@Suite("SampleGrouping")
struct SampleGroupingTests {
    private func group(_ items: [SampleGrouping.Item], policy: SampleGroupPolicy = .default) -> [SampleGrouping.Group] {
        SampleGrouping.group(items, dimension: GV.dimension, policy: policy)
    }

    /// The `voiceGroups` seed's shape: Close {0, 1, 5}, Far {2, 3, 4}, Speaker {6, 7}; 0.85 within a setting, 0.36
    /// across.
    static let seedBlocks = [0, 0, 1, 1, 1, 0, 2, 2]
    static var seedLike: [SampleGrouping.Item] {
        GV.items(GV.blocks(seedBlocks, within: [0.85, 0.85, 0.85], across: 0.36))
    }

    @Test func emptyGivesNoGroups() {
        #expect(group([]).isEmpty)
    }

    @Test func oneSampleIsOneGroup() throws {
        let v = GV.vectors(1) { _, _ in 0 }[0]
        let groups = group([GV.item(0, v)])
        let g = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(g.key == TV.uuid(0) && g.memberIDs == [TV.uuid(0)] && g.representativeIDs == [TV.uuid(0)])
        #expect(g.channel == "iphone")
        #expect(g.centroid.packed == v.packed)
    }

    @Test func threeSettingsMakeThreeGroups() {
        let groups = group(Self.seedLike)
        #expect(GV.members(groups) == [GV.ids([0, 1, 5]), GV.ids([2, 3, 4]), GV.ids([6, 7])])
        #expect(groups.map(\.key) == GV.ids([0, 2, 6]))
    }

    @Test func inputOrderNeverChangesGroups() {
        // Ten items in three settings with uneven cosines (0.67 to 0.77 within a setting, 0.30 to 0.35 across), random
        // ids not in age order, two channels.
        let blocks = [0, 1, 0, 2, 1, 0, 2, 1, 0, 1]
        let a = (0..<10).map { 0.82 + 0.006 * Double($0) }
        let vectors = GV.vectors(10) { i, j in a[i] * a[j] * (blocks[i] == blocks[j] ? 1 : 0.45) }
        let items = vectors.enumerated().map { n, v in
            SampleGrouping.Item(id: UUID(), vector: v, channel: n == 9 ? "ipad" : "iphone",
                                addedAtMillis: Int64(1_790_000_000_000 + (n * 7_919) % 13 * 1_000))
        }
        let baseline = group(items)
        #expect(baseline.count == 4)
        var rng = SplitMix64(seed: 7)
        for _ in 0..<50 {
            let shuffled = group(items.shuffled(using: &rng))
            #expect(shuffled.map(\.key) == baseline.map(\.key))
            #expect(shuffled.map(\.memberIDs) == baseline.map(\.memberIDs))
            #expect(shuffled.map(\.representativeIDs) == baseline.map(\.representativeIDs))
            #expect(shuffled.map(\.centroid.packed) == baseline.map(\.centroid.packed))
            #expect(shuffled.map(\.channel) == baseline.map(\.channel))
        }
    }

    @Test func averageLinkageDoesNotChain() {
        // A–B 0.7, B–C 0.7, A–C 0.2: single linkage would chain all three.
        let v = GV.vectors(3) { i, j in (i, j) == (0, 2) ? 0.2 : 0.7 }
        let groups = group(GV.items(v))
        #expect(GV.members(groups) == [GV.ids([0, 1]), GV.ids([2])])
    }

    @Test("Threshold is inclusive at the quantised value", arguments: [(0.65, true), (0.6499, false), (0.6501, true)])
    func thresholdIsInclusiveAtQuantisedValue(cosine: Double, joins: Bool) {
        let v = GV.vectors(2) { _, _ in cosine }
        #expect(group(GV.items(v)).count == (joins ? 1 : 2))
    }

    @Test func nearDuplicatesShareAGroup() {
        // 0 and 1 are near-duplicates (0.97); 2 is close to neither on its own average.
        let v = GV.vectors(3) { i, j in (i, j) == (0, 1) ? 0.97 : 0.40 }
        let groups = group(GV.items(v))
        #expect(GV.members(groups) == [GV.ids([0, 1]), GV.ids([2])])
        // Identical vectors also share a group.
        let same = GV.vectors(1) { _, _ in 0 }[0]
        #expect(group([GV.item(0, same), GV.item(1, same)]).count == 1)
    }

    @Test func channelsNeverMix() {
        let v = GV.vectors(1) { _, _ in 0 }[0]
        let groups = group([GV.item(0, v, channel: "iphone"), GV.item(1, v, channel: "ipad")])
        #expect(groups.map(\.channel) == ["ipad", "iphone"])
        #expect(GV.members(groups) == [GV.ids([1]), GV.ids([0])])
    }

    @Test func wrongDimensionIsDropped() throws {
        let v = GV.vectors(1) { _, _ in 0 }[0]
        let placeholder = try #require(VoiceVector(raw: [1]))
        let groups = group([GV.item(0, v), GV.item(1, placeholder)])
        #expect(GV.members(groups) == [GV.ids([0])])
    }

    @Test func keyIsOldestMemberAtMillisecondPrecision() {
        let v = GV.vectors(3) { _, _ in 0.9 }
        // Item 2 is the oldest by one millisecond.
        let items = [GV.item(0, v[0], millis: 5_001), GV.item(1, v[1], millis: 5_002), GV.item(2, v[2], millis: 5_000)]
        let groups = group(items)
        #expect(groups.map(\.key) == [TV.uuid(2)])
        #expect(groups.first?.memberIDs == GV.ids([2, 0, 1]))
    }

    @Test func tiesBreakByID() {
        let v = GV.vectors(3) { _, _ in 0.9 }
        // Same millisecond: the smaller uuidString is older.
        let items = [GV.item(2, v[2], millis: 7), GV.item(1, v[1], millis: 7), GV.item(0, v[0], millis: 9)]
        let groups = group(items)
        #expect(groups.first?.key == TV.uuid(1))
        #expect(groups.first?.memberIDs == GV.ids([1, 2, 0]))

        // Equal linkage scores join the pair with the lowest indexes first: 0–1, 0–2 and 1–2 are all 0.7, so 0 and
        // 1 join; then {0, 1} with 2 averages 0.7 and joins too.
        let tied = GV.vectors(3) { _, _ in 0.7 }
        #expect(GV.members(group(GV.items(tied))) == [GV.ids([0, 1, 2])])
        // With 2 at 0.6 to both, {0, 1} stays apart from 2 whichever order the items come in.
        let apart = GV.vectors(3) { i, j in j == 2 ? 0.6 : 0.7 }
        #expect(GV.members(group(GV.items(apart).reversed())) == [GV.ids([0, 1]), GV.ids([2])])
    }

    @Test func groupsOrderByChannelThenAge() {
        let v = GV.blocks([0, 1, 0, 1], within: [0.9, 0.9], across: 0.1)
        // On iphone, the {1, 3} group holds the oldest sample (3), so it comes first.
        let items = [GV.item(0, v[0], channel: "iphone", millis: 300), GV.item(1, v[1], channel: "iphone", millis: 400),
                     GV.item(2, v[2], channel: "iphone", millis: 500), GV.item(3, v[3], channel: "iphone", millis: 100),
                     GV.item(4, v[0], channel: "mac", millis: 0), GV.item(5, v[0], channel: "ipad", millis: 900)]
        let groups = group(items)
        #expect(groups.map(\.channel) == ["ipad", "iphone", "iphone", "mac"])
        #expect(groups.map(\.key) == GV.ids([5, 3, 0, 4]))
    }

    @Test func representativesStartWithMostCentral() throws {
        // Item 1 is closest to the others (0.9 each); 0 and 2 are 0.75 apart.
        let v = GV.vectors(3) { i, j in (i, j) == (0, 2) ? 0.75 : 0.9 }
        let g = try #require(group(GV.items(v)).first)
        #expect(g.representativeIDs.first == TV.uuid(1))
        #expect(g.representativeIDs == GV.ids([1, 0, 2]))   // 0 and 2 tie and are ordered by id
        let centroid = try #require(VoiceVector.weightedMean(v.map { ($0, 1.0) }))
        #expect(g.centroid.packed == centroid.packed)
    }

    @Test func policyMovesTheJoinLine() {
        var strict = SampleGroupPolicy()
        strict.joinCosine = 0.9
        #expect(group(Self.seedLike, policy: strict).count == 8)
        #expect(SampleGroupPolicy.default.joinCosine == 0.65)
    }

    @Test func quantisationRoundsToFourPlaces() {
        #expect(SampleGrouping.q(0.65) == 6500)
        #expect(SampleGrouping.q(Double(Float(0.65))) == 6500)
        #expect(SampleGrouping.q(0.649_95) == 6500)
        #expect(SampleGrouping.q(0.649_94) == 6499)
        #expect(SampleGrouping.q(-0.25) == -2500)
    }

    @Test func averageLinkageIsTheMeanOfEveryPair() throws {
        let table: [[Double]] = [[1, 0.1, 0.2, 0.3], [0.1, 1, 0.4, 0.5], [0.2, 0.4, 1, 0.6], [0.3, 0.5, 0.6, 1]]
        let v = GV.vectors(4) { i, j in table[i][j] }
        let mean = try #require(SampleGrouping.averageLinkage([v[0], v[1]], [v[2], v[3]]))
        let expected = (Double(v[0].cosine(v[2])) + Double(v[0].cosine(v[3])) + Double(v[1].cosine(v[2]))
                        + Double(v[1].cosine(v[3]))) / 4
        #expect(abs(mean - expected) < 1e-12)
        #expect(SampleGrouping.averageLinkage([], [v[0]]) == nil)
        #expect(SampleGrouping.averageLinkage([v[0]], [try #require(VoiceVector(raw: [1]))]) == nil)
    }
}
