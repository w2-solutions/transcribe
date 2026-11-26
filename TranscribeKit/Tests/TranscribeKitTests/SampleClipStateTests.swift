import Foundation
import Testing
import TranscribeCore
@testable import TranscribeKit

@Suite struct SampleClipStateTests {
    let source = UUID()
    let clip = TimeRange(start: 10.8, end: 14.8)

    private func resolve(source: UUID?, clip: TimeRange?, recording: (fileName: String, channel: String?)?,
                         audio: Bool) -> SampleClipState {
        SampleClipState.resolve(sourceRecordingID: source, clip: clip, recording: recording, audioExists: { _ in audio })
    }

    @Test func everyState() {
        #expect(resolve(source: source, clip: clip, recording: ("a.wav", "iphone"), audio: true)
                == .playable(fileName: "a.wav", range: clip))
        #expect(resolve(source: source, clip: clip, recording: ("a.wav", "ipad"), audio: false) == .audioElsewhere(channel: "ipad"))
        #expect(resolve(source: source, clip: clip, recording: ("a.wav", nil), audio: false) == .audioElsewhere(channel: nil))
        #expect(resolve(source: source, clip: clip, recording: nil, audio: true) == .recordingDeleted)
        #expect(resolve(source: nil, clip: clip, recording: nil, audio: true) == .noClip)
        #expect(resolve(source: source, clip: nil, recording: ("a.wav", "iphone"), audio: true) == .noClip)
        #expect(SampleClipState.playable(fileName: "a.wav", range: clip).isPlayable)
        #expect(![SampleClipState.audioElsewhere(channel: "ipad"), .recordingDeleted, .noClip].contains { $0.isPlayable })
    }

    @Test func orderOfChecks() {
        // No source recording: no clip, whatever else is known.
        #expect(resolve(source: nil, clip: clip, recording: ("a.wav", "iphone"), audio: true) == .noClip)
        // The recording is gone: deleted, even with no clip range.
        #expect(resolve(source: source, clip: nil, recording: nil, audio: false) == .recordingDeleted)
        // No clip wins over audio elsewhere: there is nothing to play on any device.
        #expect(resolve(source: source, clip: nil, recording: ("a.wav", "ipad"), audio: false) == .noClip)
        // The disk is asked last, and about the recording's file only.
        var asked: [String] = []
        _ = SampleClipState.resolve(sourceRecordingID: source, clip: nil, recording: ("a.wav", "ipad"),
                                    audioExists: { asked.append($0); return true })
        #expect(asked.isEmpty)
        _ = SampleClipState.resolve(sourceRecordingID: source, clip: clip, recording: ("b.wav", "ipad"),
                                    audioExists: { asked.append($0); return true })
        #expect(asked == ["b.wav"])
    }

    @Test func captions() {
        let iPhone = DeviceCopy(platform: .iPhone), mac = DeviceCopy(platform: .mac)
        #expect(SampleClipState.playable(fileName: "a.wav", range: clip).caption(iPhone) == nil)
        #expect(SampleClipState.recordingDeleted.caption(iPhone) == "Recording deleted")
        #expect(SampleClipState.noClip.caption(mac) == "No clip saved")
        #expect(SampleClipState.audioElsewhere(channel: "iphone").caption(mac) == "Audio is on your iPhone")
        #expect(SampleClipState.audioElsewhere(channel: "ipad").caption(iPhone) == "Audio is on your iPad")
        #expect(SampleClipState.audioElsewhere(channel: "iphone").caption(iPhone) == "Audio is on your other iPhone")
        #expect(SampleClipState.audioElsewhere(channel: "mac").caption(mac) == "Audio is on your other Mac")
        #expect(SampleClipState.audioElsewhere(channel: nil).caption(mac) == "Audio is on another device")
        #expect(SampleClipState.audioDownloading.caption(iPhone) == "Downloading audio…")
        #expect(SampleClipState.audioDownloading.caption(mac) == "Downloading audio…")
        #expect(SampleClipState.audioInICloud.caption(iPhone) == "Audio is in iCloud")
        #expect(SampleClipState.audioInICloud.caption(mac) == "Audio is in iCloud")
        // The old captions are the same with audio sync on.
        let synced = DeviceCopy(platform: .mac, syncOn: true, audioSyncOn: true)
        #expect(SampleClipState.audioElsewhere(channel: "iphone").caption(synced) == "Audio is on your iPhone")
        #expect(SampleClipState.audioElsewhere(channel: "mac").caption(synced) == "Audio is on your other Mac")
    }

    /// With audio sync, a missing file is described by the recording's audio state (§1.3 "Voice samples").
    @Test func audioStateDecidesWhenTheFileIsMissing() {
        func resolve(_ state: RecordingAudioState?, audio: Bool = false) -> SampleClipState {
            SampleClipState.resolve(sourceRecordingID: source, clip: clip, recording: ("a.m4a", "mac"),
                                    audioExists: { _ in audio }, audioState: { _ in state })
        }
        #expect(resolve(.downloading(fraction: nil)) == .audioDownloading)
        #expect(resolve(.downloading(fraction: 0.4)) == .audioDownloading)
        for wait in [AudioDownloadWait.queued, .network, .lowPower, .lowStorage, .syncPaused] {
            #expect(resolve(.inICloud(bytes: 14_000_000, wait: wait)) == .audioInICloud)
        }
        #expect(resolve(.failed(bytes: 14_000_000)) == .audioInICloud)
        #expect(resolve(.syncAudioOffHere(inICloud: true, channel: "mac")) == .audioInICloud)
        // Anything else is still "audio is on the device that recorded it".
        for state: RecordingAudioState? in [nil, .checking, .notInICloud(channel: "mac"), .needsUpdate,
                                            .syncAudioOffHere(inICloud: false, channel: "mac"), .syncOffHere(channel: "mac"),
                                            .local] {
            #expect(resolve(state) == .audioElsewhere(channel: "mac"), "\(String(describing: state))")
        }
        // A file on disk plays whatever the state says.
        #expect(resolve(.downloading(fraction: 0.4), audio: true) == .playable(fileName: "a.m4a", range: clip))
        #expect(![SampleClipState.audioDownloading, .audioInICloud].contains { $0.isPlayable })
    }

    /// The audio state is asked about the source recording only, and only once the file is found missing.
    @Test func audioStateIsAskedLast() {
        var asked: [UUID] = []
        _ = SampleClipState.resolve(sourceRecordingID: source, clip: nil, recording: ("a.m4a", "mac"),
                                    audioExists: { _ in false }, audioState: { asked.append($0); return .audioStateSample })
        _ = SampleClipState.resolve(sourceRecordingID: source, clip: clip, recording: nil,
                                    audioExists: { _ in false }, audioState: { asked.append($0); return .audioStateSample })
        _ = SampleClipState.resolve(sourceRecordingID: source, clip: clip, recording: ("a.m4a", "mac"),
                                    audioExists: { _ in true }, audioState: { asked.append($0); return .audioStateSample })
        #expect(asked.isEmpty)
        #expect(SampleClipState.resolve(sourceRecordingID: source, clip: clip, recording: ("a.m4a", "mac"),
                                        audioExists: { _ in false },
                                        audioState: { asked.append($0); return .audioStateSample }) == .audioInICloud)
        #expect(asked == [source])
    }
}

private extension RecordingAudioState {
    static let audioStateSample = RecordingAudioState.inICloud(bytes: 1, wait: .queued)
}
