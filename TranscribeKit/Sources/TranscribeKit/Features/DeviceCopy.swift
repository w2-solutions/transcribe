import Foundation

/// The kind of device the app runs on, for user-facing wording ("this iPhone", "this Mac").
public enum DevicePlatform: String, Sendable, Codable, CaseIterable {
    case iPhone, iPad, mac

    /// The platform this build runs on. `swift test` runs on a Mac host, where this is `.mac`, so tests that check
    /// iPhone wording pass `.iPhone` explicitly.
    public static let current: DevicePlatform = {
        #if os(macOS)
        .mac
        #else
        .iPhone
        #endif
    }()

    /// "iPhone", "iPad" or "Mac".
    public var noun: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .mac: "Mac"
        }
    }

    /// The platform of a capture channel ("iphone", "ipad", "mac"); nil for anything else.
    public init?(channel: String?) {
        switch channel {
        case "iphone": self = .iPhone
        case "ipad": self = .iPad
        case "mac": self = .mac
        default: return nil
        }
    }
}

/// Every user-facing string that names the device or a touch gesture. Shared code never spells out "iPhone"
/// itself: it asks this type, so the Mac app says "this Mac" and "Click", and sync can change the privacy wording.
public struct DeviceCopy: Sendable, Equatable {
    public var platform: DevicePlatform
    public var syncOn: Bool
    /// Sync is off but an iCloud copy was kept ("Keep the iCloud Copy"): transcripts and voices synced earlier are still
    /// in iCloud and on the other devices. Ignored while sync is on.
    public var cloudCopyKept: Bool
    /// Mac only: "Let Claude read transcripts" is on, so no privacy line may claim that nothing is shared (D20).
    public var claudeOn: Bool
    /// Mac only: the Sparkle updater runs in this build, so the privacy wording says the app contacts w2solutions.ai
    /// for updates. Ignored on the iPhone.
    public var updatesAvailable: Bool

    public init(platform: DevicePlatform = .current, syncOn: Bool = false, cloudCopyKept: Bool = false, claudeOn: Bool = false,
                updatesAvailable: Bool = false) {
        self.platform = platform
        self.syncOn = syncOn
        self.cloudCopyKept = cloudCopyKept && !syncOn
        self.claudeOn = claudeOn
        self.updatesAvailable = updatesAvailable
    }

    private var noun: String { platform.noun }
    private var isMac: Bool { platform == .mac }

    // MARK: Package strings

    /// Processing panel, while running.
    public var processingDefault: String {
        isMac ? "This happens on your Mac. You can keep working." : "This happens on your \(noun). You can leave and come back."
    }

    /// Processing panel, while the speech models are not ready.
    public var processingModels: String { "Processing starts once the speech models are ready on this \(noun)." }

    /// Library card and Speech models screen, while the models are being prepared.
    public var preparingModels: String { "Preparing for this \(noun)… (after installing or updating, about a minute)" }

    /// Name sheet: the help under "Remember this voice".
    public func rememberHelp(who: String) -> String {
        syncOn
            ? "Saved to your voices and synced with iCloud. Used to label \(who) automatically next time."
            : "Saved on this \(noun) only. Used to label \(who) automatically next time."
    }

    /// Voices list and voice profile: a profile whose embedding model changed.
    public var needsSample: String { "Needs a new sample on this \(noun)" }

    /// Library card preview of the recording still being captured.
    public var capturingPreview: String { "\(isMac ? "Click" : "Tap") to go back to the recording." }

    // MARK: App strings

    /// The privacy note under the Voices list.
    public var voicesFooter: String {
        if syncOn { return "Voice profiles sync with iCloud. Each device learns how a voice sounds through its own microphone." }
        if cloudCopyKept { return "Not syncing. Voice profiles synced earlier remain in your iCloud until you remove them." }
        return isMac
            ? "Voice profiles are stored on this Mac only."
            : "Voice profiles never leave this \(noun). Each device learns voices from its own microphone."
    }

    /// The Mac sidebar's footer.
    public var sidebarFooter: String {
        if syncOn { return claudeOn ? "On-device · synced with iCloud · Claude can read" : "Transcribed on-device · synced with iCloud" }
        if cloudCopyKept {
            return claudeOn ? "Not syncing · a copy remains in iCloud · Claude can read" : "Not syncing. A copy remains in your iCloud."
        }
        return claudeOn ? "On-device. Claude can read transcripts." : "On-device. Nothing is uploaded."
    }

    /// Asking about a voice that was named on another device.
    public func askFromOtherDevice(name: String, other: DevicePlatform) -> String {
        "\(name) was named on your \(other.noun). Each microphone hears a voice a little differently, so Transcribe asks once here. Is this \(name)?"
    }

    /// A synced transcript whose audio stayed on the device that recorded it.
    public func audioElsewhere(other: DevicePlatform) -> String {
        "Audio is on your \(other.noun). The transcript and names are synced; audio stays on the device that recorded it."
    }

    /// `audioElsewhere` for a recording's capture channel: "your other Mac" when it was another device of this kind,
    /// and plain wording when the channel is unknown.
    public func audioElsewhere(channel: String?) -> String {
        guard let other = DevicePlatform(channel: channel) else {
            return "Audio is on the device that recorded it. The transcript and names are synced; audio never syncs."
        }
        guard other == platform else { return audioElsewhere(other: other) }
        return "Audio is on your other \(other.noun). The transcript and names are synced; audio stays on the device that recorded it."
    }

