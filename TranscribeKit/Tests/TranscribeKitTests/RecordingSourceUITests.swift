import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Mac audio's settings and wording (2026-11-26): the per-device source setting, the copy, the privacy lines, and what
/// the transcript and naming sheet show for a speaker heard through Mac audio or on both streams.
@Suite("Recording source: settings")
@MainActor
struct RecordingSourceSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "recording-source-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func microphoneByDefaultAndRemembered() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.recordingSource == .microphone)
        #expect(!settings.macAudioExplained)
        settings.recordingSource = .both
        settings.macAudioExplained = true
        #expect(defaults.string(forKey: "settings.recordingSource") == "both")
        let again = AppSettings(defaults: defaults)
        #expect(again.recordingSource == .both && again.macAudioExplained)
        settings.recordingSource = .macAudio
        #expect(AppSettings(defaults: defaults).recordingSource == .macAudio)
    }

    @Test func storedValuesAreTheCaptureSourcesRawValues() {
        #expect(CaptureSources.allCases.map(\.rawValue) == ["microphone", "both", "macAudio"])
        let defaults = freshDefaults()
        defaults.set("somethingElse", forKey: "settings.recordingSource")
        #expect(AppSettings(defaults: defaults).recordingSource == .microphone, "an unknown value reads as the microphone")
    }

    @Test func effectiveSourceIsTheMicrophoneWithoutMacAudio() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.recordingSource = .macAudio
        #expect(settings.effectiveRecordingSource(systemAudioAvailable: true) == .macAudio)
        #expect(settings.effectiveRecordingSource(systemAudioAvailable: false) == .microphone)
        #expect(settings.recordingSource == .macAudio, "the choice is kept for when Mac audio is available")
    }
}

@Suite("Recording source: copy")
struct RecordingSourceCopyTests {
    @Test func titles() {
        #expect(CaptureSources.allCases.map(RecordingSourceCopy.title) == ["Microphone", "Microphone and Mac audio", "Mac audio only"])
        #expect(RecordingSourceCopy.sourceLine(.both) == "Recording the microphone and Mac audio")
        #expect(RecordingSourceCopy.footnote
                == "Mac audio records calls and other apps' sound. Use headphones with both, so the other side isn't recorded twice. Let people know you're recording.")
        #expect(RecordingSourceCopy.explainerBody.contains("Screen & System Audio Recording"))
        #expect(RecordingSourceCopy.explainerBody.contains("never your screen"))
    }

    @Test func notices() {
        #expect(RecordingSourceCopy.note(nil, sources: .both) == nil)
        #expect(RecordingSourceCopy.note(.systemAudioSilent, sources: .both) == RecordingSourceCopy.silentNote)
        #expect(RecordingSourceCopy.note(.systemAudioSilent, sources: .macAudio) == RecordingSourceCopy.silentNote)
        #expect(RecordingSourceCopy.note(.systemAudioLost, sources: .both) == "Mac audio stopped. Recording the microphone only.")
        // Mac audio only: losing it pauses the recording, which the status says; no note claims the microphone carries on.
        #expect(RecordingSourceCopy.note(.systemAudioLost, sources: .macAudio) == nil)
    }
}

@Suite("Recording source: privacy wording")
struct DeviceCopyMacAudioTests {
    static let line = " When you record Mac audio, the sound of calls and other apps is recorded too and stays on this Mac."
    static let states: [(sync: Bool, kept: Bool, claude: Bool, updates: Bool)] = [
        (false, false, false, false), (false, false, true, false), (true, false, false, false), (true, false, true, true),
        (false, true, false, true), (false, true, true, false), (false, false, false, true),
    ]

    @Test func everyMacPrivacyBranchCarriesTheLineBeforeItsClosingAbsolute() throws {
        let absolutes = ["nothing else", "Nothing is shared", "never shared", "never synced or shared"]
        for s in Self.states {
            let on = DeviceCopy(platform: .mac, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude,
                                updatesAvailable: s.updates, macAudio: true)
            let off = DeviceCopy(platform: .mac, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude,
                                 updatesAvailable: s.updates)
            let detail = on.privacyDetail
            let range = try #require(detail.range(of: Self.line), "\(s): \(detail)")
            let before = String(detail[..<range.lowerBound]), after = String(detail[range.upperBound...])
            for phrase in absolutes { #expect(!before.contains(phrase), "“\(phrase)” before the Mac audio line: \(detail)") }
            #expect(before + after == off.privacyDetail, "\(s)")
            // The short lines are unchanged: Mac audio stays on the Mac like any recording.
            #expect(on.sidebarFooter == off.sidebarFooter && on.privacyValue == off.privacyValue)
            #expect(on.nothingLeaves == off.nothingLeaves && on.micDeniedBody == off.micDeniedBody)
        }
    }

    @Test func exactLocalMacPrivacy() {
        #expect(DeviceCopy(platform: .mac, macAudio: true).privacyDetail
                == "Audio, transcripts and voice profiles are stored only on this Mac." + Self.line
                    + " Voice profiles are never synced or shared.")
    }

