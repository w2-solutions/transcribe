#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFluid

/// The pure rules behind Mac audio's clock and rebuilds (2026-11-27, Bose QC headphones on macOS 27): which clock
/// composition is tried, which notices rebuild (the rebuild loop of that day), how often, what a rate verdict does,
/// zeros for skipped IO cycles and the IO heartbeat. The Core Audio side runs only in the gated `RealMacAudioTests`.
@Suite("Mac audio: clock plan, rebuild policy, gap fill")
struct TapClockTests {
    // MARK: Clock plan

    @Test func theTapClockIsTriedFirstThenTheBuiltInOutputThenTheOutput() {
        let plan = TapClockPlan()
        #expect(plan.attempts(outputUID: "bose") == [.tap, .builtIn, .output])
        #expect(TapClockPlan.order == [.tap, .builtIn, .output])
        #expect(TapClockPlan.firstIOTimeout == .seconds(2))
    }

    /// The DEBUG override picks the first mode; the others still follow in the usual order.
    @Test func theOverrideOnlyPicksTheFirstMode() {
        #expect(TapClockPlan.preferred(override: nil) == .tap)
        #expect(TapClockPlan.preferred(override: "output") == .output)
        #expect(TapClockPlan.preferred(override: "builtIn") == .builtIn)
        #expect(TapClockPlan.preferred(override: "speakers") == .tap)     // unknown: the default
        #expect(TapClockPlan(preferred: .output).attempts(outputUID: nil) == [.output, .tap, .builtIn])
        #expect(TapClockPlan(preferred: .builtIn).attempts(outputUID: nil) == [.builtIn, .tap, .output])
    }

    /// The mode that worked is kept; only the `output` clock, which is the default output, starts again from the
    /// preferred mode when the default output changed (review 2026-11-27).
    @Test func theModeThatWorkedIsKeptAndTheOutputClockOnlyForItsOutput() {
        var plan = TapClockPlan()
        plan.confirmed(.builtIn, outputUID: "bose")
        #expect(plan.attempts(outputUID: "bose") == [.builtIn, .tap, .output])   // rebuilds start from it
        #expect(plan.attempts(outputUID: "speakers") == [.builtIn, .tap, .output])
        #expect(plan.attempts(outputUID: nil) == [.builtIn, .tap, .output])
        plan.confirmed(.output, outputUID: "bose")
        #expect(plan.attempts(outputUID: "bose") == [.output, .tap, .builtIn])
        #expect(plan.attempts(outputUID: "speakers") == [.tap, .builtIn, .output])
        plan.forget()                                                             // every mode failed
        #expect(plan.attempts(outputUID: "bose") == [.tap, .builtIn, .output])
    }

    /// Review 2026-11-27: a mode that started and delivered no IO is not tried again this recording (a later notice,
    /// retry or rebuild would otherwise lose another 2 s on it), unless every mode did.
    @Test func aModeWithNoIOIsLeftOutUntilEveryModeHadNone() {
        var plan = TapClockPlan()
        plan.noIO(.tap)
        #expect(plan.attempts(outputUID: "bose") == [.builtIn, .output])
        plan.confirmed(.builtIn, outputUID: "bose")
        #expect(plan.attempts(outputUID: "bose") == [.builtIn, .output])
        plan.noIO(.builtIn)                                                       // the kept mode stopped delivering
        #expect(plan.working == nil && plan.attempts(outputUID: "bose") == [.output])
        plan.noIO(.output)
        #expect(plan.attempts(outputUID: "bose") == [.tap, .builtIn, .output])   // none left: all again
        plan.confirmed(.tap, outputUID: "bose")
        #expect(plan.attempts(outputUID: "bose") == [.tap])
    }

