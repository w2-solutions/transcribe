import XCTest

/// Playback on recording B (`library`, route `transcript:1`, 0:24).
final class PlaybackFlowTests: FlowTestCase {
    @MainActor func testPlayPauseSpeedAndSeek() {
        let app = UITestApp.launch(seed: "library", route: "transcript:1")
        app.waitFor(AX.Transcript.screen, timeout: 20)
        let play = app.waitFor(AX.Player.playButton)
        let time = app.waitFor(AX.Player.time)
        Wait.label(play, equals: "Play")

        let before = time.label
        play.press()
        Wait.label(play, equals: "Pause")
        Wait.label(time, changesFrom: before, timeout: 2)
        play.press()
        Wait.label(play, equals: "Play")

        let speed = app.waitFor(AX.Player.speedButton)
        Wait.label(speed, equals: "1×")
        speed.press()
        Wait.label(speed, equals: "1.5×")

        // Turn 2 starts at 0:15 (conversation B, rounded to the nearest second).
        app.waitFor(AX.Transcript.turnTimestamp(2)).press()
        // The scrubber's value reads "0:15 of 0:24"; anything from 0:14 to the end means the seek landed.
        Wait.until(app.element(AX.Player.scrubber), "value MATCHES %@", "0:(1[4-9]|2[0-4]) of 0:24", timeout: 5,
                   "Seeking to turn 2 should move the playhead to 0:14 or later")
    }
}
