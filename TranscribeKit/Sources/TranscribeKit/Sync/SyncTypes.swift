import Foundation

// Sync value types (§8.1). No CloudKit import in this folder: only `TranscribeCloudKit` imports CloudKit.
//
// Stage 5 adds only `SyncRecordType`, which the V3 model `SyncRecordState` needs. Stage 7 adds the rest of §8.1
// (`SyncRecordID`, `SyncValue`, `SyncRecord`, `SyncPauseReason`, `SyncStatus`) to this file.

/// The record types in the `Library` zone. The raw value is the CloudKit record type and is stored in
/// `SyncRecordState.typeRaw`, so it must never change.
public enum SyncRecordType: String, CaseIterable, Sendable {
    case recording = "Recording", speaker = "Speaker", profile = "VoiceProfile", sample = "VoiceSample",
         negative = "VoiceNegative", folder = "Folder"

    /// The record-name prefix: "<prefix>.<UUID>".
    public var prefix: String {
        switch self {
        case .recording: "rec"
        case .speaker: "spk"
        case .profile: "vp"
        case .sample: "vs"
        case .negative: "vn"
        case .folder: "fd"
        }
    }
}
