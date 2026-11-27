#if os(macOS)
import Foundation

/// What clocks Mac audio's private aggregate device (2026-11-27). Found with Bose QC headphones on macOS 27: an
/// aggregate clocked by a Bluetooth headset in call mode (HFP, 16 kHz) sets off coreaudiod's "HALS_IORawClock::Update:
/// Re-anchoring IO timeline" about 100 times a second for up to 12.5 s, starting within about 20 ms of the aggregate's
/// IO start; about 30% of IO cycles then come late or not at all and the audio is choppy. Chromium
/// (`catap_audio_input_stream.mm`) and Apple's own corespeechd use an aggregate with the tap alone.
enum MacAudioClock: String, CaseIterable, Sendable {
    /// Only the tap: no sub-device, so no headset clock (as Chromium does). The aggregate's rate is set to 48 kHz and
    /// read back. Not yet tested on hardware.
    case tap
    /// The built-in output device as main sub-device: a steady clock that is never the headset.
    case builtIn
    /// The default output device as main sub-device (the composition before 2026-11-27), the last resort.
    case output
}

/// Which clock compositions a build tries, in order (2026-11-27): `tap`, then `builtIn`, then `output`, each tried
/// only when the one before failed (it could not be created or started, read back no rate or the wrong one, had other
/// input buffers than the tap's, or delivered no IO cycle within `firstIOTimeout` of its start). The mode that worked
/// (delivered its first IO cycle) is kept for the rest of the recording: later rebuilds start from it, then the others
/// in order. Only for `output`, whose clock is the default output, a new default output since starts again from
/// `preferred`; `tap` and `builtIn` do not contain the default output. A mode that started but delivered no IO
/// (`noIO`) is left out of later attempts for the recording, unless that would leave none. When every mode fails the
/// working mode is forgotten.
///
/// `preferred` is `tap`, or in DEBUG builds the user default `macAudioClock` (`tap`, `builtIn`, `output`) for an A/B
/// test on real hardware (`open Transcribe.app --args -macAudioClock output`); the other modes follow it in the usual
/// order.
struct TapClockPlan: Equatable {
    static let order: [MacAudioClock] = [.tap, .builtIn, .output]
    /// IO must start this soon after `AudioDeviceStart`, or the mode counts as failed.
    static let firstIOTimeout: Duration = .seconds(2)

    let preferred: MacAudioClock
    private(set) var working: MacAudioClock?
    /// The default output's UID when `working` was found to work.
    private(set) var workingOutputUID: String?
    /// Modes that started and delivered no IO this recording.
    private(set) var silentModes: Set<MacAudioClock> = []

    init(preferred: MacAudioClock = .tap) { self.preferred = preferred }

    /// The preferred mode from the DEBUG override's raw value (`tap` when absent or unknown).
    static func preferred(override raw: String?) -> MacAudioClock { raw.flatMap(MacAudioClock.init(rawValue:)) ?? .tap }

    /// `first`, then every other mode in the usual order.
    static func sequence(from first: MacAudioClock) -> [MacAudioClock] { [first] + order.filter { $0 != first } }

    /// The modes a build tries now, with the default output at `outputUID`.
    func attempts(outputUID: String?) -> [MacAudioClock] {
        let all: [MacAudioClock]
        if let working, working != .output || workingOutputUID == outputUID {
            all = Self.sequence(from: working)
        } else {
            all = Self.sequence(from: preferred)
        }
        let left = all.filter { !silentModes.contains($0) }
        return left.isEmpty ? all : left
    }

    /// `mode` delivered its first IO cycle with the default output at `outputUID`.
    mutating func confirmed(_ mode: MacAudioClock, outputUID: String?) {
        working = mode
        workingOutputUID = outputUID
        silentModes.remove(mode)
    }

    /// `mode` started and delivered no IO cycle within `firstIOTimeout`.
    mutating func noIO(_ mode: MacAudioClock) {
        silentModes.insert(mode)
        if working == mode { forget() }
    }

    /// Every mode failed: start from `preferred` next time.
    mutating func forget() {
        working = nil
        workingOutputUID = nil
    }
}

