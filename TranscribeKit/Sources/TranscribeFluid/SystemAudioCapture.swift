#if os(macOS)
@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Foundation
import os
import TranscribeCore

/// Mac audio: everything the Mac plays except Transcribe itself, through a Core Audio process tap (Mac audio, decided
/// 2026-11-26; checked against the macOS 27 SDK's `AudioHardwareTapping.h`, `CATapDescription.h` and
/// `AudioHardware.h`). No ScreenCaptureKit, and no entitlement: the system asks for "Screen & System Audio Recording"
/// the first time the tap runs, using the Info.plist's `NSAudioCaptureUsageDescription`.
///
/// - **Tap:** `CATapDescription(monoGlobalTapButExcludeProcesses:)`, excluding this app by bundle id (`bundleIDs`,
///   macOS 26) and by its audio object (`kAudioHardwarePropertyTranslatePIDToProcessObject` on `getpid()`). This
///   process has no audio object until it has used audio (a Mac-audio-only recording uses none before the tap), so
///   when there was none it watches the process list (`kAudioHardwarePropertyProcessObjectList`, and checks after
///   0.1 to 5 s) and sets the tap's description again with it as soon as it appears (`kAudioTapPropertyDescription`).
///   Private, `.unmuted` (the user still hears everything).
/// - **Aggregate device and its clock** (2026-11-27, `TapClockPlan`): private, `tapautostart` off (so starting it
///   never waits for sound), with the tap (drift compensation on), in the first of three compositions that works:
///   `tap` (the tap alone, no sub-device, its rate set to 48 kHz and read back until it is 48 kHz, at most 0.5 s:
///   `TapRateSettle`, as the HAL applies a rate asynchronously), `builtIn` (the
///   built-in output device as main sub-device) and `output` (the default output device as main sub-device, the
///   composition before 2026-11-27). Why: an aggregate clocked by a Bluetooth headset in call mode set off a storm of
///   clock re-anchoring in coreaudiod that lost about 30% of IO cycles for up to 12.5 s. A composition fails when it
///   cannot be created or started, reads back no rate (`tap`, `builtIn`) or not the rate set (`tap`), has other input
///   buffers than the tap's (`tap`) or than `TapBufferLayout.place` can account for, or delivers no IO cycle within
///   2 s of its start (the receiver reports its first IO cycle, `onFirstIO`; a watchdog with its own token checks at
///   2 s); then the next is tried. The one that delivered IO is kept for the rest of the recording; one that never
///   did is left out of later attempts. A build counts as a success, and lost Mac audio as back, only once its first
///   IO cycle came (`TapLifecycle.confirmed`). When the clock device has inputs
///   of its own (AirPods, a USB headset as the default output), the tap's buffers are picked by position and the other
///   input streams are turned off for the IOProc (`kAudioDevicePropertyIOProcStreamUsage`), so the device's microphone
///   is never used. The IO block drops any cycle whose buffer count is not the one the aggregate was built with; that
///   rebuilds it.
/// - **IOProc:** `AudioDeviceCreateIOProcIDWithBlock` on a serial queue. The block only copies the tap's buffers and
///   the host time into a preallocated `TapRing` and signals; a second queue converts them with a `TapConverter` to
///   16 kHz mono, fills IO cycles the HAL skipped with zeros (`TapGapFill`) and delivers them with their host time.
/// - **Changes** (`TapRebuildPolicy`, `TapRebuildLimiter`): every notice is compared with what was built, so the
///   notices our own aggregate's creation and destruction cause never rebuild it (2026-11-27: comparing nothing
///   rebuilt it every 0.29 s for over 20 s). With the `tap` and `builtIn` clocks a new default output only updates
///   the route detail; with `output` it rebuilds when its UID differs. A changed tap format, composition, input
///   streams or IO format, or an aggregate or clock device that died, rebuild. At most one rebuild a second. A change
///   while paused is remembered, and `resume()` then rebuilds (`TapResumePlan`). A rebuild without a list of modes
///   restarts the mode still waiting for its first IO, if any, else follows the plan. A rebuild that fails delivers
///   `.systemAudioLost` once (a Both recording carries on with the microphone; a Mac-audio-only recording pauses, see
///   `FluidLiveRecording`) and is tried again on every later change and after `TapRetryPolicy.delays`, unless paused;
///   when one delivers its first IO cycle it delivers `.systemAudioRestored`. The rules are `TapLifecycle`'s.
/// - **Rate:** `TapRateCheck` measures the rate the IO runs at; when it disagrees with the converter's, the aggregate
///   is rebuilt (at most twice a recording), and only after that does the receiver convert from the measured rate
///   (`TapRateResponse`).
/// - **Start:** with `keepsTryingAfterFailedStart` (a Both recording), a start that fails still throws (the caller
///   reports Mac audio lost) but keeps the listeners and retries like a failed rebuild, so Mac audio joins the
///   recording when the output comes back. Without it (Mac audio only) a failed start tears everything down.
/// - **No permission API:** when access is off the tap delivers exact zeros. After `silentNoticeSeconds` of nothing
///   but exact zeros while another process is playing sound (`kAudioProcessPropertyIsRunningOutput`), it delivers
///   `.systemAudioSilent` once. No private TCC calls.
/// - **`stop()`:** stops and destroys the IOProc, then the aggregate, then the tap.
actor SystemAudioCapture: StampedCaptureSource {
    /// Exact silence this long, with another app playing, gives `.systemAudioSilent`.
    static let silentNoticeSeconds: Double = 5
    /// Rebuilds asked for by the IO block seeing an input list of another length, per recording.
    static let maxLayoutRebuilds = 3
    /// The rate the `tap` clock's aggregate is set to (read back afterwards; the HAL resamples the tap to it).
    static let tapClockRate: Float64 = 48_000
    /// When to look again for this process's audio object if no notice brings it.
    static let ownProcessChecks: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500), .seconds(1),
                                               .seconds(2), .seconds(5)]

    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "SystemAudioCapture")
    private let ioQueue = DispatchQueue(label: "ai.w2solutions.transcribe.mac-audio.io", qos: .userInitiated)
    /// Converts and delivers what the IO block put in the ring (every receiver of this capture, in order).
    private let processQueue = DispatchQueue(label: "ai.w2solutions.transcribe.mac-audio.process", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "ai.w2solutions.transcribe.mac-audio.listeners")
    private let keepsTryingAfterFailedStart: Bool

    private var deliver: (@Sendable (StampedInput) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID = ""
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var receiver: TapReceiver?
    private var state = TapLifecycle()
    private var plan: TapClockPlan
    private var limiter = TapRebuildLimiter()
    /// Changes on every build attempt and every teardown of the aggregate, so callbacks of an old one are ignored.
    private var generation = 0
    /// What the running aggregate was built for.
    private var builtMode: MacAudioClock?
    private var builtClockDevice = AudioObjectID(kAudioObjectUnknown)
    private var builtOutputUID: String?
    private var builtFormat: AudioStreamBasicDescription?
    private var builtLayout: [UInt32] = []
    /// The tap's first buffer among the aggregate's inputs when it was built.
    private var builtFirst = 0
    private var builtStreams: [AudioObjectID] = []
    /// The composition asked for (sub-device UIDs) and the sub-device and tap lists the aggregate reported after it
    /// was made (nil when unreadable).
    private var builtSubDevices: [String] = []
    private var builtSubDevicesRead: [String]?
    private var builtTapsRead: [String]?
    /// The default output's UID and the tap's format at the last build attempt, kept while Mac audio is lost so only a
    /// real change tries again.
    private var attemptOutputUID: String?
    private var attemptTapFormat: AudioStreamBasicDescription?
    /// The mode started last, until its first IO cycle confirms it, with the modes still to try if it never comes.
    private var unconfirmed: (mode: MacAudioClock, rest: [MacAudioClock], outputUID: String?)?
    /// Changes whenever a first-IO watchdog is armed, a mode is confirmed or IO pauses, so an older watchdog is ignored.
    private var watchdogToken = 0
    private var layoutRebuilds = 0
    private var rateRebuilds = 0
    private var tapDescription: CATapDescription?
    private var excludesOwnProcess = false
    private var watchingOwnProcess = false
    private var silentNoticeSent = false
    private var detail: CaptureDetail?
    /// The default output the route detail was last noted for.
    private var routeOutputUID: String?
    private var listeners: [Listener] = []

    private struct Listener {
        enum Kind { case system, aggregate, ownProcess }
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        /// The aggregate's own listeners are replaced on every rebuild; the process-list one goes once this process
        /// is excluded.
        let kind: Kind
    }

    /// Why one clock composition failed (logged; the next one is tried).
    private struct ClockFailure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// - Parameter keepsTryingAfterFailedStart: a Both recording's Mac audio: a failed start keeps trying to join.
    init(keepsTryingAfterFailedStart: Bool = false) {
        self.keepsTryingAfterFailedStart = keepsTryingAfterFailedStart
        plan = TapClockPlan(preferred: Self.preferredClock())
    }

    /// `tap`, or in DEBUG builds the user default `macAudioClock` (`tap`, `builtIn` or `output`), for an A/B test on
    /// real hardware: `open Transcribe.app --args -macAudioClock output`. The other modes still follow as fallbacks.
    static func preferredClock() -> MacAudioClock {
        #if DEBUG
        TapClockPlan.preferred(override: UserDefaults.standard.string(forKey: "macAudioClock"))
        #else
        .tap
        #endif
    }

    func captureDetail() async -> CaptureDetail? { detail }

    func startStamped(_ deliver: @escaping @Sendable (StampedInput) -> Void) async throws {
        guard self.deliver == nil, !state.stopped else { throw EngineError.failed("Capture already started") }
        self.deliver = deliver
        if plan.preferred != .tap { log.notice("Mac audio: trying the \(self.plan.preferred.rawValue, privacy: .public) clock first (DEBUG override)") }
        do {
            try createTap()
            try buildAndStart(modes: plan.attempts(outputUID: Self.currentOutputUID()))
            limiter.rebuilt(at: Self.now())
            state.started()
            detail = Self.currentDetail()
            routeOutputUID = Self.currentOutputUID()
            addSystemListeners()
            ownProcessMayHaveChanged()
        } catch {
            guard keepsTryingAfterFailedStart else {
                teardown()
                self.deliver = nil
                throw FluidErrorMapping.engineError(error)
            }
            // A Both recording: the caller reports Mac audio lost; device changes and retries may still bring it in.
            destroyAggregate()
            let failure = state.failed()
            routeOutputUID = Self.currentOutputUID()
            addSystemListeners()
            scheduleRetry(failure)
            log.error("Mac audio did not start; trying again on device changes: \(FluidErrorMapping.describe(error), privacy: .public)")
            throw FluidErrorMapping.engineError(error)
        }
    }

    func pause() async {
        guard state.pause() else { return }
        watchdogToken &+= 1     // `resume()` arms a fresh one for a mode still waiting for its first IO
        if let procID, aggregateID != kAudioObjectUnknown { _ = AudioDeviceStop(aggregateID, procID) }
        receiver?.flush()       // nothing is delivered after a pause returns
        receiver?.breakRun()    // the pause is never filled with zeros
    }

    func resume() async throws {
        guard deliver != nil, state.beginResume() else { return }
        do {
            let inPlace = procID != nil && aggregateID != kAudioObjectUnknown && TapResumePlan.canResumeInPlace(
                mode: builtMode ?? .output, changedWhilePaused: state.changedWhilePaused,
                aggregateAlive: Self.isAlive(aggregateID), builtOutputUID: builtOutputUID,
                currentOutputUID: Self.currentOutputUID(), builtFormat: builtFormat, currentFormat: currentIOFormat())
            if inPlace, let procID, AudioDeviceStart(aggregateID, procID) == noErr {
                state.started()
                // Restarted as it was. A mode whose first IO came while paused is confirmed now; one whose first IO
                // has not come yet gets its 2 s again.
                if unconfirmed != nil {
                    if (receiver?.ioCycles ?? 0) > 0 { confirmMode() } else { armFirstIOWatchdog() }
                }
            } else {
                // Something changed while paused, or the aggregate went away (or never came back after a lost
                // route): rebuild it around the current output and tap format.
                noteRoute()
                let modes = plannedModes()
                destroyAggregate()
                try ensureTap()
                try buildAndStart(modes: modes)
                limiter.rebuilt(at: Self.now())
                state.started()
            }
            if detail == nil { detail = Self.currentDetail() }
            ownProcessMayHaveChanged()
        } catch {
            // The caller reports it lost; later device changes and the retries may still bring it back (unless the
            // caller pauses again, as a Mac-audio-only recording does).
            destroyAggregate()
            scheduleRetry(state.failed())
            throw EngineError.failed("Could not resume Mac audio: \(FluidErrorMapping.describe(error))")
        }
    }

    func stop() async {
        guard !state.stopped else { return }
        state.stop()
        teardown()
    }

    // MARK: Tap and aggregate

    private func createTap() throws {
        let own = Self.ownProcessObject()
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        if let bundleID = Bundle.main.bundleIdentifier { description.bundleIDs = [bundleID] }
        description.uuid = UUID()
        description.name = "Transcribe Mac audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw EngineError.failed("Could not start recording Mac audio (tap \(status))")
        }
        tapID = id
        tapUID = description.uuid.uuidString
        tapDescription = description
        excludesOwnProcess = own != nil
        if own == nil { log.notice("Mac audio tap created before this process had an audio object; excluding it when one appears") }
    }

    /// Creates the tap if a failed start left none, with its format listener.
    private func ensureTap() throws {
        guard tapID == kAudioObjectUnknown else { return }
        try createTap()
        if deliver != nil { addListener(tapID, kAudioTapPropertyFormat, kind: .system) { await $0.tapFormatNoticed() } }
    }

    /// The tap was made before this process had an audio object (a Mac-audio-only recording starts no microphone
    /// first). Once it has one, the tap's description is set again excluding it. Without this, sound Transcribe plays
    /// during the recording (a transcript or a voice sample) would be recorded.
    private func excludeOwnProcessIfNeeded() {
        guard !excludesOwnProcess, tapID != kAudioObjectUnknown, let description = tapDescription,
              let own = Self.ownProcessObject() else { return }
        description.processes = [own]
        var addr = Self.address(kAudioTapPropertyDescription)
        var value: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr {
            excludesOwnProcess = true
            log.info("Mac audio tap now excludes this process")
        } else {
            log.error("Could not exclude this process from the Mac audio tap (\(status, privacy: .public))")
        }
    }

    /// Excludes this process if it now has an audio object; until then, watches the process list and checks again
    /// after `ownProcessChecks` (whichever comes first). Stops watching once excluded.
    private func ownProcessMayHaveChanged() {
        guard !state.stopped else { return }
        excludeOwnProcessIfNeeded()
        if excludesOwnProcess {
            if watchingOwnProcess { removeListeners { $0 == .ownProcess } }
            watchingOwnProcess = false
            return
        }
        guard !watchingOwnProcess, tapID != kAudioObjectUnknown else { return }
        watchingOwnProcess = true
        log.notice("This process has no audio object yet; the tap excludes it by bundle id until it has one")
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, kind: .ownProcess) {
            await $0.ownProcessMayHaveChanged()
        }
        Task { [weak self] in
            for delay in Self.ownProcessChecks {
                try? await Task.sleep(for: delay)
                guard let self, await self.stillWatchingOwnProcess else { return }
                await self.ownProcessMayHaveChanged()
            }
        }
    }

    private var stillWatchingOwnProcess: Bool { watchingOwnProcess && !state.stopped }

    /// Builds the aggregate around the tap with the first of `modes` that works and starts IO (`TapClockPlan`). Each
    /// mode that fails is logged and torn down before the next; when none works, the plan forgets its working mode
    /// and this throws. The mode that started still has to deliver its first IO cycle (`armFirstIOWatchdog`).
    private func buildAndStart(modes: [MacAudioClock]) throws {
        guard deliver != nil else { throw EngineError.failed("Capture not started") }
        let outputID = Self.defaultOutputDevice()
        let outputUID = outputID.flatMap(Self.outputUID)
        attemptOutputUID = outputUID
        attemptTapFormat = tapID == kAudioObjectUnknown ? nil : Self.tapFormat(tapID)
        var lastReason = "no clock to try"
        for (i, mode) in modes.enumerated() {
            do {
                try build(mode, outputID: outputID, outputUID: outputUID)
                unconfirmed = (mode, Array(modes.dropFirst(i + 1)), outputUID)
                armFirstIOWatchdog()
                return
            } catch let failure as ClockFailure {
                destroyAggregate()
                lastReason = failure.reason
                let next = i + 1 < modes.count ? "trying \(modes[i + 1].rawValue)" : "no clock left"
                log.notice("Mac audio: \(mode.rawValue, privacy: .public) clock failed (\(failure.reason, privacy: .public)); \(next, privacy: .public)")
            }
        }
        plan.forget()
        throw EngineError.failed("Could not start recording Mac audio (\(lastReason))")
    }

    /// One composition (see the type's doc). Throws `ClockFailure`; the caller tears down what it left.
    private func build(_ mode: MacAudioClock, outputID: AudioObjectID?, outputUID: String?) throws {
        guard let deliver else { throw ClockFailure("capture not started") }
        generation &+= 1
        let gen = generation
        let clock: (id: AudioObjectID, uid: String)?
        switch mode {
        case .tap:
            clock = nil
        case .builtIn:
            guard let builtIn = Self.builtInOutputDevice() else { throw ClockFailure("no built-in output") }
            clock = builtIn
        case .output:
            guard let outputID, let outputUID else { throw ClockFailure("no sound output") }
            clock = (outputID, outputUID)
        }

        // The tap-only composition is Chromium's (catap_audio_input_stream.mm): no sub-device list, no main sub-device.
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcribe Mac audio",
            kAudioAggregateDeviceUIDKey: "ai.w2solutions.transcribe.mac-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let clock {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = clock.uid
            composition[kAudioAggregateDeviceIsStackedKey] = false
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: clock.uid]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else { throw ClockFailure("create \(status)") }
        aggregateID = aggregate

        // The tap clock runs at the rate we set (the HAL resamples the tap to it). The HAL applies it asynchronously, so
        // read it back until it is the rate set (`TapRateSettle`); a rate that never gets there fails the mode.
        var rateSet: Float64?
        var aggregateRate: Float64?
        if mode == .tap, Self.setNominalSampleRate(aggregate, Self.tapClockRate) == noErr {
            rateSet = Self.tapClockRate
            aggregateRate = TapRateSettle.wait(for: Self.tapClockRate) { Self.nominalSampleRate(aggregate) }
            guard aggregateRate == Self.tapClockRate else {
                throw ClockFailure("rate read back \(aggregateRate.map { "\(Int($0))" } ?? "none"), set \(Int(Self.tapClockRate))")
            }
        } else {
            aggregateRate = Self.nominalSampleRate(aggregate)
        }
        if mode != .output, aggregateRate == nil { throw ClockFailure("no rate") }

        guard let tapASBD = Self.tapFormat(tapID) else { throw ClockFailure("unsupported tap format") }
        let interleaved = tapASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let tapChannels = Swift.max(1, tapASBD.mChannelsPerFrame)

        // The tap's buffers among the aggregate's inputs (a clock device may add its own microphone streams; with the
        // tap alone there must be nothing else). A new aggregate can report no inputs for a moment, or not list the
        // clock device's own inputs yet: read once more before giving up.
        let tapBuffers = interleaved ? 1 : Int(tapChannels)
        let subLayout = clock.map { Self.inputLayout($0.id) } ?? []
        var layout = Self.inputLayout(aggregate)
        if layout.count < tapBuffers + subLayout.count {
            usleep(50_000)
            layout = Self.inputLayout(aggregate)
        }
        let streams = Self.inputStreams(aggregate)
        guard let placement = TapBufferLayout.place(
            channelsPerBuffer: layout, aggregateStreams: streams,
            subDeviceStreams: clock.map { Set(Self.inputStreams($0.id)) } ?? [], subDeviceLayout: subLayout,
            terminalTypes: streams.count == layout.count ? streams.map(Self.terminalType) : [],
            tapBuffers: tapBuffers, tapChannelsPerBuffer: interleaved ? tapChannels : 1)
        else { throw ClockFailure("input layout \(layout.count) buffers, expected \(tapBuffers + subLayout.count)") }
        let first = placement.first

        // The IO block gets the tap's samples at the aggregate's rate: with the `output` clock that is the output
        // device's, and a Bluetooth headset in call mode runs at 16 kHz while the tap still says 48 kHz (found
        // 2026-11-27 with Bose headphones: read as 48 kHz, every 40 ms chunk shrank to a third and the aligner filled
        // the rest with zeros).
        let streamASBD = streams.count == layout.count && first < streams.count ? Self.virtualFormat(streams[first]) : nil
        var ioASBD = TapStreamFormat.ioFormat(tap: tapASBD, streamFormat: streamASBD, aggregateRate: aggregateRate)
        guard let format = AVAudioFormat(streamDescription: &ioASBD), let converter = TapConverter(inputFormat: format)
        else { throw ClockFailure("unsupported format") }

        if layout.count > tapBuffers {
            log.notice("The \(mode.rawValue, privacy: .public) clock device has \(layout.count - tapBuffers, privacy: .public) input streams of its own; recording only the tap's at \(first, privacy: .public) of \(layout, privacy: .public)\(placement.certain ? "" : " (by the composition's order)", privacy: .public)")
        }

        let bytesPerFrame = Int(ioASBD.mBytesPerFrame)
        let maxFrames = Swift.max(8_192, 4 * Int(Self.uint32(aggregate, kAudioDevicePropertyBufferFrameSize) ?? 0))
        let ring = TapRing(slotCount: 128, bufferCount: tapBuffers, bytesPerBuffer: Swift.max(1, bytesPerFrame) * maxFrames,
                           expectedBufferCount: layout.count)
        let receiver = TapReceiver(format: format, converter: converter, ring: ring, firstIndex: first,
                                   bytesPerFrame: bytesPerFrame, queue: processQueue, deliver: deliver,
                                   silentFrames: Int(Self.silentNoticeSeconds * TapConverter.outputSampleRate),
                                   onLongSilence: { [weak self] in Task { await self?.longSilence() } },
                                   onLayoutMismatch: { [weak self] in Task { await self?.layoutMismatch(generation: gen) } },
                                   onFirstIO: { [weak self] in Task { await self?.firstIOArrived(generation: gen) } },
                                   onRateVerdict: { [weak self] inUse, measured in
                                       Task { await self?.rateDisagrees(generation: gen, inUse: inUse, measured: measured) }
                                   },
                                   onStats: { [log] r in
                                       log.info("Mac audio io: cycles=\(r.cycles, privacy: .public) frames=\(r.frames, privacy: .public) rate(sample/host)=\(Int(r.rate.rounded()), privacy: .public) skipped=\(r.skipped, privacy: .public) ringDrops=\(r.ringDrops, privacy: .public) maxHostGapMs=\(Int(r.maxHostGapMs.rounded()), privacy: .public)")
                                   })
        self.receiver = receiver
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue, receiver.ioBlock)
        guard status == noErr, let proc else { throw ClockFailure("IOProc \(status)") }
        procID = proc
        if layout.count > tapBuffers {
            let usage = TapBufferLayout.streamUsage(streamCount: layout.count, firstTapIndex: first, tapBuffers: tapBuffers)
            let set = Self.setStreamUsage(aggregate, proc: proc, usage: usage)
            if set != noErr { log.error("Could not turn off the clock device's own input streams (\(set, privacy: .public))") }
        }
        let started = ContinuousClock.now
        status = AudioDeviceStart(aggregate, proc)
        let startMs = Int((ContinuousClock.now - started) / .milliseconds(1))
        guard status == noErr else { throw ClockFailure("start \(status)") }
        builtMode = mode
        builtClockDevice = clock?.id ?? AudioObjectID(kAudioObjectUnknown)
        builtOutputUID = outputUID
        builtFormat = ioASBD
        builtFirst = first
        builtLayout = layout
        builtStreams = streams
        builtSubDevices = clock.map { [$0.uid] } ?? []
        builtSubDevicesRead = Self.stringArray(aggregate, kAudioAggregateDevicePropertyFullSubDeviceList)
        builtTapsRead = Self.stringArray(aggregate, kAudioAggregateDevicePropertyTapList)
        let outRate = outputID.flatMap(Self.nominalSampleRate).map { "\(Int($0))" } ?? "-"
        let set = rateSet.map { "\(Int($0))" } ?? "-"
        log.notice("Mac audio build: clock=\(mode.rawValue, privacy: .public) out=\(SystemOutputRoute.current(), privacy: .public) outRate=\(outRate, privacy: .public) aggRate set=\(set, privacy: .public) read=\(Int(aggregateRate ?? 0), privacy: .public) tap=\(Int(tapASBD.mSampleRate), privacy: .public) buffers=\(layout.count, privacy: .public) startMs=\(startMs, privacy: .public)")
        if Int(ioASBD.mSampleRate) != Int(aggregateRate ?? 0) {
            log.notice("Mac audio converts from \(Int(ioASBD.mSampleRate), privacy: .public) Hz (tap stream \(Int(streamASBD?.mSampleRate ?? 0), privacy: .public) Hz)")
        }
        addAggregateListeners()
    }

    /// The mode just started must deliver an IO cycle within `TapClockPlan.firstIOTimeout`, else the next is tried.
    /// Each watchdog has its own token, so one armed before a pause, a confirmation or a later arm does nothing.
    private func armFirstIOWatchdog() {
        watchdogToken &+= 1
        let gen = generation, token = watchdogToken
        Task { [weak self] in
            try? await Task.sleep(for: TapClockPlan.firstIOTimeout)
            await self?.checkFirstIO(generation: gen, token: token)
        }
    }

    /// The receiver saw its first IO cycle (`onFirstIO`). While paused it waits for `resume()`, which confirms it.
    private func firstIOArrived(generation gen: Int) {
        guard gen == generation, unconfirmed != nil, !state.paused, !state.stopped else { return }
        confirmMode()
    }

    /// The mode waiting for its first IO delivered it: the plan keeps it, and lost Mac audio is back.
    private func confirmMode() {
        guard let pending = unconfirmed else { return }
        unconfirmed = nil
        watchdogToken &+= 1
        plan.confirmed(pending.mode, outputUID: pending.outputUID)
        if state.confirmed() {
            log.notice("Mac audio is back")
            deliver?(.event(.systemAudioRestored))
        }
    }

    private func checkFirstIO(generation gen: Int, token: Int) async {
        // Paused meanwhile: `resume()` arms it again; rebuilt, confirmed or stopped: not this watchdog's any more.
        guard gen == generation, token == watchdogToken, let pending = unconfirmed, let receiver, state.running,
              !state.paused, !state.stopped
        else { return }
        if receiver.ioCycles > 0 {
            confirmMode()
            return
        }
        let next = pending.rest.first.map { "trying \($0.rawValue)" } ?? "no clock left"
        log.notice("Mac audio: \(pending.mode.rawValue, privacy: .public) clock failed (no IO within 2 s); \(next, privacy: .public)")
        plan.noIO(pending.mode)
        await rebuild(reason: "no IO from the \(pending.mode.rawValue) clock", modes: pending.rest)
    }

    /// The modes a rebuild without its own list tries: the mode still waiting for its first IO and the ones after it,
    /// else the plan's order (so a notice or a retry never goes back to a mode the watchdog already left).
    private func plannedModes() -> [MacAudioClock] {
        if let pending = unconfirmed { return [pending.mode] + pending.rest }
        return plan.attempts(outputUID: Self.currentOutputUID())
    }

    private func destroyAggregate() {
        removeListeners { $0 == .aggregate }
        generation &+= 1
        if let procID, aggregateID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        // IO has stopped: deliver what is left in the ring (in the old format), then let the receiver go.
        if let receiver {
            if receiver.dropped > 0 {
                log.info("Mac audio dropped \(receiver.dropped, privacy: .public) tap buffers (\(receiver.layoutMismatches, privacy: .public) for a changed input layout)")
            }
            receiver.finish()
            let skipped = receiver.skippedFrames
            if skipped > 0 {
                log.notice("Mac audio: the output skipped \(skipped, privacy: .public) frames of IO (lost audio, filled with silence; \(receiver.filledFrames, privacy: .public) filled in place)")
            }
        }
        receiver = nil
        unconfirmed = nil
        watchdogToken &+= 1
        builtMode = nil
        builtClockDevice = AudioObjectID(kAudioObjectUnknown)
        builtOutputUID = nil
        builtFormat = nil
        builtLayout = []
        builtStreams = []
        builtSubDevices = []
        builtSubDevicesRead = nil
        builtTapsRead = nil
        if aggregateID != kAudioObjectUnknown { _ = AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func teardown() {
        removeListeners { _ in true }
        watchingOwnProcess = false
        destroyAggregate()
        if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Changes

    private func addSystemListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        addListener(system, kAudioHardwarePropertyDefaultOutputDevice, kind: .system) {
            await $0.defaultOutputNoticed("default output")
        }
        addListener(system, kAudioHardwarePropertyDefaultSystemOutputDevice, kind: .system) {
            await $0.defaultOutputNoticed("default system output")
        }
        addListener(tapID, kAudioTapPropertyFormat, kind: .system) { await $0.tapFormatNoticed() }
    }

    private func addAggregateListeners() {
        addListener(aggregateID, kAudioDevicePropertyDeviceIsAlive, kind: .aggregate) { await $0.aggregateAliveNoticed() }
        addListener(aggregateID, kAudioAggregateDevicePropertyFullSubDeviceList, kind: .aggregate) {
            await $0.compositionNoticed("sub-devices")
        }
        addListener(aggregateID, kAudioAggregateDevicePropertyTapList, kind: .aggregate) { await $0.compositionNoticed("taps") }
        addListener(aggregateID, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                    kind: .aggregate) { await $0.inputStreamsNoticed() }
        addListener(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput,
                    kind: .aggregate) { await $0.inputStreamsNoticed() }
        // The output switching rate (a Bluetooth headset going into or out of call mode when a microphone starts).
        addListener(aggregateID, kAudioDevicePropertyNominalSampleRate, kind: .aggregate) { await $0.ioFormatNoticed() }
        if builtFirst < builtStreams.count {
            addListener(builtStreams[builtFirst], kAudioStreamPropertyVirtualFormat, kind: .aggregate) {
                await $0.ioFormatNoticed()
            }
        }
        // The built-in or output device that clocks the aggregate going away.
        addListener(builtClockDevice, kAudioDevicePropertyDeviceIsAlive, kind: .aggregate) { await $0.clockDeviceAliveNoticed() }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, kind: Listener.Kind,
                             _ handler: @escaping @Sendable (SystemAudioCapture) async -> Void) {
        guard object != kAudioObjectUnknown else { return }
        var address = Self.address(selector, scope: scope)
        guard !listeners.contains(where: { $0.object == object && $0.address.mSelector == selector && $0.address.mScope == scope })
        else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await handler(self) }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr else { return }
        listeners.append(Listener(object: object, address: address, block: block, kind: kind))
    }

    private func removeListeners(where remove: (Listener.Kind) -> Bool) {
        var kept: [Listener] = []
        for var l in listeners {
            guard remove(l.kind) else { kept.append(l); continue }
            _ = AudioObjectRemovePropertyListenerBlock(l.object, &l.address, listenerQueue, l.block)
        }
        listeners = kept
    }

    private func defaultOutputNoticed(_ what: String) async {
        await handle(.defaultOutput(currentUID: Self.currentOutputUID(), builtUID: attemptOutputUID), what)
    }

    private func tapFormatNoticed() async {
        let current = tapID == kAudioObjectUnknown ? nil : Self.tapFormat(tapID)
        let same: Bool
        switch (current, attemptTapFormat) {
        case let (current?, built?): same = TapResumePlan.sameFormat(current, built)
        case (nil, nil): same = true
        default: same = false
        }
        await handle(.tapFormat(same: same), "tap format")
    }

    private func aggregateAliveNoticed() async {
        guard aggregateID != kAudioObjectUnknown else { return }
        await handle(.aggregateAlive(Self.isAlive(aggregateID)), "aggregate alive")
    }

    private func clockDeviceAliveNoticed() async {
        guard builtClockDevice != kAudioObjectUnknown else { return }
        await handle(.clockDeviceAlive(Self.isAlive(builtClockDevice)), "clock device alive")
    }

    /// The aggregate's sub-device or tap list: the same when it is what we asked for, or what the aggregate reported
    /// right after it was made (an unreadable list is left to the alive notices).
    private func compositionNoticed(_ what: String) async {
        guard aggregateID != kAudioObjectUnknown else { return }
        func same(_ current: [String]?, read: [String]?, asked: [String]) -> Bool {
            guard let current else { return true }
            let lowered = current.map { $0.lowercased() }
            return lowered == read?.map { $0.lowercased() } || lowered == asked.map { $0.lowercased() }
        }
        let subs = Self.stringArray(aggregateID, kAudioAggregateDevicePropertyFullSubDeviceList)
        let taps = Self.stringArray(aggregateID, kAudioAggregateDevicePropertyTapList)
        let unchanged = same(subs, read: builtSubDevicesRead, asked: builtSubDevices)
            && same(taps, read: builtTapsRead, asked: [tapUID])
        await handle(.composition(same: unchanged), what)
    }

    /// The aggregate's input streams: a rebuild only when they differ from what it was built with (turning the
    /// sub-device's streams off for the IOProc may notify without changing them).
    private func inputStreamsNoticed() async {
        guard aggregateID != kAudioObjectUnknown, !builtLayout.isEmpty else { return }
        let same = Self.inputLayout(aggregateID) == builtLayout && Self.inputStreams(aggregateID) == builtStreams
        await handle(.inputStreams(same: same), "input streams")
    }

    /// The aggregate's rate or the tap stream's format: a rebuild only when the IO format differs from what the
    /// converter was built for (a new aggregate may notify while it settles).
    private func ioFormatNoticed() async {
        guard aggregateID != kAudioObjectUnknown, let builtFormat, let current = currentIOFormat() else { return }
        let same = TapResumePlan.sameFormat(builtFormat, current)
        if !same {
            log.notice("Mac audio's rate changed from \(builtFormat.mSampleRate, privacy: .public) to \(current.mSampleRate, privacy: .public) Hz")
        }
        await handle(.ioFormat(same: same), "IO format")
    }

    /// Every notice goes through `TapRebuildPolicy` (compared with what was built), then `TapLifecycle` (running,
    /// paused or lost), then `TapRebuildLimiter` (a second after the last rebuild, and dropped when a rebuild already
    /// ran after it).
    private func handle(_ notice: TapNotice, _ what: String) async {
        guard deliver != nil, !state.stopped else { return }
        switch TapRebuildPolicy.decide(notice, mode: builtMode) {
        case .ignore:
            log.debug("Mac audio notice: \(what, privacy: .public) → ignored")
        case .routeOnly:
            let changed = noteRoute()
            log.debug("Mac audio notice: \(what, privacy: .public) → ignored\(changed ? " (route noted)" : "", privacy: .public)")
        case .rebuild:
            switch state.noticed() {
            case .ignore:
                log.debug("Mac audio notice: \(what, privacy: .public) → ignored")
            case .remember:
                log.info("Mac audio notice: \(what, privacy: .public) → rebuild on resume")
            case .rebuild:
                log.info("Mac audio notice: \(what, privacy: .public) → rebuild")
                await requestRebuild(reason: "\(what) changed")
            }
        }
    }

    /// Notes a new default output in the capture detail (log-only): `routeChanged`, and where the sound plays now.
    /// Returns whether it changed.
    @discardableResult
    private func noteRoute() -> Bool {
        let current = Self.currentOutputUID()
        guard current != routeOutputUID else { return false }
        routeOutputUID = current
        guard var noted = detail else { return false }
        let now = Self.currentDetail()
        noted.inputName = now.inputName
        noted.inputModelUID = now.inputModelUID
        noted.outputRoute = now.outputRoute
        noted.routeChanged = true
        detail = noted
        return true
    }

    /// Schedules one rebuild through `TapRebuildLimiter`; a request while one is pending joins it. When its delay is
    /// over it is dropped if a rebuild (a retry, a resume or a fallback) already ran after its last notice, and waits
    /// on if one ran less than a second ago.
    private func requestRebuild(reason: String) async {
        guard var delay = limiter.request(at: Self.now()) else { return }
        while true {
            try? await Task.sleep(for: .seconds(delay))
            switch limiter.fire(at: Self.now()) {
            case .rebuild:
                await rebuild(reason: reason)
                return
            case .skip:
                log.debug("Mac audio: a rebuild already ran after the notice; not rebuilding again")
                return
            case .wait(let more):
                delay = more
            }
        }
    }

    /// The format the IO block delivers now: the tap's sample layout at the aggregate's (else the tap stream's) rate.
    private func currentIOFormat() -> AudioStreamBasicDescription? {
        guard tapID != kAudioObjectUnknown, let tap = Self.tapFormat(tapID) else { return nil }
        let stream = builtFirst < builtStreams.count ? Self.virtualFormat(builtStreams[builtFirst]) : nil
        let rate = aggregateID == kAudioObjectUnknown ? nil : Self.nominalSampleRate(aggregateID)
        return TapStreamFormat.ioFormat(tap: tap, streamFormat: stream, aggregateRate: rate)
    }

    /// The IO block saw an input list of another length than the aggregate was built with.
    /// Each counts against `maxLayoutRebuilds` only when it starts a rebuild. Once they are used up, Mac audio is
    /// reported lost (the IO block drops every cycle, so nothing would reach the receiver or its silence notice); a
    /// later device change still tries again.
    private func layoutMismatch(generation gen: Int) async {
        guard gen == generation, deliver != nil, !limiter.pending, state.running else { return }
        guard layoutRebuilds < Self.maxLayoutRebuilds else {
            log.error("Mac audio's input layout keeps changing under the IO block; stopping Mac audio until the output changes")
            destroyAggregate()
            let failure = state.failed()
            if failure.firstLoss { deliver?(.event(.systemAudioLost)) }
            return
        }
        layoutRebuilds += 1
        log.error("Mac audio's input layout changed under the IO block; rebuilding (\(self.layoutRebuilds, privacy: .public) of \(Self.maxLayoutRebuilds, privacy: .public))")
        await requestRebuild(reason: "input layout changed under the IO block")
    }

    /// `TapRateCheck` found the IO running at `measured` Hz while the converter uses `inUse` (`TapRateResponse`):
    /// rebuild, at most `TapRateResponse.maxRebuilds` times a recording; after that, convert from the measured rate.
    private func rateDisagrees(generation gen: Int, inUse: Double, measured: Double) async {
        guard gen == generation, deliver != nil, state.running, let receiver else { return }
        switch TapRateResponse.decide(rateRebuildsSoFar: rateRebuilds) {
        case .rebuild:
            rateRebuilds += 1
            log.notice("Mac audio arrives at \(Int(measured), privacy: .public) Hz, not \(Int(inUse), privacy: .public) Hz; rebuilding")
            await requestRebuild(reason: "rate check")
        case .convertFromMeasured:
            log.notice("Mac audio arrives at \(Int(measured), privacy: .public) Hz, not \(Int(inUse), privacy: .public) Hz after \(TapRateResponse.maxRebuilds, privacy: .public) rebuilds; converting from \(Int(measured), privacy: .public) Hz")
            receiver.convert(fromRate: measured)
        }
    }

    /// Rebuilds the aggregate around the current output (running, or lost and not paused), trying `modes`, else
    /// `plannedModes()`. Mac audio counts as back only when the new build delivers its first IO (`confirmMode`).
    private func rebuild(reason: String, modes: [MacAudioClock]? = nil) async {
        guard deliver != nil, state.mayRebuild() else { return }
        limiter.rebuilt(at: Self.now())
        log.info("Mac audio: \(reason, privacy: .public); rebuilding the aggregate device")
        let modes = modes ?? plannedModes()
        destroyAggregate()
        do {
            try ensureTap()
            try buildAndStart(modes: modes)
            noteRoute()
            state.started()
            if detail == nil {
                detail = Self.currentDetail()
                routeOutputUID = Self.currentOutputUID()
            }
            ownProcessMayHaveChanged()
        } catch {
            destroyAggregate()
            plan.forget()
            let failure = state.failed()
            log.error("Mac audio rebuild failed: \(FluidErrorMapping.describe(error), privacy: .public)")
            if failure.firstLoss { deliver?(.event(.systemAudioLost)) }
            scheduleRetry(failure)
        }
    }

    /// A failed build is tried again after `TapRetryPolicy.delays` (a device that was briefly unknown during a
    /// switch usually settles within seconds), besides every later change notice.
    private func scheduleRetry(_ failure: TapLifecycle.Failure) {
        guard let delay = failure.retryAfter else { return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.retry(attempt: failure.attempt)
        }
    }

    private func retry(attempt: Int) async {
        // A newer failure (from a change notice) scheduled its own retry; a success, a pause or a stop ends the chain.
        guard state.retryDue(attempt: attempt) else { return }
        await rebuild(reason: "retrying after a failed build")
    }

    /// The IO block saw `silentNoticeSeconds` of exact zeros. Access is probably off if another app is playing.
    private func longSilence() async {
        guard !silentNoticeSent, state.running else { return }
        guard Self.anotherProcessIsPlaying() else { return }
        silentNoticeSent = true
        log.notice("Mac audio is silent while another app plays sound; access may be off")
        deliver?(.event(.systemAudioSilent))
    }

    // MARK: HAL helpers

    /// Seconds on a monotonic clock (`TapRebuildLimiter`).
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func currentOutputUID() -> String? { defaultOutputDevice().flatMap(outputUID) }

    /// Sets a device's nominal rate (`kAudioDevicePropertyNominalSampleRate`).
    static func setNominalSampleRate(_ device: AudioObjectID, _ rate: Float64) -> OSStatus {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    /// A property that is a CFArray of CFStrings (an aggregate's sub-device or tap list), or nil when unreadable.
    static func stringArray(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [String]? {
        var addr = address(selector)
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return (value.takeRetainedValue() as NSArray).compactMap { $0 as? String }
    }

    /// Every audio device (`kAudioHardwarePropertyDevices`).
    static func allDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    /// The built-in output device for the `builtIn` clock: transport type built-in, with output streams. The default
    /// output when it is one, else the first such device; nil when the Mac has none.
    static func builtInOutputDevice() -> (id: AudioObjectID, uid: String)? {
        func isBuiltInOutput(_ id: AudioObjectID) -> Bool {
            uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
                && !streams(id, scope: kAudioObjectPropertyScopeOutput).isEmpty
        }
        let candidates = (defaultOutputDevice().map { [$0] } ?? []) + allDevices()
        for id in candidates where isBuiltInOutput(id) {
            if let uid = outputUID(id) { return (id, uid) }
        }
        return nil
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              id != kAudioObjectUnknown else { return nil }
        return AudioObjectID(id)
    }

    static func isAlive(_ id: AudioObjectID) -> Bool { uint32(id, kAudioDevicePropertyDeviceIsAlive) == 1 }

    static func outputUID(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// Channels per buffer of a device's input stream configuration (one entry per buffer its IOProc gets).
    static func inputLayout(_ id: AudioObjectID) -> [UInt32] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }

    /// A device's input stream objects, in order.
    static func inputStreams(_ id: AudioObjectID) -> [AudioObjectID] { streams(id, scope: kAudioObjectPropertyScopeInput) }

    /// A device's stream objects in `scope`, in order.
    static func streams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr else { return [] }
        return streams
    }

    /// A stream's `kAudioStreamPropertyTerminalType` (0 when unreadable).
    static func terminalType(_ stream: AudioObjectID) -> UInt32 { uint32(stream, kAudioStreamPropertyTerminalType) ?? 0 }

    /// Turns the IOProc's input streams on or off (`kAudioDevicePropertyIOProcStreamUsage`).
    static func setStreamUsage(_ device: AudioObjectID, proc: AudioDeviceIOProcID, usage: [Bool]) -> OSStatus {
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn) ?? 12
        let size = Swift.max(MemoryLayout<AudioHardwareIOProcStreamUsage>.size, offset + usage.count * MemoryLayout<UInt32>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let header = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        header.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        header.pointee.mNumberStreams = UInt32(usage.count)
        let flags = (raw + offset).assumingMemoryBound(to: UInt32.self)
        for (i, on) in usage.enumerated() { flags[i] = on ? 1 : 0 }
        var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(size), raw)
    }

    /// A stream's virtual format (`kAudioStreamPropertyVirtualFormat`).
    static func virtualFormat(_ stream: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = address(kAudioStreamPropertyVirtualFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Float64? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd
    }

    /// This process's Core Audio process object, or nil when it has none yet.
    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// Whether any process other than this one is playing sound now.
    static func anotherProcessIsPlaying() -> Bool {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return false }
        let own = getpid()
        return objects.contains { object in
            var pidAddr = address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid) == noErr, pid != own else { return false }
            return uint32(object, kAudioProcessPropertyIsRunningOutput) == 1
        }
    }

    /// The default output device as a capture detail (log-only): its name and model, and where the sound plays.
    static func currentDetail() -> CaptureDetail {
        let output = defaultOutputDevice()
        return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: CaptureDetail.Input.systemAudio,
                             inputName: output.flatMap { string($0, kAudioObjectPropertyName) },
                             inputModelUID: output.flatMap { string($0, kAudioDevicePropertyModelUID) },
                             sources: CaptureDetail.Sources.system,
                             outputRoute: SystemOutputRoute.current())
    }
}

