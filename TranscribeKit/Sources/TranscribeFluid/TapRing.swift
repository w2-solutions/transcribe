#if os(macOS)
import CoreAudio
import Foundation
import Synchronization

/// Single-producer, single-consumer slots between Mac audio's IO block and the queue that converts and delivers it
/// (review 2026-11-26). The IO block only copies the tap's buffers and the host time into a preallocated slot and
/// signals; resampling, allocation and delivery happen off the IO cycle, so a busy Mac never makes the HAL skip tap
/// buffers because the block ran long.
///
/// `write` is real-time safe: no allocation, no locks, no Swift arrays grown. A full ring, a missing buffer or one
/// larger than a slot drops that buffer (counted in `dropped`); the `StreamAligner` sees the host-time gap and fills it.
final class TapRing: @unchecked Sendable {
    let slotCount: Int
    /// The tap's buffers per IO cycle (1 for an interleaved or mono format, else one per channel).
    let bufferCount: Int
    /// Bytes each buffer of a slot can hold.
    let bytesPerBuffer: Int
    /// The number of buffers the aggregate's input list had when the ring was built (its stream configuration), or
    /// nil for no check. A list of another length means the layout changed under the IO block, so `firstIndex` may
    /// point at another stream: the cycle is dropped and counted in `layoutMismatches`.
    let expectedBufferCount: Int?

    private let storage: UnsafeMutableRawPointer
    private let byteCounts: UnsafeMutablePointer<Int>
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let hostValid: UnsafeMutablePointer<Bool>
    /// Slots written and read so far (monotonic; the slot is the count modulo `slotCount`).
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let drops = Atomic<Int>(0)
    private let mismatches = Atomic<Int>(0)

    init(slotCount: Int, bufferCount: Int, bytesPerBuffer: Int, expectedBufferCount: Int? = nil) {
        precondition(slotCount > 0 && bufferCount > 0 && bytesPerBuffer > 0)
        self.slotCount = slotCount
        self.bufferCount = bufferCount
        self.bytesPerBuffer = bytesPerBuffer
        self.expectedBufferCount = expectedBufferCount
        storage = UnsafeMutableRawPointer.allocate(byteCount: slotCount * bufferCount * bytesPerBuffer, alignment: 16)
        byteCounts = .allocate(capacity: slotCount * bufferCount)
        byteCounts.initialize(repeating: 0, count: slotCount * bufferCount)
        hostTimes = .allocate(capacity: slotCount)
        hostTimes.initialize(repeating: 0, count: slotCount)
        hostValid = .allocate(capacity: slotCount)
        hostValid.initialize(repeating: false, count: slotCount)
    }

    deinit {
        storage.deallocate()
        byteCounts.deallocate()
        hostTimes.deallocate()
        hostValid.deallocate()
    }

    /// Buffers dropped so far (log-only).
    var dropped: Int { drops.load(ordering: .relaxed) }

    /// IO cycles dropped because the input list did not have `expectedBufferCount` buffers.
    var layoutMismatches: Int { mismatches.load(ordering: .relaxed) }

    /// Slots written and not read yet (tests).
    var pending: Int { written.load(ordering: .acquiring) - read.load(ordering: .acquiring) }

    /// Real-time safe. Copies buffers `firstIndex ..< firstIndex + bufferCount` of `list` into the next slot with the
    /// host time. Returns whether a slot was written.
    func write(_ list: UnsafePointer<AudioBufferList>, firstIndex: Int, hostTime: UInt64?) -> Bool {
        let w = written.load(ordering: .relaxed)
        guard w - read.load(ordering: .acquiring) < slotCount else { return drop() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        if let expectedBufferCount, buffers.count != expectedBufferCount {
            mismatches.add(1, ordering: .relaxed)
            return drop()
        }
        guard firstIndex >= 0, buffers.count >= firstIndex + bufferCount else { return drop() }
        let slot = w % slotCount
        for b in 0..<bufferCount {
            let buffer = buffers[firstIndex + b]
            let size = Int(buffer.mDataByteSize)
            guard let data = buffer.mData, size <= bytesPerBuffer else { return drop() }
            let index = slot * bufferCount + b
            (storage + index * bytesPerBuffer).copyMemory(from: data, byteCount: size)
            byteCounts[index] = size
        }
        hostTimes[slot] = hostTime ?? 0
        hostValid[slot] = hostTime != nil
        written.store(w + 1, ordering: .releasing)
        return true
    }

    /// The consumer: hands every written slot to `body` in order (its buffers' bytes, valid only during the call, and
    /// its host time), then frees it. Returns the number of slots read.
    @discardableResult
    func drain(_ body: (_ buffers: [UnsafeRawBufferPointer], _ hostTime: UInt64?) -> Void) -> Int {
        var r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        var count = 0
        while r < w {
            let slot = r % slotCount
            let buffers = (0..<bufferCount).map { b -> UnsafeRawBufferPointer in
                let index = slot * bufferCount + b
                return UnsafeRawBufferPointer(start: storage + index * bytesPerBuffer, count: byteCounts[index])
            }
            body(buffers, hostValid[slot] ? hostTimes[slot] : nil)
            r += 1
            count += 1
            read.store(r, ordering: .releasing)
        }
        return count
    }

    private func drop() -> Bool {
        drops.add(1, ordering: .relaxed)
        return false
    }
}

/// Where the tap's buffers sit in the aggregate device's input buffer list (review 2026-11-26). The aggregate has the
/// default output device as its clock, and when that device also has inputs (AirPods, a USB headset or audio
/// interface) the aggregate's input list carries their microphone streams beside the tap's.
enum TapBufferLayout {
    struct Placement: Equatable {
        /// The index of the tap's first buffer.
        var first: Int
        /// False when two placements fitted equally and the composition's order (sub-device inputs first) decided.
        var certain: Bool
    }

