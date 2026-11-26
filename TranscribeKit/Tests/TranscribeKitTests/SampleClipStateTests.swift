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
    }
}
