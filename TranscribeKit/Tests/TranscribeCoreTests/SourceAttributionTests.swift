import Foundation
import Testing
@testable import TranscribeCore

/// Which stream each speaker of a Both recording was heard on (`SourceAttribution`, Mac audio, decision D1). Built on
/// hand-made frame levels, so every share is exact; the constants themselves are untested on real calls.
@Suite("Mac audio: source attribution")
struct SourceAttributionTests {
    static let f = 0.02
    static let speech: Float = -20, noise: Float = -45, silence: Float = -200

    /// Levels over `seconds`, silent except where `loud` says (ranges in seconds → level).
    static func levels(_ seconds: Double, _ loud: [(TimeRange, Float)], floor: Float = silence) -> SourceAttribution.Levels {
        let n = Int((seconds / f).rounded())
        var db = [Float](repeating: floor, count: n)
        for (range, level) in loud {
            for i in 0..<n where (Double(i) + 0.5) * f >= range.start && (Double(i) + 0.5) * f < range.end { db[i] = level }
        }
        return SourceAttribution.Levels(frameSeconds: f, dbfs: db)
    }

    static func r(_ a: Double, _ b: Double) -> TimeRange { TimeRange(start: a, end: b) }

    @Test func headphonesPutTheFarSideOnMacAudioAndTheRoomOnTheMicrophone() {
        // The far side speaks 10–20 s; on the system stem nothing else.
        let levels = Self.levels(30, [(Self.r(10, 20), Self.speech)])
        let out = SourceAttribution.attribute(speakers: ["S1": [Self.r(0, 9.5), Self.r(21, 29)], "S2": [Self.r(10, 20)]],
                                              levels: levels)
        #expect(out["S1"]?.source == .mic && out["S1"]?.share == 0 && out["S1"]?.reason == .share)
        #expect(out["S2"]?.source == .system && out["S2"]?.share == 1)
    }

    /// On a loudspeaker the microphone also hears the far side (echo), but only the system stem is read: the far side
    /// is still `system` and the room still `mic`.
    @Test func loudspeakerEchoDoesNotMatter() {
        let levels = Self.levels(30, [(Self.r(10, 20), Self.speech)])
        let analysis = SourceAttribution.analyse(levels)
        #expect(SourceAttribution.attribute(spans: [Self.r(10, 20)], levels: levels, analysis: analysis).source == .system)
        #expect(SourceAttribution.attribute(spans: [Self.r(0, 9)], levels: levels, analysis: analysis).source == .mic)
    }

    /// A noisy line hisses through the whole call 25 dB under the far side's speech: the relative floor (reference −
    /// 20 dB) keeps that hiss from counting as system speech.
    @Test func aNoisyFarLineIsNotSpeech() {
        let levels = Self.levels(30, [(Self.r(10, 20), Self.speech)], floor: Self.speech - 25)
        let analysis = SourceAttribution.analyse(levels)
        #expect(analysis.reference == Self.speech && analysis.threshold == Self.speech - 20)
        let out = SourceAttribution.attribute(speakers: ["room": [Self.r(0, 9)], "far": [Self.r(10, 20)]], levels: levels)
        #expect(out["room"]?.source == .mic && out["far"]?.source == .system)
    }

    @Test func aSilentStreamPutsEveryoneOnTheMicrophone() {
        // 99 frames of sound is under the 100-frame minimum: the stream is silent (no permission, nothing playing).
        let levels = Self.levels(30, [(Self.r(10, 10 + 99 * Self.f), Self.speech)])
        let analysis = SourceAttribution.analyse(levels)
        #expect(analysis.silent && analysis.activeFrames == 99 && analysis.threshold == nil)
        let out = SourceAttribution.attribute(spans: [Self.r(10, 12)], levels: levels, analysis: analysis)
        #expect(out == SourceAttribution.Result(source: .mic, share: nil, cleanSeconds: 2, reason: .silentStream))
        // At 100 it is not.
        let heard = Self.levels(30, [(Self.r(10, 10 + 100 * Self.f), Self.speech)])
        #expect(!SourceAttribution.analyse(heard).silent)
    }