    @Test func voicesFooter() {
        #expect(DeviceCopy(platform: .mac, macAudio: true).voicesFooter
                == "Voice profiles are stored on this Mac only, including how voices sound through call audio.")
        #expect(DeviceCopy(platform: .mac, syncOn: true, macAudio: true).voicesFooter
                == "Voice profiles sync with iCloud. Each device learns how a voice sounds through its own microphone, and this Mac also learns how voices sound through call audio.")
        // A kept iCloud copy: the footer is about the copy, unchanged.
        #expect(DeviceCopy(platform: .mac, cloudCopyKept: true, macAudio: true).voicesFooter
                == DeviceCopy(platform: .mac, cloudCopyKept: true).voicesFooter)
    }

    @Test func theIPhoneAndAMacWithoutMacAudioAreUnchanged() {
        for platform in [DevicePlatform.iPhone, .iPad] {
            for s in Self.states {
                let off = DeviceCopy(platform: platform, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude)
                let on = DeviceCopy(platform: platform, syncOn: s.sync, cloudCopyKept: s.kept, claudeOn: s.claude, macAudio: true)
                #expect(on.privacyDetail == off.privacyDetail && on.voicesFooter == off.voicesFooter)
            }
        }
        #expect(DeviceCopy(platform: .mac) == DeviceCopy(platform: .mac, macAudio: false))
        #expect(DeviceCopy(platform: .mac).voicesFooter == "Voice profiles are stored on this Mac only.")
    }
}

@Suite("Recording source: speakers")
@MainActor
struct SpeakerSourceDisplayTests {
    @MainActor final class Fixture {
        let context: ModelContext
        let paths: AppPaths
        let container: ModelContainer
        init() throws {
            container = try ModelContainerFactory.make(inMemory: true, url: nil)
            context = container.mainContext
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)"))
            try Seeds.apply(.twoSpeakersUnnamed, context: context, paths: paths, clock: .frozen(Seeds.Dates.a))
        }
        deinit { try? FileManager.default.removeItem(at: paths.root) }
        var recording: Recording {
            get throws { try #require(try context.fetch(FetchDescriptor<Recording>()).first { $0.id == Seeds.ID.recordingB }) }
        }
        var profiles: [VoiceProfile] { (try? context.fetch(FetchDescriptor<VoiceProfile>())) ?? [] }
        func setSource(_ key: SpeakerKey, _ source: SpeakerSource?) throws {
            try #require(try recording.speaker(key)).captureSource = source?.rawValue
        }
        func model(_ key: SpeakerKey) throws -> NameSpeakerModel {
            NameSpeakerModel(recording: try recording, key: key, mode: .name, profiles: profiles, platform: .mac)
        }
    }

    @Test func chipsShowTheGlyphForMacAudioSpeakersOnly() throws {
        let f = try Fixture()
        let speaker = try #require(try f.recording.speaker("S2"))
        #expect(!TranscriptSpeaker(speaker, suggestedName: nil).heardThroughMacAudio, "nil reads as the microphone")
        for (stored, glyph) in [(SpeakerSource.mic, false), (.system, true), (.mixed, false)] {
            try f.setSource("S2", stored)
            let s = TranscriptSpeaker(speaker, suggestedName: nil)
            #expect(s.source == stored && s.heardThroughMacAudio == glyph)
        }
    }

    @Test func aMixedSpeakerSaysItIsNotLearnedAndOffersNoRemember() throws {
        let f = try Fixture()
        try f.setSource("S2", .mixed)
        let m = try f.model("S2")
        #expect(m.notLearnedNote == RecordingSourceCopy.mixedNotLearned)
        #expect(m.notLearnedNote
                == "This voice was heard on both your microphone and Mac audio, so Transcribe won't learn it from this recording.")
        #expect(!m.showsRemember && !m.rememberEnabled && !m.remember)
        m.name = "Karan"
        #expect(m.action == .name(.newPerson(name: "Karan"), remember: false), "the name only: no sample, no negative")
    }

    @Test func microphoneAndMacAudioSpeakersAreNamedAsBefore() throws {
        for source in [SpeakerSource?.none, .mic, .system] {
            let f = try Fixture()
            try f.setSource("S2", source)
            let m = try f.model("S2")
            #expect(m.notLearnedNote == nil)
            #expect(m.showsRemember && m.rememberEnabled && m.remember)
            m.name = "Karan"
            #expect(m.action == .name(.newPerson(name: "Karan"), remember: true))
        }
    }
}
