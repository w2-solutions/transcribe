import Foundation
import Testing
@testable import TranscribeKit

/// `RecordingAudioState.resolve`, branch by branch in §3.5 order, and `withoutAudioSync`.
@Suite("Recording audio state")
struct RecordingAudioStateTests {
    typealias Marker = (descriptor: AudioDescriptor, version: Int64, deleting: Bool)

    static let d = AudioDescriptor(recordingID: UUID(), format: .aac16kMono, bytes: 14_000_000,
                                   sha256: String(repeating: "1a", count: 32), duration: 3_500)
    static let known: Marker = (d, 1, false)

    /// Everything on and running, a known marker, nothing in flight: `.inICloud(bytes, .queued)`. Each test changes
    /// one input.
    static func resolve(hasLocalFile: Bool = false, syncOn: Bool = true, syncRunning: Bool = true, audioOn: Bool = true,
                        marker: Marker? = known, probed: Bool = true, downloading: Bool = false, fraction: Double? = nil,
                        failed: Bool = false, wait: AudioDownloadWait = .queued,
                        channel: String? = "iphone") -> RecordingAudioState {
        RecordingAudioState.resolve(hasLocalFile: hasLocalFile, syncOn: syncOn, syncRunning: syncRunning, audioOn: audioOn,
                                    marker: marker, probed: probed, downloading: downloading, fraction: fraction,
                                    failed: failed, wait: wait, channel: channel)
    }

    @Test func aLocalFileWinsOverEverything() {
        #expect(Self.resolve(hasLocalFile: true) == .local)
        #expect(Self.resolve(hasLocalFile: true, syncOn: false, audioOn: false, marker: nil) == .local)
        #expect(Self.resolve(hasLocalFile: true, marker: (Self.d, 2, false)) == .local)
        #expect(Self.resolve(hasLocalFile: true, downloading: true, failed: true) == .local)
        #expect(RecordingAudioState.local.canPlay)
    }

    @Test func syncOffHereComesNext() {
        #expect(Self.resolve(syncOn: false) == .syncOffHere(channel: "iphone"))
        #expect(Self.resolve(syncOn: false, marker: nil, channel: nil) == .syncOffHere(channel: nil))
        #expect(Self.resolve(syncOn: false, marker: (Self.d, 2, false)) == .syncOffHere(channel: "iphone"))
        #expect(Self.resolve(syncOn: false, audioOn: false, channel: "mac") == .syncOffHere(channel: "mac"))
    }

    @Test func aMarkerFromALaterBuildNeedsAnUpdate() {
        #expect(Self.resolve(marker: (Self.d, 2, false)) == .needsUpdate)
        // Even with Sync audio off, downloading or failed: this build cannot play it.
        #expect(Self.resolve(audioOn: false, marker: (Self.d, 3, false)) == .needsUpdate)
        #expect(Self.resolve(marker: (Self.d, 2, false), downloading: true) == .needsUpdate)
        var opus = Self.d
        opus.format = AudioFormat(rawValue: "opus/16000/1")
        #expect(Self.resolve(marker: (opus, 1, false)) == .needsUpdate)
        // A marker being deleted is not a known marker.
        #expect(Self.resolve(marker: (Self.d, 2, true)) == .notInICloud(channel: "iphone"))
        #expect(!RecordingAudioState.needsUpdate.canPlay)
    }

    @Test func noMarkerIsCheckingUntilTheProbeAnswers() {
        #expect(Self.resolve(marker: nil, probed: false) == .checking)
        #expect(Self.resolve(marker: nil, probed: true) == .notInICloud(channel: "iphone"))
        #expect(Self.resolve(marker: nil, probed: true, channel: nil) == .notInICloud(channel: nil))
        // A marker being deleted reads as none.
        #expect(Self.resolve(marker: (Self.d, 1, true), probed: false) == .checking)
        #expect(Self.resolve(marker: (Self.d, 1, true), probed: true, channel: "mac") == .notInICloud(channel: "mac"))
        // In flight or failed says nothing without a marker.
        #expect(Self.resolve(marker: nil, downloading: true, failed: true) == .notInICloud(channel: "iphone"))
    }

