import Foundation
import Testing
@testable import TranscribeKit

/// In-app updates on the Mac (D10, D23): when the updater may run, the wording, and the quiet "Update available"
/// reminder that replaces Sparkle's uninvited window (hidden during a recording).
@Suite struct UpdatesTests {
    static let feed = "https://w2solutions.ai/transcribe/appcast.xml"
    /// Base64 of 32 bytes, the length of an Ed25519 public key.
    static let key = Data(repeating: 7, count: 32).base64EncodedString()

    static func resolve(debug: Bool = false, uiTesting: Bool = false, fake: Bool = false,
                        feed: String? = UpdatesTests.feed, key: String? = UpdatesTests.key) -> UpdateAvailability {
        UpdateAvailability.resolve(isDebugBuild: debug, uiTesting: uiTesting, useFakeEngine: fake, feedURL: feed, publicKey: key)
    }

    @Test func onOnlyForAConfiguredReleaseRun() {
        #expect(Self.resolve() == .on)
        #expect(Self.resolve(feed: "http://127.0.0.1:8788/transcribe/appcast.xml") == .on, "the local end-to-end test's feed")
    }

    @Test func debugWinsOverEverything() {
        #expect(Self.resolve(debug: true) == .offDebugBuild)
        #expect(Self.resolve(debug: true, uiTesting: true, fake: true, feed: nil, key: nil) == .offDebugBuild)
        #expect(Self.resolve(debug: true, feed: "", key: "") == .offDebugBuild)
    }

    @Test func testRunsAreOffInRelease() {
        #expect(Self.resolve(uiTesting: true) == .offTestRun)
        #expect(Self.resolve(fake: true) == .offTestRun)
        #expect(Self.resolve(uiTesting: true, fake: true) == .offTestRun)
        // A test run is reported before a missing configuration.
        #expect(Self.resolve(uiTesting: true, feed: nil, key: nil) == .offTestRun)
    }

    @Test func feedMustBeAnHTTPURLWithAHost() {
        for feed in [nil, "", "not a url", "appcast.xml", "ftp://w2solutions.ai/transcribe/appcast.xml",
                     "file:///tmp/appcast.xml", "https://", "https:///appcast.xml"] as [String?] {
            #expect(Self.resolve(feed: feed) == .offNotConfigured, "feed \(String(describing: feed))")
        }
        #expect(Self.resolve(feed: "HTTPS://w2solutions.ai/transcribe/appcast.xml") == .on)
    }

    @Test func keyMustDecodeToExactly32Bytes() {
        #expect(Self.resolve(key: Data(repeating: 1, count: 31).base64EncodedString()) == .offNotConfigured)
        #expect(Self.resolve(key: Data(repeating: 1, count: 32).base64EncodedString()) == .on)
        #expect(Self.resolve(key: Data(repeating: 1, count: 33).base64EncodedString()) == .offNotConfigured)
        for key in [nil, "", "not base64!", "$(TRANSCRIBE_ED_PUBLIC_KEY)"] as [String?] {
            #expect(Self.resolve(key: key) == .offNotConfigured, "key \(String(describing: key))")
        }
    }

