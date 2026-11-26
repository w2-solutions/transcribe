import Foundation

/// Audio sync's fixed numbers and pure rules (§2 decisions 3–7, 11, 13). No state, no I/O.
public enum AudioPolicy {
    /// The iPhone and iPad download by themselves only audio of recordings made in the last 30 days.
    public static let iPhoneAutoWindow: TimeInterval = 30 * 86_400
    /// Free space an automatic download leaves (opportunistic capacity ≥ file + 1 GB).
    public static let autoReserveBytes: Int64 = 1_000_000_000
    /// Free space Download Now leaves (important capacity ≥ file + 300 MB).
    public static let demandReserveBytes: Int64 = 300_000_000
    /// Free space an encode leaves before an upload (important capacity ≥ estimate + 300 MB).
    public static let encodeReserveBytes: Int64 = 300_000_000
    /// AAC-LC at 32 kbit/s: about 4,000 bytes a second (14.4 MB an hour).
    public static let bytesPerSecondEstimate: Double = 4_000
    /// The largest blob this build uploads (≈ 13.9 h of AAC).
    public static let maxUploadBytes: Int64 = 200_000_000
    /// Retry waits per recording after 1, 2, 3 and 4 or more failures in a row: 1 min, 10 min, 1 h, then every 6 h.
    public static let backoff: [TimeInterval] = [60, 600, 3_600, 21_600]
    /// How long an audio upload refused for a full iCloud blocks audio uploads.
    public static let quotaRetry: TimeInterval = 86_400
    /// The orphan sweep never deletes a blob created less than a day ago.
    public static let orphanMinimumAge: TimeInterval = 86_400
    /// How often the orphan sweep runs; also the wait before the first sweep.
    public static let sweepInterval: TimeInterval = 7 * 86_400
    public static let maxNotFoundMarkerDeletesPerLaunch = 25
    public static let maxUploadsPerRecordingPerLaunch = 3
    /// The launch probe asks again after a transient error (with the backoff above); after this many failures in a
    /// row it reads those recordings as absent for the launch.
    public static let launchProbeTries = 3
    /// Ids per CloudKit request.
    public static let batch = 200

    /// Whether a recording's audio downloads without being asked: always on the Mac; on the iPhone and iPad only
    /// for recordings made in the last `iPhoneAutoWindow` (a recording dated in the future counts as recent).
    public static func autoDownloads(platform: DevicePlatform, createdAt: Date, now: Date) -> Bool {
        switch platform {
        case .mac: true
        case .iPhone, .iPad: now.timeIntervalSince(createdAt) <= iPhoneAutoWindow
        }
    }

    /// nil = automatic work may run; else why it waits: `.network` for a metered, constrained or missing network
    /// (checked first), `.lowPower` in Low Power Mode.
    public static func automaticWait(network: NetworkKind, lowPower: Bool) -> AudioDownloadWait? {
        if network != .unmetered { return .network }
        if lowPower { return .lowPower }
        return nil
    }

    /// Room for `bytes` more: `free` must cover them plus the reserve (1 GB automatic, 300 MB when the user asked).
    /// An unknown `free` (nil) counts as room.
    public static func hasRoom(free: Int64?, bytes: Int64, userInitiated: Bool) -> Bool {
        guard let free else { return true }
        let reserve = userInitiated ? demandReserveBytes : autoReserveBytes
        return free >= max(0, bytes) + reserve
    }

    /// The wait after `failures` failures in a row (0 → none).
    public static func backoffDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return backoff[min(failures, backoff.count) - 1]
    }

    /// The expected size of a recording's AAC copy (`duration` × 4,000, rounded); used before encoding, for the
    /// too-long check, the free-space check and the one-time notice.
    public static func estimatedBytes(duration: TimeInterval) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int64((duration * bytesPerSecondEstimate).rounded())
    }
}