    /// Review 2026-11-27: the HAL applies a rate set asynchronously. The read-back is repeated until it is the rate
    /// set (so the converter and the later rate notice see 48 kHz), and gives up after 0.5 s with what it read.
    @Test func theTapClockRateIsReadBackUntilItSettles() {
        var reads = 0
        var slept = 0.0
        let settled = TapRateSettle.wait(for: 48_000, read: {
            reads += 1
            return reads < 4 ? 44_100 : 48_000          // the old rate for the first three reads
        }, sleep: { slept += $0 })
        #expect(settled == 48_000 && reads == 4 && abs(slept - 0.03) < 1e-9)
        reads = 0; slept = 0
        let stuck = TapRateSettle.wait(for: 48_000, read: { reads += 1; return 44_100 }, sleep: { slept += $0 })
        #expect(stuck == 44_100 && abs(slept - TapRateSettle.timeout) < 1e-6 && reads == 51)
        reads = 0
        #expect(TapRateSettle.wait(for: 48_000, read: { reads += 1; return 48_000 }, sleep: { _ in }) == 48_000)
        #expect(reads == 1)
    }

    // MARK: Rebuild policy

    @Test func theDefaultOutputRebuildsOnlyTheOutputClockAndOnlyWhenItChanged() {
        let same = TapNotice.defaultOutput(currentUID: "bose", builtUID: "bose")
        let other = TapNotice.defaultOutput(currentUID: "speakers", builtUID: "bose")
        for mode in [MacAudioClock.tap, .builtIn] {
            #expect(TapRebuildPolicy.decide(same, mode: mode) == .routeOnly)
            #expect(TapRebuildPolicy.decide(other, mode: mode) == .routeOnly)    // the global tap follows it
        }
        #expect(TapRebuildPolicy.decide(same, mode: .output) == .ignore)
        #expect(TapRebuildPolicy.decide(other, mode: .output) == .rebuild)
        // Lost (no aggregate): only a real change tries again.
        #expect(TapRebuildPolicy.decide(same, mode: nil) == .ignore)
        #expect(TapRebuildPolicy.decide(other, mode: nil) == .rebuild)
        #expect(TapRebuildPolicy.decide(.defaultOutput(currentUID: nil, builtUID: "bose"), mode: .output) == .rebuild)
    }

    @Test func otherNoticesRebuildOnlyWhenSomethingDiffersOrDied() {
        for mode in [MacAudioClock?.some(.tap), .builtIn, .output, nil] {
            #expect(TapRebuildPolicy.decide(.tapFormat(same: true), mode: mode) == .ignore)
            #expect(TapRebuildPolicy.decide(.tapFormat(same: false), mode: mode) == .rebuild)
            #expect(TapRebuildPolicy.decide(.composition(same: true), mode: mode) == .ignore)
            #expect(TapRebuildPolicy.decide(.composition(same: false), mode: mode) == .rebuild)
            #expect(TapRebuildPolicy.decide(.inputStreams(same: true), mode: mode) == .ignore)
            #expect(TapRebuildPolicy.decide(.inputStreams(same: false), mode: mode) == .rebuild)
            #expect(TapRebuildPolicy.decide(.ioFormat(same: true), mode: mode) == .ignore)
            #expect(TapRebuildPolicy.decide(.ioFormat(same: false), mode: mode) == .rebuild)
            #expect(TapRebuildPolicy.decide(.aggregateAlive(true), mode: mode) == .ignore)
            #expect(TapRebuildPolicy.decide(.aggregateAlive(false), mode: mode) == .rebuild)
        }
        // The built-in (or output) device that clocks the aggregate dying; the tap clock has none.
        #expect(TapRebuildPolicy.decide(.clockDeviceAlive(false), mode: .builtIn) == .rebuild)
        #expect(TapRebuildPolicy.decide(.clockDeviceAlive(false), mode: .output) == .rebuild)
        #expect(TapRebuildPolicy.decide(.clockDeviceAlive(false), mode: .tap) == .ignore)
        #expect(TapRebuildPolicy.decide(.clockDeviceAlive(true), mode: .builtIn) == .ignore)
    }

