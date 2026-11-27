#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import TranscribeFluid

/// The pure parts of Mac audio's capture (review 2026-11-26): the IO block's ring and receiver, where the tap's buffers
/// sit among the aggregate's inputs, when a paused capture may restart in place, and the lost and retry rules. The
/// Core Audio tap itself runs only in the gated `RealMacAudioTests`.
@Suite("Mac audio: tap ring, buffer layout, resume and retry")
struct TapRingTests {
    /// An AudioBufferList of `buffers` (each its own array of floats), kept alive for the call.
    func withList<R>(_ buffers: [[Float]], nullAt: Int? = nil, _ body: (UnsafePointer<AudioBufferList>) -> R) -> R {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        var storage = buffers.map { b -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Swift.max(1, b.count))
            p.initialize(from: b, count: b.count)
            return p
        }
        defer { storage.forEach { $0.deallocate() }; storage = [] }
        for (i, b) in buffers.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(b.count * 4),
                                  mData: i == nullAt ? nil : UnsafeMutableRawPointer(storage[i]))
        }
        return body(UnsafePointer(list.unsafeMutablePointer))
    }

    func floats(_ bytes: UnsafeRawBufferPointer) -> [Float] { Array(bytes.bindMemory(to: Float.self)) }

    @Test func slotsComeOutInOrderWithTheirHostTimes() {
        let ring = TapRing(slotCount: 4, bufferCount: 1, bytesPerBuffer: 64)
        for k in 0..<3 {
            #expect(withList([[Float(k), Float(k) + 0.5]]) { ring.write($0, firstIndex: 0, hostTime: UInt64(100 + k)) })
        }
        #expect(withList([[9]]) { ring.write($0, firstIndex: 0, hostTime: nil) })
        var got: [([Float], UInt64?)] = []
        #expect(ring.drain { buffers, host in got.append((floats(buffers[0]), host)) } == 4)
        #expect(got.map(\.0) == [[0, 0.5], [1, 1.5], [2, 2.5], [9]])
        #expect(got.map(\.1) == [100, 101, 102, nil])
        #expect(ring.pending == 0 && ring.dropped == 0)
    }

    @Test func aFullRingDropsAndWrapsAround() {
        let ring = TapRing(slotCount: 2, bufferCount: 1, bytesPerBuffer: 16)
        #expect(withList([[1]]) { ring.write($0, firstIndex: 0, hostTime: 1) })
        #expect(withList([[2]]) { ring.write($0, firstIndex: 0, hostTime: 2) })
        #expect(!withList([[3]]) { ring.write($0, firstIndex: 0, hostTime: 3) })   // full: dropped
        #expect(ring.dropped == 1)
        var got: [Float] = []
        ring.drain { buffers, _ in got += floats(buffers[0]) }
        #expect(withList([[4]]) { ring.write($0, firstIndex: 0, hostTime: 4) })
        #expect(withList([[5]]) { ring.write($0, firstIndex: 0, hostTime: 5) })
        ring.drain { buffers, _ in got += floats(buffers[0]) }
        #expect(got == [1, 2, 4, 5])
    }

    /// The tap's buffer is taken by position: a microphone stream of the output device before it is never read.
    @Test func onlyTheTapsBuffersAreCopied() {
        let ring = TapRing(slotCount: 2, bufferCount: 1, bytesPerBuffer: 64)
        #expect(withList([[0.9, 0.9], [0.1, 0.2]]) { ring.write($0, firstIndex: 1, hostTime: 7) })
        var got: [Float] = []
        ring.drain { buffers, _ in got = floats(buffers[0]) }
        #expect(got == [0.1, 0.2])
    }

    @Test func aMissingOrOversizedBufferIsDropped() {
        let ring = TapRing(slotCount: 2, bufferCount: 1, bytesPerBuffer: 8)
        #expect(!withList([[1, 2, 3]]) { ring.write($0, firstIndex: 0, hostTime: 1) })    // 12 bytes > 8
        #expect(!withList([[1]], nullAt: 0) { ring.write($0, firstIndex: 0, hostTime: 1) })
        #expect(!withList([[1]]) { ring.write($0, firstIndex: 1, hostTime: 1) })          // no such buffer
        #expect(ring.dropped == 3 && ring.pending == 0)
    }

    @Test func aNonInterleavedFormatCopiesEveryChannelsBuffer() {
        let ring = TapRing(slotCount: 2, bufferCount: 2, bytesPerBuffer: 16)
        #expect(withList([[0.5], [1], [2]]) { ring.write($0, firstIndex: 1, hostTime: 1) })
        var got: [[Float]] = []
        ring.drain { buffers, _ in got = buffers.map(floats) }
        #expect(got == [[1], [2]])
    }

    /// Review 2026-11-26: an input list of another length than the aggregate was built with (a stream added before
    /// the tap's) is dropped, never read at the old index.
    @Test func anInputListOfAnotherLengthIsDropped() {
        let ring = TapRing(slotCount: 4, bufferCount: 1, bytesPerBuffer: 64, expectedBufferCount: 1)
        #expect(withList([[0.25]]) { ring.write($0, firstIndex: 0, hostTime: 1) })
        #expect(!withList([[0.9], [0.25]]) { ring.write($0, firstIndex: 0, hostTime: 2) })
        #expect(!withList([[0.1], [0.2], [0.3]]) { ring.write($0, firstIndex: 0, hostTime: 3) })
        #expect(ring.layoutMismatches == 2 && ring.dropped == 2 && ring.pending == 1)
    }

    // MARK: Receiver

    /// The IO block and its consumer end to end, without Core Audio: only the tap's buffer is used, it comes out at
    /// 16 kHz with its host time, and a cycle with another layout is dropped and reported once.
    @Test func theReceiverDeliversOnlyTheTapsBufferWithItsHostTime() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try #require(TapConverter(inputFormat: format))
        let ring = TapRing(slotCount: 8, bufferCount: 1, bytesPerBuffer: 4 * 4_800, expectedBufferCount: 2)
        let got = Mutex<[(samples: [Float], host: Double?)]>([])
        let mismatches = Mutex(0)
        let receiver = TapReceiver(format: format, converter: converter, ring: ring, firstIndex: 1, bytesPerFrame: 4,
                                   queue: DispatchQueue(label: "test.tap"), deliver: { input in
                                       if case .audio(let samples, let host) = input { got.withLock { $0.append((samples, host)) } }
                                   }, silentFrames: 80_000, onLongSilence: {},
                                   onLayoutMismatch: { mismatches.withLock { $0 += 1 } })
        let tone = (0..<4_800).map { Float(0.25 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let host = mach_absolute_time()
        func cycle(_ buffers: [[Float]], host: UInt64) {
            var stamp = AudioTimeStamp()
            stamp.mHostTime = host
            stamp.mFlags = .hostTimeValid
            var none = AudioTimeStamp()
            withList(buffers) { list in
                receiver.ioBlock(&none, list, &stamp, UnsafeMutablePointer(mutating: list), &none)
            }
        }
        for k in 0..<3 { cycle([[Float](repeating: 0.9, count: 4_800), tone], host: host + UInt64(k)) }
        cycle([tone], host: host + 3)    // the microphone stream is gone: another layout
        cycle([tone], host: host + 4)
        receiver.flush()
        let chunks = got.withLock { $0 }
        #expect(chunks.count == 3)
        let all = chunks.flatMap(\.samples)
        #expect(all.count > 4_000 && all.count <= 4_800 + 64)       // about 300 ms at 16 kHz
        let peak = all.map(abs).max() ?? 0
        #expect(peak > 0.1 && peak < 0.3, "peak \(peak), count \(all.count)")   // the tone, never the 0.9 microphone
        #expect(chunks.first?.host == AVAudioTime.seconds(forHostTime: host))
        #expect(ring.layoutMismatches == 2 && mismatches.withLock { $0 } == 1)
        receiver.finish()
    }

    /// 2026-11-27: a rate verdict is reported to the capture (which rebuilds) and changes nothing by itself; only
    /// `convert(fromRate:)`, the capture's last resort, switches the converter.
    @Test func theReceiverReportsAnotherRateAndSwitchesOnlyWhenTold() throws {
        // The Bose case end to end: built for 48 kHz, fed 4 s of 16 kHz IO in 10 ms buffers.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try #require(TapConverter(inputFormat: format))
        let ring = TapRing(slotCount: 64, bufferCount: 1, bytesPerBuffer: 4 * 4_800, expectedBufferCount: 1)
        let got = Mutex<[Int]>([])
        let verdicts = Mutex<[(Double, Double)]>([])
        let receiver = TapReceiver(format: format, converter: converter, ring: ring, firstIndex: 0, bytesPerFrame: 4,
                                   queue: DispatchQueue(label: "test.tap.rate"), deliver: { input in
                                       if case .audio(let samples, _) = input { got.withLock { $0.append(samples.count) } }
                                   }, silentFrames: 80_000, onLongSilence: {},
                                   onRateVerdict: { inUse, measured in verdicts.withLock { $0.append((inUse, measured)) } })
        let start = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        func feed(_ range: Range<Int>) {
            for k in range {
                let tone = (0..<160).map { Float(0.25 * sin(2 * Double.pi * 440 * Double(k * 160 + $0) / 16_000)) }
                var stamp = AudioTimeStamp()
                stamp.mHostTime = AVAudioTime.hostTime(forSeconds: start + Double(k) * 0.01)
                stamp.mSampleTime = Double(k * 160)
                stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
                var none = AudioTimeStamp()
                withList([tone]) { list in
                    receiver.ioBlock(&none, list, &stamp, UnsafeMutablePointer(mutating: list), &none)
                }
                if k % 8 == 7 { receiver.flush() }
            }
            receiver.flush()
        }
        feed(0..<400)
        let reported = verdicts.withLock { $0 }
        #expect(reported.count == 1 && reported.first?.0 == 48_000 && reported.first?.1 == 16_000)
        // Not switched: 160 frames in still give about 53 samples out.
        var tail = got.withLock { $0 }.suffix(50).reduce(0, +)
        #expect(abs(tail - 50 * 53) < 200, "last 50 buffers gave \(tail) samples")
        // The capture's last resort: from then on, 160 frames in give about 160 samples out.
        receiver.convert(fromRate: 16_000)
        feed(400..<500)
        tail = got.withLock { $0 }.suffix(50).reduce(0, +)
        #expect(abs(tail - 50 * 160) < 200, "last 50 buffers gave \(tail) samples")
        receiver.finish()
    }

    // MARK: Layout

    @Test func theTapIsFoundBesideTheOutputDevicesInputs() {
        // Built-in speakers: no inputs, the tap alone.
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1], aggregateStreams: [50], subDeviceStreams: [],
                                              subDeviceLayout: [], tapBuffers: 1, tapChannelsPerBuffer: 1) == 0)
        // AirPods: one microphone stream, recognised by its object id wherever it sits.
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1, 1], aggregateStreams: [40, 50], subDeviceStreams: [40],
                                              subDeviceLayout: [1], tapBuffers: 1, tapChannelsPerBuffer: 1) == 1)
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1, 2], aggregateStreams: [50, 40], subDeviceStreams: [40],
                                              subDeviceLayout: [2], tapBuffers: 1, tapChannelsPerBuffer: 1) == 0)
        // Ids not shared: the order whose buffers match the output device's own inputs, here a 2-channel headset
        // microphone before the tap, or after it.
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [2, 1], aggregateStreams: [60, 61], subDeviceStreams: [40],
                                              subDeviceLayout: [2], tapBuffers: 1, tapChannelsPerBuffer: 1) == 1)
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [2, 1], subDeviceLayout: [2], tapBuffers: 1,
                                              tapChannelsPerBuffer: 1) == 1)
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1, 2], subDeviceLayout: [2], tapBuffers: 1,
                                              tapChannelsPerBuffer: 1) == 0)
        // A stereo non-interleaved tap after a mono microphone.
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1, 1, 1], subDeviceLayout: [1], terminalTypes: [],
                                              tapBuffers: 2, tapChannelsPerBuffer: 1) == 1)
    }

    /// Review 2026-11-26: a mono headset microphone beside a mono tap fits either order. A microphone terminal type
    /// decides; without one the composition's order is taken and flagged.
    @Test func aMonoMicrophoneBesideAMonoTapIsToldApartByItsTerminalType() {
        func place(_ terminals: [UInt32]) -> TapBufferLayout.Placement? {
            TapBufferLayout.place(channelsPerBuffer: [1, 1], aggregateStreams: [60, 61], subDeviceStreams: [40],
                                  subDeviceLayout: [1], terminalTypes: terminals, tapBuffers: 1, tapChannelsPerBuffer: 1)
        }
        #expect(place([]) == .init(first: 1, certain: false))
        #expect(place([0, 0]) == .init(first: 1, certain: false))
        #expect(place([kAudioStreamTerminalTypeHeadsetMicrophone, 0]) == .init(first: 1, certain: true))
        #expect(place([0, kAudioStreamTerminalTypeHeadsetMicrophone]) == .init(first: 0, certain: true))
        #expect(place([0, 0x0402]) == .init(first: 0, certain: true))               // a USB headset
        #expect(place([kAudioStreamTerminalTypeMicrophone, kAudioStreamTerminalTypeMicrophone]) == nil)
        #expect(TapBufferLayout.isMicrophone(kAudioStreamTerminalTypeReceiverMicrophone))
        #expect(TapBufferLayout.isMicrophone(0x0201))
        #expect(!TapBufferLayout.isMicrophone(kAudioStreamTerminalTypeSpeaker))
        #expect(!TapBufferLayout.isMicrophone(kAudioStreamTerminalTypeUnknown))
        #expect(!TapBufferLayout.isMicrophone(0x0301))                              // a USB speaker
    }

    /// Final review 2026-11-26: with only one set of input streams listed, a microphone stream is never taken as the
    /// tap, and when the output has inputs of its own the placement is certain only if a terminal type says so.
    @Test func aSingleInputStreamIsNeverAMicrophone() {
        func place(_ terminals: [UInt32], sub: [UInt32]) -> TapBufferLayout.Placement? {
            TapBufferLayout.place(channelsPerBuffer: [1], aggregateStreams: [60], subDeviceStreams: [40],
                                  subDeviceLayout: sub, terminalTypes: terminals, tapBuffers: 1, tapChannelsPerBuffer: 1)
        }
        #expect(place([kAudioStreamTerminalTypeHeadsetMicrophone], sub: [1]) == nil)
        #expect(place([0x0402], sub: [1]) == nil)                                   // a USB headset microphone
        #expect(place([], sub: [1]) == .init(first: 0, certain: false))
        #expect(place([kAudioStreamTerminalTypeUnknown], sub: [1]) == .init(first: 0, certain: true))
        #expect(place([], sub: []) == .init(first: 0, certain: true))               // built-in speakers: no inputs
    }

    /// 2026-11-27, Bose headphones in call mode: the tap said 48 kHz while the aggregate ran at 16 kHz, so every chunk
    /// was converted as a third of its length. The IO format takes the stream's rate, else the aggregate's.
    @Test func theIOFormatUsesTheRateTheAggregateRunsAt() {
        var tap = AudioStreamBasicDescription()
        tap.mSampleRate = 48_000; tap.mFormatID = kAudioFormatLinearPCM
        tap.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        tap.mBytesPerPacket = 4; tap.mFramesPerPacket = 1; tap.mBytesPerFrame = 4; tap.mChannelsPerFrame = 1; tap.mBitsPerChannel = 32
        var stream = tap; stream.mSampleRate = 48_000
        // Bose headphones in call mode (2026-11-27): the tap and its stream said 48 kHz, the aggregate ran at 16 kHz.
        #expect(TapStreamFormat.ioFormat(tap: tap, streamFormat: stream, aggregateRate: 16_000).mSampleRate == 16_000)
        stream.mSampleRate = 16_000
        #expect(TapStreamFormat.ioFormat(tap: tap, streamFormat: stream, aggregateRate: nil).mSampleRate == 16_000)
        #expect(TapStreamFormat.ioFormat(tap: tap, streamFormat: nil, aggregateRate: nil).mSampleRate == 48_000)
        let io = TapStreamFormat.ioFormat(tap: tap, streamFormat: stream, aggregateRate: nil)
        #expect(io.mBytesPerFrame == 4 && io.mChannelsPerFrame == 1 && io.mFormatFlags == tap.mFormatFlags)
        #expect(!TapResumePlan.sameFormat(tap, io))      // a rate change means a rebuild, not a restart in place
    }

    /// Feeds `seconds` of IO from a device running at `rate`, in buffers of `frames`, starting at `start`; with
    /// `sampleTimes` the buffers carry the device's sample time. `delivered` is the share of IO cycles that arrive
    /// (the rest are skipped, as while a Bluetooth headset switches modes). Returns the first correction.
    func feed(_ check: inout TapRateCheck, rate: Double, current: Double, frames: Int = 160, seconds: Double,
              start: Double = 100, sampleTimes: Bool = false, delivered: Double = 1) -> Double? {
        let step = Double(frames) / rate
        var k = 0
        while Double(k) * step < seconds {
            defer { k += 1 }
            // Skip cycles evenly: deliver cycle k when the running share crosses a whole number.
            guard (Double(k + 1) * delivered).rounded(.down) > (Double(k) * delivered).rounded(.down) || delivered >= 1
            else { continue }
            let sample = sampleTimes ? Double(k * frames) : nil
            if let r = check.observe(frames: frames, host: start + Double(k) * step, sampleTime: sample, current: current) {
                return r
            }
        }
        return nil
    }

    @Test func aWrongRateIsCorrectedFromTheFramesThatArrive() {
        // The Bose case: 16 kHz IO read as 48 kHz, with and without sample times.
        var check = TapRateCheck()
        #expect(feed(&check, rate: 16_000, current: 48_000, seconds: 4) == 16_000)
        check = TapRateCheck()
        #expect(feed(&check, rate: 16_000, current: 48_000, seconds: 4, sampleTimes: true) == 16_000)
        // The other way round, and at 44.1 kHz.
        check = TapRateCheck()
        #expect(feed(&check, rate: 48_000, current: 16_000, frames: 512, seconds: 4) == 48_000)
        check = TapRateCheck()
        #expect(feed(&check, rate: 44_100, current: 48_000, frames: 441, seconds: 4, sampleTimes: true) == 44_100)
    }

    @Test func aRightRateIsLeftAlone() {
        var check = TapRateCheck()
        #expect(feed(&check, rate: 48_000, current: 48_000, frames: 512, seconds: 20) == nil)
        // Clock drift of a fraction of a percent is not a different rate.
        check = TapRateCheck()
        #expect(feed(&check, rate: 48_100, current: 48_000, frames: 512, seconds: 20) == nil)
        // Not before two windows of IO agree.
        check = TapRateCheck()
        #expect(feed(&check, rate: 16_000, current: 48_000, seconds: 2.9) == nil)
    }

    @Test func skippedCyclesAreLostAudioNotAnotherRate() {
        // Bose headphones turning on call mode (2026-11-27): about 70% of the 16 kHz IO cycles arrive for seconds.
        // With sample times that is never another rate, and the skipped frames are counted.
        var check = TapRateCheck()
        #expect(feed(&check, rate: 16_000, current: 16_000, seconds: 8, sampleTimes: true, delivered: 0.69) == nil)
        let expected = Int(8 * 16_000 * 0.31)
        #expect(abs(check.skippedFrames - expected) < 2_000, "skipped \(check.skippedFrames)")
        // Without sample times, one short burst of skipped cycles is not enough: two windows must agree.
        check = TapRateCheck()
        #expect(feed(&check, rate: 16_000, current: 16_000, seconds: 1.6, delivered: 0.69) == nil)
        #expect(feed(&check, rate: 16_000, current: 16_000, seconds: 6, start: 101.6) == nil)
    }

    @Test func aStallStartsTheCountAgain() {
        // IO that stops for a second (a device switch) must not read as a slower rate.
        var check = TapRateCheck()
        #expect(feed(&check, rate: 48_000, current: 48_000, frames: 512, seconds: 1.0) == nil)
        #expect(feed(&check, rate: 48_000, current: 48_000, frames: 512, seconds: 1.0, start: 102) == nil)
        // A count that matches no standard rate changes nothing.
        check = TapRateCheck()
        #expect(feed(&check, rate: 37_000, current: 48_000, frames: 512, seconds: 5) == nil)
        // A sample time that goes back (IO restarted) starts again too.
        check = TapRateCheck()
        _ = check.observe(frames: 160, host: 1, sampleTime: 1_000, current: 16_000)
        #expect(check.observe(frames: 160, host: 1.01, sampleTime: 0, current: 16_000) == nil)
        #expect(check.skippedFrames == 0)
    }

    @Test func anUnexpectedLayoutIsRefused() {
        // More buffers than the output device and the tap account for.
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1, 1, 1], subDeviceLayout: [1], tapBuffers: 1,
                                              tapChannelsPerBuffer: 1) == nil)
        // Neither order gives the tap its channel count and the output device its own layout.
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1, 2], subDeviceLayout: [1], tapBuffers: 1,
                                              tapChannelsPerBuffer: 1) == nil)
        // Inputs the output device does not report.
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [1, 1], subDeviceLayout: [], tapBuffers: 1,
                                              tapChannelsPerBuffer: 1) == nil)
        #expect(TapBufferLayout.firstTapIndex(channelsPerBuffer: [], subDeviceLayout: [], tapBuffers: 1,
                                              tapChannelsPerBuffer: 1) == nil)
    }

    @Test func onlyTheTapsStreamsAreTurnedOn() {
        #expect(TapBufferLayout.streamUsage(streamCount: 3, firstTapIndex: 2, tapBuffers: 1) == [false, false, true])
        #expect(TapBufferLayout.streamUsage(streamCount: 3, firstTapIndex: 1, tapBuffers: 2) == [false, true, true])
    }

    // MARK: Resume and retry

    func asbd(rate: Double, channels: UInt32 = 1) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * channels,
                                    mFramesPerPacket: 1, mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    @Test func aPausedCaptureRestartsInPlaceOnlyWhenNothingChanged() {
        let f48 = asbd(rate: 48_000), f44 = asbd(rate: 44_100)
        func plan(changed: Bool = false, alive: Bool = true, built: String? = "speakers", current: String? = "speakers",
                  builtFormat: AudioStreamBasicDescription? = nil, currentFormat: AudioStreamBasicDescription? = nil) -> Bool {
            TapResumePlan.canResumeInPlace(changedWhilePaused: changed, aggregateAlive: alive, builtOutputUID: built,
                                           currentOutputUID: current, builtFormat: builtFormat ?? f48,
                                           currentFormat: currentFormat ?? f48)
        }
        #expect(plan())
        #expect(!plan(changed: true))                       // a change notice came during the pause
        #expect(!plan(alive: false))
        #expect(!plan(current: "usb-dac"))                  // another default output
        #expect(!plan(current: nil))
        #expect(!plan(currentFormat: f44))                  // the tap's format changed
        #expect(!plan(built: nil))
    }

    @Test func aFailedRebuildIsRetriedAFewTimes() {
        #expect(TapRetryPolicy.delay(afterFailures: 0) == nil)
        #expect(TapRetryPolicy.delay(afterFailures: 1) == .seconds(1))
        #expect(TapRetryPolicy.delay(afterFailures: 5) == .seconds(30))
        #expect(TapRetryPolicy.delay(afterFailures: 6) == nil)   // then only device changes
    }

    // MARK: Lifecycle

    @Test func aChangeWhilePausedIsKeptForResume() {
        var s = TapLifecycle()
        var notice = s.noticed()
        #expect(notice == .ignore)                      // not started yet
        s.started()
        var restored = s.confirmed()
        #expect(!restored)
        notice = s.noticed()
        #expect(notice == .rebuild)
        let wasRunning = s.pause()
        #expect(wasRunning && !s.changedWhilePaused)    // IO was running: stop it
        notice = s.noticed()
        #expect(notice == .remember && s.changedWhilePaused)
        let resumes = s.beginResume()
        #expect(resumes)
        s.started()
        restored = s.confirmed()
        #expect(!restored && !s.changedWhilePaused)
        // A notice that came just before a pause: its rebuild finds the capture paused and leaves it for resume.
        notice = s.noticed()
        #expect(notice == .rebuild)
        _ = s.pause()
        let rebuilds = s.mayRebuild()
        #expect(!rebuilds && s.changedWhilePaused)
    }

    @Test func aFailedRebuildIsReportedOnceAndRetriedUntilItComesBack() {
        var s = TapLifecycle()
        s.started()
        _ = s.confirmed()
        var rebuilds = s.mayRebuild()
        #expect(rebuilds)
        let first = s.failed()
        #expect(first == .init(firstLoss: true, retryAfter: .seconds(1), attempt: 1))
        #expect(s.retryDue(attempt: 1))
        let notice = s.noticed()
        rebuilds = s.mayRebuild()
        #expect(notice == .rebuild && rebuilds)        // every later change tries again
        let second = s.failed()
        #expect(second == .init(firstLoss: false, retryAfter: .seconds(2), attempt: 2))
        #expect(!s.retryDue(attempt: 1) && s.retryDue(attempt: 2))   // the newer failure's retry wins
        for _ in 3...5 { _ = s.failed() }
        let sixth = s.failed()
        #expect(sixth.retryAfter == nil)               // then only device changes and resume
        s.started()
        #expect(s.lost && s.failedBuilds == 6)         // started, but not back until IO comes
        let restored = s.confirmed()
        #expect(restored)                              // back: report it
        #expect(!s.lost && s.failedBuilds == 0 && !s.retryDue(attempt: 2))
    }

    /// A Both recording's Mac audio that could not start counts as lost from the start and keeps trying.
    @Test func aFailedStartKeepsTryingLikeARebuild() {
        var s = TapLifecycle()
        let failure = s.failed()
        #expect(failure.firstLoss)
        let notice = s.noticed()
        #expect(notice == .rebuild && s.retryDue(attempt: 1))
        s.started()
        let restored = s.confirmed()
        #expect(restored)
    }

    /// Review 2026-11-27: clocks that all start and never deliver IO. Each chain that runs out of modes is one more
    /// failed build: reported lost once, never restored, and its retries back off until only device changes are left.
    @Test func buildsThatNeverDeliverIOBackOffAndAreNeverRestored() {
        var s = TapLifecycle()
        s.started()                                    // the start: IO running, not yet confirmed
        var failures: [TapLifecycle.Failure] = []
        failures.append(s.failed())                    // the watchdog ran out of modes
        for _ in 0..<6 {
            #expect(s.retryDue(attempt: failures.last!.attempt))
            s.started()                                // the retry starts a mode...
            #expect(s.lost && !s.retryDue(attempt: failures.last!.attempt))
            failures.append(s.failed())                // ...which never delivers IO either
        }
        #expect(failures.map(\.firstLoss) == [true, false, false, false, false, false, false])
        #expect(failures.map(\.retryAfter) == [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30), nil, nil])
        #expect(s.lost && s.failedBuilds == 7)
    }

    /// A recording resumed while lost (a Mac-audio-only recording resumes itself): a build that then never delivers
    /// IO is reported lost again, so that recording pauses again.
    @Test func aLossAfterAResumeWhileLostIsReportedAgain() {
        var s = TapLifecycle()
        s.started()
        _ = s.confirmed()
        let lost = s.failed()
        #expect(lost.firstLoss)
        _ = s.pause()
        let resumes = s.beginResume()
        #expect(resumes && s.resumedWhileLost)
        s.started()
        let again = s.failed()
        let third = s.failed()
        #expect(again.firstLoss && !third.firstLoss)   // reported again, once
        s.started()
        let restored = s.confirmed()
        #expect(restored && !s.resumedWhileLost)
    }

    @Test func aPauseOrAStopEndsTheRetries() {
        var s = TapLifecycle()
        s.started()
        _ = s.confirmed()
        _ = s.failed()
        let wasRunning = s.pause()
        #expect(!wasRunning)                            // nothing running to stop
        let rebuilds = s.mayRebuild()
        let notice = s.noticed()
        #expect(!s.retryDue(attempt: 1) && !rebuilds && notice == .remember)
        let resumes = s.beginResume()
        #expect(resumes)
        let again = s.failed()                          // the resume failed too: still lost (the caller reports it)
        #expect(again.firstLoss && s.retryDue(attempt: again.attempt))
        s.stop()
        let afterStop = (s.noticed(), s.mayRebuild(), s.beginResume(), s.pause())
        #expect(afterStop == (.ignore, false, false, false) && !s.retryDue(attempt: again.attempt))
    }
}
#endif
