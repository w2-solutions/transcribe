import Foundation
import Testing
@testable import TranscribeCore

private func req(_ key: SpeakerKey, _ ordinal: Int, _ slot: Int? = nil) -> ColourRequest {
    ColourRequest(key: key, ordinal: ordinal, profileSlot: slot)
}

@Suite("ColourAssigner")
struct ColourAssignerTests {

    // MARK: assign

    @Test func ordinalFill() {
        let r = ColourAssigner.assign([req("S3", 3), req("S1", 1), req("S2", 2)])
        #expect(r == ["S1": 0, "S2": 1, "S3": 2])
    }

    @Test("Profile slot honoured", arguments: [
        ([req("S1", 1), req("S2", 2, 1)], ["S1": 0, "S2": 1]),            // Speaker 2 is Karan (rose)
        ([req("S1", 1), req("S2", 2, 0)], ["S1": 1, "S2": 0]),            // Liam keeps teal as Speaker 2
        ([req("S1", 1, 0), req("S2", 2, 1)], ["S1": 0, "S2": 1]),
        ([req("S1", 1), req("S2", 2), req("S3", 3, 4)], ["S1": 0, "S2": 1, "S3": 4]),
    ])
    func profileSlotHonoured(_ requests: [ColourRequest], _ expected: [SpeakerKey: Int]) {
        #expect(ColourAssigner.assign(requests) == expected)
        #expect(ColourAssigner.assign(requests.reversed()) == expected)
    }

    @Test func collisionFallsBackToLowestFree() {
        // Two profiles share slot 2 (possible once slots wrap): the earlier ordinal keeps it.
        let r = ColourAssigner.assign([req("S2", 2, 2), req("S1", 1, 2), req("S3", 3)])
        #expect(r == ["S1": 2, "S2": 0, "S3": 1])
    }

    @Test func profileSlotsBeatEarlierOrdinalsWithoutProfiles() {
        let r = ColourAssigner.assign([req("S1", 1), req("S2", 2), req("S3", 3, 0)])
        #expect(r == ["S1": 1, "S2": 2, "S3": 0])
    }

    @Test func wrapsPastSix() {
        let requests = (1...8).map { req("S\($0)", $0) }
        let r = ColourAssigner.assign(requests)
        #expect((1...6).allSatisfy { r["S\($0)"] == $0 - 1 })
        #expect(r["S7"] == 0 && r["S8"] == 1)
        #expect(SpeakerSlots.count == 6)
    }

    @Test func wrapUsesOrdinalAfterProfileSlots() {
        var requests = (1...6).map { req("S\($0)", $0) }
        requests.append(req("S7", 7, 3))     // step 1 places profile slots before any ordinal fill
        requests.append(req("S8", 8))
        let r = ColourAssigner.assign(requests)
        #expect(r["S7"] == 3)
        #expect(r["S1"] == 0 && r["S2"] == 1 && r["S3"] == 2 && r["S4"] == 4 && r["S5"] == 5)
        #expect(r["S6"] == (6 - 1) % 6)       // all slots used → (ordinal − 1) % 6
        #expect(r["S8"] == (8 - 1) % 6)
    }

    @Test func userKeysAndEmptyInput() {
        #expect(ColourAssigner.assign([]).isEmpty)
        let r = ColourAssigner.assign([req("S1", 1), req("U1", 2, 1)])
        #expect(r == ["S1": 0, "U1": 1])
    }

    // MARK: reassign

    @Test func reassignMovesTheHolder() {
        let r = ColourAssigner.reassign(key: "S1", toProfileSlot: 1, current: ["S1": 0, "S2": 1])
        #expect(r == ["S1": 1, "S2": 0])
    }

    @Test func reassignHolderTakesLowestFreeSlot() {
        let r = ColourAssigner.reassign(key: "S3", toProfileSlot: 0, current: ["S1": 0, "S2": 1, "S3": 2])
        #expect(r == ["S1": 2, "S2": 1, "S3": 0])
    }