/// Where the Mac's sound is playing now, as a `CaptureDetail.OutputRoute` value (log-only; the recording window can
/// also use it for its headphones hint). Built-in outputs are told apart by their data source ('ispk' speakers,
/// 'hdpn' headphones).
public enum SystemOutputRoute {
    public static func current() -> String {
        guard let device = SystemAudioCapture.defaultOutputDevice() else { return CaptureDetail.OutputRoute.other }
        let transport = SystemAudioCapture.uint32(device, kAudioDevicePropertyTransportType)
        let dataSource = SystemAudioCapture.uint32(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        return route(transportType: transport, dataSource: dataSource)
    }

    /// The pure mapping (tests).
    static func route(transportType: UInt32?, dataSource: UInt32?) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            dataSource == fourCC("hdpn") ? CaptureDetail.OutputRoute.headphones : CaptureDetail.OutputRoute.builtInSpeaker
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            CaptureDetail.OutputRoute.bluetooth
        default:
            CaptureDetail.OutputRoute.other
        }
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

/// Mac audio's IO block and its consumer (review 2026-11-26). The IO block (on the IO queue, while the HAL's IO thread
/// waits) only copies the tap's buffers and host time into the `TapRing` and signals; the consumer, on the capture's
/// process queue, converts each slot to 16 kHz mono, fills IO cycles the HAL skipped with zeros (`TapGapFill`, converted
/// at the input rate like the audio, so a resampler's held tail of the buffer before comes out before them), tracks
/// the run of exact zeros for the silence notice, and delivers it. An IO cycle whose input list has another length
/// than the aggregate was built with is dropped by the ring and reported once (`onLayoutMismatch`), so the capture can
/// rebuild. When `TapRateCheck` finds the IO running at another rate it reports it (`onRateVerdict`) and changes
/// nothing; only the capture can switch the converter (`convert(fromRate:)`, its last resort after rebuilds). Every
/// `TapIOStats.interval` of host time it reports the IO heartbeat (`onStats`), and it reports the first IO cycle once
/// (`onFirstIO`, the capture's confirmation of a clock mode).
final class TapReceiver: @unchecked Sendable {
    // Replaced on `queue`, only when the capture asks (`convert(fromRate:)`).
    private var format: AVAudioFormat
    private var converter: TapConverter
    private var rateCheck = TapRateCheck()
    private var gapFill = TapGapFill()
    private var stats = TapIOStats()
    private let onRateVerdict: @Sendable (_ inUse: Double, _ measured: Double) -> Void
    private let onStats: @Sendable (TapIOStats.Report) -> Void
    private let ring: TapRing
    private let firstIndex: Int
    private let bytesPerFrame: Int
    private let queue: DispatchQueue
    private let signal: DispatchSourceUserDataAdd
    private let deliver: @Sendable (StampedInput) -> Void
    private let silentFrames: Int
    private let onLongSilence: @Sendable () -> Void
    private let onLayoutMismatch: @Sendable () -> Void
    private let onFirstIO: @Sendable () -> Void
    // Consumer state, used only on `queue`.
    private var mismatchReported = false
    private var firstIOReported = false
    private var zeroRun = 0
    private var nextSilenceReport: Int
    private var finished = false
    private var statsCycles = 0
    private var statsDrops = 0

