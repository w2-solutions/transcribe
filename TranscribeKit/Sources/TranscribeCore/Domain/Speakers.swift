import Foundation

public struct SpeakerSegment: Sendable, Hashable {
    public var speakerKey: SpeakerKey
    public var range: TimeRange
    public var quality: Float
    public init(speakerKey: SpeakerKey, range: TimeRange, quality: Float = 1) {
        self.speakerKey = speakerKey; self.range = range; self.quality = quality
    }
}

/// Which model decided when each person speaks (for logs and diagnostics; not persisted).
public enum SpeakerSeparator: String, Sendable, Equatable {
    case nemotron3          // NVIDIA Nemotron 3 Diarization (primary on the real engine)
    case communityOne       // pyannote community-1 offline pipeline (fallback)
    case unspecified        // fakes and older callers
}

public struct SpeakerSeparation: Sendable {
    public var segments: [SpeakerSegment]               // sorted by start; may overlap
    public var centroids: [SpeakerKey: VoiceVector]     // L2-normalised fallback vectors (may be empty)
    public var separator: SpeakerSeparator
    public init(segments: [SpeakerSegment], centroids: [SpeakerKey: VoiceVector],
                separator: SpeakerSeparator = .unspecified) {
        self.segments = segments; self.centroids = centroids; self.separator = separator
    }
}

/// Persisted label state of a speaker within one recording.
public enum SpeakerLabelState: String, Sendable, Codable, CaseIterable {
    case unnamed        // "Speaker N", dashed amber chip
    case suggested      // "Karan?" ask
    case autoLabelled   // matched automatically (filled chip + recognised badge)
    case named          // named/confirmed/corrected by the user
}

public enum SpeakerSlots {
    /// teal, rose, violet, green, slate-blue, brown. Amber is NEVER a slot.
    public static let count = 6
}