    @Test func reassignWithoutHolderTouchesOnlyTheKey() {
        let current: [SpeakerKey: Int] = ["S1": 0, "S2": 1]
        #expect(ColourAssigner.reassign(key: "S2", toProfileSlot: 4, current: current) == ["S1": 0, "S2": 4])
        #expect(ColourAssigner.reassign(key: "S2", toProfileSlot: 1, current: current) == current)
        #expect(ColourAssigner.reassign(key: "U1", toProfileSlot: 3, current: current) == ["S1": 0, "S2": 1, "U1": 3])
    }

    @Test func reassignWithEverySlotUsed() {
        // S7 shares teal with S1 (more speakers than slots). Taking slot 3 leaves no free slot,
        // so S4 swaps into the slot S7 gave up.
        let current: [SpeakerKey: Int] = ["S1": 0, "S2": 1, "S3": 2, "S4": 3, "S5": 4, "S6": 5, "S7": 0]
        let swapped = ColourAssigner.reassign(key: "S7", toProfileSlot: 3, current: current)
        #expect(swapped == ["S1": 0, "S2": 1, "S3": 2, "S4": 0, "S5": 4, "S6": 5, "S7": 3])

        // A key with no slot of its own gives nothing up: the holder keeps sharing.
        let full: [SpeakerKey: Int] = ["S1": 0, "S2": 1, "S3": 2, "S4": 3, "S5": 4, "S6": 5]
        let shared = ColourAssigner.reassign(key: "U1", toProfileSlot: 3, current: full)
        #expect(shared == full.merging(["U1": 3]) { a, _ in a })
    }

    // MARK: slotForNewProfile

    static let newProfileCases: [(speakerSlot: Int, profileSlots: Set<Int>, expected: Int)] = [
        (1, [], 1),
        (1, [0], 1),                // Speaker 2's rose carries through to Karan
        (1, [0, 1], 2),
        (0, [0, 1, 2], 3),
        (2, [0, 1, 3], 2),
        (1, [0, 1, 2, 3, 4, 5], 1), // every slot owned → keep the speaker's slot
    ]

    @Test("slotForNewProfile", arguments: newProfileCases)
    func slotForNewProfile(speakerSlot: Int, profileSlots: Set<Int>, expected: Int) {
        #expect(ColourAssigner.slotForNewProfile(speakerSlot: speakerSlot, profileSlots: profileSlots) == expected)
    }

    // MARK: Defensive inputs

    @Test func outOfRangeSlotsWrap() {
        #expect(ColourAssigner.assign([req("S1", 1, 7)]) == ["S1": 1])
        #expect(ColourAssigner.assign([req("S1", 1, -1)]) == ["S1": 5])
        #expect(ColourAssigner.reassign(key: "S1", toProfileSlot: 8, current: ["S1": 0, "S2": 2]) == ["S1": 2, "S2": 0])
        #expect(ColourAssigner.slotForNewProfile(speakerSlot: 7, profileSlots: []) == 1)
        #expect(ColourAssigner.slotForNewProfile(speakerSlot: 1, profileSlots: [7]) == 0)
    }

    @Test func repeatedKeyKeepsItsFirstAssignment() {
        let r = ColourAssigner.assign([req("S1", 1), req("S1", 2, 4), req("S2", 3)])
        #expect(r == ["S1": 0, "S2": 1])
    }

    @Test func zeroSlotsDoesNotCrash() {
        #expect(ColourAssigner.assign([req("S1", 1), req("S2", 2, 3)], slotCount: 0) == ["S1": 0, "S2": 0])
        #expect(ColourAssigner.reassign(key: "S1", toProfileSlot: 2, current: [:], slotCount: 0) == ["S1": 2])
        #expect(ColourAssigner.slotForNewProfile(speakerSlot: 3, profileSlots: [3], slotCount: 0) == 3)
    }
}
