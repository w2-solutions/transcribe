import Foundation

/// What a recording captures (Mac audio, decided 2026-11-26). The Mac offers all three; the iPhone records the
/// microphone only. Raw values are the stored setting values (`settings.recordingSource`).
///
/// Mac audio is not a capture channel of its own (decision D2): every recording made on a Mac stays on the "mac"
/// channel whatever it captured, and sound groups tell the room and call audio apart.
public enum CaptureSources: String, Sendable, Codable, CaseIterable, Hashable {
    case microphone
    /// The microphone and Mac audio, mixed into one recording (with temporary per-stream stems).
    case both
    /// Mac audio only: the system output through a process tap.
    case macAudio

    public var includesMicrophone: Bool { self != .macAudio }
    public var includesSystemAudio: Bool { self != .microphone }

    /// The value stored in `CaptureDetail.sources`: "mic", "both" or "system".
    public var detailValue: String {
        switch self {
        case .microphone: CaptureDetail.Sources.mic
        case .both: CaptureDetail.Sources.both
        case .macAudio: CaptureDetail.Sources.system
        }
    }

    /// The sources a `CaptureDetail.sources` value names; nil or unknown values are the microphone.
    public init(detailValue: String?) {
        switch detailValue {
        case CaptureDetail.Sources.both: self = .both
        case CaptureDetail.Sources.system: self = .macAudio
        default: self = .microphone
        }
    }

    /// `CaptureDetail.input` for a recording that captured Mac audio; nil for the microphone (the device route then
    /// says what the input was).
    public var detailInput: String? {
        switch self {
        case .microphone: nil
        case .both: CaptureDetail.Input.micAndSystem
        case .macAudio: CaptureDetail.Input.systemAudio
        }
    }
}

/// Which stream a speaker was heard on (decision D1), stored in `RecordingSpeaker.captureSource`.
/// nil there (every recording before V5, and every microphone-only recording) reads as `.mic`.
///
/// - `system`: heard through Mac audio (the far side of a call); embedded from the system stem.
/// - `mixed`: heard on both streams, or not attributable. Never auto-labelled, learns no sample or negative from that
///   recording, and is left out of the cohort.
public enum SpeakerSource: String, Sendable, Codable, CaseIterable, Hashable {
    case mic, system, mixed

    /// The stored value read back: nil and unknown values are `.mic`.
    public init(stored: String?) {
        self = stored.flatMap(SpeakerSource.init(rawValue:)) ?? .mic
    }

    /// The source of a speaker made by joining two ("Same as"): the same source stays, different sources are mixed.
    public static func joined(_ a: SpeakerSource, _ b: SpeakerSource) -> SpeakerSource { a == b ? a : .mixed }
}

/// One stream of a recording that captured both the microphone and Mac audio.
public enum CaptureStream: String, Sendable, Codable, CaseIterable, Hashable {
    case mic, system
}

/// The per-stream files of a Both recording, beside its mixed `<id>.wav`: `Stems/<id>.mic.wav` and
/// `Stems/<id>.system.wav` in the audio folder. Temporary: they are deleted when the recording is ready.
public struct CaptureStems: Sendable, Equatable, Hashable {
    public var mic: URL
    public var system: URL
    public init(mic: URL, system: URL) { self.mic = mic; self.system = system }

    public func url(_ stream: CaptureStream) -> URL { stream == .mic ? mic : system }

    /// The subfolder of the audio folder that holds stems.
    public static let directoryName = "Stems"

    /// "<base>.<stream>.wav", where base is the recording's audio file name without its extension.
    public static func fileName(base: String, stream: CaptureStream) -> String { "\(base).\(stream.rawValue).wav" }

    /// The stems that belong beside the mixed file at `audioURL` (`<audio folder>/Stems/<base>.<stream>.wav`).
    public static func beside(audioURL: URL) -> CaptureStems {
        let folder = audioURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
        let base = audioURL.deletingPathExtension().lastPathComponent
        return CaptureStems(mic: folder.appendingPathComponent(fileName(base: base, stream: .mic), isDirectory: false),
                            system: folder.appendingPathComponent(fileName(base: base, stream: .system), isDirectory: false))
    }
}
