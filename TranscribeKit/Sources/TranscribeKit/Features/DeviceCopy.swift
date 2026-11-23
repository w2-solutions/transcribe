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

    public init(platform: DevicePlatform = .current, syncOn: Bool = false) {
        self.platform = platform
        self.syncOn = syncOn
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
        return isMac
            ? "Voice profiles are stored on this Mac only."
            : "Voice profiles never leave this \(noun). Each device learns voices from its own microphone."
    }

    /// The Mac sidebar's footer.
    public var sidebarFooter: String {
        syncOn ? "Transcribed on-device · synced with iCloud" : "On-device. Nothing is uploaded."
    }

    /// Asking about a voice that was named on another device.
    public func askFromOtherDevice(name: String, other: DevicePlatform) -> String {
        "\(name) was named on your \(other.noun). Each microphone hears a voice a little differently, so Transcribe asks once here. Is this \(name)?"
    }

    /// A synced transcript whose audio stayed on the device that recorded it.
    public func audioElsewhere(other: DevicePlatform) -> String {
        "Audio is on your \(other.noun). The transcript and names are synced; audio stays on the device that recorded it."
    }

    /// Settings → Acknowledgements, first line.
    public var attributionsIntro: String { "Transcribe runs these models and libraries on your \(noun)." }

    /// Settings → Privacy row value.
    public var privacyValue: String { "On this \(noun) only" }

    /// Settings → Privacy explanation.
    public var privacyDetail: String {
        "Audio, transcripts and voice profiles are stored only on this \(noun). Voice profiles are never synced or shared."
    }

    /// Speech models screen, intro.
    public var modelsIntro: String {
        "These come with Transcribe. Speech and speakers are processed on this \(noun), even offline. Nothing is downloaded."
    }

    /// Speech models screen, ready status.
    public var modelsReady: String { "Ready. Everything runs on this \(noun), even offline." }

    /// Recording stopped because storage ran out.
    public var lowStorageStop: String { "Recording stopped — \(noun) storage is almost full" }

    /// Processing panel footnote.
    public var nothingLeaves: String { "Nothing leaves this \(noun)" }

    /// Microphone denied sheet.
    public var micDeniedBody: String { "Transcribe needs the microphone to record. Audio stays on this \(noun)." }

    /// Delete confirmation on a transcript.
    public var deleteTranscriptMessage: String { "The audio and transcript are removed from this \(noun). Saved voices are kept." }

    /// Delete confirmation in the Library.
    public var deleteRecordingMessage: String { "The audio and transcript are removed from this \(noun)." }

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
    public var notInAnyRecording: String { "Not in any recording on this \(noun) yet." }
}
