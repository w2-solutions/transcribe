import Foundation

/// Whether Download Audio First can download now (the remove and leave dialogs offer it only then, and say why not).
public enum AudioDownloadAvailability: Equatable, Sendable {
    case available
    /// Sync audio is off on this device: nothing downloads, and audio recorded elsewhere may be only in iCloud
    /// (markers a 0.3.3 build dropped are learnt only by the launch probe, which runs with Sync audio on).
    case syncAudioOff
    /// iCloud sync is paused or not running here (an iCloud that is full, say).
    case syncPaused
}

/// Why a download that could run waits.
public enum AudioDownloadWait: String, Equatable, Sendable {
    /// It runs shortly (it is in the queue).
    case queued
    /// Automatic downloads need Wi-Fi or Ethernet.
    case network
    /// Automatic downloads wait while Low Power Mode is on.
    case lowPower
    /// The last free-space check failed.
    case lowStorage
    /// iCloud sync is not running here (paused, or not started yet).
    case syncPaused
}

/// Where one recording's audio is, as this device sees it; drives the transcript banner and the voice sample clips.
public enum RecordingAudioState: Equatable, Sendable {
    /// The file is on this device.
    case local
    /// No marker row yet and this launch's probe has not answered for it (decision 23).
    case checking
    case downloading(fraction: Double?)
    case inICloud(bytes: Int64, wait: AudioDownloadWait)
    case failed(bytes: Int64)
    /// Not in iCloud (yet): `channel` is the capture channel of the device that recorded it.
    case notInICloud(channel: String?)
    case syncAudioOffHere(inICloud: Bool, channel: String?)
    case syncOffHere(channel: String?)
    /// A marker from a later build (a higher `sv`, a newer row, or a format this build cannot play).
    case needsUpdate

    public var canPlay: Bool { self == .local }

    /// The pure decision, first match wins (§3.5 "State for views"):
    /// 1. a local file → `.local`;
    /// 2. sync off here → `.syncOffHere`;
    /// 3. a known marker (not being deleted) with `version > 1` or a format this build cannot play → `.needsUpdate`;
    /// 4. no marker, or one being deleted → `.notInICloud` once `probed` (else `.checking`) with Sync audio on,
    ///    `.syncAudioOffHere(inICloud: false)` with it off;
    /// 5. Sync audio off → `.syncAudioOffHere(inICloud: true)`;
    /// 6. downloading → `.downloading(fraction)`;
    /// 7. the last download failed → `.failed(bytes)`;
    /// 8. sync not running (or paused) → `.inICloud(bytes, .syncPaused)`;
    /// 9. else `.inICloud(bytes, wait)`.
    ///
    /// `marker` is the known marker's descriptor and version, if any (a row from a newer build is passed with a
    /// version above 1). `probed`: this launch's probe has answered for this recording (only read when there is no
    /// marker row, or it is being deleted).
    public static func resolve(hasLocalFile: Bool, syncOn: Bool, syncRunning: Bool, audioOn: Bool,
                               marker: (descriptor: AudioDescriptor, version: Int64, deleting: Bool)?,
                               probed: Bool, downloading: Bool, fraction: Double?, failed: Bool,
                               wait: AudioDownloadWait, channel: String?) -> RecordingAudioState {
        if hasLocalFile { return .local }
        if !syncOn { return .syncOffHere(channel: channel) }
        if let m = marker, !m.deleting, m.version > SyncSchema.version || !m.descriptor.format.isPlayable {
            return .needsUpdate
        }
        guard let m = marker, !m.deleting else {
            guard audioOn else { return .syncAudioOffHere(inICloud: false, channel: channel) }
            return probed ? .notInICloud(channel: channel) : .checking
        }
        guard audioOn else { return .syncAudioOffHere(inICloud: true, channel: channel) }
        if downloading { return .downloading(fraction: fraction) }
        if failed { return .failed(bytes: m.descriptor.bytes) }
        guard syncRunning else { return .inICloud(bytes: m.descriptor.bytes, wait: .syncPaused) }
        return .inICloud(bytes: m.descriptor.bytes, wait: wait)
    }

    /// For builds or runs without `AudioSync` (no transport): `.local`, or `.syncOffHere(channel)`.
    public static func withoutAudioSync(hasLocalFile: Bool, channel: String?) -> RecordingAudioState {
        hasLocalFile ? .local : .syncOffHere(channel: channel)
    }
}

/// Why audio work that is left does not run (Settings' audio status line), in precedence order.
public enum AudioWait: String, Equatable, Sendable {
    /// Remove iCloud Copy failed: this device uploads nothing until it succeeds or the app relaunches.
    case removalFailed
    /// An audio upload was refused for a full iCloud (24 h, Sync Now or a relaunch).
    case iCloudFull
    case lowStorage
    /// Automatic transfers need Wi-Fi or Ethernet.
    case network
    case lowPower
    /// Uploads wait while a recording is captured or processed.
    case busy
}

/// What audio work this device has left, for Settings and the one-time notice.
public struct AudioSyncSummary: Equatable, Sendable {
    public var uploadsLeft = 0, downloadsLeft = 0, tooLong = 0
    /// Estimate (duration × 4,000) of the uploads left, for the notice.
    public var uploadBytesLeft: Int64 = 0
    public var wait: AudioWait?

    public init(uploadsLeft: Int = 0, downloadsLeft: Int = 0, tooLong: Int = 0, uploadBytesLeft: Int64 = 0,
                wait: AudioWait? = nil) {
        self.uploadsLeft = uploadsLeft; self.downloadsLeft = downloadsLeft; self.tooLong = tooLong
        self.uploadBytesLeft = uploadBytesLeft; self.wait = wait
    }
}
