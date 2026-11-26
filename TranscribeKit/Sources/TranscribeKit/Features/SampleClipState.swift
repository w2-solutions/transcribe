import Foundation
import TranscribeCore

/// Whether a voice sample's clip can play on this device, and if not, why (voice sample groups §3, audio sync §1.3).
///
/// A sample keeps only a clip range in its source recording (`clipStart…clipEnd`), never audio of its own, so the clip
/// plays from that recording's audio file (its WAV, or a copy downloaded from iCloud). A sample learned on another
/// device can have its recording row here but no audio: not in iCloud, not downloaded yet, or not syncing here.
public enum SampleClipState: Equatable, Sendable {
    /// The recording and its audio file are here: play `range` of `fileName` (relative to `AppPaths.audioDirectory`).
    case playable(fileName: String, range: TimeRange)
    /// The recording is here but its audio is not, and it is not known to be in iCloud (not uploaded yet, or not
    /// syncing here): it is on the device that recorded it (`channel`, nil = unknown).
    case audioElsewhere(channel: String?)
    /// The recording's audio is downloading from iCloud.
    case audioDownloading
    /// The recording's audio is in iCloud and not downloaded here yet (waiting, failed, or Sync audio off here).
    case audioInICloud
    /// The sample names a source recording that no longer exists here.
    case recordingDeleted
    /// The sample has no source recording or no clip range, so there is nothing to play on any device.
    case noClip

    /// Checks in this order: no source recording → `.noClip`; recording missing → `.recordingDeleted`; no clip range
    /// → `.noClip` (nothing to play anywhere, so never "audio elsewhere"); audio file missing → by the recording's
    /// audio state; otherwise `.playable`. `recording` is the source recording when it exists here; `audioExists` is
    /// asked about its file name only once every other check passed. `audioState` gives the source recording's
    /// `RecordingAudioState` (nil without audio sync) and is asked only when the file is missing: `.downloading` →
    /// `.audioDownloading`; `.inICloud`, `.failed` and `.syncAudioOffHere(inICloud: true)` → `.audioInICloud`; anything
    /// else (no state, `.checking`, `.notInICloud`, `.needsUpdate`, `.syncOffHere`) → `.audioElsewhere`.
    public static func resolve(sourceRecordingID: UUID?, clip: TimeRange?,
                               recording: (fileName: String, channel: String?)?,
                               audioExists: (String) -> Bool,
                               audioState: (UUID) -> RecordingAudioState? = { _ in nil }) -> SampleClipState {
        guard let sourceRecordingID else { return .noClip }
        guard let recording else { return .recordingDeleted }
        guard let clip else { return .noClip }
        guard audioExists(recording.fileName) else {
            switch audioState(sourceRecordingID) {
            case .downloading: return .audioDownloading
            case .inICloud, .failed, .syncAudioOffHere(inICloud: true, _): return .audioInICloud
            default: return .audioElsewhere(channel: recording.channel)
            }
        }
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
        case .audioDownloading: "Downloading audio…"
        case .audioInICloud: "Audio is in iCloud"
        case .recordingDeleted: "Recording deleted"
        case .noClip: "No clip saved"
        }
    }
}
