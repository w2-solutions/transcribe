import Foundation
import Observation

/// One owner of the microphone, and of the model work that follows a capture, at a time: a meeting recording or a
/// dictation (Mac). The recorder claims it in `start()` and gives it back when the recording ends; a dictation claims
/// it when the shortcut is pressed and gives it back once it is idle again, after transcribing and pasting. So a
/// meeting's live text can never run beside a dictation's transcription, and the two never share the microphone.
@MainActor @Observable
public final class CaptureGate {
    public enum Owner: Sendable, Equatable { case meeting, dictation }

    public private(set) var owner: Owner?

    /// What a meeting recording started during a dictation says.
    public static let dictationBusyMessage = "Finish dictating first."

    public init() {}

    /// True when the gate was free and now belongs to `who`. A second claim, even by the same owner, is refused.
    public func claim(_ who: Owner) -> Bool {
        guard owner == nil else { return false }
        owner = who
        return true
    }

    /// Frees the gate if `who` holds it; anything else is ignored, so a late release never frees another owner's claim.
    public func release(_ who: Owner) {
        if owner == who { owner = nil }
    }
}