    init(format: AVAudioFormat, converter: TapConverter, ring: TapRing, firstIndex: Int, bytesPerFrame: Int,
         queue: DispatchQueue, deliver: @escaping @Sendable (StampedInput) -> Void, silentFrames: Int,
         onLongSilence: @escaping @Sendable () -> Void, onLayoutMismatch: @escaping @Sendable () -> Void = {},
         onFirstIO: @escaping @Sendable () -> Void = {},
         onRateVerdict: @escaping @Sendable (_ inUse: Double, _ measured: Double) -> Void = { _, _ in },
         onStats: @escaping @Sendable (TapIOStats.Report) -> Void = { _ in }) {
        self.onRateVerdict = onRateVerdict; self.onStats = onStats
        self.format = format; self.converter = converter; self.ring = ring; self.firstIndex = firstIndex
        self.bytesPerFrame = Swift.max(1, bytesPerFrame); self.queue = queue; self.deliver = deliver
        self.silentFrames = silentFrames; self.onLongSilence = onLongSilence; self.onLayoutMismatch = onLayoutMismatch
        self.onFirstIO = onFirstIO
        self.nextSilenceReport = silentFrames
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        signal.setEventHandler { [weak self] in self?.process() }
        signal.activate()
    }

    deinit { signal.cancel() }

