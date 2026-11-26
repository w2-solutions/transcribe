import Foundation
import TranscribeCore

/// Every user-facing string about what a recording captures (Mac audio, 2026-11-26). Only the Mac offers a choice;
/// the iPhone records the microphone only and shows none of this, except the speaker wording, which a synced
/// recording can carry to any device.
public enum RecordingSourceCopy {
    /// The choice's name in Settings → Recording, the toolbar menu and File → Record From.
    public static func title(_ sources: CaptureSources) -> String {
        switch sources {
        case .microphone: "Microphone"
        case .both: "Microphone and Mac audio"
        case .macAudio: "Mac audio only"
        }
    }

    /// The SF Symbol for a choice.
    public static func symbol(_ sources: CaptureSources) -> String {
        switch sources {
        case .microphone: "mic"
        case .both: "waveform.and.mic"
        case .macAudio: "speaker.wave.2"
        }
    }

    /// Settings → Recording: the picker's title.
    public static let pickerTitle = "Record"

    /// The submenu in File, and the toolbar menu's header.
    public static let recordFromTitle = "Record From"

    /// Settings → Recording, under the picker.
    public static let footnote = "Mac audio records calls and other apps' sound. Use headphones with both, so the other side isn't recorded twice. Let people know you're recording."

    // MARK: First use of Mac audio

    public static let explainerTitle = "Record your Mac's audio"
    public static let explainerBody = "macOS will ask to let Transcribe record your Mac's audio. It's listed under Screen & System Audio Recording. Transcribe records sound only, never your screen, and the audio stays on this Mac."
    public static let explainerContinue = "Continue"
    public static let explainerCancel = "Cancel"

    // MARK: The recording window

    /// The source line under the date: what this recording captures.
    public static func sourceLine(_ sources: CaptureSources) -> String {
        switch sources {
        case .microphone: "Recording the microphone"
        case .both: "Recording the microphone and Mac audio"
        case .macAudio: "Recording Mac audio only"
        }
    }

    /// The captions of the two level meters in a Both recording.
    public static let micMeterCaption = "Microphone"
    public static let macAudioMeterCaption = "Mac audio"

    /// Both mode while the Mac's sound plays through its own speakers: the microphone hears the call as well.
    public static let headphonesHint = "Use headphones so the other side isn't recorded twice."

    /// Mac audio has been silent while another app plays sound (usually access turned off in Privacy & Security).
    public static let silentNote = "No sound from Mac audio. If you turned off access, allow Transcribe in Privacy & Security."
    public static let openPrivacySettings = "Open Privacy Settings"

    /// Mac audio stopped mid-recording; in Both mode the microphone carries on.
    public static let lostNote = "Mac audio stopped. Recording the microphone only."

    /// The note for a recording notice, by what the recording captures. A lost Mac audio stream in Mac-audio-only mode
    /// pauses the recording instead (the status says so), so it has no note.
    public static func note(_ notice: RecordingNotice?, sources: CaptureSources) -> String? {
        switch notice {
        case .systemAudioSilent?: silentNote
        case .systemAudioLost?: sources == .both ? lostNote : nil
        case nil: nil
        }
    }

    // MARK: Microphone denied

    /// The microphone-denied sheet in Both mode: record Mac audio alone instead.
    public static let macAudioOnlyInstead = "Record Mac audio only"

    // MARK: Speakers

    /// A speaker heard through Mac audio (the glyph on its chip): its accessibility label.
    public static let heardThroughMacAudio = "Heard through Mac audio"
    public static let heardThroughMacAudioSymbol = "speaker.wave.2"

    /// The naming sheet of a speaker heard on both streams.
    public static let mixedNotLearned = "This voice was heard on both your microphone and Mac audio, so Transcribe won't learn it from this recording."
}