    @Test func noMarkerWithSyncAudioOffIsNotInICloud() {
        #expect(Self.resolve(audioOn: false, marker: nil, probed: false) == .syncAudioOffHere(inICloud: false, channel: "iphone"))
        #expect(Self.resolve(audioOn: false, marker: nil, probed: true, channel: "ipad")
                == .syncAudioOffHere(inICloud: false, channel: "ipad"))
        #expect(Self.resolve(audioOn: false, marker: (Self.d, 1, true)) == .syncAudioOffHere(inICloud: false, channel: "iphone"))
    }

    @Test func aKnownMarkerWithSyncAudioOffIsInICloud() {
        #expect(Self.resolve(audioOn: false) == .syncAudioOffHere(inICloud: true, channel: "iphone"))
        #expect(Self.resolve(audioOn: false, downloading: true, fraction: 0.5, failed: true, channel: nil)
                == .syncAudioOffHere(inICloud: true, channel: nil))
    }

    @Test func inFlightThenFailed() {
        #expect(Self.resolve(downloading: true) == .downloading(fraction: nil))
        #expect(Self.resolve(downloading: true, fraction: 0.4) == .downloading(fraction: 0.4))
        #expect(Self.resolve(syncRunning: false, downloading: true, fraction: 0.4, failed: true) == .downloading(fraction: 0.4))
        #expect(Self.resolve(failed: true) == .failed(bytes: 14_000_000))
        #expect(Self.resolve(syncRunning: false, failed: true, wait: .lowStorage) == .failed(bytes: 14_000_000))
    }

    @Test func syncNotRunningWaitsForSync() {
        #expect(Self.resolve(syncRunning: false) == .inICloud(bytes: 14_000_000, wait: .syncPaused))
        #expect(Self.resolve(syncRunning: false, wait: .network) == .inICloud(bytes: 14_000_000, wait: .syncPaused))
    }

    @Test(arguments: [AudioDownloadWait.queued, .network, .lowPower, .lowStorage, .syncPaused])
    func otherwiseInICloudWithItsWait(wait: AudioDownloadWait) {
        #expect(Self.resolve(wait: wait) == .inICloud(bytes: 14_000_000, wait: wait))
        #expect(!Self.resolve(wait: wait).canPlay)
    }

    @Test func withoutAudioSyncIsLocalOrSyncOff() {
        #expect(RecordingAudioState.withoutAudioSync(hasLocalFile: true, channel: "iphone") == .local)
        #expect(RecordingAudioState.withoutAudioSync(hasLocalFile: true, channel: nil) == .local)
        #expect(RecordingAudioState.withoutAudioSync(hasLocalFile: false, channel: "mac") == .syncOffHere(channel: "mac"))
        #expect(RecordingAudioState.withoutAudioSync(hasLocalFile: false, channel: nil) == .syncOffHere(channel: nil))
    }

    @Test func onlyLocalCanPlay() {
        let others: [RecordingAudioState] = [.checking, .downloading(fraction: 0.9), .inICloud(bytes: 1, wait: .queued),
                                             .failed(bytes: 1), .notInICloud(channel: nil),
                                             .syncAudioOffHere(inICloud: true, channel: nil), .syncOffHere(channel: nil),
                                             .needsUpdate]
        #expect(others.allSatisfy { !$0.canPlay })
    }

    @Test func theSummaryStartsEmpty() {
        let s = AudioSyncSummary()
        #expect(s.uploadsLeft == 0 && s.downloadsLeft == 0 && s.tooLong == 0 && s.uploadBytesLeft == 0 && s.wait == nil)
        let t = AudioSyncSummary(uploadsLeft: 2, downloadsLeft: 1, tooLong: 3, uploadBytesLeft: 9, wait: .busy)
        #expect(t.uploadsLeft == 2 && t.downloadsLeft == 1 && t.tooLong == 3 && t.uploadBytesLeft == 9 && t.wait == .busy)
    }
}