    var dropped: Int { ring.dropped }
    /// IO cycles the IO block has seen (the first-IO watchdog).
    var ioCycles: Int { ring.ioCycles }
    /// Frames the device's sample time moved past with no IO delivered (log-only; read after `finish()`).
    var skippedFrames: Int { queue.sync { rateCheck.skippedFrames } }
    /// Of those, the frames filled with zeros in place (log-only).
    var filledFrames: Int { queue.sync { gapFill.filledFrames } }
    var layoutMismatches: Int { ring.layoutMismatches }

    /// Real-time safe: copies and signals, nothing else. A cycle with another input layout signals too, so the
    /// consumer reports it.
    var ioBlock: AudioDeviceIOBlock {
        { [ring, firstIndex, signal] _, inputData, inputTime, _, _ in
            let stamp = inputTime.pointee
            let host: UInt64? = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil
            let sample: Double? = stamp.mFlags.contains(.sampleTimeValid) ? stamp.mSampleTime : nil
            let before = ring.layoutMismatches
            if ring.write(inputData, firstIndex: firstIndex, hostTime: host, sampleTime: sample)
                || ring.layoutMismatches != before {
                signal.add(data: 1)
            }
        }
    }

    /// Delivers everything written so far before returning (IO must have stopped, or the rest comes later).
    func flush() { queue.sync { process() } }

