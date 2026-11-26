import Foundation
import Testing
@testable import TranscribeCore

/// The alignment of a Both recording's two streams: gaps, drift either side of 20 ms, a late start, a lag over
/// 500 ms, a lost stream, a pause, the end, and that arrival order never changes the result.
@Suite("StreamAligner")
struct StreamAlignerTests {
    /// A chunk of `n` samples all equal to `v`.
    func chunk(_ n: Int, _ v: Float) -> [Float] { [Float](repeating: v, count: n) }

    /// Collects every output, in order.
    struct Collected {
        var mic: [Float] = []
        var system: [Float] = []
        mutating func add(_ o: StreamAligner.Output) {
            #expect(o.mic.count == o.system.count)
            mic += o.mic; system += o.system
        }
    }

    @Test func withoutHostTimesChunksAreAppendedAsTheyCome() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(100, 0.1), hostSeconds: nil))
        #expect(c.mic.isEmpty)   // nothing from the system stream yet
        c.add(a.push(.system, chunk(60, 0.2), hostSeconds: nil))
        #expect(c.mic == chunk(60, 0.1) && c.system == chunk(60, 0.2))
        c.add(a.finish())
        #expect(c.mic == chunk(100, 0.1))
        #expect(c.system == chunk(60, 0.2) + chunk(40, 0))
        #expect(a.insertedFrames == 0 && a.droppedFrames == 0)
    }

    @Test func aLateStartIsPaddedWithZeros() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0))
        // Mac audio's first sample is 50 ms (800 frames) after the microphone's.
        c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.05))
        #expect(c.mic == chunk(1_600, 0.1))
        #expect(c.system == chunk(800, 0) + chunk(800, 0.2))
        #expect(a.insertedFrames == 800)
        #expect(a.position(of: .system) == 2_400)
    }

    @Test func aStreamThatStartsEarlierLosesItsLeadingSamples() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0))
        // Its first sample is 30 ms (480 frames) before the anchor: those are dropped.
        c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 9.97))
        #expect(a.droppedFrames == 480)
        #expect(a.position(of: .system) == 1_120)
        #expect(c.mic == chunk(1_120, 0.1) && c.system == chunk(1_120, 0.2))
    }

    @Test func offsetsUpTo20msAreLeftAlone() {
        var a = StreamAligner()
        _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0)
        // 19 ms late (304 frames) and then 19 ms early: jitter, appended as is.
        _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.1 + 0.019)
        _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.2 - 0.019)
        #expect(a.position(of: .mic) == 4_800)
        #expect(a.insertedFrames == 0 && a.droppedFrames == 0)
        // Exactly 20 ms (320 frames) is still within tolerance.
        _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.3 + 0.02)
        #expect(a.insertedFrames == 0)
    }

    @Test func driftOver20msInsertsOrDropsThatMany() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0))
        c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.0))
        // Mac audio's clock ran slow: its next chunk is due 30 ms later than where its last one ended.
        c.add(a.push(.system, chunk(1_600, 0.3), hostSeconds: 10.1 + 0.03))
        #expect(a.insertedFrames == 480)
        // The microphone ran fast: its chunk claims to start 25 ms before where its last one ended.
        c.add(a.push(.mic, chunk(1_600, 0.4), hostSeconds: 10.1 - 0.025))
        #expect(a.droppedFrames == 400)
        #expect(a.position(of: .mic) == 2_800)
        #expect(a.position(of: .system) == 3_680)
        c.add(a.finish())
        #expect(c.system == chunk(1_600, 0.2) + chunk(480, 0) + chunk(1_600, 0.3))
        #expect(c.mic == chunk(1_600, 0.1) + chunk(1_200, 0.4) + chunk(880, 0))
    }

    @Test func aLagUnder500msWaitsAndOver500msIsFilled() {
        var a = StreamAligner()
        var c = Collected()
        for k in 0..<5 { c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k))) }
        #expect(c.mic.isEmpty)        // 500 ms behind exactly: still waiting for Mac audio
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.5))
        #expect(c.mic.count == 9_600) // 600 ms behind: Mac audio is filled with zeros
        #expect(c.system == chunk(9_600, 0))
        #expect(a.lagFilledFrames == 9_600)
        // Its audio for that stretch arrives late: dropped, and the rest goes where it belongs.
        c.add(a.push(.system, chunk(11_200, 0.2), hostSeconds: 10.0))
        #expect(a.droppedFrames == 9_600)
        #expect(a.position(of: .system) == 11_200)
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.6))
        #expect(c.system == chunk(9_600, 0) + chunk(1_600, 0.2))
        #expect(c.mic.count == 11_200)
    }

    @Test func aLostStreamIsFilledAtOnceAndIgnoredAfter() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(800, 0.1), hostSeconds: 10.0))
        c.add(a.markLost(.system))
        #expect(c.mic == chunk(800, 0.1) && c.system == chunk(800, 0))
        c.add(a.push(.system, chunk(800, 0.9), hostSeconds: 10.05))
        c.add(a.push(.mic, chunk(800, 0.1), hostSeconds: 10.05))
        #expect(a.isLost(.system))
        #expect(c.mic == chunk(1_600, 0.1) && c.system == chunk(1_600, 0))
    }

    /// Review 2026-11-26: Mac audio that comes back after it was lost is placed by its host time again.
    @Test func aRestoredStreamIsPlacedByItsHostTimeAgain() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(800, 0.1), hostSeconds: 10.0))
        c.add(a.push(.system, chunk(800, 0.2), hostSeconds: 10.0))
        c.add(a.markLost(.system))
        c.add(a.push(.mic, chunk(800, 0.1), hostSeconds: 10.05))   // 10.05–10.10: system filled with zeros
        c.add(a.markRestored(.system))
        #expect(!a.isLost(.system))
        // Mac audio is back from 10.15 (a 50 ms gap after the zeros): the gap is filled, then its audio follows.
        c.add(a.push(.system, chunk(800, 0.3), hostSeconds: 10.15))
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.10))
        #expect(c.mic == chunk(3_200, 0.1))
        #expect(c.system == chunk(800, 0.2) + chunk(1_600, 0) + chunk(800, 0.3))
    }

    @Test func aPauseLeavesNoZeros() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0))
        c.add(a.push(.system, chunk(1_200, 0.2), hostSeconds: 10.0))
        c.add(a.rebase())
        #expect(c.mic.count == 1_600 && c.system == chunk(1_200, 0.2) + chunk(400, 0))
        // Ten seconds later: the timeline carries on from 1,600, not 161,600.
        c.add(a.push(.system, chunk(1_600, 0.3), hostSeconds: 20.0))
        c.add(a.push(.mic, chunk(1_600, 0.4), hostSeconds: 20.0))
        #expect(a.position(of: .mic) == 3_200 && a.position(of: .system) == 3_200)
        #expect(a.insertedFrames == 0)
        #expect(c.mic == chunk(1_600, 0.1) + chunk(1_600, 0.4))
    }

    @Test func theMixIsClampedAndNonFiniteSamplesAreSilence() {
        let out = StreamAligner.Output(mic: [0.8, -0.8, 0.2, .nan], system: [0.7, -0.7, 0.1, 0.3])
        let mixed = out.mixed()
        #expect(mixed[0] == 1 && mixed[1] == -1 && mixed[3] == 0.3)
        #expect(abs(mixed[2] - 0.3) < 1e-6)
    }

    @Test func macAudioBeforeTheMicrophoneWaitsForItsAnchor() {
        var a = StreamAligner()
        var c = Collected()
        // Mac audio's callback runs first, with audio from 30 ms before the microphone's first sample.
        c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 9.97))
        #expect(a.position(of: .system) == 0)   // held, not placed
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0))
        #expect(a.droppedFrames == 480)
        #expect(c.mic == chunk(1_120, 0.1) && c.system == chunk(1_120, 0.2))
    }

    @Test func withoutAMicrophoneMacAudioAnchorsItselfAfter500ms() {
        var a = StreamAligner()
        var c = Collected()
        for k in 0..<5 { c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.0 + 0.1 * Double(k))) }
        #expect(a.position(of: .system) == 0)
        c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.5))
        // Placed from its own first chunk, and the silent microphone is filled up to it.
        #expect(a.position(of: .system) == 9_600)
        #expect(c.mic == chunk(9_600, 0) && c.system == chunk(9_600, 0.2))
    }

    @Test func arrivalOrderNeverChangesTheResult() {
        // The same stamped chunks of both streams, with drift and a missing chunk, delivered in many interleavings
        // (neither stream more than two chunks ahead of the other, as callbacks of 100 ms allow).
        var micChunks: [([Float], Double)] = []
        var systemChunks: [([Float], Double)] = []
        for k in 0..<20 {
            micChunks.append((chunk(1_600, Float(k) / 100), 10.0 + 0.1 * Double(k)))
            let drift = Double(k) * 0.004   // 4 ms per chunk: a correction every few chunks
            if k != 7 { systemChunks.append((chunk(1_600, Float(k) / 50 + 0.5), 10.02 + 0.1 * Double(k) + drift)) }
        }
        func run(seed: UInt64) -> (Collected, Int, Int) {
            var rng = SplitMix(seed: seed)
            var a = StreamAligner()
            var c = Collected()
            var i = 0, j = 0
            while i < micChunks.count || j < systemChunks.count {
                let micMay = i < micChunks.count && i - j < 2
                let systemMay = j < systemChunks.count && j - i < 2
                let takeMic = micMay && (!systemMay || rng.next() % 2 == 0)
                if takeMic {
                    c.add(a.push(.mic, micChunks[i].0, hostSeconds: micChunks[i].1)); i += 1
                } else {
                    c.add(a.push(.system, systemChunks[j].0, hostSeconds: systemChunks[j].1)); j += 1
                }
            }
            c.add(a.finish())
            return (c, a.insertedFrames, a.droppedFrames)
        }
        let (reference, inserted, dropped) = run(seed: 1)
        #expect(reference.mic.count == reference.system.count)
        #expect(inserted > 1_600 && dropped == 0)   // the missing chunk and the drift corrections
        for seed in 2...40 {
            let (other, _, _) = run(seed: UInt64(seed))
            #expect(other.mic == reference.mic && other.system == reference.system, "seed \(seed)")
        }
    }
}

/// A small deterministic generator for the interleavings.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
