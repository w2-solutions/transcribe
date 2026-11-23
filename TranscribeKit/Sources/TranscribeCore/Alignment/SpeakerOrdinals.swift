import Foundation

public enum SpeakerOrdinals {
    /// "Speaker N" numbering by first appearance in turns (effective key), starting at 1.
    /// User-created `U*` keys are numbered after every other key; `nil` keys are skipped.
    public static func assign(turns: [Turn]) -> [SpeakerKey: Int] {
        var diarized: [SpeakerKey] = [], userCreated: [SpeakerKey] = []
        var seen = Set<SpeakerKey>()
        for turn in turns {
            guard let key = turn.effectiveSpeakerKey, seen.insert(key).inserted else { continue }
            if isUserCreated(key) { userCreated.append(key) } else { diarized.append(key) }
        }
        var result: [SpeakerKey: Int] = [:]
        for (i, key) in (diarized + userCreated).enumerated() { result[key] = i + 1 }
        return result
    }

    /// `U` followed by digits, e.g. "U1".
    static func isUserCreated(_ key: SpeakerKey) -> Bool {
        key.count > 1 && key.first == "U" && key.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}