    /// IO stopped and will start again (a pause): the next buffer starts a new run, so the gap is never filled, and a
    /// new heartbeat window, so the pause never shows as a stall or a low rate.
    func breakRun() {
        queue.sync {
            gapFill.breakRun()
            stats.breakRun()
            statsCycles = ring.ioCycles
            statsDrops = ring.dropped
        }
    }

    /// IO has stopped for good: deliver the rest, then stop the consumer.
    func finish() {
        queue.sync {
            process()
            finished = true
        }
        signal.setEventHandler(handler: nil)
        signal.cancel()
    }

    /// The capture's last resort (`TapRateResponse.convertFromMeasured`): convert from `rate` from the next buffer on.
    /// Only the rate changes: the sample layout, and so the copy, stay as built.
    func convert(fromRate rate: Double) {
        queue.async { [self] in
            guard !finished, rate > 0, rate != format.sampleRate else { return }
            var asbd = format.streamDescription.pointee
            asbd.mSampleRate = rate
            guard let newFormat = AVAudioFormat(streamDescription: &asbd),
                  let newConverter = TapConverter(inputFormat: newFormat) else { return }
            format = newFormat
            converter = newConverter
        }
    }

    private func process() {
        guard !finished else { return }
        if !firstIOReported, ring.ioCycles > 0 {
            firstIOReported = true
            onFirstIO()
        }
        if !mismatchReported, ring.layoutMismatches > 0 {
            mismatchReported = true
            onLayoutMismatch()
        }
        ring.drainStamped { buffers, hostTime, sampleTime in
            guard let first = buffers.first, first.count >= bytesPerFrame else { return }
            let frames = first.count / bytesPerFrame
            let host = hostTime.map { AVAudioTime.seconds(forHostTime: $0) }
            let rate = format.sampleRate
            let skippedBefore = rateCheck.skippedFrames
            if let host, let measured = rateCheck.observe(frames: frames, host: host, sampleTime: sampleTime, current: rate) {
                onRateVerdict(rate, measured)
            }
            report(frames: frames, host: host, sampleTime: sampleTime, skipped: rateCheck.skippedFrames - skippedBefore)
            // IO cycles the HAL skipped: zeros where they belong, before this buffer (lost audio, never silence the
            // tap delivered, so they do not count towards the silence notice). Converted at the input rate like the
            // audio, so the resampler's held tail of the buffer before comes out ahead of them.
            if let fill = gapFill.observe(frames: frames, host: host, sampleTime: sampleTime, rate: rate),
               let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fill.frames)) {
                zeros.frameLength = AVAudioFrameCount(fill.frames)
                for buffer in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                let filled = converter.convert(zeros)
                if !filled.isEmpty { deliver(.audio(filled, hostSeconds: fill.hostSeconds)) }
            }
            // A fresh buffer each time: the converter may keep reading its last input until the next call.
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            // The length first: a fresh buffer's byte sizes are 0 until it is set, and the copy is bounded by them.
            pcm.frameLength = AVAudioFrameCount(frames)
            let list = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            guard list.count == buffers.count else { return }
            for (i, bytes) in buffers.enumerated() {
                guard let dst = list[i].mData, let src = bytes.baseAddress else { return }
                dst.copyMemory(from: src, byteCount: Swift.min(bytes.count, Int(list[i].mDataByteSize)))
            }
            let samples = converter.convert(pcm)
            guard !samples.isEmpty else { return }
            if samples.allSatisfy({ $0 == 0 }) {
                zeroRun += samples.count
                if zeroRun >= nextSilenceReport {
                    nextSilenceReport += silentFrames   // check again every `silentFrames` while it stays silent
                    onLongSilence()
                }
            } else {
                zeroRun = 0
                nextSilenceReport = silentFrames
            }
            deliver(.audio(samples, hostSeconds: host))
        }
    }

    /// The IO heartbeat: `TapIOStats` with the ring's cycles and drops since the last report.
    private func report(frames: Int, host: Double?, sampleTime: Double?, skipped: Int) {
        guard var report = stats.observe(frames: frames, host: host, sampleTime: sampleTime, skipped: skipped) else { return }
        let cycles = ring.ioCycles, drops = ring.dropped
        report.cycles = cycles - statsCycles
        report.ringDrops = drops - statsDrops
        statsCycles = cycles; statsDrops = drops
        onStats(report)
    }
}
#endif
