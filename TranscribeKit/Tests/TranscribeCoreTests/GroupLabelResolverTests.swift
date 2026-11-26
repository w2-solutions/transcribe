import Foundation
import Testing
@testable import TranscribeCore

/// A label saved on `items` now: their vectors in canonical order, packed and read back as the store keeps them.
private func label(_ n: Int, on items: [SampleGrouping.Item], channel: String = "iphone",
                   edited: Int64 = 0) -> GroupLabelAnchor {
    let vectors = items.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.vector)
    let stored = VoiceVector.unpacked(VoiceVector.packed(vectors), dimension: GV.dimension)
    return GroupLabelAnchor(id: labelID(n), channel: channel, vectors: stored, editedAtMillis: edited)
}

private func labelID(_ n: Int) -> UUID { TV.uuid(0x1000 + n) }

private struct Resolved {
    let groups: [SampleGrouping.Group]
    let placement: LabelPlacement

    /// The group holding sample `n`.
    func group(holding n: Int) -> SampleGrouping.Group? { groups.first { $0.memberIDs.contains(TV.uuid(n)) } }
    /// The label shown on the group holding sample `n`.
    func shown(on n: Int) -> UUID? { group(holding: n).flatMap { placement.placed[$0.key] } }
    func contenders(on n: Int) -> [UUID] { group(holding: n).flatMap { placement.contenders[$0.key] } ?? [] }
}

private func resolve(_ items: [SampleGrouping.Item], _ labels: [GroupLabelAnchor]) -> Resolved {
    let groups = SampleGrouping.group(items, dimension: GV.dimension)
    let vectors = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.vector) })
    return Resolved(groups: groups, placement: GroupLabelResolver.resolve(groups: groups, memberVectors: vectors, labels: labels))
}

private func pick(_ items: [SampleGrouping.Item], _ ns: [Int]) -> [SampleGrouping.Item] {
    ns.map { n in items.first { $0.id == TV.uuid(n) }! }
}

@Suite("GroupLabelResolver")
struct GroupLabelResolverTests {
    /// A: 0–5 (0.70 within), B: 6–8 (0.70 within), 0.60 across: the two never join.
    static let conditions = GV.items(GV.blocks([0, 0, 0, 0, 0, 0, 1, 1, 1], within: [0.70, 0.70], across: 0.60))

    /// A: 0–2, B: 3–4 (0.70 within, 0.60 across); 5 is a bridge at 0.84 to all five, which joins them into one group.
    static let bridged = GV.items(GV.vectors(6) { i, j in
        let block = [0, 0, 0, 1, 1]
        return j == 5 ? 0.84 : (block[i] == block[j] ? 0.70 : 0.60)
    })

    @Test func labelFollowsGroupAsSamplesAreAdded() throws {
        let items = Self.conditions
        let l = label(0, on: pick(items, [0, 1, 2]))
        for count in 3...6 {
            let r = resolve(pick(items, Array(0..<count) + [6, 7, 8]), [l])
            #expect(r.group(holding: 0)?.memberIDs.count == count)
            #expect(r.shown(on: 0) == l.id, "with \(count) samples")
            #expect(r.shown(on: 6) == nil)
            #expect(r.placement.unplaced.isEmpty && r.placement.contenders.isEmpty)
        }
    }

    @Test func labelOnAGroupOfOneSurvivesTenSamplesJoining() throws {
        // Sample 0 at 0.80 on the shared factor; joiners at 0.775 to 0.865, so each is 0.62 to 0.69 from sample 0.
        let a = [0.80] + (0..<10).map { 0.775 + 0.01 * Double($0) }
        let items = GV.items(GV.oneFactor(a))
        let l = label(0, on: [items[0]])
        for count in 2...11 {
            let r = resolve(Array(items.prefix(count)), [l])
            #expect(r.shown(on: 0) == l.id, "with \(count) samples")
            #expect(r.placement.unplaced.isEmpty)
        }
        let r = resolve(items, [l])
        let grown = try #require(r.group(holding: 0))
        #expect(grown.memberIDs.count >= 8)
        // The premise: the label's one sample now sits far below 0.80 from the group's members on average, which
        // is where a centroid anchor would have lost it.
        let fit = try #require(GroupLabelResolver.fit(l, grown, memberVectors: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.vector) })))
        #expect(fit.present == 1 && fit.linkage < SampleGrouping.q(0.75))
    }

