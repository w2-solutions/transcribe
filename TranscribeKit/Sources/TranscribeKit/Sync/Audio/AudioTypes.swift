import Foundation

// Audio sync value types (§3.3). No CloudKit import in this folder: only `TranscribeCloudKit` imports CloudKit.

/// What a transferred audio file is: codec, sample rate and channels ("aac-lc/16000/1"), never a container or a
/// bit rate, so a device can describe a copy it downloaded.
public struct AudioFormat: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// AAC-LC, 16 kHz, mono, in `.m4a`: what the app uploads.
    public static let aac16kMono = AudioFormat(rawValue: "aac-lc/16000/1")
    /// 16-bit PCM, 16 kHz, mono, in `.wav` (fakes and tests).
    public static let pcm16kMono = AudioFormat(rawValue: "pcm-s16le/16000/1")

    /// "m4a" for aac-lc/…, "wav" for pcm-s16le/…, nil for a format this build cannot play.
    public var fileExtension: String? {
        if rawValue.hasPrefix("aac-lc/") { return "m4a" }
        if rawValue.hasPrefix("pcm-s16le/") { return "wav" }
        return nil
    }

    public var isPlayable: Bool { fileExtension != nil }

    /// From a local file's extension (any case): m4a → aac16kMono, wav → pcm16kMono; anything else → nil.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "m4a": self = .aac16kMono
        case "wav": self = .pcm16kMono
        default: return nil
        }
    }
}

/// One recording's transferred audio: what the marker and the blob both say about it.
public struct AudioDescriptor: Codable, Equatable, Sendable {
    public var recordingID: UUID
    public var format: AudioFormat
    public var bytes: Int64
    /// Lowercase hex SHA-256 of the transfer file. Never logged (it fingerprints content).
    public var sha256: String
    /// Seconds.
    public var duration: Double

    public init(recordingID: UUID, format: AudioFormat, bytes: Int64, sha256: String, duration: Double) {
        self.recordingID = recordingID; self.format = format; self.bytes = bytes; self.sha256 = sha256
        self.duration = duration
    }
}

/// What iCloud holds for one recording's audio blob.
public enum AudioPresence: Equatable, Sendable {
    case present(AudioDescriptor)
    case absent
    /// The blob exists but its encrypted fields cannot be read (after an encrypted-data reset, say).
    case unreadable
}

public enum AudioUploadOutcome: Equatable, Sendable {
    case uploaded
    /// Another device (or an earlier attempt whose reply was lost) stored it first: the server's descriptor.
    case alreadyThere(AudioDescriptor)
}

/// How a transfer runs. Automatic transfers are `.utility` and unmetered only; user-initiated ones (Download Now,
/// Try Again, Sync Audio Now) are `.userInitiated` and may use any network.
public struct AudioTransferOptions: Equatable, Sendable {
    /// QoS `.userInitiated`, else `.utility`.
    public var userInitiated: Bool
    /// `allowsCellularAccess`; false for automatic transfers.
    public var allowsMetered: Bool
    /// `CKOperationGroup.expectedSendSize`/`expectedReceiveSize`, bucketed by the transport.
    public var expectedBytes: Int64

    public init(userInitiated: Bool, allowsMetered: Bool, expectedBytes: Int64) {
        self.userInitiated = userInitiated; self.allowsMetered = allowsMetered; self.expectedBytes = expectedBytes
    }
}

/// One blob in iCloud and when it was created (the listing the orphan sweep and Remove iCloud Copy use).
public struct AudioListing: Equatable, Sendable {
    public var recordingID: UUID
    public var created: Date
    public init(recordingID: UUID, created: Date) { self.recordingID = recordingID; self.created = created }
}

/// Every failure an `AudioTransfer` reports.
public enum AudioTransferError: Error, Equatable, Sendable {
    case noAccount, networkUnavailable, quotaExceeded, notFound, tooLarge, cancelled, indexMissing
    /// `recordingRecordsExist`: the `Library` zone is gone (zoneNotFound/userDeletedZone).
    case zoneMissing
    /// The staged file vanished or changed under the operation (assetFileNotFound / assetFileModified): stage again.
    case sourceChanged
    case retryable(retryAfter: Double?)
    case other(code: Int)
}

/// The `au.<id>` marker as a sync record: "this recording's audio is in iCloud", with the blob's descriptor. It rides
/// in the `Library` zone through the sync engine like any record, write-once and create-only; its record name carries
/// the recording id, so it has no link fields.
public enum AudioMarker {
    public static let groups = ["body": ["bytes", "sha256", "format", "duration"]]

    /// id (.audio, d.recordingID), the four fields and `sv` 1, no system fields.
    public static func record(_ d: AudioDescriptor) -> SyncRecord {
        SyncRecord(id: SyncRecordID(type: .audio, entityID: d.recordingID),
                   fields: ["bytes": .int(d.bytes), "sha256": .string(d.sha256), "format": .string(d.format.rawValue),
                            "duration": .double(d.duration), SyncSchema.versionField: .int(SyncSchema.version)])
    }

    /// The descriptor a marker record carries; nil when it is not a marker or a field is missing or mistyped.
    public static func descriptor(_ r: SyncRecord) -> AudioDescriptor? {
        guard r.id.type == .audio,
              case .int(let bytes)? = r.fields["bytes"],
              case .string(let sha)? = r.fields["sha256"],
              case .string(let format)? = r.fields["format"],
              case .double(let duration)? = r.fields["duration"] else { return nil }
        return AudioDescriptor(recordingID: r.id.entityID, format: AudioFormat(rawValue: format), bytes: bytes,
                               sha256: sha, duration: duration)
    }
}