    @Test func underThreeSecondsOfSpeechIsMixed() {
        let levels = Self.levels(30, [(Self.r(10, 20), Self.speech)])
        let analysis = SourceAttribution.analyse(levels)
        let short = SourceAttribution.attribute(spans: [Self.r(10, 12.9)], levels: levels, analysis: analysis)
        #expect(short.source == .mixed && short.reason == .shortSpeech && short.share == 1)
        #expect(SourceAttribution.attribute(spans: [Self.r(10, 13)], levels: levels, analysis: analysis).source == .system)
    }

    @Test func aTruncatedStemIsMixed() {
        // The stem stops at 20 s: a speaker at 18–30 s is covered for 2 of 12 seconds.
        let levels = Self.levels(20, [(Self.r(10, 20), Self.speech)])
        let analysis = SourceAttribution.analyse(levels)
        let cut = SourceAttribution.attribute(spans: [Self.r(18, 30)], levels: levels, analysis: analysis)
        #expect(cut.source == .mixed && cut.reason == .truncatedStem)
        // Covered for exactly half: the share decides, over the covered frames only.
        let half = SourceAttribution.attribute(spans: [Self.r(14, 26)], levels: levels, analysis: analysis)
        #expect(half.reason == .share && half.source == .system && half.share == 1)
    }

    /// 150 frames (3 s) of clean speech, `system` of them loud on the system stem.
    static func share(_ system: Int) -> SourceAttribution.Result {
        let loud = [(r(10, 13), speech), (r(20, 20 + Double(system) * f), speech)]
        let levels = levels(40, loud)
        let span = r(20, 23)
        return SourceAttribution.attribute(spans: [span], levels: levels, analysis: SourceAttribution.analyse(levels))
    }

    @Test func shareEdges() {
        #expect(Self.share(30).share == 0.2 && Self.share(30).source == .mic)
        #expect(Self.share(31).source == .mixed)
        #expect(Self.share(119).source == .mixed)
        #expect(Self.share(120).share == 0.8 && Self.share(120).source == .system)
    }

    @Test func framesBelongToTheSpanHoldingTheirCentreAndCountOnce() {
        let levels = Self.levels(10, [(Self.r(0, 10), Self.speech)])
        let analysis = SourceAttribution.analyse(levels)
        // Overlapping spans count each frame once: 4 s of frames, not 6.
        let out = SourceAttribution.attribute(spans: [Self.r(1, 4), Self.r(2, 5)], levels: levels, analysis: analysis)
        #expect(out.share == 1 && out.cleanSeconds == 6)
        // A span shorter than a frame's centre spacing that holds no centre covers nothing.
        let none = SourceAttribution.attribute(spans: [Self.r(1.001, 1.009)], levels: levels, analysis: analysis)
        #expect(none.reason == .truncatedStem && none.share == nil)
    }

    @Test func wavLevelsMatchSampleLevels() throws {
        let rate = 16_000
        // 1 s of silence, then 1 s of a 0.25-amplitude 440 Hz tone, then 10 ms.
        var samples = [Float](repeating: 0, count: rate)
        samples += (0..<rate).map { Float(0.25 * sin(2 * .pi * 440 * Double($0) / Double(rate))) }
        samples += [Float](repeating: 0.1, count: 160)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attr-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url)
        try writer.append(samples)
        try writer.finish()
        let fromFile = try SourceAttribution.levels(ofWAV: url)
        let fromSamples = SourceAttribution.levels(samples: samples, sampleRate: rate)
        #expect(fromFile.frameSeconds == 0.02 && fromFile.dbfs.count == 101 && fromSamples.dbfs.count == 101)
        for (a, b) in zip(fromFile.dbfs, fromSamples.dbfs) where b > -100 { #expect(abs(a - b) < 0.05) }
        #expect(fromFile.dbfs[0] == -200)
        // A sine of amplitude A has an RMS of A/√2: 0.25 → −15.05 dBFS.
        #expect(abs(fromFile.dbfs[75] - (-15.05)) < 0.05)
    }

    @Test func roundedShareKeepsTwoPlaces() {
        #expect(SourceAttribution.rounded(0.83333) == 0.83 && SourceAttribution.rounded(nil) == nil)
    }
}