    @Test func labelOnATightPairSurvivesLooserJoiners() throws {
        // A label on {a, b} at 0.9; then c, d and e at 0.66 to everything.
        let items = GV.items(GV.vectors(5) { i, j in (i, j) == (0, 1) ? 0.9 : 0.66 })
        let l = label(0, on: pick(items, [0, 1]))
        let r = resolve(items, [l])
        #expect(GV.members(r.groups) == [GV.ids([0, 1, 2, 3, 4])])
        #expect(r.shown(on: 0) == l.id)
    }

    @Test func labelSurvivesEvictionOfEverySampleItWasMadeFrom() {
        let items = Self.conditions
        let l = label(0, on: pick(items, [0, 1, 2]))
        // 0, 1 and 2 are all gone; 3, 4 and 5 sound the same.
        let r = resolve(pick(items, [3, 4, 5, 6, 7, 8]), [l])
        #expect(r.shown(on: 3) == l.id)
        #expect(r.shown(on: 6) == nil)
    }

    @Test func labelNeverJumpsToANeighbourGroup() throws {
        let items = Self.conditions
        let l = label(0, on: pick(items, [0, 1, 2]))
        // Only the neighbouring condition is left, at 0.60 across.
        let r = resolve(pick(items, [6, 7, 8]), [l])
        #expect(r.placement.placed.isEmpty && r.placement.contenders.isEmpty)
        #expect(r.placement.unplaced == [l.id])
        let neighbour = try #require(r.groups.first)
        let fit = GroupLabelResolver.fit(l, neighbour, memberVectors: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.vector) }))
        #expect(fit == LabelFit(present: 0, linkage: 6000))
    }

    @Test func unplacedLabelReturnsWithSimilarSamples() {
        let items = Self.conditions
        let l = label(0, on: pick(items, [0, 1, 2]))
        #expect(resolve(pick(items, [6, 7, 8]), [l]).placement.unplaced == [l.id])
        let back = resolve(pick(items, [3, 4, 6, 7, 8]), [l])
        #expect(back.shown(on: 3) == l.id)
        #expect(back.placement.unplaced.isEmpty)
    }

    @Test func splitGivesTheLabelToThePartWithMoreLabelledSamples() throws {
        let items = Self.bridged
        let before = resolve(items, [])
        #expect(GV.members(before.groups) == [GV.ids([0, 1, 2, 3, 4, 5])])
        let l = label(0, on: items)
        // The bridge is evicted: {0, 1, 2} holds three labelled samples, {3, 4} two.
        let r = resolve(pick(items, [0, 1, 2, 3, 4]), [l])
        #expect(GV.members(r.groups) == [GV.ids([0, 1, 2]), GV.ids([3, 4])])
        #expect(r.shown(on: 0) == l.id)
        #expect(r.shown(on: 3) == nil)
        #expect(r.placement.contenders.isEmpty && r.placement.unplaced.isEmpty)
    }

    @Test func mergeShowsOneLabelAndKeepsTheOtherAsContender() {
        let items = Self.bridged
        let close = label(0, on: pick(items, [0, 1, 2]), edited: 10)
        let far = label(1, on: pick(items, [3, 4]), edited: 20)
        let apart = resolve(pick(items, [0, 1, 2, 3, 4]), [close, far])
        #expect(apart.shown(on: 0) == close.id && apart.shown(on: 3) == far.id)

        // The bridge joins them: "close" holds three samples of the group, "far" two, so "close" shows although
        // "far" was edited later.
        let merged = resolve(items, [close, far])
        #expect(merged.groups.count == 1)
        #expect(merged.shown(on: 0) == close.id)
        #expect(merged.contenders(on: 0) == [far.id])
        #expect(merged.placement.unplaced.isEmpty)

        // The bridge goes again: both come back.
        let split = resolve(pick(items, [0, 1, 2, 3, 4]), [close, far])
        #expect(split.placement == apart.placement)
    }

    @Test func labelWhoseBestGroupIsTakenIsAContenderNotMovedOn() throws {
        // Pairs {0, 1}, {2, 3}, {4, 5} at 0.75; {0, 1}–{2, 3} at 0.70 joins them; {2, 3}–{4, 5} at 0.66 and
        // {0, 1}–{4, 5} at 0.40 average 0.53, so {4, 5} stays apart.
        let pair = [0, 0, 1, 1, 2, 2]
        let items = GV.items(GV.vectors(6) { i, j in
            let (a, b) = (pair[i], pair[j])
            if a == b { return 0.75 }
            switch Set([a, b]) { case [0, 1]: return 0.70; case [1, 2]: return 0.66; default: return 0.40 }
        })
        let close = label(0, on: pick(items, [0, 1]), edited: 20)
        let far = label(1, on: pick(items, [2, 3]), edited: 10)
        let r = resolve(items, [close, far])
        #expect(GV.members(r.groups).map(Set.init) == [Set(GV.ids([0, 1, 2, 3])), Set(GV.ids([4, 5]))])
        // The premise: "far" is eligible for {4, 5} at 0.66, a group that never held its samples.
        let vectors = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.vector) })
        let other = try #require(r.group(holding: 4))
        let fit = try #require(GroupLabelResolver.fit(far, other, memberVectors: vectors))
        #expect(fit.present == 0 && fit.linkage >= SampleGrouping.q(0.65))

        #expect(r.shown(on: 0) == close.id)
        #expect(r.contenders(on: 0) == [far.id])
        #expect(r.shown(on: 4) == nil)
        #expect(r.placement.unplaced.isEmpty)
    }

    @Test func presentOutranksLinkage() throws {
        // Group {0, 1} at 0.7. "held" was saved on sample 0; "near" on vector 2, outside the group but 0.9 to both.
        let items = GV.items(GV.vectors(3) { i, j in j == 2 ? 0.9 : 0.7 })
        let held = label(0, on: [items[0]], edited: 1)
        let near = label(1, on: [items[2]], edited: 2)
        let r = resolve(pick(items, [0, 1]), [held, near])
        #expect(r.shown(on: 0) == held.id)
        #expect(r.contenders(on: 0) == [near.id])
        let group = try #require(r.group(holding: 0))
        let vectors = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.vector) })
        #expect(GroupLabelResolver.fit(held, group, memberVectors: vectors) == LabelFit(present: 1, linkage: 8500))
        #expect(GroupLabelResolver.fit(near, group, memberVectors: vectors) == LabelFit(present: 0, linkage: 9000))
    }

    @Test func presentNeedsBitForBitEquality() throws {
        // Normalising this vector again changes its last bits, although it is the same voice.
        var raw = [Float](repeating: 0, count: GV.dimension)
        raw[0] = 1; raw[1] = 1; raw[2] = 1
        let v = try #require(VoiceVector(raw: raw))
        let again = try #require(VoiceVector(raw: v.values))
        #expect(again.packed != v.packed)

        let item = GV.item(0, v)
        let groups = SampleGrouping.group([item], dimension: GV.dimension)
        let group = try #require(groups.first)
        let exact = label(0, on: [item])
        let renormalised = GroupLabelAnchor(id: labelID(1), channel: "iphone", vectors: [again], editedAtMillis: 0)
        #expect(GroupLabelResolver.fit(exact, group, memberVectors: [item.id: v]) == LabelFit(present: 1, linkage: 10_000))
        #expect(GroupLabelResolver.fit(renormalised, group, memberVectors: [item.id: v]) == LabelFit(present: 0, linkage: 10_000))
    }

    @Test func otherChannelLabelNeverApplies() throws {
        let items = GV.items(GV.vectors(3) { _, _ in 0.8 }, channel: "ipad")
        let l = label(0, on: items, channel: "iphone")
        let r = resolve(items, [l])
        #expect(r.placement.placed.isEmpty)
        #expect(r.placement.unplaced == [l.id])
        let group = try #require(r.groups.first)
        #expect(GroupLabelResolver.fit(l, group, memberVectors: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.vector) })) == nil)
    }

    @Test func unreadableOrOtherDimensionAnchorIsUnplaced() throws {
        let items = GV.items(GV.vectors(2) { _, _ in 0.8 })
        let empty = GroupLabelAnchor(id: labelID(0), channel: "iphone", vectors: [], editedAtMillis: 0)
        let short = GroupLabelAnchor(id: labelID(1), channel: "iphone", vectors: [try #require(VoiceVector(raw: [1, 0]))],
                                     editedAtMillis: 0)
        let r = resolve(items, [empty, short])
        #expect(r.placement.placed.isEmpty)
        #expect(r.placement.unplaced == [labelID(0), labelID(1)])
    }

    @Test func laterEditWinsATie() {
        let items = GV.items(GV.vectors(3) { _, _ in 0.8 })
        let older = label(0, on: items, edited: 5)
        let later = label(1, on: items, edited: 9)
        let r = resolve(items, [older, later])
        #expect(r.shown(on: 0) == later.id)
        #expect(r.contenders(on: 0) == [older.id])

        // Same edit time too: the smaller id shows.
        let a = label(2, on: items, edited: 9)
        let tied = resolve(items, [later, a])
        #expect(tied.shown(on: 0) == later.id)
        #expect(tied.contenders(on: 0) == [a.id])
    }

    @Test func oneLabelPerGroupAndOneGroupPerLabel() {
        // One label holds samples of both groups: it shows on the part with more of them only, and the other
        // group's own label still shows.
        let items = Self.conditions
        let wide = label(0, on: pick(items, [0, 1, 6]), edited: 1)
        let b = label(1, on: pick(items, [7, 8]), edited: 0)
        let r = resolve(pick(items, [0, 1, 6, 7, 8]), [wide, b])
        #expect(r.shown(on: 0) == wide.id)
        #expect(r.shown(on: 6) == b.id)
        #expect(Set(r.placement.placed.values).count == r.placement.placed.count)
    }

    @Test func resolutionIsOrderIndependent() {
        let items = Self.bridged
        let iphoneLabels = [label(0, on: pick(items, [0, 1, 2]), edited: 10), label(1, on: pick(items, [3, 4]), edited: 20),
                            label(2, on: pick(items, [3, 4]), edited: 20), label(3, on: pick(items, [0]), edited: 30)]
        let ipadItems = GV.items(GV.vectors(2) { _, _ in 0.8 }, channel: "ipad", first: 20)
        let labels = iphoneLabels + [label(4, on: ipadItems, channel: "ipad"), label(5, on: ipadItems, channel: "mac")]
        let all = items + ipadItems
        let vectors = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.vector) })

        for scenario in [all, pick(items, [0, 1, 2, 3, 4]) + ipadItems] {
            let groups = SampleGrouping.group(scenario, dimension: GV.dimension)
            let baseline = GroupLabelResolver.resolve(groups: groups, memberVectors: vectors, labels: labels)
            #expect(!baseline.placed.isEmpty && !baseline.contenders.isEmpty && !baseline.unplaced.isEmpty)
            var rng = SplitMix64(seed: 11)
            for _ in 0..<50 {
                let shuffled = GroupLabelResolver.resolve(groups: groups.shuffled(using: &rng), memberVectors: vectors,
                                                          labels: labels.shuffled(using: &rng))
                #expect(shuffled == baseline)
            }
        }
    }
}

