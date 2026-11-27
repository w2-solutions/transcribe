import Foundation
import TranscribeCore

/// The words of the iCloud section in Settings, its sheets and banners, and the Mac sidebar footer (§8.6).
public enum SyncCopy {
    public static let toggleTitle = "Sync with iCloud"

    /// Under the iCloud card, whether sync is on or off: what syncs, how audio moves, and how voices behave. `audio` is
    /// this device's "Sync audio" switch (its stored value, also while sync is off).
    public static func explanation(audio: Bool, platform: DevicePlatform) -> String {
        let speech = "Speech is still processed on each device. A voice learned on another device is asked about first (\"Is this Karan?\") until you confirm it here."
        guard audio else {
            return "Transcripts, speaker labels, folders and voice profiles sync through your private iCloud. With Sync audio off, this \(platform.noun) doesn't upload or download audio, and audio already in iCloud stays there. " + speech
        }
        let start = "Transcripts, audio, speaker labels, folders and voice profiles sync through your private iCloud."
        if platform == .mac {
            return start + " Audio moves on Wi-Fi or Ethernet as a compressed copy, about 15 MB an hour, and counts towards your iCloud storage. " + speech
        }
        return start + " Audio moves on Wi-Fi as a compressed copy, about 15 MB an hour, and counts towards your iCloud storage. This \(platform.noun) downloads the last 30 days of audio by itself, and older audio when you open a recording. " + speech
    }

    // MARK: Audio

    /// The "Sync audio" switch, under "Sync with iCloud".
    public static let audioToggleTitle = "Sync audio"
    /// Runs the audio left once, on any network and in Low Power Mode; shown while audio waits for either.
    public static let audioNow = "Sync Audio Now"

    /// The audio status line under the sync status, first match wins: why audio work waits, else what is left, else
    /// "Audio up to date"; then a second line when recordings are too long to sync their audio. Settings shows it only
    /// while sync and Sync audio are both on (the summary alone cannot tell), so it never returns nil today.
    public static func audioStatusLine(_ summary: AudioSyncSummary, platform: DevicePlatform) -> String? {
        let left = summary.uploadsLeft + summary.downloadsLeft
        let line: String
        switch summary.wait {
        case .removalFailed: line = "Audio uploads paused until the iCloud copy is removed"
        case .iCloudFull: line = "Audio uploads paused: iCloud storage is full."
        case .lowStorage: line = "Audio downloads paused: \(platform.noun) storage is low"
        case .network:
            line = "Audio waits for \(platform == .mac ? "Wi-Fi or Ethernet" : "Wi-Fi") · \(recordings(left))"
        case .lowPower: line = "Audio waits while Low Power Mode is on · \(recordings(left))"
        case .busy: line = "Audio uploads wait until recording and processing finish"
        case nil:
            switch (summary.uploadsLeft > 0, summary.downloadsLeft > 0) {
            case (true, true): line = "Syncing audio · \(recordings(left)) left"
            case (true, false): line = "Uploading audio · \(recordings(summary.uploadsLeft)) left"
            case (false, true): line = "Downloading audio · \(recordings(summary.downloadsLeft)) left"
            case (false, false): line = "Audio up to date"
            }
        }
        switch summary.tooLong {
        case ...0: return line
        case 1: return line + "\n1 recording is too long to sync its audio"
        default: return line + "\n\(summary.tooLong) recordings are too long to sync their audio"
        }
    }

    /// Under "iCloud storage is full" while sync is paused for it: how much of that storage synced audio uses (the
    /// known markers' sizes). Nil when no audio is known to be in iCloud.
    public static func quotaAudioLine(bytes: Int64) -> String? {
        bytes > 0 ? "Synced audio uses about \(AudioCopy.size(bytes)) of your iCloud storage." : nil
    }

