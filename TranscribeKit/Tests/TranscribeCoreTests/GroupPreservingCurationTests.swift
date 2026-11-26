import Foundation
import Testing
@testable import TranscribeCore

private func sample(_ n: Int, _ vector: VoiceVector, _ origin: SampleOrigin = .confirmed, day: Int,
                    seconds: TimeInterval = 60) -> CuratedSample {
    CuratedSample(id: TV.uuid(0x400 + n), vector: vector, origin: origin,
                  addedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400), speechSeconds: seconds)
}

private let groupsOff: MatchPolicy = { var p = MatchPolicy.default; p.groupScoring = false; return p }()

/// The sound groups of `samples` as the voice screen makes them (one channel).
private func screenGroups(_ samples: [CuratedSample]) -> [SampleGrouping.Group] {
    SampleGrouping.group(samples.map { SampleGrouping.Item(id: $0.id, vector: $0.vector, channel: "mac",
                                                           addedAtMillis: $0.addedAtMillis) },
                         dimension: GV.dimension)
}

/// Group-preserving curation (decision D4): soft cap 12, ceiling 20 per (profile, channel), groups taken before the
/// insert, representatives protected, automatic-only groups unprotected, `insertMany` for merges.
@Suite("Group-preserving curation")
struct GroupPreservingCurationTests {

