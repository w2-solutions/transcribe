import Foundation
import Testing
@testable import TranscribeCore

fileprivate func turn(_ index: Int, _ key: SpeakerKey?, _ start: Double, _ end: Double, _ text: String,
                      override: SpeakerKey? = nil) -> Turn {
    Turn(id: Turn.stableID(index: index), speakerKey: key, range: TimeRange(start: start, end: end),
         words: [TimedWord(text: text, range: TimeRange(start: start, end: end))], speakerKeyOverride: override)
}

@Suite("SpeakerOrdinals")
struct SpeakerOrdinalsTests {
    @Test func numbersByFirstAppearance() {
        let turns = [turn(0, "S2", 0, 1, "a"), turn(1, "S1", 1, 2, "b"), turn(2, "S2", 2, 3, "c"), turn(3, "S3", 3, 4, "d")]
        #expect(SpeakerOrdinals.assign(turns: turns) == ["S2": 1, "S1": 2, "S3": 3])
    }

    @Test func userKeysComeAfterDiarizerKeys() {
        let turns = [turn(0, "U1", 0, 1, "a"), turn(1, "S1", 1, 2, "b"), turn(2, "U2", 2, 3, "c"), turn(3, "S2", 3, 4, "d")]
        #expect(SpeakerOrdinals.assign(turns: turns) == ["S1": 1, "S2": 2, "U1": 3, "U2": 4])
    }

    @Test func overridesAreRespectedAndNilKeysSkipped() {
        let turns = [
            turn(0, nil, 0, 1, "no speaker"),
            turn(1, "S1", 1, 2, "moved", override: "S2"),
            turn(2, "S1", 2, 3, "stays"),
            turn(3, "S3", 3, 4, "moved to new", override: "U1"),
        ]
        #expect(SpeakerOrdinals.assign(turns: turns) == ["S2": 1, "S1": 2, "U1": 3])
        #expect(SpeakerOrdinals.assign(turns: []).isEmpty)
    }
}
