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
    /// Sync and this device's "Sync audio" are both on, so audio moves through iCloud too. Always false while sync is
    /// off (the switch acts only while sync is on).
    public var audioSyncOn: Bool

    public init(platform: DevicePlatform = .current, syncOn: Bool = false, cloudCopyKept: Bool = false, claudeOn: Bool = false,
                updatesAvailable: Bool = false, audioSyncOn: Bool = false) {
        self.platform = platform
        self.syncOn = syncOn
        self.cloudCopyKept = cloudCopyKept && !syncOn
        self.claudeOn = claudeOn
        self.updatesAvailable = updatesAvailable
        self.audioSyncOn = audioSyncOn && syncOn
    }

    private var noun: String { platform.noun }
    private var isMac: Bool { platform == .mac }

    // MARK: Package strings

    /// Processing panel, while running.
    public var processingDefault: String {
        isMac ? "This happens on your Mac. You can keep working." : "This happens on your \(noun). You can leave and come back."
    }

    /// Processing panel, while the speech models are not ready.
    public var processingModels: String {
        "Transcribe is getting ready on this \(noun). This recording is processed as soon as setup finishes."
    }

    /// Processing panel, when setup failed while this recording waits for it (the panel shows Try again).
    public var processingModelsFailed: String {
        "Transcribe couldn't get ready on this \(noun), so this recording is still waiting. \(isMac ? "Click" : "Tap") Try again to finish setup."
    }

    /// Processing panel's leave button. On iPhone it goes back to the list, and a recording waiting for setup is not
    /// processed in the background (setup itself carries on only for a short while there), so it says where it goes
    /// rather than promising background work. On the Mac it folds the panel away and processing carries on.
    public func processingLeaveButton(waitingForSetup: Bool) -> String {
        waitingForSetup && !isMac ? "Back to Recordings" : "Continue in background"
    }

    // MARK: Setup (the speech models getting ready after an install or update)

    /// Setup card and Speech models screen: the headline while setting up.
    public var setupHeadline: String { "Getting ready on this \(noun)" }

    /// The headline once setup has finished (shown briefly before the card goes).
    public var setupReadyHeadline: String { "Ready on this \(noun)" }

    /// Why setup is happening.
    public var setupOnce: String { "This happens once after installing or updating." }

    /// What the user can do meanwhile.
    public var setupRecordNow: String { "You can record now. Recordings are processed when setup finishes." }

    /// Under the bar on a first install, when this device has no times of its own yet (never a time left). No
    /// number: an iPhone 15 takes about 20 s, other iPhones and the Mac have not been measured.
    public var setupTypicalTime: String { "This can take a little while." }

    /// While setup runs on the iPhone. True with and without Background Inference (`TranscribeBackgroundInference`):
    /// with it, setup carries on for iOS's short allowance (about 27 s) after the user leaves and finishes the rest on
    /// return; without it, it pauses once the step running then ends. Either way it may pause, and it finishes when
    /// the app is opened again. Nil on the Mac, which never pauses it.
    public var setupKeepOpen: String? {
        isMac ? nil : "If you leave Transcribe, setup may pause after a short while. It finishes when you come back."
    }

    /// Recordings made during setup wait for it.
    public func setupWaiting(count: Int) -> String {
        count == 1 ? "1 recording will be processed when setup finishes."
            : "\(count) recordings will be processed when setup finishes."
    }

    /// Setup paused while the app is in the background (iPhone).
    public var setupPaused: String { "Paused while Transcribe is in the background. It carries on when you open it." }

    /// Back after leaving the app mid-setup.
    public var setupResumed: String { "Carrying on where it left off." }

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

    /// The transcript's audio banner (audio sync §1.3): where the recording's audio is and what happens next, with the
    /// one button that can help. Nil when the audio is here.
    public func audioBanner(_ state: RecordingAudioState) -> AudioBannerCopy? {
        switch state {
        case .local:
            return nil
        case .checking:
            return AudioBannerCopy(text: "Checking iCloud for the audio…")
        case .downloading(let fraction):
            guard let fraction else { return AudioBannerCopy(text: "Downloading audio…") }
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            return AudioBannerCopy(text: "Downloading audio… \(percent)%")
        case .inICloud(let bytes, let wait):
            let size = AudioCopy.size(bytes)
            switch wait {
            case .queued:
                return AudioBannerCopy(text: "Audio is in iCloud (\(size)) and downloads shortly.", action: .downloadNow)
            case .network:
                return AudioBannerCopy(text: "Audio is in iCloud (\(size)). It downloads on \(unmeteredNetwork).",
                                       action: .downloadNow)
            case .lowPower:
                return AudioBannerCopy(text: "Audio is in iCloud (\(size)). It downloads when Low Power Mode is off.",
                                       action: .downloadNow)
            case .lowStorage:
                return AudioBannerCopy(text: "There isn't enough storage on this \(noun) to download the audio (\(size)).",
                                       action: .tryAgain)
            case .syncPaused:
                return AudioBannerCopy(text: "Audio is in iCloud (\(size)). It downloads when iCloud sync resumes.")
            }
        case .failed:
            return AudioBannerCopy(text: "Couldn't download the audio. Check your connection and try again.", action: .tryAgain)
        case .notInICloud(let channel):
            return AudioBannerCopy(text: notInICloud(channel: channel))
        case .syncAudioOffHere(inICloud: true, _):
            return AudioBannerCopy(text: "Audio is in iCloud. Turn on Sync audio in Settings to play it here.")
        case .syncAudioOffHere(inICloud: false, let channel):
            return AudioBannerCopy(text: "Audio is on \(recordedOn(channel)). Sync audio is off on this \(noun).")
        case .syncOffHere(let channel):
            return AudioBannerCopy(text: "Audio is on \(recordedOn(channel)). Sync is off on this \(noun).")
        case .needsUpdate:
            return AudioBannerCopy(text: "Update Transcribe to play this audio.")
        }
    }

    /// The network automatic transfers wait for on this device: "Wi-Fi", or "Wi-Fi or Ethernet" on the Mac.
    private var unmeteredNetwork: String { isMac ? "Wi-Fi or Ethernet" : "Wi-Fi" }

    /// The device that recorded a recording (its capture `channel`): "your iPhone", "your other Mac" when it was
    /// another device of this kind, and "the device that recorded it" when the channel is unknown.
    private func recordedOn(_ channel: String?) -> String {
        guard let other = DevicePlatform(channel: channel) else { return "the device that recorded it" }
        return other == platform ? "your other \(other.noun)" : "your \(other.noun)"
    }

    /// `.notInICloud`: the audio is still on the recording device, and when that device uploads it. An iPhone or iPad
    /// uploads only on Wi-Fi; the Mac's network is not named.
    private func notInICloud(channel: String?) -> String {
        guard let other = DevicePlatform(channel: channel) else {
            return "Audio is on the device that recorded it and isn't in iCloud yet."
        }
        let wifi = other == .mac ? "" : ", on Wi-Fi,"
        if other == platform {
            return "Audio is on your other \(other.noun) and isn't in iCloud yet. It uploads when Transcribe is open there\(wifi) with Sync audio on."
        }
        return "Audio is on your \(other.noun) and isn't in iCloud yet. It uploads when Transcribe is open on your \(other.noun)\(wifi) with Sync audio on."
    }

    /// A voice sample whose clip is in a recording whose audio is not on this device and not known to be in iCloud
    /// (not uploaded yet, or not syncing here), in the place of its waveform; `channel` is the recording's: "Audio is on your iPad", "Audio is on your other Mac" when it was another device of
    /// this kind, and "Audio is on another device" when the channel is unknown.
    public func sampleAudioElsewhere(channel: String?) -> String {
        guard let other = DevicePlatform(channel: channel) else { return "Audio is on another device" }
        return other == platform ? "Audio is on your other \(other.noun)" : "Audio is on your \(other.noun)"
    }

    /// Settings → Acknowledgements, first line.
    public var attributionsIntro: String { "Transcribe runs these models and libraries on your \(noun)." }

    /// Settings → Privacy row value.
    public var privacyValue: String {
        if audioSyncOn || cloudCopyKept { return "This \(noun) and your iCloud" }
        return syncOn || claudeOn ? "Audio on this \(noun) only" : "On this \(noun) only"
    }

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
            let base = audioSyncOn
                ? "Audio, transcripts, speaker labels, folders and voice profiles sync through your private iCloud. Speech is processed on each device."
                : "Transcripts, speaker labels, folders and voice profiles sync through your private iCloud. With Sync audio off, new audio stays on this \(noun); any audio synced earlier stays in your private iCloud until you remove it. Speech is processed on each device."
            if claudeOn { return base + claudeLine + updateLine + " Transcribe shares nothing else." }
            if isMac { return base + updateLine + " Nothing is shared with anyone else." }
            // The iPhone cannot see the Mac's switch, and synced transcripts can be read there.
            return base + " If you let Claude read transcripts on your Mac, synced transcripts can be read there too."
        }
        if cloudCopyKept {
            return "Sync is off. Transcripts, speaker labels, folders, voice profiles and any audio synced earlier remain in your private iCloud and on your other devices until you remove them."
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

    /// Microphone denied sheet. While audio syncs, or audio synced earlier is still in iCloud, it does not claim that
    /// audio stays here.
    public var micDeniedBody: String {
        audioSyncOn || cloudCopyKept
            ? "Transcribe needs the microphone to record. Speech is processed on this \(noun)."
            : "Transcribe needs the microphone to record. Audio stays on this \(noun)."
    }

    /// Delete confirmation title on a transcript.
    public var deleteTranscriptTitle: String { syncOn ? "Delete from all your devices?" : "Delete this recording?" }

    /// Delete confirmation on a transcript.
    public var deleteTranscriptMessage: String {
        syncOn
            ? "The transcript and its audio are removed from all your devices and from iCloud. Saved voices are kept."
            : "The audio and transcript are removed from this \(noun). Saved voices are kept."
    }

    /// Delete confirmation title in the Library.
    public var deleteRecordingTitle: String { syncOn ? "Delete from all your devices?" : "Delete recording?" }

    /// Delete confirmation in the Library.
    public var deleteRecordingMessage: String {
        syncOn
            ? "The transcript and its audio are removed from all your devices and from iCloud."
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

/// The transcript's audio banner: its text and its one button, if any.
public struct AudioBannerCopy: Equatable, Sendable {
    public var text: String
    public var action: AudioBannerAction?

    public init(text: String, action: AudioBannerAction? = nil) {
        self.text = text
        self.action = action
    }
}

/// The audio banner's button. Both download the recording's audio now, on any network (`AudioSync.downloadNow`).
public enum AudioBannerAction: String, Sendable {
    case downloadNow, tryAgain

    public var title: String {
        switch self {
        case .downloadNow: "Download Now"
        case .tryAgain: "Try Again"
        }
    }
}

/// Wording shared by the audio banner and the iCloud settings.
public enum AudioCopy {
    /// A transfer size: "under 1 MB", "14 MB" (whole megabytes, rounded) below 1 GB, then "1.7 GB" (one decimal, always
    /// a full stop). Decimal units, as iCloud storage is shown.
    public static func size(_ bytes: Int64) -> String {
        if bytes < 1_000_000 { return "under 1 MB" }
        if bytes < 1_000_000_000 { return "\(Int((Double(bytes) / 1e6).rounded())) MB" }
        return String(format: "%.1f GB", Double(bytes) / 1e9)
    }
}