    /// The index of the tap's first buffer, or nil when the layout cannot be read safely (`place`).
    static func firstTapIndex(channelsPerBuffer: [UInt32], aggregateStreams: [AudioObjectID] = [],
                              subDeviceStreams: Set<AudioObjectID> = [], subDeviceLayout: [UInt32],
                              terminalTypes: [UInt32] = [], tapBuffers: Int, tapChannelsPerBuffer: UInt32) -> Int? {
        place(channelsPerBuffer: channelsPerBuffer, aggregateStreams: aggregateStreams, subDeviceStreams: subDeviceStreams,
              subDeviceLayout: subDeviceLayout, terminalTypes: terminalTypes, tapBuffers: tapBuffers,
              tapChannelsPerBuffer: tapChannelsPerBuffer)?.first
    }

    /// Where the tap's buffers are.
    ///
    /// - `channelsPerBuffer`: the aggregate's input stream configuration (one entry per buffer the IO block gets).
    /// - `aggregateStreams`: the aggregate's input stream objects, in the same order (may be empty if unreadable).
    /// - `subDeviceStreams` / `subDeviceLayout`: the output device's own input streams and their configuration.
    /// - `terminalTypes`: the aggregate's input streams' `kAudioStreamPropertyTerminalType`, in order (may be empty).
    /// - `tapBuffers` / `tapChannelsPerBuffer`: what the tap's format needs.
    ///
    /// 1. When the aggregate reports the sub-device's own stream objects, the tap is what is left.
    /// 2. Otherwise the sub-device's inputs sit either before the tap (the composition's order) or after it; each
    ///    order must match the sub-device's configuration buffer for buffer and give the tap its channel count.
    /// 3. A stream whose terminal type is a microphone is never taken as the tap. When both orders still fit (a mono
    ///    headset microphone beside a mono tap, with no terminal type that tells), the composition's order is taken
    ///    and the placement is marked not certain (logged; to be checked on a real Mac with AirPods).
    static func place(channelsPerBuffer: [UInt32], aggregateStreams: [AudioObjectID], subDeviceStreams: Set<AudioObjectID>,
                      subDeviceLayout: [UInt32], terminalTypes: [UInt32], tapBuffers: Int,
                      tapChannelsPerBuffer: UInt32) -> Placement? {
        let n = channelsPerBuffer.count
        guard tapBuffers > 0, n >= tapBuffers else { return nil }
        func fits(_ first: Int) -> Bool {
            first >= 0 && first + tapBuffers <= n
                && channelsPerBuffer[first..<(first + tapBuffers)].allSatisfy { $0 == tapChannelsPerBuffer }
        }
        func microphoneAt(_ first: Int) -> Bool {
            terminalTypes.count == n && (first..<(first + tapBuffers)).contains { isMicrophone(terminalTypes[$0]) }
        }
        if aggregateStreams.count == n, aggregateStreams.contains(where: subDeviceStreams.contains) {
            let others = aggregateStreams.indices.filter { !subDeviceStreams.contains(aggregateStreams[$0]) }
            guard others.count == tapBuffers, let first = others.first, others.last == first + tapBuffers - 1,
                  fits(first) else { return nil }
            return Placement(first: first, certain: true)
        }
        if n == tapBuffers { return fits(0) ? Placement(first: 0, certain: true) : nil }
        let sub = subDeviceLayout.count
        guard sub > 0, n == sub + tapBuffers else { return nil }
        let subFirst = fits(sub) && Array(channelsPerBuffer[0..<sub]) == subDeviceLayout && !microphoneAt(sub)
        let tapFirst = fits(0) && Array(channelsPerBuffer[tapBuffers..<n]) == subDeviceLayout && !microphoneAt(0)
        switch (subFirst, tapFirst) {
        case (true, false): return Placement(first: sub, certain: true)
        case (false, true): return Placement(first: 0, certain: true)
        case (true, true):
            // Both fit and no microphone stream rules either out: the composition's order, flagged.
            return Placement(first: sub, certain: false)
        case (false, false): return nil
        }
    }

