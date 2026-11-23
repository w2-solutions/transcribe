import Foundation

public enum CopyFormat: String, Sendable, Codable, CaseIterable {
    case off, textOnly, withSpeakers
    public var title: String { switch self { case .off: "Off"; case .textOnly: "Text only"; case .withSpeakers: "Text with speakers" } }
}

public enum TranscriptFormatter {
    /// textOnly: turn texts separated by blank lines.
    /// withSpeakers: "Liam · 0:01\nHey, Karan…\n\nKaran · 0:07\n…" (DisplayFormat.duration for times).
    ///
    /// Turns without a speaker use just the time ("0:01\n…"). The effective key (a "just this turn" override)
    /// names each turn. Turns that are empty (after filler removal, if on) are left out. `.off` formats like
    /// `.withSpeakers`, which is what a manual copy uses when auto copy is off.
    public static func plainText(_ document: TranscriptDocument, format: CopyFormat, removeFillers: Bool,
                                 speakerName: (SpeakerKey) -> String) -> String {
        var blocks: [String] = []
        for turn in document.turns {
            let raw = turn.text
            let text = (removeFillers ? FillerWordFilter.filter(raw) : raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch format {
            case .textOnly:
                blocks.append(text)
            case .withSpeakers, .off:
                let time = DisplayFormat.duration(turn.range.start)
                let heading = turn.effectiveSpeakerKey.map { "\(speakerName($0)) · \(time)" } ?? time
                blocks.append(heading + "\n" + text)
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}
