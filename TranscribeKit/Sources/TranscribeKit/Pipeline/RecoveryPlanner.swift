import Foundation
import TranscribeCore

/// What launch recovery does with one unfinished recording (§5.7).
public enum RecoveryAction: Sendable, Equatable {
    /// Capture was cut off (crash or kill): patch the WAV header, rebuild peaks, then queue it.
    case repairAndQueue(UUID)
    /// Capture never produced audio: remove the row.
    case discard(UUID)
    /// Give up with a message shown on the card.
    case fail(UUID, message: String)
    /// Resume from the last checkpoint.
    case requeue(UUID)

    public var recordingID: UUID {
        switch self {
        case .repairAndQueue(let id), .discard(let id), .fail(let id, _), .requeue(let id): id
        }
    }
}

/// Pure launch-recovery decisions (§5.7). Input order is kept, so oldest recordings resume first.
public enum RecoveryPlanner {
    public static let maxAttempts = 3
    public static let audioMissingMessage = "Audio file is missing"
    public static let gaveUpMessage = "Couldn't finish processing"

    public static func plan(_ snapshots: [RecoverySnapshot]) -> [RecoveryAction] {
        snapshots.compactMap(action)
    }

    public static func action(for s: RecoverySnapshot) -> RecoveryAction? {
        switch s.stage {
        case .capturing:
            return s.audioExists ? .repairAndQueue(s.id) : .discard(s.id)
        case .queued, .transcribing, .transcribed, .separating, .separated, .matching:
            if !s.audioExists { return .fail(s.id, message: audioMissingMessage) }
            if s.attemptCount >= maxAttempts { return .fail(s.id, message: gaveUpMessage) }
            return .requeue(s.id)
        case .ready, .failed:
            return nil
        }
    }
}