    @Test func everyVouchedGroupKeepsAMember() {
        var rng = SplitMix64(seed: 31)
        let origins: [(SampleOrigin, TimeInterval)] = [(.confirmed, 60), (.confirmed, 6), (.strongMatch, 30),
                                                       (.addedFromRecording, 20), (.corrected, 7), (.named, 30)]
        var ceilingRuns = 0
        for _ in 0..<300 {
            let groupCount = Int.random(in: 1...8, using: &rng)
            let n = Int.random(in: 12...22, using: &rng)
            let blocks = (0...n).map { _ in Int.random(in: 0..<groupCount, using: &rng) }
            let vectors = GV.blocks(blocks, within: Array(repeating: 0.8, count: groupCount), across: 0.2)
            let all = (0...n).map { i -> CuratedSample in
                let (origin, seconds) = origins[Int.random(in: 0..<origins.count, using: &rng)]
                return sample(i, vectors[i], origin, day: Int.random(in: 0..<40, using: &rng), seconds: seconds)
            }
            let existing = Array(all.prefix(n)), new = all[n]
            let r = SampleCurator.insert(new, into: existing)
            #expect(r.added)    // block vectors are 0.8 apart, never duplicates
            #expect(Set(r.keep.map(\.id)).union(r.evicted) == Set(all.map(\.id)))
            #expect(Set(r.keep.map(\.id)).isDisjoint(with: r.evicted))

            let g0 = screenGroups(existing)
            let vouched = g0.filter { g in g.memberIDs.contains { id in !existing.first { $0.id == id }!.origin.isAutomatic } }
            let named = existing.filter { $0.origin == .named }
                .min { ($0.addedAtMillis, $0.id.uuidString) < ($1.addedAtMillis, $1.id.uuidString) }
            // New sample + earliest named + one representative per vouched group (a named sample may be one).
            let protectedBound = 1 + (named == nil ? 0 : 1) + vouched.count
            let kept = Set(r.keep.map(\.id))
            if r.keep.count > 20 { Issue.record("over the ceiling: \(r.keep.count)") }
            if protectedBound <= 20 {
                for g in vouched { #expect(g.memberIDs.contains(where: kept.contains), "group \(g.key) lost") }
                #expect(r.keep.count <= Swift.max(12, protectedBound))
            } else {
                ceilingRuns += 1
            }
            #expect(kept.contains(new.id))
            if let named { #expect(kept.contains(named.id)) }
        }
        #expect(ceilingRuns == 0)   // at most 9 groups + 2: the ceiling step never runs here
    }

    @Test(arguments: [true, false])
    func aShortOnlyGroupSurvivesAFullChannelOfTrustedSamples(groups: Bool) {
        // Eleven trusted desk samples and one short sample of another sound; a twelfth desk sample arrives.
        let vectors = GV.blocks(Array(repeating: 0, count: 12) + [1] + [0], within: [0.85, 1], across: 0.2)
        let desk = (0..<11).map { sample($0, vectors[$0], $0 == 0 ? .named : .confirmed, day: $0) }
        let short = sample(20, vectors[12], .confirmed, day: 30, seconds: 6)
        let new = sample(21, vectors[13], .confirmed, day: 40)
        let r = SampleCurator.insert(new, into: desk + [short], policy: groups ? .default : groupsOff)
        #expect(r.evicted.count == 1)
        if groups {
            #expect(r.keep.contains { $0.id == short.id } && desk.map(\.id).contains(r.evicted[0]))
        } else {
            #expect(r.evicted == [short.id])   // before groups the short sample went first
        }
    }

    @Test(arguments: [SampleOrigin.strongMatch, .confirmed])
    func anAutomaticOnlyGroupIsUnprotected(origin: SampleOrigin) {
        let vectors = GV.blocks(Array(repeating: 0, count: 11) + [1, 0], within: [0.85, 1], across: 0.2)
        let desk = (0..<11).map { sample($0, vectors[$0], $0 == 0 ? .named : .confirmed, day: $0) }
        let lone = sample(20, vectors[11], origin, day: 30, seconds: origin == .confirmed ? 6 : 30)
        let r = SampleCurator.insert(sample(21, vectors[12], day: 40), into: desk + [lone])
        if origin.isAutomatic {
            #expect(r.evicted == [lone.id])          // an automatic sample's group has no one vouching for it
        } else {
            #expect(r.keep.contains { $0.id == lone.id } && r.evicted.count == 1)
        }
    }

    @Test func protectedSamplesStayBetweenThirteenAndTwenty() {
        // Fifteen orthogonal user samples are fifteen groups: every one is its group's last member.
        let existing = (0..<15).map { sample($0, TV.axis($0), $0 == 0 ? .named : .confirmed, day: $0) }
        let r = SampleCurator.insert(sample(30, TV.axis(30), day: 30), into: existing)
        #expect(r.added && r.keep.count == 16 && r.evicted.isEmpty)
        // An automatic sample among them is not protected: it goes, down to fifteen (its class comes first).
        let withAuto = existing + [sample(31, TV.axis(31), .strongMatch, day: 31)]
        let r2 = SampleCurator.insert(sample(30, TV.axis(30), day: 30), into: withAuto)
        #expect(r2.evicted == [TV.uuid(0x400 + 31)] && r2.keep.count == 16)
    }

    @Test func aboveTheCeilingTheClosestGroupGoes() {
        // Twenty orthogonal groups, except that A and B sit at 0.5 to each other (below the join value, so separate).
        // A 21st arrives: over the ceiling, the group nearest another goes, the older of A and B.
        var existing = (0..<18).map { sample($0, TV.axis($0), $0 == 0 ? .named : .confirmed, day: $0 + 10) }
        let a = sample(40, TV.axis(40), .confirmed, day: 5)
        let b = sample(41, TV.vector([40: 0.5], residual: 41), .confirmed, day: 3)
        existing += [a, b]
        let new = sample(50, TV.axis(50), day: 60)
        let r = SampleCurator.insert(new, into: existing)
        #expect(r.keep.count == 20 && r.evicted == [b.id])

        // A short sample among them goes first, whatever its neighbours (lowest class).
        let short = sample(42, TV.axis(42), .confirmed, day: 50, seconds: 6)
        let r2 = SampleCurator.insert(new, into: Array(existing.dropLast()) + [short])
        #expect(r2.keep.count == 20 && r2.evicted == [short.id])
    }

    @Test func theEarliestNamedAndTheNewSampleAreNeverEvictedAboveTheCeiling() {
        // 22 orthogonal named samples (earliest is #0) plus a new one: two go, never #0 or the new one.
        let existing = (0..<22).map { sample($0, TV.axis($0), .named, day: $0) }
        let new = sample(40, TV.axis(40), day: 40)
        let r = SampleCurator.insert(new, into: existing)
        #expect(r.keep.count == 20 && r.evicted.count == 3)
        #expect(r.keep.contains { $0.id == existing[0].id } && r.keep.contains { $0.id == new.id })
        // All tie on class and linkage (0): the oldest go first, #1 to #3.
        #expect(r.evicted == [1, 2, 3].map { TV.uuid(0x400 + $0) })
    }

    @Test func evictionTakesFromTheLargestGroupFirst() {
        // Group A has 7 members, group B 6; a new sample of a third sound makes 14: two go. The first comes from A
        // (largest); then A and B both have 6 and the tie goes to the smaller key (the group's oldest member).
        let blocks = Array(repeating: 0, count: 7) + Array(repeating: 1, count: 6) + [2]
        let vectors = GV.blocks(blocks, within: [0.85, 0.85, 1], across: 0.2)
        let existing = (0..<13).map { sample($0, vectors[$0], .confirmed, day: $0) }
        let r = SampleCurator.insert(sample(20, vectors[13], day: 20), into: existing)
        let groupA = Set((0..<7).map { TV.uuid(0x400 + $0) }), groupB = Set((7..<13).map { TV.uuid(0x400 + $0) })
        #expect(r.evicted.count == 2 && groupA.contains(r.evicted[0]))
        // Keys: A's is #0 (0x400), B's is #7 (0x407); 0x400 sorts first, so the second also comes from A.
        #expect(groupA.contains(r.evicted[1]) && r.evicted.allSatisfy { !groupB.contains($0) })
        #expect(r.keep.count == 12)
    }

    @Test func withinAGroupTheMostRedundantGoesThenTheOldest() {
        // Group A: an edge sample #0 (0.7 to the rest, the oldest) and eight core samples #1–#8 (0.9 to each other).
        // Group B: four samples #9–#12. A new sample of a third sound makes 14: two go, both from A (the largest),
        // core samples first (mean cosine 0.875 against the edge's 0.7). #1 is A's representative (core samples tie
        // on the centroid, then the id), so #2 and #3 go, oldest first; the edge stays although it is the oldest.
        let vectors = GV.vectors(14) { i, j in
            if j <= 8 { return i == 0 ? 0.7 : 0.9 }
            if i >= 9 && j <= 12 { return 0.85 }
            return 0.1
        }
        let existing = (0..<13).map { sample($0, vectors[$0], .confirmed, day: $0) }
        let r = SampleCurator.insert(sample(20, vectors[13], day: 30), into: existing)
        #expect(r.evicted == [TV.uuid(0x402), TV.uuid(0x403)])
        #expect(r.keep.contains { $0.id == TV.uuid(0x400) })
    }

    @Test func theResultDoesNotDependOnInputOrder() {
        var rng = SplitMix64(seed: 77)
        for _ in 0..<40 {
            let n = Int.random(in: 13...22, using: &rng)
            let groupCount = Int.random(in: 1...6, using: &rng)
            let blocks = (0...n).map { _ in Int.random(in: 0..<groupCount, using: &rng) }
            let vectors = GV.blocks(blocks, within: Array(repeating: 0.75, count: groupCount), across: 0.3)
            let all = (0...n).map { i in
                sample(i, vectors[i], [.named, .confirmed, .strongMatch][Int.random(in: 0..<3, using: &rng)],
                       day: Int.random(in: 0..<3, using: &rng), seconds: Bool.random(using: &rng) ? 60 : 6)
            }
            let existing = Array(all.prefix(n))
            let baseline = SampleCurator.insert(all[n], into: existing)
            for _ in 0..<10 {
                let r = SampleCurator.insert(all[n], into: existing.shuffled(using: &rng))
                #expect(r.evicted == baseline.evicted && Set(r.keep.map(\.id)) == Set(baseline.keep.map(\.id)))
            }
        }
    }

    // MARK: insertMany

    @Test func insertManyKeepsBothProfilesGroups() {
        // Target: twelve desk samples (block 0). Source: a trusted pair (block 1), a short one (block 2), an automatic
        // one (block 3) and a near-copy of a desk sample.
        let blocks = Array(repeating: 0, count: 12) + [1, 1, 2, 3]
        let vectors = GV.blocks(blocks, within: [0.85, 0.85, 1, 1], across: 0.2)
        let target = (0..<12).map { sample($0, vectors[$0], $0 == 0 ? .named : .confirmed, day: $0) }
        let pair = [sample(20, vectors[12], .named, day: 1), sample(21, vectors[13], .confirmed, day: 2)]
        let short = sample(22, vectors[14], .confirmed, day: 3, seconds: 6)
        let auto = sample(23, vectors[15], .strongMatch, day: 4)
        let copy = sample(24, vectors[5], .confirmed, day: 5)
        let r = SampleCurator.insertMany(pair + [short, auto, copy], into: target)
        // The copy is a duplicate; the automatic sample is accepted, then evicted first (nobody vouches for its group).
        #expect(r.skippedIDs.contains(copy.id) && r.skippedIDs.contains(auto.id))
        #expect(Set(r.addedIDs) == Set([pair[0].id, pair[1].id, short.id]))
        #expect(r.keep.count == 12 && r.evicted.count == 3 && r.evicted.allSatisfy { id in target.contains { $0.id == id } })
        #expect(r.keep.contains { $0.id == target[0].id })   // the target's first naming
        let ordered = target + pair + [short, auto]
        let keptBlocks = Set(r.keep.map { s in blocks[ordered.firstIndex { $0.id == s.id }!] })
        #expect(keptBlocks == [0, 1, 2])
        // Both first namings are kept.
        #expect(r.keep.contains { $0.id == target[0].id } && r.keep.contains { $0.id == pair[0].id })
    }

    @Test func insertManyWithGroupsOffIsOneInsertAfterAnother() {
        var rng = SplitMix64(seed: 3)
        let existing = (0..<10).map { sample($0, TV.axis($0), $0 == 0 ? .named : .confirmed, day: $0) }
        let incoming = (0..<6).map { sample(20 + $0, TV.axis(20 + $0), .merged, day: Int.random(in: 0..<30, using: &rng)) }
        var expected = existing
        for s in incoming.sorted(by: { ($0.addedAtMillis, $0.id.uuidString) < ($1.addedAtMillis, $1.id.uuidString) }) {
            expected = SampleCurator.insert(s, into: expected, policy: groupsOff).keep
        }
        let r = SampleCurator.insertMany(incoming.shuffled(using: &rng), into: existing, policy: groupsOff)
        #expect(r.keep.map(\.id) == expected.map(\.id))
        #expect(Set(r.addedIDs).union(r.skippedIDs) == Set(incoming.map(\.id)))
    }

    @Test func insertManyUnderTheCapKeepsEverything() {
        let existing = (0..<4).map { sample($0, TV.axis($0), day: $0) }
        let incoming = (0..<4).map { sample(10 + $0, TV.axis(10 + $0), .merged, day: 10 - $0) }
        let r = SampleCurator.insertMany(incoming, into: existing)
        #expect(r.keep.count == 8 && r.evicted.isEmpty && r.skippedIDs.isEmpty)
        // Incoming samples follow in canonical order: oldest first.
        #expect(r.addedIDs == [13, 12, 11, 10].map { TV.uuid(0x400 + $0) })
    }
}