    /// A stream terminal type that is a microphone: Core Audio's own ('micr', 'hmic', 'rmic') and the USB Audio input
    /// (0x02xx) and bidirectional (0x04xx, headsets) terminal types that USB devices report.
    static func isMicrophone(_ terminalType: UInt32) -> Bool {
        switch terminalType {
        case kAudioStreamTerminalTypeMicrophone, kAudioStreamTerminalTypeHeadsetMicrophone,
             kAudioStreamTerminalTypeReceiverMicrophone: true
        case 0x0200..<0x0300, 0x0400..<0x0500: true
        default: false
        }
    }

    /// Per input stream: whether the IO block uses it (only the tap's), for `kAudioDevicePropertyIOProcStreamUsage`, so
    /// the output device's microphone is never turned on for a recording that does not use it.
    static func streamUsage(streamCount: Int, firstTapIndex: Int, tapBuffers: Int) -> [Bool] {
        (0..<streamCount).map { $0 >= firstTapIndex && $0 < firstTapIndex + tapBuffers }
    }
}

/// Whether a paused Mac audio capture can restart its aggregate as it was (review 2026-11-26): only when nothing
/// changed while it was paused. A change notice that arrived during the pause, another default output, a different
/// tap format, or an aggregate that is gone all mean a rebuild.
enum TapResumePlan {
    static func canResumeInPlace(changedWhilePaused: Bool, aggregateAlive: Bool, builtOutputUID: String?,
                                 currentOutputUID: String?, builtFormat: AudioStreamBasicDescription?,
                                 currentFormat: AudioStreamBasicDescription?) -> Bool {
        guard !changedWhilePaused, aggregateAlive, let builtOutputUID, builtOutputUID == currentOutputUID,
              let builtFormat, let currentFormat else { return false }
        return sameFormat(builtFormat, currentFormat)
    }

    static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }
}

/// When a failed rebuild of Mac audio is tried again (review 2026-11-26): besides every later device change, after
/// these delays, then only on device changes.
enum TapRetryPolicy {
    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    static func delay(afterFailures failures: Int) -> Duration? {
        failures >= 1 && failures <= delays.count ? delays[failures - 1] : nil
    }
}

/// Mac audio's running, paused and lost bookkeeping (review 2026-11-26), kept apart from the Core Audio calls in
/// `SystemAudioCapture` so its rules can be tested: when a change notice rebuilds, when it is only remembered, when a
/// failure is reported and retried, and when Mac audio counts as back.
struct TapLifecycle: Equatable {
    /// IO is running.
    private(set) var running = false
    /// Paused by the recording.
    private(set) var paused = false
    /// The last build (start, rebuild or resume) failed; later notices and retries try again.
    private(set) var lost = false
    private(set) var stopped = false
    /// A change notice (or a rebuild) came while paused: `resume()` rebuilds instead of restarting in place.
    private(set) var changedWhilePaused = false
    /// Builds that failed since the last success.
    private(set) var failedBuilds = 0

    enum Notice: Equatable { case ignore, remember, rebuild }

    /// A device, tap or stream change notice.
    mutating func noticed() -> Notice {
        guard !stopped else { return .ignore }
        if paused { changedWhilePaused = true; return .remember }
        return running || lost ? .rebuild : .ignore
    }

    /// Whether a rebuild runs now: running, or lost, and not paused. One that a pause stops (the notice came just
    /// before it) is remembered for `resume()`.
    mutating func mayRebuild() -> Bool {
        guard !stopped else { return false }
        if paused { changedWhilePaused = true; return false }
        return running || lost
    }

    /// A build succeeded. Returns whether Mac audio had been lost (deliver `.systemAudioRestored`).
    mutating func built() -> Bool {
        let wasLost = lost
        running = true
        lost = false
        failedBuilds = 0
        changedWhilePaused = false
        return wasLost
    }

    struct Failure: Equatable {
        /// The first failure since Mac audio last ran: report it lost once.
        var firstLoss: Bool
        /// When to try again (nil: only on later change notices, or on resume).
        var retryAfter: Duration?
        /// The failure count the retry belongs to (`retryDue`).
        var attempt: Int
    }

    /// A build failed.
    mutating func failed() -> Failure {
        running = false
        failedBuilds += 1
        let first = !lost
        lost = true
        return Failure(firstLoss: first, retryAfter: TapRetryPolicy.delay(afterFailures: failedBuilds), attempt: failedBuilds)
    }

    /// Whether a scheduled retry runs: still lost, not paused or stopped, and no newer failure has scheduled its own.
    func retryDue(attempt: Int) -> Bool { !stopped && !paused && lost && !running && failedBuilds == attempt }

    /// The recording paused. Returns whether IO was running (stop it).
    mutating func pause() -> Bool {
        guard !stopped else { return false }
        paused = true
        defer { running = false }
        return running
    }

    /// The recording resumes. Returns whether to start or rebuild (not stopped, not running already).
    mutating func beginResume() -> Bool {
        guard !stopped, !running else { return false }
        paused = false
        return true
    }

    mutating func stop() {
        stopped = true
        running = false
    }
}
#endif
