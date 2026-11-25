import Foundation
import Testing
@testable import TranscribeKit

/// In-app updates on the Mac (D10, D23): when the updater may run, the Settings note, and holding back a scheduled
/// update alert while recording.
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

    @Test func notBusyShowsAtOnce() {
        var d = UpdateDeferral()
        let show = d.scheduledUpdateFound(busy: false)
        #expect(show)
        #expect(!d.pending)
        let present = d.busyEnded()
        #expect(!present, "nothing was deferred")
    }

    @Test func busyDefersUntilTheRecordingStopsThenShowsOnce() {
        var d = UpdateDeferral()
        let show = d.scheduledUpdateFound(busy: true)
        #expect(!show)
        #expect(d.pending)
        let first = d.busyEnded()
        #expect(first)
        #expect(!d.pending)
        let second = d.busyEnded()
        #expect(!second, "presented once only")
    }

    @Test func busyEndedWithoutADeferralDoesNothing() {
        var d = UpdateDeferral()
        let present = d.busyEnded()
        #expect(!present)
        #expect(d == UpdateDeferral())
    }
}
