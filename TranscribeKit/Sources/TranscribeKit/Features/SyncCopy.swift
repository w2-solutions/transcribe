import Foundation
import TranscribeCore

/// The words of the iCloud section in Settings, its sheets and banners, and the Mac sidebar footer (§8.6).
public enum SyncCopy {
    public static let toggleTitle = "Sync with iCloud"

    /// Under the switch, whether sync is on or off: what syncs, what never does, and how voices behave.
    public static let explanation = """
        Transcripts, speaker labels, folders and voice profiles sync through your private iCloud. \
        Audio stays on the device that recorded it, and speech is still processed on each device. \
        A voice learned on another device is asked about first ("Is this Karan?") until you confirm it here.
        """

    /// The status line, or nil when sync is off.
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
    public static let leaveMessage = "This device keeps its library either way. Your other devices keep syncing with the iCloud copy unless you remove it."
    public static let leaveKeep = "Keep the iCloud Copy"
    public static let leaveRemove = "Also Remove from iCloud"

    public static let removeTitle = "Remove the iCloud copy?"
    public static let removeMessage = "Transcripts and voices are deleted from iCloud, and sync turns off on this device. This device keeps its library. Your other devices keep theirs but stop syncing until sync is turned on there again."
    public static let removeConfirm = "Remove iCloud Copy"

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
