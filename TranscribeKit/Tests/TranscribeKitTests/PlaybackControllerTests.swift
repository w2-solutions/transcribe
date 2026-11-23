import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A scripted player: time only moves when the test says so.
@MainActor
final class ScriptedBackend: PlaybackBackend {
    let duration: TimeInterval
    var currentTime: TimeInterval = 0
    var rate: Float = 1
    private(set) var isPlaying = false
    private(set) var playCalls = 0
    init(duration: TimeInterval) { self.duration = duration }
    func play() -> Bool { isPlaying = true; playCalls += 1; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
    /// Advances the clock; stops at the end of the file like AVAudioPlayer.
    func advance(to t: TimeInterval) {
        currentTime = Swift.min(t, duration)
        if currentTime >= duration { isPlaying = false }
    }
}

@MainActor final class CaptureFlag { var on = false }

@Suite("PlaybackController")
@MainActor
struct PlaybackControllerTests {
    let url = URL(fileURLWithPath: "/tmp/fake.wav")

    func scripted(duration: TimeInterval = 20) -> (PlaybackController, () -> ScriptedBackend?) {
        var made: ScriptedBackend?
        let controller = PlaybackController(backend: { _ in
            let b = ScriptedBackend(duration: duration); made = b; return b
        })
        return (controller, { made })
    }

    @Test func loadsASyntheticWAV() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("b.wav")
        _ = try SyntheticAudio.write(to: wav, duration: 3, segments: [(TimeRange(start: 0.5, end: 2.5), .karan)])

        let player = PlaybackController()
        try player.load(url: wav)
        #expect(player.loadedURL == wav)
        #expect(abs(player.duration - 3) < 0.05)
        #expect(player.currentTime == 0)
        #expect(!player.isPlaying)

        player.seek(to: 1.25)
        #expect(player.currentTime == 1.25)
        // Loading the same file again is a no-op and keeps the position.
        try player.load(url: wav)
        #expect(player.currentTime == 1.25)
    }

    @Test func sessionFollowsCaptureNotTheLeftoverCategory() throws {
        let (player, _) = scripted(duration: 10)
        var log: [String] = []
        player.sessionActions = PlaybackSessionActions(setPlaybackCategory: { log.append("category") },
                                                       activate: { log.append("activate") },
                                                       deactivate: { log.append("deactivate") })
        let capture = CaptureFlag()
        player.isCaptureActive = { capture.on }
        try player.load(url: url)

        // After a recording has ended, Play sets the speaker-friendly playback category again.
        player.play()
        #expect(log == ["category", "activate"])
        // Pausing hands the audio back to other apps.
        player.pause()
        #expect(log == ["category", "activate", "deactivate"])

        // While capture runs, playback neither changes the category nor deactivates the session.
        log.removeAll()
        capture.on = true
        player.play()
        player.pause()
        #expect(log == ["activate"])
    }

    @Test func aFinishedClipReleasesTheSession() throws {
        let (player, backend) = scripted(duration: 10)
        var deactivations = 0
        player.sessionActions = PlaybackSessionActions(setPlaybackCategory: {}, activate: {}, deactivate: { deactivations += 1 })
        player.playClip(url: url, range: TimeRange(start: 1, end: 2), id: "c")
        backend()?.advance(to: 2.1)
        player.tick()
        #expect(!player.isPlaying && deactivations == 1)
    }

    @Test func loadingAMissingFileThrows() {
        let player = PlaybackController()
        #expect(throws: (any Error).self) { try player.load(url: URL(fileURLWithPath: "/nonexistent/\(UUID()).wav")) }
        #expect(player.loadedURL == nil)
    }

    @Test func seekClampsToTheFile() throws {
        let (player, _) = scripted(duration: 20)
        try player.load(url: url)
        player.seek(to: -3)
        #expect(player.currentTime == 0)
        player.seek(to: 99)
        #expect(player.currentTime == 20)
        player.seek(to: 14.8)
        #expect(player.currentTime == 14.8)
    }

    @Test func rateCyclesThroughTheFourSpeeds() throws {
        let (player, backend) = scripted()
        try player.load(url: url)
        var seen: [Float] = [player.rate]
        for _ in 0..<4 { player.cycleRate(); seen.append(player.rate) }
        #expect(seen == [1, 1.5, 2, 0.75, 1])
        player.cycleRate()
        #expect(backend()?.rate == 1.5)
        #expect(DisplayFormat.rate(player.rate) == "1.5×")
    }

    @Test func rateSurvivesLoadingAnotherFile() throws {
        let (player, backend) = scripted()
        try player.load(url: url)
        player.cycleRate()
        try player.load(url: URL(fileURLWithPath: "/tmp/other.wav"))
        #expect(player.rate == 1.5)
        #expect(backend()?.rate == 1.5)
    }

    @Test func playPauseAndToggle() throws {
        let (player, backend) = scripted()
        try player.load(url: url)
        player.play()
        #expect(player.isPlaying)
        backend()?.advance(to: 3.2)
        player.tick()
        #expect(player.currentTime == 3.2)
        player.toggle()
        #expect(!player.isPlaying)
        #expect(player.currentTime == 3.2)
        player.toggle()
        #expect(player.isPlaying)
    }

    @Test func clipStopsAtTheEndOfItsRange() throws {
        let (player, backend) = scripted(duration: 24)
        player.playClip(url: url, range: TimeRange(start: 7.05, end: 10.0), id: "clip-0")
        #expect(player.isPlaying)
        #expect(player.playingClipID == "clip-0")
        #expect(player.currentTime == 7.05)

        backend()?.advance(to: 9.9)
        player.tick()
        #expect(player.isPlaying)
        #expect(player.playingClipID == "clip-0")

        backend()?.advance(to: 10.04)
        player.tick()
        #expect(!player.isPlaying)
        #expect(player.playingClipID == nil)
        #expect(player.currentTime == 10.0)
        #expect(backend()?.isPlaying == false)
    }

    @Test func playingNormallyEndsClipMode() throws {
        let (player, _) = scripted(duration: 24)
        player.playClip(url: url, range: TimeRange(start: 1, end: 2), id: "clip-1")
        player.play()
        #expect(player.playingClipID == nil)
        #expect(player.isPlaying)
        player.seek(to: 5)
        #expect(player.playingClipID == nil)
    }

    @Test func seekingEndsClipMode() throws {
        let (player, _) = scripted(duration: 24)
        player.playClip(url: url, range: TimeRange(start: 1, end: 2), id: "clip-1")
        player.seek(to: 12)
        #expect(player.playingClipID == nil)
        #expect(player.currentTime == 12)
    }

    @Test func clipOutsideTheFileIsIgnored() throws {
        let (player, _) = scripted(duration: 5)
        player.playClip(url: url, range: TimeRange(start: 6, end: 8), id: "late")
        #expect(!player.isPlaying)
        #expect(player.playingClipID == nil)
    }

    @Test func reachingTheEndRewinds() throws {
        let (player, backend) = scripted(duration: 4)
        try player.load(url: url)
        player.seek(to: 3.5)
        player.play()
        backend()?.advance(to: 4)
        player.tick()
        #expect(!player.isPlaying)
        #expect(player.currentTime == 0)
        player.play()
        #expect(player.isPlaying)
        #expect(backend()?.playCalls == 2)
    }

    @Test func stopEndsPlaybackAndClip() throws {
        let (player, _) = scripted()
        player.playClip(url: url, range: TimeRange(start: 1, end: 3), id: "c")
        player.stop()
        #expect(!player.isPlaying)
        #expect(player.playingClipID == nil)
    }
}