/// The `tap` clock's rate after it was set (review 2026-11-27). The HAL applies `kAudioDevicePropertyNominalSampleRate`
/// asynchronously, so a read straight after a set that returned noErr can still give the aggregate's old rate (a
/// default output at 44.1 kHz starts a new tap-only aggregate at 44.1 kHz). Built with that stale rate, the converter
/// would run at the wrong rate, or the rate notice that follows would rebuild every second. So the capture reads the
/// rate back until it is the one set, for at most `timeout`; if it never is, the `tap` clock fails ("rate read back
/// X, set 48000") and the next mode is tried.
enum TapRateSettle {
    static let timeout = 0.5
    static let interval = 0.01

    /// Reads `read` until it gives `target`, at most `timeout` seconds of `sleep(interval)` between reads. Returns
    /// the last value read (the target when it settled).
    static func wait(for target: Double, read: () -> Double?,
                     sleep: (Double) -> Void = { usleep(useconds_t($0 * 1_000_000)) }) -> Double? {
        var value = read()
        var waited = 0.0
        while value != target, waited < timeout - 1e-9 {
            sleep(interval)
            waited += interval
            value = read()
        }
        return value
    }
}

/// A Core Audio property notice about Mac audio's tap or aggregate, with what the capture read when it arrived.
enum TapNotice: Equatable {
    /// The default output (or default system output) is now `currentUID`; the last build was for `builtUID`.
    case defaultOutput(currentUID: String?, builtUID: String?)
    /// The tap's format, compared with the one the last build used.
    case tapFormat(same: Bool)
    /// The aggregate's `kAudioDevicePropertyDeviceIsAlive`.
    case aggregateAlive(Bool)
    /// The clock sub-device's (built-in or output device) `kAudioDevicePropertyDeviceIsAlive`.
    case clockDeviceAlive(Bool)
    /// The aggregate's sub-device or tap list, compared with what it was built with.
    case composition(same: Bool)
    /// The aggregate's input streams, compared with what it was built with.
    case inputStreams(same: Bool)
    /// The IO format (the aggregate's rate, the tap stream's format), compared with the one the converter uses.
    case ioFormat(same: Bool)
}

/// Whether a notice rebuilds Mac audio's aggregate (2026-11-27). Found the same day: on an output switch the
/// default-output listeners rebuilt without comparing anything, and every create or destroy of our own aggregate made
/// coreaudiod pick the defaults again and notify, so the aggregate was rebuilt every 0.29 s for over 20 s (87 times).
/// So every notice is compared with what was built, and a notice that our own build caused compares equal:
/// - The default output: with the `tap` and `builtIn` clocks never a rebuild (the global tap follows every app's
///   output wherever it plays), only the route detail; with `output`, or with no aggregate (lost, `mode` nil), a
///   rebuild only when its UID differs from the one the last build was for.
/// - The tap's format, the aggregate's composition, input streams or IO format: a rebuild only when they differ.
/// - The aggregate, or the clock sub-device of `builtIn` and `output`, no longer alive: a rebuild.
/// Rebuilds the policy asks for are further spaced by `TapRebuildLimiter`, and `TapLifecycle` decides whether one
/// runs now, waits for `resume()`, or is ignored.
enum TapRebuildPolicy {
    enum Decision: Equatable {
        case ignore
        /// Not a rebuild; the capture notes the new output in its detail if the UID really changed.
        case routeOnly
        case rebuild
    }

    static func decide(_ notice: TapNotice, mode: MacAudioClock?) -> Decision {
        switch notice {
        case let .defaultOutput(current, built):
            switch mode {
            case .tap?, .builtIn?: return .routeOnly
            case .output?, nil: return current != built ? .rebuild : .ignore
            }
        case let .tapFormat(same), let .composition(same), let .inputStreams(same), let .ioFormat(same):
            return same ? .ignore : .rebuild
        case let .aggregateAlive(alive):
            return alive ? .ignore : .rebuild
        case let .clockDeviceAlive(alive):
            return alive || mode == .tap ? .ignore : .rebuild
        }
    }
}

