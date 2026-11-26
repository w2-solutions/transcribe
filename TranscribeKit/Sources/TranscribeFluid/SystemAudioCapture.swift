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
/// - **Aggregate device:** private, not stacked, `tapautostart` off (so starting it never waits for sound), with the
///   default output device as its main sub-device and clock, and the tap (drift compensation on). When that device
///   has inputs of its own (AirPods, a USB headset), the aggregate's input list carries them too: the tap's buffers
///   are picked by position (`TapBufferLayout.place`) and the other input streams are turned off for the IOProc
///   (`kAudioDevicePropertyIOProcStreamUsage`), so the device's microphone is never used. The IO block drops any
///   cycle whose buffer count is not the one the aggregate was built with; that, or a change of the aggregate's input
///   streams, rebuilds it.
/// - **IOProc:** `AudioDeviceCreateIOProcIDWithBlock` on a serial queue. The block only copies the tap's buffers and
///   the host time into a preallocated `TapRing` and signals; a second queue converts them with a `TapConverter` to
///   16 kHz mono and delivers them with their host time.
/// - **Changes:** the tap's format, the aggregate going away, its sub-device, tap or input stream list changing, and
///   the default output device changing all rebuild the aggregate (the tap is kept) after a short settle;
///   `detail.routeChanged` is set. A change while paused is remembered, and `resume()` then rebuilds
///   (`TapResumePlan`). A rebuild that fails delivers `.systemAudioLost` once (a Both recording carries on with the
///   microphone; a Mac-audio-only recording pauses, see `FluidLiveRecording`) and is tried again on every later
///   change and after `TapRetryPolicy.delays`, unless paused; when one succeeds it delivers `.systemAudioRestored`.
///   The rules are `TapLifecycle`'s.
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
    /// How long a burst of property changes settles before the aggregate is rebuilt.
    static let rebuildSettle: Duration = .milliseconds(250)
    /// Rebuilds asked for by the IO block seeing an input list of another length, per recording.
    static let maxLayoutRebuilds = 3
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
    private var rebuildScheduled = false
    /// What the running aggregate was built for.
    private var builtOutputUID: String?
    private var builtFormat: AudioStreamBasicDescription?
    private var builtLayout: [UInt32] = []
    private var builtStreams: [AudioObjectID] = []
    private var layoutRebuilds = 0
    private var tapDescription: CATapDescription?
    private var excludesOwnProcess = false
    private var watchingOwnProcess = false
    private var silentNoticeSent = false
    private var detail: CaptureDetail?
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

    /// - Parameter keepsTryingAfterFailedStart: a Both recording's Mac audio: a failed start keeps trying to join.
    init(keepsTryingAfterFailedStart: Bool = false) {
        self.keepsTryingAfterFailedStart = keepsTryingAfterFailedStart
    }

    func captureDetail() async -> CaptureDetail? { detail }

    func startStamped(_ deliver: @escaping @Sendable (StampedInput) -> Void) async throws {
        guard self.deliver == nil, !state.stopped else { throw EngineError.failed("Capture already started") }
        self.deliver = deliver
        do {
            try createTap()
            try buildAndStart()
            _ = state.built()
            detail = Self.currentDetail()
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
            addSystemListeners()
            scheduleRetry(failure)
            log.error("Mac audio did not start; trying again on device changes: \(FluidErrorMapping.describe(error), privacy: .public)")
            throw FluidErrorMapping.engineError(error)
        }
    }

    func pause() async {
        guard state.pause() else { return }
        if let procID, aggregateID != kAudioObjectUnknown { _ = AudioDeviceStop(aggregateID, procID) }
        receiver?.flush()   // nothing is delivered after a pause returns
    }

    func resume() async throws {
        guard deliver != nil, state.beginResume() else { return }
        do {
            let inPlace = procID != nil && aggregateID != kAudioObjectUnknown && TapResumePlan.canResumeInPlace(
                changedWhilePaused: state.changedWhilePaused, aggregateAlive: Self.isAlive(aggregateID),
                builtOutputUID: builtOutputUID, currentOutputUID: Self.defaultOutputDevice().flatMap(Self.outputUID),
                builtFormat: builtFormat, currentFormat: tapID == kAudioObjectUnknown ? nil : Self.tapFormat(tapID))
            if inPlace, let procID, AudioDeviceStart(aggregateID, procID) == noErr {
                // Restarted as it was.
            } else {
                // Something changed while paused, or the aggregate went away (or never came back after a lost
                // route): rebuild it around the current output and tap format.
                if state.changedWhilePaused { detail?.routeChanged = true }
                destroyAggregate()
                try ensureTap()
                try buildAndStart()
            }
            if state.built() { deliver?(.event(.systemAudioRestored)) }
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
        if deliver != nil { addListener(tapID, kAudioTapPropertyFormat, kind: .system) { await $0.configurationChanged() } }
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

    /// Builds the aggregate around the tap and the current default output, reads the tap's format and starts IO.
    private func buildAndStart() throws {
        guard let deliver else { throw EngineError.failed("Capture not started") }
        guard let outputID = Self.defaultOutputDevice(), let outputUID = Self.string(outputID, kAudioDevicePropertyDeviceUID)
        else { throw EngineError.failed("No sound output is available for Mac audio") }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcribe Mac audio",
            kAudioAggregateDeviceUIDKey: "ai.w2solutions.transcribe.mac-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            throw EngineError.failed("Could not start recording Mac audio (aggregate \(status))")
        }
        aggregateID = aggregate

        guard let tapASBD = Self.tapFormat(tapID) else { throw EngineError.failed("Unsupported Mac audio format") }
        var asbd = tapASBD
        guard let format = AVAudioFormat(streamDescription: &asbd), let converter = TapConverter(inputFormat: format)
        else { throw EngineError.failed("Unsupported Mac audio format") }

        // The tap's buffers among the aggregate's inputs (the output device may add its own microphone streams). A
        // new aggregate can report no inputs for a moment: read once more before giving up.
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        var layout = Self.inputLayout(aggregate)
        if layout.count < tapBuffers {
            usleep(50_000)
            layout = Self.inputLayout(aggregate)
        }
        let streams = Self.inputStreams(aggregate)
        let subLayout = Self.inputLayout(outputID)
        guard let placement = TapBufferLayout.place(
            channelsPerBuffer: layout, aggregateStreams: streams, subDeviceStreams: Set(Self.inputStreams(outputID)),
            subDeviceLayout: subLayout, terminalTypes: streams.count == layout.count ? streams.map(Self.terminalType) : [],
            tapBuffers: tapBuffers, tapChannelsPerBuffer: format.isInterleaved ? format.channelCount : 1)
        else {
            throw EngineError.failed("Could not start recording Mac audio (unexpected input layout \(layout.count))")
        }
        let first = placement.first
        if layout.count > tapBuffers {
            log.notice("The sound output has \(layout.count - tapBuffers, privacy: .public) input streams of its own; recording only the tap's at \(first, privacy: .public) of \(layout, privacy: .public)\(placement.certain ? "" : " (by the composition's order)", privacy: .public)")
        }

        let bytesPerFrame = Int(tapASBD.mBytesPerFrame)
        let maxFrames = Swift.max(8_192, 4 * Int(Self.uint32(aggregate, kAudioDevicePropertyBufferFrameSize) ?? 0))
        let ring = TapRing(slotCount: 128, bufferCount: tapBuffers, bytesPerBuffer: Swift.max(1, bytesPerFrame) * maxFrames,
                           expectedBufferCount: layout.count)
        let receiver = TapReceiver(format: format, converter: converter, ring: ring, firstIndex: first,
                                   bytesPerFrame: bytesPerFrame, queue: processQueue, deliver: deliver,
                                   silentFrames: Int(Self.silentNoticeSeconds * TapConverter.outputSampleRate),
                                   onLongSilence: { [weak self] in Task { await self?.longSilence() } },
                                   onLayoutMismatch: { [weak self] in Task { await self?.layoutMismatch() } })
        self.receiver = receiver
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue, receiver.ioBlock)
        guard status == noErr, let proc else {
            throw EngineError.failed("Could not start recording Mac audio (IOProc \(status))")
        }
        procID = proc
        if layout.count > tapBuffers {
            let usage = TapBufferLayout.streamUsage(streamCount: layout.count, firstTapIndex: first, tapBuffers: tapBuffers)
            let set = Self.setStreamUsage(aggregate, proc: proc, usage: usage)
            if set != noErr { log.error("Could not turn off the output's own input streams (\(set, privacy: .public))") }
        }
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw EngineError.failed("Could not start recording Mac audio (start \(status))") }
        builtOutputUID = outputUID
        builtFormat = tapASBD
        builtLayout = layout
        builtStreams = streams
        addAggregateListeners()
    }

    private func destroyAggregate() {
        removeListeners { $0 == .aggregate }
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
        }
        receiver = nil
        builtOutputUID = nil
        builtFormat = nil
        builtLayout = []
        builtStreams = []
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
        addListener(system, kAudioHardwarePropertyDefaultOutputDevice, kind: .system) { await $0.configurationChanged() }
        addListener(system, kAudioHardwarePropertyDefaultSystemOutputDevice, kind: .system) { await $0.configurationChanged() }
        addListener(tapID, kAudioTapPropertyFormat, kind: .system) { await $0.configurationChanged() }
    }

    private func addAggregateListeners() {
        addListener(aggregateID, kAudioDevicePropertyDeviceIsAlive, kind: .aggregate) { await $0.configurationChanged() }
        addListener(aggregateID, kAudioAggregateDevicePropertyFullSubDeviceList, kind: .aggregate) { await $0.configurationChanged() }
        addListener(aggregateID, kAudioAggregateDevicePropertyTapList, kind: .aggregate) { await $0.configurationChanged() }
        addListener(aggregateID, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                    kind: .aggregate) { await $0.inputStreamsChanged() }
        addListener(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput,
                    kind: .aggregate) { await $0.inputStreamsChanged() }
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

    /// Something about the output or the tap changed: rebuild once the burst of notifications settles. While paused
    /// the change is only remembered (`resume()` rebuilds). After a failed build (lost), every later change tries
    /// again.
    private func configurationChanged() async {
        guard deliver != nil, state.noticed() == .rebuild, !rebuildScheduled else { return }
        rebuildScheduled = true
        try? await Task.sleep(for: Self.rebuildSettle)
        rebuildScheduled = false
        await rebuild(reason: "configuration changed")
    }

    /// The aggregate's input streams changed: rebuild only when they differ from what it was built with (turning the
    /// sub-device's streams off for the IOProc may notify without changing them).
    private func inputStreamsChanged() async {
        guard aggregateID != kAudioObjectUnknown, !builtLayout.isEmpty else { return }
        guard Self.inputLayout(aggregateID) != builtLayout || Self.inputStreams(aggregateID) != builtStreams else { return }
        await configurationChanged()
    }

    /// The IO block saw an input list of another length than the aggregate was built with.
    private func layoutMismatch() async {
        guard layoutRebuilds < Self.maxLayoutRebuilds else { return }
        layoutRebuilds += 1
        log.error("Mac audio's input layout changed under the IO block; rebuilding (\(self.layoutRebuilds, privacy: .public) of \(Self.maxLayoutRebuilds, privacy: .public))")
        await configurationChanged()
    }

    /// Rebuilds the aggregate around the current output (running, or lost and not paused).
    private func rebuild(reason: String) async {
        guard deliver != nil, state.mayRebuild() else { return }
        detail?.routeChanged = true
        log.info("Mac audio: \(reason, privacy: .public); rebuilding the aggregate device")
        destroyAggregate()
        do {
            try ensureTap()
            try buildAndStart()
            if state.built() {
                log.notice("Mac audio is back after a rebuild")
                deliver?(.event(.systemAudioRestored))
            }
            if detail == nil { detail = Self.currentDetail() }
            ownProcessMayHaveChanged()
        } catch {
            destroyAggregate()
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
    static func inputStreams(_ id: AudioObjectID) -> [AudioObjectID] {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
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
/// process queue, converts each slot to 16 kHz mono, tracks the run of exact zeros for the silence notice, and
/// delivers it. An IO cycle whose input list has another length than the aggregate was built with is dropped by the
/// ring and reported once (`onLayoutMismatch`), so the capture can rebuild.
final class TapReceiver: @unchecked Sendable {
    private let format: AVAudioFormat
    private let converter: TapConverter
    private let ring: TapRing
    private let firstIndex: Int
    private let bytesPerFrame: Int
    private let queue: DispatchQueue
    private let signal: DispatchSourceUserDataAdd
    private let deliver: @Sendable (StampedInput) -> Void
    private let silentFrames: Int
    private let onLongSilence: @Sendable () -> Void
    private let onLayoutMismatch: @Sendable () -> Void
    // Consumer state, used only on `queue`.
    private var mismatchReported = false
    private var zeroRun = 0
    private var nextSilenceReport: Int
    private var finished = false

    init(format: AVAudioFormat, converter: TapConverter, ring: TapRing, firstIndex: Int, bytesPerFrame: Int,
         queue: DispatchQueue, deliver: @escaping @Sendable (StampedInput) -> Void, silentFrames: Int,
         onLongSilence: @escaping @Sendable () -> Void, onLayoutMismatch: @escaping @Sendable () -> Void = {}) {
        self.format = format; self.converter = converter; self.ring = ring; self.firstIndex = firstIndex
        self.bytesPerFrame = Swift.max(1, bytesPerFrame); self.queue = queue; self.deliver = deliver
        self.silentFrames = silentFrames; self.onLongSilence = onLongSilence; self.onLayoutMismatch = onLayoutMismatch
        self.nextSilenceReport = silentFrames
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        signal.setEventHandler { [weak self] in self?.process() }
        signal.activate()
    }

    deinit { signal.cancel() }

    var dropped: Int { ring.dropped }
    var layoutMismatches: Int { ring.layoutMismatches }

    /// Real-time safe: copies and signals, nothing else. A cycle with another input layout signals too, so the
    /// consumer reports it.
    var ioBlock: AudioDeviceIOBlock {
        { [ring, firstIndex, signal] _, inputData, inputTime, _, _ in
            let stamp = inputTime.pointee
            let host: UInt64? = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil
            let before = ring.layoutMismatches
            if ring.write(inputData, firstIndex: firstIndex, hostTime: host) || ring.layoutMismatches != before {
                signal.add(data: 1)
            }
        }
    }

    /// Delivers everything written so far before returning (IO must have stopped, or the rest comes later).
    func flush() { queue.sync { process() } }

    /// IO has stopped for good: deliver the rest, then stop the consumer.
    func finish() {
        queue.sync {
            process()
            finished = true
        }
        signal.setEventHandler(handler: nil)
        signal.cancel()
    }

    private func process() {
        guard !finished else { return }
        if !mismatchReported, ring.layoutMismatches > 0 {
            mismatchReported = true
            onLayoutMismatch()
        }
        ring.drain { buffers, hostTime in
            guard let first = buffers.first, first.count >= bytesPerFrame else { return }
            let frames = first.count / bytesPerFrame
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
            let host = hostTime.map { AVAudioTime.seconds(forHostTime: $0) }
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
}
#endif
