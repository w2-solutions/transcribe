import Testing
import TranscribeCore
@testable import TranscribeKit

/// The Mac menu bar item: which icon it shows, and when its record item can start or stop a recording.
@Suite struct MenuBarStateTests {
    static func resolve(_ recorder: RecorderController.State, dictationBusy: Bool = false,
                        launched: Bool = true) -> MenuBarState {
        MenuBarState.resolve(recorder: recorder, dictationBusy: dictationBusy, launched: launched)
    }

    @Test func idleOffersANewRecording() {
        let state = Self.resolve(.idle)
        #expect(state == MenuBarState(icon: .idle, label: "Transcribe", recordTitle: "New Recording", recordEnabled: true))
    }

    @Test func aRunningRecordingShowsTheDotAndOffersStop() {
        for recorder: RecorderController.State in [.recording, .paused(.user), .paused(.interruption), .paused(.routeLost)] {
            let state = Self.resolve(recorder)
            #expect(state == MenuBarState(icon: .recording, label: "Transcribe, recording", recordTitle: "Stop Recording",
                                          recordEnabled: true), "\(recorder)")
        }
    }

    @Test func startingAndStoppingShowTheDotButCannotBeChosen() {
        for recorder: RecorderController.State in [.starting, .stopping] {
            let state = Self.resolve(recorder)
            #expect(state.icon == .recording, "\(recorder)")
            #expect(state.recordTitle == "Stop Recording", "\(recorder)")
            #expect(!state.recordEnabled, "\(recorder)")
        }
    }

    @Test func nothingStartsBeforeLaunchHasFinished() {
        let state = Self.resolve(.idle, launched: false)
        #expect(state.recordTitle == "New Recording")
        #expect(!state.recordEnabled)
        #expect(state.icon == .idle)
    }

    @Test func theHUDForARecordingStartedFromTheMenuNamesNoShortcut() {
        let message = MenuBarCopy.recordingStarted
        #expect(message.title == "Recording started")
        #expect(message.detail == nil)
        #expect(message.tone == .record)
        #expect(message.action == nil)
    }

    @Test func aDictationBlocksANewRecording() {
        let state = Self.resolve(.idle, dictationBusy: true)
        #expect(state.recordTitle == "New Recording")
        #expect(!state.recordEnabled)
    }
}