/// Spaces the rebuilds that change notices ask for (2026-11-27, after the rebuild loop above). The first runs after
/// `settle` (a burst of property notices settles first); one asked for sooner than `minInterval` after the last
/// rebuild waits until that second has passed. Notices while one is pending join it. A rebuild that runs at once
/// (a retry, a resume or a clock fallback) counts as the last rebuild, and a pending one whose notices all came before
/// it is dropped when its delay is over, since that rebuild already used the current state (review 2026-11-27); one
/// with a notice after it waits until a second after it. So notice rebuilds are at least a second after any rebuild;
/// only the direct ones can come sooner. Times are seconds on any monotonic clock.
struct TapRebuildLimiter: Equatable {
    static let minInterval = 1.0
    static let settle = 0.25

    enum Fire: Equatable {
        /// Rebuild now.
        case rebuild
        /// A rebuild ran after the last notice: nothing to do.
        case skip
        /// Still pending: wait this many seconds more, then `fire` again.
        case wait(Double)
    }

    private(set) var pending = false
    private(set) var lastRebuild: Double?
    /// When the last notice asked for a rebuild.
    private(set) var lastRequest: Double?

    /// A notice asks for a rebuild at `now`: the delay before `fire`, or nil when one is already pending (it joins).
    mutating func request(at now: Double) -> Double? {
        lastRequest = now
        guard !pending else { return nil }
        pending = true
        guard let lastRebuild else { return Self.settle }
        return Swift.max(Self.settle, lastRebuild + Self.minInterval - now)
    }

    /// The pending rebuild's delay is over at `now`.
    mutating func fire(at now: Double) -> Fire {
        guard pending else { return .skip }
        if let lastRebuild {
            if let lastRequest, lastRequest <= lastRebuild {
                pending = false
                return .skip
            }
            let due = lastRebuild + Self.minInterval
            if now < due - 1e-9 { return .wait(due - now) }
        }
        pending = false
        return .rebuild
    }

    /// A rebuild ran at `now` (scheduled, or a retry, a resume or a fallback that runs at once).
    mutating func rebuilt(at now: Double) { lastRebuild = now }
}

/// What the capture does when `TapRateCheck` finds Mac audio arriving at another rate than the converter's
/// (2026-11-27): rebuild the aggregate, at most `maxRebuilds` times a recording, so the rate comes from Core Audio
/// again. Only when those are used up and the check still disagrees does the receiver convert from the measured rate
/// (the swap that used to happen at once, and that stretched the audio when skipped IO cycles were misread as
/// 11,025 Hz).
enum TapRateResponse: Equatable {
    static let maxRebuilds = 2

    case rebuild
    case convertFromMeasured

    static func decide(rateRebuildsSoFar: Int) -> TapRateResponse {
        rateRebuildsSoFar < maxRebuilds ? .rebuild : .convertFromMeasured
    }
}

/// Zeros for IO cycles the HAL skipped (2026-11-27). While a Bluetooth headset's clock re-anchors, about 30% of IO
/// cycles never reach the IO block: the device's sample time moves on past frames that were never delivered. Within
/// one continuous run (host times increasing by no more than `maxGap`, sample time increasing), when the sample time
/// advanced by more than the previous buffer's frames, and the host time advanced by that span at `rate` to within
/// `hostAgreement`, the skipped frames are delivered as zeros at 16 kHz, stamped where they belong (the end of the
/// previous buffer), before the buffer that follows. So Mac audio stays one contiguous, correctly timed stream, also in
/// a Mac-audio-only recording, which has no aligner. `maxGap` is its own (0.5 s, review 2026-11-27), not
/// `TapRateCheck.maxGap`: the aligner places a stream again at once only after a jump in its host times of over
/// 80 ms, and a gap the fill left would otherwise sit early against the microphone; `hostAgreement` already rejects a
/// re-anchored timeline. The receiver converts the zeros at the input rate through its converter, so a resampler's
/// held tail of the previous buffer comes out before them.
struct TapGapFill: Equatable {
    static let maxGap = 0.5
    static let hostAgreement = 0.25