    @Test func noteWording() {
        #expect(UpdateCopy.note(for: .on) == "Transcribe asks w2solutions.ai whether a newer version exists: once a day if automatic checks are on, and whenever you choose Check for Updates. It sends no recordings, transcripts or names, only which version you have and what any web request carries, such as your Mac's internet address and language. Updates are large because the speech models are inside. One installs only when you choose, and only if it comes from W2 Solutions.")
        #expect(UpdateCopy.note(for: .offDebugBuild) == "Updates are off in Debug builds.")
        #expect(UpdateCopy.note(for: .offTestRun) == "Updates are off while testing.")
        #expect(UpdateCopy.note(for: .offNotConfigured)
                == "This copy of Transcribe can't check for updates. Download the latest version from w2solutions.ai/transcribe.")
        #expect(UpdateCopy.postponeTitle == "Update after this recording")
        #expect(UpdateCopy.postponeText == "Transcribe will install the update and reopen when you stop recording.")
    }

    @Test func reminderWording() {
        #expect(UpdateCopy.checkTitle(pendingVersion: nil) == "Check for Updates…")
        #expect(UpdateCopy.checkTitle(pendingVersion: "0.3.1") == "Update Available…")
        #expect(UpdateCopy.reminderTitle(version: "0.3.1") == "Update available · 0.3.1")
        #expect(UpdateCopy.reminderHelp(version: "0.3.1") == "Transcribe 0.3.1 is ready to download. Click to see what's new.")
        #expect(UpdateCopy.reminderAccessibilityLabel(version: "0.3.1") == "Update available: Transcribe 0.3.1")
        #expect(UpdateCopy.reminderAccessibilityHint == "Shows what's new and lets you install it")
    }

    static func reminder(_ events: UpdateReminder.Event...) -> UpdateReminder {
        var r = UpdateReminder()
        for e in events { r.apply(e) }
        return r
    }

    @Test func nothingShowsUntilAnUpdateIsFound() {
        let r = UpdateReminder()
        #expect(r.version == nil && r.visibleVersion == nil && !r.isRecording)
        #expect(Self.reminder(.notFound, .sessionEnded) == UpdateReminder())
    }

    @Test func aFoundUpdateShowsItsVersion() {
        let r = Self.reminder(.found(version: "0.3.1"))
        #expect(r.version == "0.3.1")
        #expect(r.visibleVersion == "0.3.1")
        #expect(Self.reminder(.found(version: "0.3.1"), .found(version: "0.3.2")).visibleVersion == "0.3.2", "the newest wins")
    }

    @Test func installingOrSkippingClearsIt() {
        for choice in [UpdateReminder.Choice.install, .skip] {
            #expect(Self.reminder(.found(version: "0.3.1"), .chose(choice)).visibleVersion == nil, "\(choice)")
            #expect(Self.reminder(.found(version: "0.3.1"), .chose(choice), .sessionEnded).visibleVersion == nil, "\(choice)")
        }
    }

    @Test func remindMeLaterKeepsItAfterTheSessionEnds() {
        let later = Self.reminder(.found(version: "0.3.1"), .chose(.later), .sessionEnded)
        #expect(later.visibleVersion == "0.3.1", "the update is still available")
        // Only for that session: a later session that ends with no choice (an error, "You're up to date") clears it.
        #expect(Self.reminder(.found(version: "0.3.1"), .chose(.later), .sessionEnded, .sessionEnded).visibleVersion == nil)
        // A new check that finds it again starts over: the next choice decides.
        let again = Self.reminder(.found(version: "0.3.1"), .chose(.later), .sessionEnded, .found(version: "0.3.1"))
        #expect(again.visibleVersion == "0.3.1")
        let againThenNothing = Self.reminder(.found(version: "0.3.1"), .chose(.later), .sessionEnded,
                                             .found(version: "0.3.1"), .sessionEnded)
        #expect(againThenNothing.visibleVersion == nil)
    }

    @Test func aSessionThatEndsWithoutAChoiceClearsIt() {
        // An error during the download or the check, after the update was shown.
        #expect(Self.reminder(.found(version: "0.3.1"), .sessionEnded).visibleVersion == nil)
    }

    @Test func noUpdateFoundClearsIt() {
        // A later check finds nothing newer (the version was skipped, or withdrawn from the feed).
        #expect(Self.reminder(.found(version: "0.3.1"), .chose(.later), .sessionEnded, .notFound).visibleVersion == nil)
        #expect(Self.reminder(.found(version: "0.3.1"), .chose(.later), .notFound, .sessionEnded).visibleVersion == nil)
    }

    @Test func hiddenDuringARecordingAndShownWhenItStops() {
        // Found while recording: nothing at all until the recording stops.
        var r = Self.reminder(.recordingChanged(isRecording: true), .found(version: "0.3.1"))
        #expect(r.version == "0.3.1")
        #expect(r.visibleVersion == nil)
        r.apply(.recordingChanged(isRecording: false))
        #expect(r.visibleVersion == "0.3.1")
        // Already showing when a recording starts: hidden for the recording, back afterwards.
        r.apply(.recordingChanged(isRecording: true))
        #expect(r.visibleVersion == nil)
        r.apply(.recordingChanged(isRecording: false))
        #expect(r.visibleVersion == "0.3.1")
    }

    @Test func choicesDuringARecordingStillCount() {
        // Check for Updates… during a recording opens Sparkle's window; skipping there leaves nothing to show later.
        let r = Self.reminder(.recordingChanged(isRecording: true), .found(version: "0.3.1"), .chose(.skip), .sessionEnded,
                              .recordingChanged(isRecording: false))
        #expect(r.visibleVersion == nil)
        #expect(Self.reminder(.recordingChanged(isRecording: true), .recordingChanged(isRecording: false)) == UpdateReminder())
    }
}
