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
/// - **Tap:** `CATapDescription(monoGlobalTapButExcludeProcesses:)`, excluding this process's audio object
///   (`kAudioHardwarePropertyTranslatePIDToProcessObject` on `getpid()`; none until this process has used audio, so
///   a Both recording starts the microphone first). Private, `.unmuted` (the user still hears everything).
/// - **Aggregate device:** private, not stacked, `tapautostart` off (so starting it never waits for sound), with the
///   default output device as its main sub-device and clock, and the tap (drift compensation on).
/// - **IOProc:** `AudioDeviceCreateIOProcIDWithBlock` on a serial queue. The block wraps the input buffer list
///   (no copy), converts it with a `TapConverter` to 16 kHz mono and delivers it with the buffer's host time.
/// - **Changes:** the tap's format, the aggregate going away, its sub-device or tap list changing, and the default
///   output device changing all rebuild the aggregate (the tap is kept) after a short settle; `detail.routeChanged`
///   is set. A rebuild that fails delivers `.systemAudioLost` (a Both recording carries on with the microphone; a
///   Mac-audio-only recording pauses, see `FluidLiveRecording`).
/// - **No permission API:** when access is off the tap delivers exact zeros. After `silentNoticeSeconds` of nothing
///   but exact zeros while another process is playing sound (`kAudioProcessPropertyIsRunningOutput`), it delivers
///   `.systemAudioSilent` once. No private TCC calls.
/// - **`stop()`:** stops and destroys the IOProc, then the aggregate, then the tap.
actor SystemAudioCapture: StampedCaptureSource {
    /// Exact silence this long, with another app playing, gives `.systemAudioSilent`.
    static let silentNoticeSeconds: Double = 5
    /// How long a burst of property changes settles before the aggregate is rebuilt.
    static let rebuildSettle: Duration = .milliseconds(250)

    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "SystemAudioCapture")
    private let ioQueue = DispatchQueue(label: "ai.w2solutions.transcribe.mac-audio.io", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "ai.w2solutions.transcribe.mac-audio.listeners")

    private var deliver: (@Sendable (StampedInput) -> Void)?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID = ""
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var stopped = false
    private var lost = false
    private var rebuildScheduled = false
    private var silentNoticeSent = false
    private var detail: CaptureDetail?
    private var listeners: [Listener] = []

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        /// The aggregate's own listeners are replaced on every rebuild.
        let onAggregate: Bool
    }

    init() {}

    func captureDetail() async -> CaptureDetail? { detail }

    func startStamped(_ deliver: @escaping @Sendable (StampedInput) -> Void) async throws {
        guard self.deliver == nil, !stopped else { throw EngineError.failed("Capture already started") }
        self.deliver = deliver
        do {
            try createTap()
            try buildAndStart()
            running = true
            detail = Self.currentDetail()
            addSystemListeners()
        } catch {
            teardown()
            self.deliver = nil
            throw FluidErrorMapping.engineError(error)
        }
    }

    func pause() async {
        guard running else { return }
        if let procID, aggregateID != kAudioObjectUnknown { _ = AudioDeviceStop(aggregateID, procID) }
        running = false
    }

    func resume() async throws {
        guard !stopped, deliver != nil, !running else { return }
        do {
            if procID != nil, aggregateID != kAudioObjectUnknown, Self.isAlive(aggregateID),
               AudioDeviceStart(aggregateID, procID) == noErr {
                running = true
                lost = false
                return
            }
            // The aggregate went away while paused (or never came back after a lost route): rebuild it.
            destroyAggregate()
            if tapID == kAudioObjectUnknown { try createTap() }
            try buildAndStart()
            running = true
            lost = false
        } catch {
            throw EngineError.failed("Could not resume Mac audio: \(FluidErrorMapping.describe(error))")
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        teardown()
    }

    // MARK: Tap and aggregate

    private func createTap() throws {
        let own = Self.ownProcessObject()
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
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
        if own == nil { log.notice("Mac audio tap created without excluding this process (no audio object yet)") }
    }

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

        guard var asbd = Self.tapFormat(tapID), let format = AVAudioFormat(streamDescription: &asbd),
              let converter = TapConverter(inputFormat: format)
        else { throw EngineError.failed("Unsupported Mac audio format") }

        let receiver = TapReceiver(format: format, converter: converter, deliver: deliver,
                                   silentFrames: Int(Self.silentNoticeSeconds * TapConverter.outputSampleRate)) {
            [weak self] in Task { await self?.longSilence() }
        }
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue, receiver.ioBlock)
        guard status == noErr, let proc else {
            throw EngineError.failed("Could not start recording Mac audio (IOProc \(status))")
        }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { throw EngineError.failed("Could not start recording Mac audio (start \(status))") }
        addAggregateListeners()
    }

    private func destroyAggregate() {
        removeListeners(aggregateOnly: true)
        if let procID, aggregateID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { _ = AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func teardown() {
        removeListeners(aggregateOnly: false)
        destroyAggregate()
        if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
    }

    // MARK: Changes

    private func addSystemListeners() {
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, aggregate: false)
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, aggregate: false)
        addListener(tapID, kAudioTapPropertyFormat, aggregate: false)
    }

    private func addAggregateListeners() {
        addListener(aggregateID, kAudioDevicePropertyDeviceIsAlive, aggregate: true)
        addListener(aggregateID, kAudioAggregateDevicePropertyFullSubDeviceList, aggregate: true)
        addListener(aggregateID, kAudioAggregateDevicePropertyTapList, aggregate: true)
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, aggregate: Bool) {
        guard object != kAudioObjectUnknown else { return }
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { await self?.configurationChanged() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr else { return }
        listeners.append(Listener(object: object, address: address, block: block, onAggregate: aggregate))
    }

    private func removeListeners(aggregateOnly: Bool) {
        var kept: [Listener] = []
        for var l in listeners {
            if aggregateOnly && !l.onAggregate { kept.append(l); continue }
            _ = AudioObjectRemovePropertyListenerBlock(l.object, &l.address, listenerQueue, l.block)
        }
        listeners = kept
    }

    /// Something about the output or the tap changed: rebuild once the burst of notifications settles.
    private func configurationChanged() async {
        guard !stopped, deliver != nil, !rebuildScheduled else { return }
        rebuildScheduled = true
        try? await Task.sleep(for: Self.rebuildSettle)
        rebuildScheduled = false
        guard !stopped, running else { return }
        detail?.routeChanged = true
        log.info("Mac audio configuration changed; rebuilding the aggregate device")
        destroyAggregate()
        do {
            try buildAndStart()
            lost = false
        } catch {
            running = false
            guard !lost else { return }
            lost = true
            log.error("Mac audio rebuild failed: \(FluidErrorMapping.describe(error), privacy: .public)")
            deliver?(.event(.systemAudioLost))
        }
    }

    /// The IO block saw `silentNoticeSeconds` of exact zeros. Access is probably off if another app is playing.
    private func longSilence() async {
        guard !silentNoticeSent, !stopped, running else { return }
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

/// The IO block's state, used only on the IO queue (Core Audio calls the block serially there):
/// the converter for the tap's format, and the run of exact zeros for the silence notice.
private final class TapReceiver: @unchecked Sendable {
    private let format: AVAudioFormat
    private let converter: TapConverter
    private let deliver: @Sendable (StampedInput) -> Void
    private let silentFrames: Int
    private let onLongSilence: @Sendable () -> Void
    private var zeroRun = 0
    private var nextSilenceReport: Int

    init(format: AVAudioFormat, converter: TapConverter, deliver: @escaping @Sendable (StampedInput) -> Void,
         silentFrames: Int, onLongSilence: @escaping @Sendable () -> Void) {
        self.format = format; self.converter = converter; self.deliver = deliver
        self.silentFrames = silentFrames; self.onLongSilence = onLongSilence
        self.nextSilenceReport = silentFrames
    }

    var ioBlock: AudioDeviceIOBlock {
        { [self] _, inputData, inputTime, _, _ in
            self.receive(inputData, inputTime)
        }
    }

    private func receive(_ data: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: data, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let samples = converter.convert(buffer)
        guard !samples.isEmpty else { return }
        let stamp = time.pointee
        let host = stamp.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: stamp.mHostTime) : nil
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
#endif