    struct Fill: Equatable {
        /// Input frames skipped.
        var frames: Int
        /// Zeros to deliver at 16 kHz: `round(frames × 16000 / rate)`.
        var samples: Int
        /// The host time of the first zero.
        var hostSeconds: Double
    }

    /// Input frames filled so far (log-only).
    private(set) var filledFrames = 0
    private var lastHost: Double?
    private var lastSample: Double?
    private var lastFrames = 0

    /// IO stopped and starts again (a pause): the next buffer begins a new run and is never preceded by zeros.
    mutating func breakRun() {
        lastHost = nil; lastSample = nil; lastFrames = 0
    }

    /// One buffer of `frames` frames at `host` seconds and the device's `sampleTime`, converted from `rate`.
    /// Returns the zeros to deliver before it, if any.
    mutating func observe(frames: Int, host: Double?, sampleTime: Double?, rate: Double,
                          outputRate: Double = TapConverter.outputSampleRate) -> Fill? {
        defer { lastHost = host; lastSample = sampleTime; lastFrames = frames }
        guard let host, let sampleTime, let lastHost, let lastSample, rate > 0 else { return nil }
        let hostStep = host - lastHost
        guard hostStep > 0, hostStep <= Self.maxGap, sampleTime > lastSample else { return nil }
        let sampleStep = sampleTime - lastSample
        let skipped = Int(sampleStep.rounded()) - lastFrames
        guard skipped > 0 else { return nil }
        let expected = sampleStep / rate
        guard abs(hostStep - expected) <= Self.hostAgreement * expected else { return nil }
        let samples = Int((Double(skipped) * outputRate / rate).rounded())
        guard samples > 0 else { return nil }
        filledFrames += skipped
        return Fill(frames: skipped, samples: samples, hostSeconds: lastHost + Double(lastFrames) / rate)
    }
}

/// Mac audio's IO heartbeat (2026-11-27), counted on the consumer queue and logged every `interval` seconds of host
/// time: frames delivered, the rate (the sample time against host time over the window, else the frames), frames the
/// HAL skipped and the longest host-time gap between two buffers. The receiver adds the IO cycles and ring drops.
struct TapIOStats: Equatable {
    static let interval = 2.0

    struct Report: Equatable {
        var cycles = 0
        var frames = 0
        var rate = 0.0
        var skipped = 0
        var ringDrops = 0
        var maxHostGapMs = 0.0
    }

    private var startHost: Double?
    private var startSample: Double?
    private var lastHost: Double?
    private var lastSample: Double?
    private var sampleRun = true
    private var frames = 0
    private var skipped = 0
    private var maxGap = 0.0

    /// IO stopped and starts again (a pause): the next buffer starts a new window, so the pause is never reported as
    /// a gap or a low rate.
    mutating func breakRun() { self = TapIOStats() }

    /// One buffer of `count` frames at `host` and `sampleTime`, after `skipped` frames the HAL skipped before it.
    mutating func observe(frames count: Int, host: Double?, sampleTime: Double?, skipped newlySkipped: Int) -> Report? {
        let before = frames
        frames += count
        skipped += newlySkipped
        guard let host else { sampleRun = false; return nil }
        if let lastHost { maxGap = Swift.max(maxGap, host - lastHost) }
        if let sampleTime {
            if let lastSample, sampleTime <= lastSample { sampleRun = false }   // IO restarted
        } else {
            sampleRun = false
        }
        lastHost = host; lastSample = sampleTime
        guard let startHost else {
            startHost = host; startSample = sampleTime
            return nil
        }
        let elapsed = host - startHost
        guard elapsed >= Self.interval else { return nil }
        let rate: Double
        if sampleRun, let sampleTime, let startSample { rate = (sampleTime - startSample) / elapsed } else {
            rate = Double(before) / elapsed
        }
        let report = Report(frames: before, rate: rate, skipped: skipped, maxHostGapMs: maxGap * 1_000)
        self.startHost = host; self.startSample = sampleTime
        frames = count; skipped = 0; maxGap = 0; sampleRun = sampleTime != nil
        return report
    }
}
#endif