    /// Settings → Acknowledgements, first line.
    public var attributionsIntro: String { "Transcribe runs these models and libraries on your \(noun)." }

    /// Settings → Privacy row value.
    public var privacyValue: String { syncOn || cloudCopyKept || claudeOn ? "Audio on this \(noun) only" : "On this \(noun) only" }

    /// The update sentence of the privacy explanation (Mac with the updater only). It always comes before a branch's
    /// closing absolute ("shares nothing else", "never shared"), never after it.
    private var updateLine: String {
        updatesAvailable && isMac
            ? " Transcribe contacts w2solutions.ai only to check for updates and download them, and sends no recordings, transcripts or names."
            : ""
    }

    /// Settings → Privacy explanation.
    public var privacyDetail: String {
        let claudeLine = " Claude on this Mac can read your transcripts and speaker names, and what it reads is sent to Anthropic."
        if syncOn {
            let base = "Audio stays on this \(noun). Transcripts, speaker labels, folders and voice profiles sync through your private iCloud. Speech is processed on each device."
            if claudeOn { return base + claudeLine + updateLine + " Transcribe shares nothing else." }
            if isMac { return base + updateLine + " Nothing is shared with anyone else." }
            // The iPhone cannot see the Mac's switch, and synced transcripts can be read there.
            return base + " If you let Claude read transcripts on your Mac, synced transcripts can be read there too."
        }
        if cloudCopyKept {
            return "Sync is off. Audio stays on this \(noun). Transcripts, speaker labels, folders and voice profiles synced earlier remain in your private iCloud and on your other devices until you remove them."
                + (claudeOn ? claudeLine : "") + updateLine
        }
        if claudeOn {
            return "Audio, transcripts and voice profiles are stored only on this \(noun)." + claudeLine + updateLine
                + " Audio and voice samples are never shared."
        }
        return "Audio, transcripts and voice profiles are stored only on this \(noun)." + updateLine
            + " Voice profiles are never synced or shared."
    }

    /// The line under the Voices title.
    public var voicesIntro: String {
        syncOn ? "People Transcribe can recognise. Synced with your iCloud."
            : cloudCopyKept ? "People Transcribe can recognise. Not syncing; a copy remains in your iCloud."
            : "People Transcribe can recognise. Stored only on this device."
    }

    /// Speech models screen, intro. On a Mac that updates itself the models do arrive over the network, inside an app
    /// update, so it says that instead of "Nothing is downloaded".
    public var modelsIntro: String {
        updatesAvailable && isMac
            ? "These come with Transcribe. Speech and speakers are processed on this Mac, even offline. They are never downloaded on their own; they change only with an app update."
            : "These come with Transcribe. Speech and speakers are processed on this \(noun), even offline. Nothing is downloaded."
    }

    /// Speech models screen, ready status.
    public var modelsReady: String { "Ready. Everything runs on this \(noun), even offline." }

    /// Recording stopped because storage ran out.
    public var lowStorageStop: String { "Recording stopped — \(noun) storage is almost full" }

    /// Processing panel footnote.
    public var nothingLeaves: String { syncOn || claudeOn ? "Processed on this \(noun)" : "Nothing leaves this \(noun)" }

    /// Microphone denied sheet.
    public var micDeniedBody: String { "Transcribe needs the microphone to record. Audio stays on this \(noun)." }

    /// Delete confirmation title on a transcript.
    public var deleteTranscriptTitle: String { syncOn ? "Delete from all your devices?" : "Delete this recording?" }

    /// Delete confirmation on a transcript.
    public var deleteTranscriptMessage: String {
        syncOn
            ? "The transcript is removed from all your devices, and the audio from the device that recorded it. Saved voices are kept."
            : "The audio and transcript are removed from this \(noun). Saved voices are kept."
    }

    /// Delete confirmation title in the Library.
    public var deleteRecordingTitle: String { syncOn ? "Delete from all your devices?" : "Delete recording?" }

    /// Delete confirmation in the Library.
    public var deleteRecordingMessage: String {
        syncOn
            ? "The transcript is removed from all your devices, and the audio from the device that recorded it."
            : "The audio and transcript are removed from this \(noun)."
    }

    /// "Forget Karan?" confirmation.
    public func forgetVoiceMessage(_ name: String) -> String {
        syncOn ? "\(name) is forgotten on all your devices. Past transcripts keep the name." : "Past transcripts keep the name."
    }

    /// Library empty state.
    public var libraryEmptyHint: String {
        isMac
            ? "Click New Recording to record a conversation. Speakers are separated when you stop."
            : "Tap the red button to record a conversation. Speakers are separated when you stop."
    }

    /// A folder with nothing in it yet.
    public func emptyFolder(_ name: String) -> String {
        "Nothing in \(name) yet. \(isMac ? "Control-click" : "Touch and hold") a recording to move it here."
    }

    /// Voice profile with no recordings.
    public var notInAnyRecording: String { syncOn ? "Not in any recording yet." : "Not in any recording on this \(noun) yet." }
}
