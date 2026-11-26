import Foundation
import TranscribeCore

/// Whether a voice sample's clip can play on this device, and if not, why (voice sample groups §3).
///
/// A sample keeps only a clip range in its source recording (`clipStart…clipEnd`), never audio of its own, so the clip
/// plays from that recording's WAV. Audio never syncs, so a sample learned on another device has its recording row
/// here but no WAV.
public enum SampleClipState: Equatable, Sendable {
    /// The recording and its WAV are here: play `range` of `fileName` (relative to `AppPaths.audioDirectory`).
    case playable(fileName: String, range: TimeRange)
    /// The recording is here but its WAV is not: it stayed on the device that recorded it (`channel`, nil = unknown).
    case audioElsewhere(channel: String?)
    /// The sample names a source recording that no longer exists here.
    case recordingDeleted
    /// The sample has no source recording or no clip range, so there is nothing to play on any device.
    case noClip

    /// Checks in this order: no source recording → `.noClip`; recording missing → `.recordingDeleted`; no clip range
    /// → `.noClip` (nothing to play anywhere, so never "audio elsewhere"); WAV missing → `.audioElsewhere`; otherwise
    /// `.playable`. `recording` is the source recording when it exists here; `audioExists` is asked about its file
    /// name only once every other check passed.
    public static func resolve(sourceRecordingID: UUID?, clip: TimeRange?,
                               recording: (fileName: String, channel: String?)?,
                               audioExists: (String) -> Bool) -> SampleClipState {
        guard sourceRecordingID != nil else { return .noClip }
        guard let recording else { return .recordingDeleted }
        guard let clip else { return .noClip }
        guard audioExists(recording.fileName) else { return .audioElsewhere(channel: recording.channel) }
        return .playable(fileName: recording.fileName, range: clip)
    }

    public var isPlayable: Bool {
        if case .playable = self { true } else { false }
    }

    /// The caption shown in place of the waveform, and read after the quote by VoiceOver; nil when the clip can play.
    public func caption(_ copy: DeviceCopy) -> String? {
        switch self {
        case .playable: nil
        case .audioElsewhere(let channel): copy.sampleAudioElsewhere(channel: channel)
        case .recordingDeleted: "Recording deleted"
        case .noClip: "No clip saved"
        }
    }
}