    /// Runs default-output notices (time, UID) through the policy and the limiter as the capture does, and returns
    /// the times rebuilds ran and the output the last one was built for. A rebuild builds for the output current at
    /// that time. `directRebuilds` are rebuilds that run at once (retries, resumes, fallbacks).
    func simulate(mode: MacAudioClock?, notices: [(Double, String)], builtUID: String, until end: Double,
                  directRebuilds: [Double] = []) -> (rebuilds: [Double], built: String) {
        enum Event { case notice(String), fire, direct }
        var events: [(time: Double, event: Event)] = notices.map { ($0.0, .notice($0.1)) }
            + directRebuilds.map { ($0, .direct) }
        var limiter = TapRebuildLimiter()
        var rebuilds: [Double] = []
        var built = builtUID
        var current = builtUID
        while let i = events.indices.min(by: { events[$0].time < events[$1].time }), events[i].time <= end {
            let (time, event) = events.remove(at: i)
            switch event {
            case .fire:
                switch limiter.fire(at: time) {
                case .rebuild:
                    limiter.rebuilt(at: time)
                    rebuilds.append(time)
                    built = current
                case .skip: break
                case .wait(let more): events.append((time + more, .fire))
                }
            case .direct:
                limiter.rebuilt(at: time)
                rebuilds.append(time)
                built = current
            case .notice(let uid):
                current = uid
                guard TapRebuildPolicy.decide(.defaultOutput(currentUID: uid, builtUID: built), mode: mode) == .rebuild,
                      let delay = limiter.request(at: time) else { continue }
                events.append((time + delay, .fire))
            }
        }
        return (rebuilds, built)
    }

    /// The 2026-11-27 loop: default-output notices every 0.29 s for 20 s, all naming the output the aggregate was built
    /// for (our own aggregate's creation made coreaudiod pick the defaults again). None of them rebuilds, in any mode.
    @Test func echoesOfOurOwnBuildNeverRebuild() {
        let echoes = (0..<70).map { (Double($0) * 0.29, "bose") }
        for mode in MacAudioClock.allCases {
            #expect(simulate(mode: mode, notices: echoes, builtUID: "bose", until: 30).rebuilds.isEmpty, "\(mode)")
        }
        // Lost: the same echoes of the last attempt never try again either.
        #expect(simulate(mode: nil, notices: echoes, builtUID: "bose", until: 30).rebuilds.isEmpty)
    }

    /// Even when every notice names another output (the worst case), with the output clock: at most one rebuild a
    /// second, each at least a second after the one before, and the last change is always built for.
    @Test func rebuildsAreAtMostOneASecond() {
        let flapping = (0..<70).map { (Double($0) * 0.29, $0 % 2 == 0 ? "speakers" : "bose") }
        let result = simulate(mode: .output, notices: flapping, builtUID: "bose", until: 30)
        #expect(result.rebuilds.count >= 15 && result.rebuilds.count <= 21, "\(result.rebuilds.count) rebuilds")
        for (a, b) in zip(result.rebuilds, result.rebuilds.dropFirst()) {
            #expect(b - a >= TapRebuildLimiter.minInterval - 1e-9)
        }
        #expect(result.built == flapping.last!.1)                          // "bose", the last notice's output
        // A burst that ends on the other output: a dropped trailing rebuild would leave "bose" built.
        let ending = Array(flapping.dropLast())
        #expect(simulate(mode: .output, notices: ending, builtUID: "bose", until: 30).built == ending.last!.1)
        // The same flapping with the tap or built-in clock rebuilds nothing.
        #expect(simulate(mode: .tap, notices: flapping, builtUID: "bose", until: 30).rebuilds.isEmpty)
        #expect(simulate(mode: .builtIn, notices: flapping, builtUID: "bose", until: 30).rebuilds.isEmpty)
    }

    @Test func aNoticeSoonerThanASecondWaitsAndJoinsThePendingRebuild() {
        var limiter = TapRebuildLimiter()
        #expect(limiter.request(at: 10) == TapRebuildLimiter.settle)      // the first: after the settle
        #expect(limiter.request(at: 10.1) == nil)                          // joins the pending one
        #expect(limiter.fire(at: 10.25) == .rebuild)
        limiter.rebuilt(at: 10.25)
        let wait = limiter.request(at: 10.5)
        #expect(wait.map { abs($0 - 0.75) < 1e-9 } == true)                // remembered until the second has passed
        #expect(limiter.fire(at: 11.25) == .rebuild)
        limiter.rebuilt(at: 11.25)
        #expect(limiter.request(at: 20) == TapRebuildLimiter.settle)       // long after: just the settle
    }