@Suite("VoiceVector packed lists")
struct VoiceVectorPackedListTests {
    @Test func roundTripsBitForBit() throws {
        var raw = [Float](repeating: 0, count: 8)
        raw[0] = 1; raw[1] = 1; raw[2] = 1
        let awkward = try #require(VoiceVector(raw: raw))
        // The premise: reading one vector back with init(packed:) normalises again and changes its bits.
        let readBack = try #require(VoiceVector(packed: awkward.packed))
        #expect(readBack.packed != awkward.packed)

        let others = GV.vectors(3, dimension: 8) { i, j in 0.3 + 0.1 * Double(i + j) }
        let vectors = [awkward] + others
        let data = VoiceVector.packed(vectors)
        #expect(data == vectors.map(\.packed).reduce(Data(), +))
        let back = VoiceVector.unpacked(data, dimension: 8)
        #expect(back.map(\.packed) == vectors.map(\.packed))
        #expect(back == vectors)
    }

    @Test func unreadableBytesGiveNoVectors() throws {
        let v = GV.vectors(2, dimension: 4) { _, _ in 0.5 }
        let data = VoiceVector.packed(v)
        #expect(VoiceVector.unpacked(Data(), dimension: 4).isEmpty)
        #expect(VoiceVector.packed([]).isEmpty)
        #expect(VoiceVector.unpacked(data, dimension: 0).isEmpty)
        #expect(VoiceVector.unpacked(data, dimension: 3).isEmpty)            // 32 bytes is not whole 12-byte vectors
        #expect(VoiceVector.unpacked(data.dropLast(4), dimension: 4).isEmpty)
        #expect(VoiceVector.unpacked(data, dimension: 8).isEmpty)            // two unit halves are not one unit vector

        var nan = data
        nan.replaceSubrange(0..<4, with: withUnsafeBytes(of: Float.nan.bitPattern.littleEndian) { Data($0) })
        #expect(VoiceVector.unpacked(nan, dimension: 4).isEmpty)
        // A vector scaled by two is not unit length.
        let doubled = Data(v[0].values.flatMap { withUnsafeBytes(of: ($0 * 2).bitPattern.littleEndian) { Array($0) } })
        #expect(VoiceVector.unpacked(doubled, dimension: 4).isEmpty)    }
}
