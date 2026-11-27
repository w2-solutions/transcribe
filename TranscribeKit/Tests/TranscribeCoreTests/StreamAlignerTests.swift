import Foundation
import Testing
@testable import TranscribeCore

/// The alignment of a Both recording's two streams: a late or early start (and its 20 ms tolerance), jitter that is
/// never corrected, a jump in a stream's own host times (a rebuild or restart) placed at once, a stall corrected at
/// once, slow drift corrected by the median in 20 ms steps, capture-filled gaps, a lag over 500 ms, a lost stream, a
/// pause, the end, and that arrival order never changes the result.
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

    /// A first chunk within 20 ms of host time is appended as it is; 21 ms is placed (zeros, or dropped samples).
    @Test func aFirstChunkWithin20msIsLeftAlone() {
        for (offsetMs, inserted, dropped) in [(19, 0, 0), (20, 0, 0), (21, 336, 0), (-19, 0, 0), (-20, 0, 0), (-21, 0, 336)] {
            var a = StreamAligner()
            var c = Collected()
            c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0))
            c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.0 + Double(offsetMs) / 1_000))
            #expect(a.insertedFrames == inserted && a.droppedFrames == dropped, "\(offsetMs) ms")
            if inserted == 0 && dropped == 0 { #expect(c.system == chunk(1_600, 0.2), "\(offsetMs) ms") }
        }
        // The same for the first chunk after a pause.
        var a = StreamAligner()
        _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0)
        _ = a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.0)
        _ = a.rebase()
        _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 20.0)
        _ = a.push(.system, chunk(1_600, 0.2), hostSeconds: 20.020)
        #expect(a.insertedFrames == 0)
        _ = a.rebase()
        _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 30.0)
        _ = a.push(.system, chunk(1_600, 0.2), hostSeconds: 30.021)
        #expect(a.insertedFrames == 336)
    }

    /// 2026-11-27: after its first chunk a stream is appended as it comes; a single late or early chunk (19 ms, 30 ms,
    /// 25 ms) never inserts zeros or drops samples.
    @Test func laterChunksAreAppendedWhateverTheirJitter() {
        var a = StreamAligner()
        var c = Collected()
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0))
        c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.0))
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.1 + 0.019))
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.2 - 0.019))
        c.add(a.push(.system, chunk(1_600, 0.3), hostSeconds: 10.1 + 0.03))
        c.add(a.push(.mic, chunk(1_600, 0.4), hostSeconds: 10.3 - 0.025))
        #expect(a.position(of: .mic) == 6_400 && a.position(of: .system) == 3_200)
        #expect(a.insertedFrames == 0 && a.droppedFrames == 0 && a.corrections == 0)
        c.add(a.finish())
        #expect(c.system == chunk(1_600, 0.2) + chunk(1_600, 0.3) + chunk(3_200, 0))
        #expect(c.mic == chunk(4_800, 0.1) + chunk(1_600, 0.4))
    }

    /// 2026-11-27: ±30 ms of host-time jitter on every chunk of both streams (more than one call-mode IO cycle) for
    /// 10 s leaves both streams contiguous: nothing inserted, dropped or corrected.
    @Test func jitteredChunksAreNeverCorrected() {
        let jitterMs: [Double] = [0, 30, -20, 10, -30, 25, -10, 20, -25, 5, 15, -30, 30, -5, -15]
        var a = StreamAligner()
        var c = Collected()
        var sent: [Float] = []
        for k in 0..<100 {
            let micJitter = jitterMs[k % jitterMs.count] / 1_000
            let systemJitter = jitterMs[(k * 7) % jitterMs.count] / 1_000
            let samples = chunk(1_600, Float(k % 10) / 20)
            sent += samples
            c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k) + micJitter))
            c.add(a.push(.system, samples, hostSeconds: 10.0 + 0.1 * Double(k) + systemJitter))
        }
        c.add(a.finish())
        #expect(a.counters(of: .mic) == StreamAligner.Counters())
        #expect(a.counters(of: .system) == StreamAligner.Counters())
        #expect(c.system == sent && c.mic == chunk(160_000, 0.1))
    }

    /// Mac audio starting 100 ms after the microphone, steadily: placed once by its first chunk, then left alone.
    @Test func aSteady100msLateStartIsCorrectedOnce() {
        var a = StreamAligner()
        var c = Collected()
        for k in 0..<50 {
            c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k)))
            c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.1 + 0.1 * Double(k)))
        }
        c.add(a.finish())
        #expect(a.counters(of: .system) == StreamAligner.Counters(inserted: 1_600, corrections: 1))
        #expect(a.counters(of: .mic) == StreamAligner.Counters())
        #expect(c.system == chunk(1_600, 0) + chunk(80_000, 0.2))
        #expect(c.mic == chunk(80_000, 0.1) + chunk(1_600, 0))
    }

    /// Review 2026-11-27: a 100 ms hole in a stream's own host times (one the capture could not fill) is a restart:
    /// that chunk is placed by host time at once, with the zeros where the hole was, and never corrected again.
    @Test func aHoleInTheHostTimesIsPlacedAtOnce() {
        var a = StreamAligner()
        var c = Collected()
        var expected: [Float] = []
        for k in 0..<60 {
            let step = k >= 3 ? 0.1 : 0
            let samples = chunk(1_600, Float(k % 10) / 20)
            c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k)))
            c.add(a.push(.system, samples, hostSeconds: 10.0 + 0.1 * Double(k) + step))
            if k == 3 { expected += chunk(1_600, 0) }
            expected += samples
        }
        c.add(a.finish())
        #expect(a.counters(of: .system) == StreamAligner.Counters(inserted: 1_600, corrections: 1))
        #expect(Array(c.system.prefix(expected.count)) == expected)
    }

    /// Review 2026-11-27: Mac audio's aggregate rebuilt while running (no lost or restored event) leaves a 300 ms gap
    /// whose host times then carry on contiguously. The first chunk after it is placed by host time at once: 4,800
    /// zeros where the gap was, no correction later.
    @Test func aRebuildGapIsPlacedAtOnce() {
        var a = StreamAligner()
        var c = Collected()
        var expected: [Float] = []
        // 20 ms chunks of Mac audio; chunks 50 to 64 (300 ms) never come.
        for k in 0..<300 {
            let host = 10.0 + 0.02 * Double(k)
            if k % 5 == 0 { c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.02 * Double(k))) }
            if (50..<65).contains(k) {
                expected += chunk(320, 0)
                continue
            }
            let samples = chunk(320, Float(k % 9 + 1) / 10)
            expected += samples
            c.add(a.push(.system, samples, hostSeconds: host))
            if k == 65 { #expect(a.counters(of: .system) == StreamAligner.Counters(inserted: 4_800, corrections: 1)) }
        }
        c.add(a.finish())
        #expect(a.counters(of: .system) == StreamAligner.Counters(inserted: 4_800, corrections: 1))
        #expect(Array(c.system.prefix(expected.count)) == expected)
    }

    /// Review 2026-11-27: the microphone's engine restarted (as after every aggregate build) with a 300 ms gap: its
    /// first chunk after it is placed at once, and Mac audio is left alone.
    @Test func aMicrophoneRestartGapIsPlacedAtOnce() {
        var a = StreamAligner()
        var c = Collected()
        var expected: [Float] = []
        for k in 0..<60 {
            let host = 10.0 + 0.1 * Double(k)
            c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: host))
            if k == 10 || k == 11 || k == 12 {   // 300 ms with no microphone chunks
                expected += chunk(1_600, 0)
                continue
            }
            let samples = chunk(1_600, Float(k % 9 + 1) / 10)
            expected += samples
            c.add(a.push(.mic, samples, hostSeconds: host))
        }
        c.add(a.finish())
        #expect(a.counters(of: .mic) == StreamAligner.Counters(inserted: 4_800, corrections: 1))
        #expect(a.counters(of: .system) == StreamAligner.Counters())
        #expect(Array(c.mic.prefix(expected.count)) == expected)
    }

    /// A 600 ms stall (more than the 500 ms hard limit) is filled at once, at the chunk that shows it.
    @Test func a600msStallIsFilledAtOnce() {
        var a = StreamAligner()
        var c = Collected()
        for k in 0..<5 {
            c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k)))
            c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.0 + 0.1 * Double(k)))
        }
        // The microphone is 400 ms ahead (not yet lagging by 500 ms) when Mac audio comes back 600 ms late.
        for k in 5..<9 { c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k))) }
        c.add(a.push(.system, chunk(1_600, 0.3), hostSeconds: 10.5 + 0.6))
        #expect(a.counters(of: .system) == StreamAligner.Counters(inserted: 9_600, corrections: 1))
        #expect(a.position(of: .system) == 8_000 + 9_600 + 1_600)
        for k in 9..<13 { c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k))) }
        #expect(a.lagFilledFrames == 0)
        c.add(a.finish())
        #expect(c.system == chunk(8_000, 0.2) + chunk(9_600, 0) + chunk(1_600, 0.3) + chunk(1_600, 0))
        #expect(c.mic == chunk(20_800, 0.1))
    }

    /// A stall that the other stream outruns by 500 ms is filled as it happens, and the stream is placed by its host
    /// time when it comes back.
    @Test func aStallTheOtherStreamOutrunsIsFilledAndPlacedAgain() {
        var a = StreamAligner()
        var c = Collected()
        for k in 0..<5 {
            c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k)))
            c.add(a.push(.system, chunk(1_600, 0.2), hostSeconds: 10.0 + 0.1 * Double(k)))
        }
        // Mac audio stops for 800 ms; the microphone carries on.
        for k in 5..<13 { c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k))) }
        #expect(a.lagFilledFrames == 9_600)
        c.add(a.push(.system, chunk(1_600, 0.3), hostSeconds: 11.3))
        c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 11.3))
        c.add(a.finish())
        #expect(a.counters(of: .system) == StreamAligner.Counters(inserted: 3_200, filled: 9_600, corrections: 1))
        #expect(c.system == chunk(8_000, 0.2) + chunk(12_800, 0) + chunk(1_600, 0.3))
        #expect(c.mic == chunk(22_400, 0.1))
    }

    /// A stream whose clock runs 50 ppm slow drifts 3 ms a minute: it is left alone until the median offset of its
    /// last 2 s passes 80 ms (after about 27 minutes), and then moved back in steps of at most 20 ms, at most one per
    /// 250 ms of the stream (review 2026-11-27: one 80 ms cut or hole is audible).
    @Test func slowDriftIsCorrectedOnlyAfterItPasses80msIn20msSteps() {
        var a = StreamAligner()
        let frames = 4_000   // 250 ms chunks
        let micChunk = chunk(frames, 0.1), systemChunk = chunk(frames, 0.2)
        var moves: [(chunk: Int, frames: Int)] = []
        func push(_ k: Int) {
            let before = a.insertedFrames
            _ = a.push(.mic, micChunk, hostSeconds: 10.0 + 0.25 * Double(k))
            _ = a.push(.system, systemChunk, hostSeconds: 10.0 + 0.25 * Double(k) * 1.000_05)
            if a.insertedFrames != before { moves.append((k, a.insertedFrames - before)) }
        }
        // 75 ms behind after 6,000 chunks (25 minutes): not corrected.
        for k in 0..<6_000 { push(k) }
        #expect(a.corrections == 0 && a.insertedFrames == 0 && a.droppedFrames == 0)
        for k in 6_000..<7_000 { push(k) }
        let system = a.counters(of: .system)
        #expect(system.dropped == 0)
        #expect(system.inserted > 1_280 && system.inserted < 1_300)
        #expect(system.corrections == 5)                               // 4 × 320 and the rest
        #expect(moves.allSatisfy { $0.frames <= a.correctionStepFrames })
        for (m, n) in zip(moves, moves.dropFirst()) { #expect(n.chunk - m.chunk == 1) }   // one per 250 ms chunk
        #expect(a.counters(of: .mic) == StreamAligner.Counters())
    }

    /// The same drift in 20 ms chunks: still at most one 20 ms step per 250 ms, never one per chunk.
    @Test func driftStepsAreSpreadOverTheStreamNotItsChunks() {
        var a = StreamAligner(correctionWindowFrames: 3_200)
        var stepsAt: [Int] = []
        for k in 0..<2_000 {
            let before = a.insertedFrames
            if k % 5 == 0 { _ = a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.02 * Double(k)) }
            // 2% slow: 6.4 frames behind per chunk, so the median passes 80 ms within the first seconds.
            _ = a.push(.system, chunk(320, 0.2), hostSeconds: 10.0 + 0.02 * Double(k) * 1.02)
            let moved = a.insertedFrames - before
            if moved > 0 { stepsAt.append(k); #expect(moved <= 320) }
        }
        #expect(stepsAt.count >= 5)
        for (m, n) in zip(stepsAt, stepsAt.dropFirst()) { #expect(n - m >= 13, "steps at \(m) and \(n)") }
    }

    /// 2026-11-27: Mac audio in 20 ms call-mode IO cycles, with every third cycle skipped by the device and filled
    /// with zeros by the capture (stamped where it belongs), and late cycles up to 15 ms, stays exactly what was sent.
    @Test func macAudioWithCaptureFilledGapsStaysContiguous() {
        var a = StreamAligner()
        var c = Collected()
        var sent: [Float] = []
        let lateMs: [Double] = [0, 15, 5, 0, 10, 0, 15, 2]
        var cycle = 0
        for k in 0..<50 {
            c.add(a.push(.mic, chunk(1_600, 0.1), hostSeconds: 10.0 + 0.1 * Double(k)))
            for _ in 0..<5 {
                let host = 10.0 + 0.02 * Double(cycle)
                if cycle % 3 == 2 {
                    sent += chunk(320, 0)   // the capture's zeros, stamped exactly
                    c.add(a.push(.system, chunk(320, 0), hostSeconds: host))
                } else {
                    let samples = chunk(320, Float(cycle % 7 + 1) / 10)
                    sent += samples
                    c.add(a.push(.system, samples, hostSeconds: host + lateMs[cycle % lateMs.count] / 1_000))
                }
                cycle += 1
            }
        }
        c.add(a.finish())
        #expect(a.counters(of: .system) == StreamAligner.Counters())
        #expect(a.counters(of: .mic) == StreamAligner.Counters())
        #expect(c.system == sent && c.mic == chunk(80_000, 0.1))
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
        // The same stamped chunks of both streams, with jitter, a missing chunk and drift (so the median corrects
        // more than once), delivered in many interleavings (neither stream more than two chunks ahead of the other,
        // as callbacks of 100 ms allow).
        let jitterMs: [Double] = [0, 12, -8, 15, -14, 6, -3, 10]
        var micChunks: [([Float], Double)] = []
        var systemChunks: [([Float], Double)] = []
        for k in 0..<100 {
            micChunks.append((chunk(1_600, Float(k % 50) / 100), 10.0 + 0.1 * Double(k)))
            let drift = Double(k) * 0.002   // 2 ms per chunk
            let jitter = jitterMs[k % jitterMs.count] / 1_000
            if k != 7 {
                systemChunks.append((chunk(1_600, Float(k % 25) / 50 + 0.5), 10.02 + 0.1 * Double(k) + drift + jitter))
            }
        }
        func run(seed: UInt64) -> (Collected, StreamAligner) {
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
            return (c, a)
        }
        let (reference, aligner) = run(seed: 1)
        #expect(reference.mic.count == reference.system.count)
        // The missing chunk and the drift: corrected by the median, more than once; nothing dropped, nothing filled.
        #expect(aligner.insertedFrames > 1_600 && aligner.droppedFrames == 0 && aligner.lagFilledFrames == 0)
        #expect(aligner.counters(of: .system).corrections >= 2 && aligner.counters(of: .mic).corrections == 0)
        for seed in 2...40 {
            let (other, _) = run(seed: UInt64(seed))
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