    /// The one-time notice on the Library for a device that already synced before audio did.
    public static let audioIntroTitle = "Audio now syncs with iCloud"
    public static let audioIntroTurnOff = "Turn Off"
    public static let audioIntroOK = "OK"

    /// The notice's body: the audio this device is about to upload (`uploads`, about `bytes`), or, with nothing to
    /// upload, that the other devices' audio downloads.
    public static func audioIntroBody(uploads: Int, bytes: Int64, platform: DevicePlatform) -> String {
        let storage = "It counts towards your iCloud storage."
        guard uploads > 0 else {
            return "Audio from your other devices downloads on \(platform == .mac ? "Wi-Fi or Ethernet" : "Wi-Fi"). " + storage
        }
        let what = "Uploading the audio of \(recordings(uploads)) (about \(AudioCopy.size(bytes)))"
        return platform == .mac
            ? what + " on Wi-Fi or Ethernet. " + storage
            : what + " on Wi-Fi while Transcribe is open. " + storage
    }

    /// "1 recording", "3 recordings".
    static func recordings(_ n: Int) -> String { n == 1 ? "1 recording" : "\(n) recordings" }

    /// The status line, or nil when sync is off.
    /// With a `problem` (and sync not off), its message follows on a second line.
    public static func statusLine(_ status: SyncStatus, now: Date, heldDeletes: Int = 0, problem: SyncProblem?) -> String? {
        guard let line = statusLine(status, now: now, heldDeletes: heldDeletes) else { return nil }
        guard let problem else { return line }
        return line + "\nLast problem \(ago(problem.at, now: now)): \(problem.message)"
    }

    public static func statusLine(_ status: SyncStatus, now: Date, heldDeletes: Int = 0) -> String? {
        switch status {
        case .off: nil
        case .joining(let message): message
        case .idle(let last): last.map { "Up to date · \(ago($0, now: now))" } ?? "Up to date"
        case .syncing(let pending): "Waiting to upload \(pending) \(pending == 1 ? "item" : "items")"
        case .paused(let reason): pausedLine(reason, heldDeletes: heldDeletes)
        }
    }

    static func pausedLine(_ reason: SyncPauseReason, heldDeletes: Int) -> String {
        switch reason {
        case .noAccount: "Not signed in to iCloud"
        case .quotaFull: "iCloud storage is full"
        case .needsUpdate: "Paused: update Transcribe"
        case .zoneRemoved: zoneRemoved
        case .accountChanged: "Paused: a different iCloud account is signed in"
        case .massDelete:
            heldDeletes > 0 ? "Paused: \(heldDeletes) \(heldDeletes == 1 ? "item was" : "items were") deleted here" : "Sync paused"
        case .restricted: "Sync paused"
        }
    }

    public static let zoneRemoved = "The iCloud copy was removed on another device. Turn sync on again to upload this device's library."

    /// The Mac sidebar footer: a short status, or the plain privacy line when sync is off.
    public static func footer(_ status: SyncStatus, copy: DeviceCopy) -> String {
        switch status {
        case .off: copy.sidebarFooter
        case .idle: copy.sidebarFooter
        case .joining, .syncing: "Syncing with iCloud…"
        case .paused(let reason):
            switch reason {
            case .noAccount: "Not signed in to iCloud"
            case .quotaFull: "iCloud storage is full"
            case .needsUpdate: "Update Transcribe to sync"
            default: "iCloud sync paused"
            }
        }
    }

