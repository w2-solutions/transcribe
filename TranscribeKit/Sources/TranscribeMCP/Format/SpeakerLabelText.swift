import Foundation

/// How a speaker is named in tool output (§3.4). The app's display rule, plus the status in words, so Claude can tell
/// a name the user gave from one Transcribe recognised by voice. A suggestion ("Is this Karan?") is never used as the
/// name: the voice stays "Speaker N" and the guess is only mentioned.
public enum SpeakerLabelText {
    /// The name on a transcript line: "Liam", "Karan (auto)", "Speaker 2".
    public static func lineName(_ s: MCPSpeaker) -> String {
        switch s.status {
        case .named, .unnamed: s.name
        case .autoLabelled: s.name + " (auto)"
        case .suggested: "Speaker \(s.ordinal)"
        }
    }

    /// For list_recordings: "Liam [the user, named]", "Karan [recognised automatically, not confirmed]",
    /// "Speaker 2 [unnamed, Transcribe guesses Priya]".
    public static func bracket(_ s: MCPSpeaker) -> String {
        let user = s.isUser ? "the user, " : ""
        switch s.status {
        case .named: return "\(s.name) [\(user)named]"
        case .autoLabelled: return "\(s.name) [\(user)recognised automatically, not confirmed]"
        case .suggested:
            let guess = s.suggestedName.map { ", Transcribe guesses \($0)" } ?? ""
            return "Speaker \(s.ordinal) [unnamed\(guess)]"
        case .unnamed: return "\(s.name) [unnamed]"
        }
    }

    /// For the get_transcript header: "- Liam: the user; named by the user".
    public static func headerLine(_ s: MCPSpeaker) -> String {
        switch s.status {
        case .named:
            return "- \(s.name): " + (s.isUser ? "the user; named by the user" : "named by the user")
        case .autoLabelled:
            return "- \(s.name) (auto): " + (s.isUser ? "the user; recognised automatically by voice; not confirmed"
                                                      : "recognised automatically by voice; not confirmed by the user")
        case .suggested:
            let guess = s.suggestedName.map { "; Transcribe's guess is \($0), not confirmed" } ?? ""
            return "- Speaker \(s.ordinal): unnamed\(guess)"
        case .unnamed:
            return "- \(s.name): unnamed"
        }
    }
}