    /// Review 2026-11-27: a rebuild that runs at once (a retry, a resume, a clock fallback) while one is pending. The
    /// pending one is dropped when all its notices came before that rebuild, and waits a second after it otherwise.
    @Test func aDirectRebuildDropsOrDelaysThePendingOne() {
        var limiter = TapRebuildLimiter()
        #expect(limiter.request(at: 10) == TapRebuildLimiter.settle)
        limiter.rebuilt(at: 10.1)                                          // the watchdog fell back meanwhile
        #expect(limiter.fire(at: 10.25) == .skip && !limiter.pending)
        // A notice after the direct rebuild: still rebuilt, but a second after it.
        #expect(limiter.request(at: 20) == TapRebuildLimiter.settle)
        limiter.rebuilt(at: 20.1)
        #expect(limiter.request(at: 20.2) == nil)                          // joins, and is newer than the rebuild
        let fire = limiter.fire(at: 20.25)
        #expect(fire == .wait(20.1 + TapRebuildLimiter.minInterval - 20.25) || {
            if case .wait(let w) = fire { return abs(w - 0.85) < 1e-9 }; return false
        }())
        #expect(limiter.pending)
        #expect(limiter.fire(at: 21.1) == .rebuild && !limiter.pending)
        // End to end: a retry at 0.1 s after a notice at 0: one rebuild, the retry's.
        let result = simulate(mode: .output, notices: [(0, "speakers")], builtUID: "bose", until: 5, directRebuilds: [0.1])
        #expect(result.rebuilds == [0.1] && result.built == "speakers")
    }

    // MARK: Rate verdict

    @Test func aRateVerdictRebuildsTwiceThenConvertsFromTheMeasuredRate() {
        #expect(TapRateResponse.decide(rateRebuildsSoFar: 0) == .rebuild)
        #expect(TapRateResponse.decide(rateRebuildsSoFar: 1) == .rebuild)
        #expect(TapRateResponse.decide(rateRebuildsSoFar: 2) == .convertFromMeasured)
        #expect(TapRateResponse.decide(rateRebuildsSoFar: 5) == .convertFromMeasured)
    }

    @Test func aPausedTapClockResumesInPlaceOnAnotherOutput() {
        var f = AudioStreamBasicDescription()
        f.mSampleRate = 48_000; f.mFormatID = kAudioFormatLinearPCM; f.mBytesPerFrame = 4; f.mChannelsPerFrame = 1
        func plan(_ mode: MacAudioClock, built: String? = "bose", current: String? = "speakers") -> Bool {
            TapResumePlan.canResumeInPlace(mode: mode, changedWhilePaused: false, aggregateAlive: true,
                                           builtOutputUID: built, currentOutputUID: current, builtFormat: f, currentFormat: f)
        }
        #expect(plan(.tap) && plan(.builtIn) && plan(.tap, built: nil, current: nil))
        #expect(!plan(.output))
        #expect(plan(.output, current: "bose"))
    }

    // MARK: Gap fill

    @Test func skippedCyclesBecomeZerosWhereTheyBelong() {
        var fill = TapGapFill()
        #expect(fill.observe(frames: 320, host: 1.00, sampleTime: 0, rate: 16_000) == nil)
        #expect(fill.observe(frames: 320, host: 1.02, sampleTime: 320, rate: 16_000) == nil)    // contiguous
        // Two 20 ms cycles never arrived: 640 frames, at 16 kHz 640 zeros, from the end of the previous buffer.
        let gap = fill.observe(frames: 320, host: 1.08, sampleTime: 1_280, rate: 16_000)
        #expect(gap?.frames == 640 && gap?.samples == 640)
        #expect(gap.map { abs($0.hostSeconds - 1.04) < 1e-9 } == true)
        // At 48 kHz, 480 skipped frames are 160 zeros at 16 kHz.
        var fill48 = TapGapFill()
        _ = fill48.observe(frames: 480, host: 2.00, sampleTime: 0, rate: 48_000)
        let gap48 = fill48.observe(frames: 480, host: 2.02, sampleTime: 960, rate: 48_000)
        #expect(gap48?.frames == 480 && gap48?.samples == 160)
        #expect(fill.filledFrames == 640 && fill48.filledFrames == 480)
    }

    @Test func zerosAreFilledOnlyWithinOneRunWhoseHostTimeAgrees() {
        var fill = TapGapFill()
        _ = fill.observe(frames: 320, host: 1.00, sampleTime: 0, rate: 16_000)
        // The host time says 20 ms passed while the sample time says 60 ms: they disagree, nothing is filled.
        #expect(fill.observe(frames: 320, host: 1.02, sampleTime: 960, rate: 16_000) == nil)
        // A host gap longer than maxGap (IO stalled or restarted), sample and host time agreeing.
        #expect(fill.observe(frames: 320, host: 1.62, sampleTime: 10_560, rate: 16_000) == nil)
        // A sample time that goes back.
        #expect(fill.observe(frames: 320, host: 1.64, sampleTime: 0, rate: 16_000) == nil)
        // No sample time, or no host time.
        #expect(fill.observe(frames: 320, host: 1.66, sampleTime: nil, rate: 16_000) == nil)
        #expect(fill.observe(frames: 320, host: nil, sampleTime: 960, rate: 16_000) == nil)
        // A pause in between.
        _ = fill.observe(frames: 320, host: 2.00, sampleTime: 10_000, rate: 16_000)
        fill.breakRun()
        #expect(fill.observe(frames: 320, host: 2.10, sampleTime: 11_600, rate: 16_000) == nil)
        #expect(fill.filledFrames == 0)
    }

    /// Review 2026-11-27: the fill reaches as far as the aligner's hard correction (0.5 s), so a 300 ms run of skipped
    /// cycles is filled in place rather than left for the aligner's median.
    @Test func skippedRunsUpToHalfASecondAreFilled() {
        #expect(TapGapFill.maxGap == 0.5)
        var fill = TapGapFill()
        _ = fill.observe(frames: 320, host: 1.00, sampleTime: 0, rate: 16_000)
        let gap = fill.observe(frames: 320, host: 1.32, sampleTime: 5_120, rate: 16_000)    // 300 ms skipped
        #expect(gap?.frames == 4_800 && gap?.samples == 4_800)
    }

    /// End to end: 16 kHz IO in 20 ms cycles of which every third never arrives (the re-anchor storm of
    /// 2026-11-27). The receiver delivers one contiguous stream: zeros for each missing cycle, stamped where it
    /// belonged, and the total length is the time that passed.
    @Test func theReceiverDeliversAContiguousStreamThroughSkippedCycles() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(TapConverter(inputFormat: format))
        let ring = TapRing(slotCount: 64, bufferCount: 1, bytesPerBuffer: 4 * 4_800, expectedBufferCount: 1)
        let got = Mutex<[(count: Int, host: Double?, zeros: Bool)]>([])
        let receiver = TapReceiver(format: format, converter: converter, ring: ring, firstIndex: 0, bytesPerFrame: 4,
                                   queue: DispatchQueue(label: "test.tap.gaps"), deliver: { input in
                                       if case .audio(let samples, let host) = input {
                                           got.withLock { $0.append((samples.count, host, samples.allSatisfy { $0 == 0 })) }
                                       }
                                   }, silentFrames: 1_000_000, onLongSilence: {})
        let start = 1_000.0
        let cycles = 150
        for k in 0..<cycles where k % 3 != 1 {
            let tone = (0..<320).map { Float(0.25 * sin(2 * Double.pi * 440 * Double(k * 320 + $0) / 16_000)) }
            var stamp = AudioTimeStamp()
            stamp.mHostTime = AVAudioTime.hostTime(forSeconds: start + Double(k) * 0.02)
            stamp.mSampleTime = Double(k * 320)
            stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
            var none = AudioTimeStamp()
            withList([tone]) { list in
                receiver.ioBlock(&none, list, &stamp, UnsafeMutablePointer(mutating: list), &none)
            }
            if k % 8 == 7 { receiver.flush() }
        }
        receiver.flush()
        let chunks = got.withLock { $0 }
        let zeroChunks = chunks.filter(\.zeros)
        #expect(zeroChunks.count == cycles / 3 && zeroChunks.allSatisfy { $0.count == 320 })
        if let firstGap = zeroChunks.first?.host {
            #expect(abs(firstGap - (start + 0.02)) < 0.001, "the first gap was stamped at \(firstGap - start)")
        }
        // The whole span, within the converter's delay.
        let total = chunks.map(\.count).reduce(0, +)
        #expect(abs(total - cycles * 320) <= 64, "delivered \(total)")
        #expect(receiver.filledFrames == cycles / 3 * 320)
        receiver.finish()
    }

    /// The same at 48 kHz, as the `tap` clock runs (review 2026-11-27): 480 frames per 10 ms cycle, every third
    /// missing, through the resampler, which holds a tail of each buffer. The zeros go through the converter too, so
    /// the held tail comes out before them: the total is the time that passed and every zero run starts within the
    /// converter's delay of where its missing cycle belonged.
    @Test func theReceiverDeliversAContiguousStreamThroughSkippedCyclesAt48kHz() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try #require(TapConverter(inputFormat: format))
        let ring = TapRing(slotCount: 64, bufferCount: 1, bytesPerBuffer: 4 * 4_800, expectedBufferCount: 1)
        let got = Mutex<[Float]>([])
        let receiver = TapReceiver(format: format, converter: converter, ring: ring, firstIndex: 0, bytesPerFrame: 4,
                                   queue: DispatchQueue(label: "test.tap.gaps48"), deliver: { input in
                                       if case .audio(let samples, _) = input { got.withLock { $0 += samples } }
                                   }, silentFrames: 1_000_000, onLongSilence: {})
        let start = 1_000.0
        let cycles = 150
        for k in 0..<cycles where k % 3 != 1 {
            let tone = (0..<480).map { Float(0.5 + 0.25 * sin(2 * Double.pi * 200 * Double(k * 480 + $0) / 48_000)) }
            var stamp = AudioTimeStamp()
            stamp.mHostTime = AVAudioTime.hostTime(forSeconds: start + Double(k) * 0.01)
            stamp.mSampleTime = Double(k * 480)
            stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
            var none = AudioTimeStamp()
            withList([tone]) { list in
                receiver.ioBlock(&none, list, &stamp, UnsafeMutablePointer(mutating: list), &none)
            }
            if k % 8 == 7 { receiver.flush() }
        }
        receiver.flush()
        let out = got.withLock { $0 }
        #expect(abs(out.count - cycles * 160) <= 64, "delivered \(out.count)")
        #expect(receiver.filledFrames == cycles / 3 * 480)
        // Where the output is near zero (a DC offset of 0.5 keeps the tone well away from it), in runs.
        var runs: [(start: Int, length: Int)] = []
        var i = 0
        while i < out.count {
            if abs(out[i]) < 0.05 {
                let s = i
                while i < out.count, abs(out[i]) < 0.05 { i += 1 }
                runs.append((s, i - s))
            } else { i += 1 }
        }
        let gaps = runs.filter { $0.length >= 100 }
        #expect(gaps.count == cycles / 3, "\(gaps.count) zero runs")
        // The converter's delay is constant: every run starts the same distance from its cycle's place (1.6 ms of
        // samples per missing cycle k = 3n + 1 at 160 samples per cycle), and is about one cycle long.
        if let first = gaps.first {
            let delay = first.start - 160
            #expect(delay >= 0 && delay <= 64, "delay \(delay)")
            for (n, gap) in gaps.enumerated() {
                #expect(abs(gap.start - (160 * (3 * n + 1) + delay)) <= 2, "run \(n) at \(gap.start)")
                #expect(abs(gap.length - 160) <= 24, "run \(n) of \(gap.length)")
            }
        }
        receiver.finish()
    }

    // MARK: Heartbeat

    @Test func theHeartbeatReportsRateGapsAndSkippedFrames() {
        // 16 kHz in cycles of 500 frames (1/32 s, exact in binary); one cycle in five is missing (62.5 ms host gaps),
        // with its skipped frames passed in on the cycle after it.
        let step = 1.0 / 32
        var stats = TapIOStats()
        var reports: [TapIOStats.Report] = []
        for k in 0..<200 where k % 5 != 4 {
            let skipped = k % 5 == 0 && k > 0 ? 500 : 0
            if let r = stats.observe(frames: 500, host: 50 + Double(k) * step, sampleTime: Double(k * 500), skipped: skipped) {
                reports.append(r)
            }
        }
        #expect(reports.count >= 2)
        let first = reports.first
        #expect(first.map { abs($0.rate - 16_000) < 1 } == true)      // from the sample time, not the frames that arrived
        #expect(first.map { abs($0.maxHostGapMs - 62.5) < 0.01 } == true)
        #expect(first?.frames == 52 * 500)                              // k 0 ..< 65 less the 13 missing
        #expect(first?.skipped == 13 * 500)
        // Without sample times the rate is the frames that arrived.
        var plain = TapIOStats()
        var report: TapIOStats.Report?
        for k in 0..<120 where report == nil {
            report = plain.observe(frames: 160, host: Double(k) * step, sampleTime: nil, skipped: 0)
        }
        #expect(report.map { abs($0.rate - 5_120) < 1 } == true)
    }

    /// Review 2026-11-27: after a pause the heartbeat starts a new window, so its first report never shows the pause
    /// as a host gap or a low rate.
    @Test func theHeartbeatStartsAgainAfterAPause() {
        var stats = TapIOStats()
        var reports: [TapIOStats.Report] = []
        func feed(_ range: Range<Int>, from host: Double, sample: Double) {
            for k in range {
                let i = k - range.lowerBound
                if let r = stats.observe(frames: 500, host: host + Double(i) / 32, sampleTime: sample + Double(i * 500),
                                         skipped: 0) { reports.append(r) }
            }
        }
        feed(0..<40, from: 50, sample: 0)          // 1.25 s: no report yet
        stats.breakRun()                           // paused for 8 s
        feed(0..<100, from: 59.25, sample: 20_000)
        #expect(!reports.isEmpty)
        #expect(reports.allSatisfy { abs($0.rate - 16_000) < 1 && abs($0.maxHostGapMs - 31.25) < 0.01 })
    }

    /// Review 2026-11-27: the 5 s "Aligner:" line ignores the fill of a lost stream, which grows on every push.
    @Test func theAlignerLineIgnoresALostStreamsFill() {
        let logged = StreamAligner.Counters(inserted: 10, dropped: 0, filled: 1_000, corrections: 1)
        var now = logged
        now.filled = 81_000
        #expect(AlignerLogPolicy.changed(now, since: logged, lost: false))
        #expect(!AlignerLogPolicy.changed(now, since: logged, lost: true))
        now.corrections = 2
        #expect(AlignerLogPolicy.changed(now, since: logged, lost: true))
    }

    @Test func theRingCountsEveryIOCycleEvenWhenItDrops() {
        let ring = TapRing(slotCount: 1, bufferCount: 1, bytesPerBuffer: 16)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        var value: Float = 0.5
        withUnsafeMutablePointer(to: &value) { p in
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: UnsafeMutableRawPointer(p))
            _ = ring.write(UnsafePointer(list.unsafeMutablePointer), firstIndex: 0, hostTime: 1)
            _ = ring.write(UnsafePointer(list.unsafeMutablePointer), firstIndex: 0, hostTime: 2)   // full: dropped
        }
        #expect(ring.ioCycles == 2 && ring.dropped == 1)
    }

    /// Feeds an AudioBufferList of `buffers` to `body` (as `TapRingTests.withList`).
    func withList<R>(_ buffers: [[Float]], _ body: (UnsafePointer<AudioBufferList>) -> R) -> R {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        let storage = buffers.map { b -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Swift.max(1, b.count))
            p.initialize(from: b, count: b.count)
            return p
        }
        defer { storage.forEach { $0.deallocate() } }
        for (i, b) in buffers.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b.count * 4), mData: UnsafeMutableRawPointer(storage[i]))
        }
        return body(UnsafePointer(list.unsafeMutablePointer))
    }
}
#endif