    /// "Up to date · just now / 2 min ago / 3 h ago / 18 Nov"
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        return DisplayFormat.dayMonth(date)
    }

    // MARK: Leaving sync

    public static let leaveTitle = "Turn off iCloud sync?"
    public static let leaveKeep = "Keep the iCloud Copy"
    public static let leaveRemove = "Also Remove from iCloud"

    /// The leave dialog's message. `cloudOnly`: ready recordings here whose audio is only in iCloud
    /// (`AudioSync.cloudOnlyCount`), which "Also Remove from iCloud" would delete. `availability`
    /// (`AudioSync.downloadAvailability`): with Sync audio off the count is not known, so it says audio may be only in
    /// iCloud; while sync is paused, Download Audio First is not offered, so it says when the audio can download.
    public static func leaveMessage(cloudOnly: Int, platform: DevicePlatform,
                                    availability: AudioDownloadAvailability = .available) -> String {
        let others = "Your other devices keep syncing with the iCloud copy unless you remove it."
        if availability == .syncAudioOff {
            return "This device keeps its library and its audio either way. " + audioOffHere(platform) + " " + others
        }
        guard cloudOnly > 0 else { return "This device keeps its library and its audio either way. " + others }
        return "This device keeps its library either way. The audio of \(recordings(cloudOnly)) is only in iCloud: removing the iCloud copy deletes it. "
            + (availability == .syncPaused ? resumes + " " : "") + others
    }

    public static let removeTitle = "Remove the iCloud copy?"
    public static let removeConfirm = "Remove iCloud Copy"

    /// The remove dialog's message; names the audio that is only in iCloud (`cloudOnly`), which the removal deletes.
    /// `availability` as for `leaveMessage`.
    public static func removeMessage(cloudOnly: Int, platform: DevicePlatform,
                                     availability: AudioDownloadAvailability = .available) -> String {
        let keeps: String
        if availability == .syncAudioOff {
            keeps = "This device keeps its library and its audio. " + audioOffHere(platform)
        } else if cloudOnly > 0 {
            keeps = "This device keeps its library. The audio of \(recordings(cloudOnly)) is only in iCloud and isn't on this \(platform.noun): removing the iCloud copy deletes it."
                + (availability == .syncPaused ? " " + resumes : "")
        } else {
            keeps = "This device keeps its library and its audio."
        }
        return "Transcripts, audio and voices are deleted from iCloud, and sync turns off on this device. " + keeps
            + " Your other devices keep theirs but stop syncing until sync is turned on there again."
    }

    /// Sync audio is off here: what this device does not know about, and how to fetch it.
    private static func audioOffHere(_ platform: DevicePlatform) -> String {
        "Sync audio is off on this \(platform.noun), so audio from your other devices may be only in iCloud: removing the iCloud copy deletes it. Turn on Sync audio to download it first."
    }

    /// Sync is paused: Download Audio First would wait, so it is not offered.
    private static let resumes = "It can download once sync resumes."

    /// The remove and leave dialogs' extra button while some audio is only in iCloud: downloads it on any network,
    /// closes the dialog and leaves sync on.
    public static let downloadAudioFirst = "Download Audio First"

    /// A removal of the iCloud copy failed. Deletes are not atomic, so some audio may already be gone.
    public static let removeFailed = "Couldn't remove the iCloud copy. Some audio may already have been removed. Check your connection and try again."

    // MARK: Account change and mass delete

    public static let accountTitle = "A different iCloud account is signed in"
    public static let accountMessage = "This library was synced with another Apple Account. Nothing is uploaded to this one unless you choose to add it."
    public static let accountMerge = "Add This Library to This Account"
    public static let accountKeepPaused = "Keep Sync Paused"

    public static func massDeleteTitle(_ n: Int) -> String { "\(n) items are missing from this device" }
    public static let massDeleteMessage = "They are still in iCloud and on your other devices. Removing them deletes them everywhere."
    public static func massDeleteConfirm(_ n: Int) -> String { "Remove \(n) Items from iCloud" }
    public static let massDeleteRestore = "Restore Them from iCloud"

    // MARK: Voices banners

    public static func duplicateTitle(_ name: String) -> String { "\(name) appears twice. Merge?" }
    public static let duplicateMessage = "Two devices each saved a voice with this name. Merge them if they are the same person."
    public static let updateOtherDevices = "Update Transcribe on your other devices. One of them uses a different voice model, so voices learned there can't be matched here."
}
