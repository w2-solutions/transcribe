@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import Foundation
import os
import TranscribeCore

// MARK: - Capture source abstraction

/// Something a capture source reports besides audio. Delivered in order with the audio.
enum CaptureSourceEvent: Sendable, Equatable {
    /// The system interrupted capture (phone call, Siri, another app took the session).
    case interrupted
    /// The interruption ended. `shouldResume` is the system's hint that resuming is appropriate.
    case interruptionEnded(shouldResume: Bool)
    /// The input device went away (headset unplugged, Bluetooth dropped) and capture could not continue.
    case routeLost
    /// The media server restarted; every audio object is invalid.
    case mediaServicesReset
    /// Capture failed for another reason.
    case failed(String)
}

/// One item from a capture source: 16 kHz mono Float32 samples, or an event.
enum CaptureInput: Sendable {
    case audio([Float])
    case event(CaptureSourceEvent)
}

/// Where a live recording's audio comes from. The app uses `MicrophoneCapture`; tests use a scripted source.
/// A source never delivers audio while paused or after `stop()`.
protocol CaptureSource: AnyObject, Sendable {
    /// Begins delivering input. Throws `EngineError` if capture cannot start.
    func start(_ deliver: @escaping @Sendable (CaptureInput) -> Void) async throws
    func pause() async
    /// Restarts after a user pause, an interruption or a route change (re-activating the session and
    /// rebuilding the converter if the input format changed).
    func resume() async throws
    func stop() async
    /// The hardware and input route of this capture (log-only, §6.1). Read after `stop()`; nil when unknown.
    func captureDetail() async -> CaptureDetail?
}

extension CaptureSource {
    func captureDetail() async -> CaptureDetail? { nil }
}

// MARK: - Input route detection (log-only, never throws)

/// Maps the platform's description of the current input to `CaptureDetail.Input` values.
enum CaptureRouteDetection {
    #if os(iOS)
    static func input(portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic: CaptureDetail.Input.builtInMic
        case .headsetMic: CaptureDetail.Input.headsetMic
        case .bluetoothHFP, .bluetoothLE: CaptureDetail.Input.bluetoothHFP
        case .usbAudio, .carAudio: CaptureDetail.Input.usbAudio
        case .continuityMicrophone: CaptureDetail.Input.continuity
        case .virtual: CaptureDetail.Input.virtual
        default: CaptureDetail.Input.unknown
        }
    }

    /// The first input of the session's current route.
    static func currentDetail() -> CaptureDetail {
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first else {
            return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: CaptureDetail.Input.unknown)
        }
        return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: input(portType: port.portType),
                             inputName: port.portName, inputModelUID: port.uid)
    }
    #endif

    #if os(macOS)
    /// `kAudioDevicePropertyTransportType` → input.
    static func input(transportType: UInt32) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: CaptureDetail.Input.builtInMic
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: CaptureDetail.Input.bluetoothHFP
        case kAudioDeviceTransportTypeUSB: CaptureDetail.Input.usbAudio
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            CaptureDetail.Input.continuity
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: CaptureDetail.Input.aggregate
        case kAudioDeviceTransportTypeVirtual: CaptureDetail.Input.virtual
        default: CaptureDetail.Input.unknown
        }
    }

    /// Reads the engine input node's Core Audio device through the HAL.
    static func detail(deviceID: AudioObjectID) -> CaptureDetail {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: CaptureDetail.Input.unknown)
        }
        let transport = uint32(deviceID, kAudioDevicePropertyTransportType)
        return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel,
                             input: transport.map(input(transportType:)) ?? CaptureDetail.Input.unknown,
                             inputName: string(deviceID, kAudioObjectPropertyName),
                             inputModelUID: string(deviceID, kAudioDevicePropertyModelUID))
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        let s = value.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }
    #endif
}

// MARK: - Converter used on the tap thread

/// The one stateful `AVAudioConverter` for a capture session (input format → 16 kHz mono Float32).
/// Keeping one converter keeps the resampler's filter state across buffers, so chunk seams are clean.
///
/// `@unchecked Sendable`: it is created on the capture actor and afterwards used only from the audio
/// engine's tap callback, which Core Audio calls serially on one thread.
final class TapConverter: @unchecked Sendable {
    static let outputSampleRate: Double = 16_000

    let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output)
        else { return nil }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.inputFormat = inputFormat
        self.outputFormat = output
        self.converter = converter
    }

    /// Converts one tap buffer. Returns the samples the resampler could produce for it (possibly empty).
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        let feeder = OneShotFeeder(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            feeder.next(inputStatus)
        }
        guard status != .error, error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// Hands the converter one buffer, then reports "no data now" so its state carries over to the next call.
private final class OneShotFeeder: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let b = buffer else {
            status.pointee = .noDataNow
            return nil
        }
        buffer = nil
        status.pointee = .haveData
        return b
    }
}

// MARK: - Microphone

/// Real capture (§5.9): `AVAudioSession` `.playAndRecord` / `.measurement` / `.allowBluetoothHFP` on iOS,
/// an `AVAudioEngine` input tap feeding one stateful converter to 16 kHz mono Float32, and the session
/// notifications mapped to `CaptureSourceEvent`s.
actor MicrophoneCapture: CaptureSource {
    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "MicrophoneCapture")
    private let engine = AVAudioEngine()
    private var deliver: (@Sendable (CaptureInput) -> Void)?
    private var converter: TapConverter?
    private var tapInstalled = false
    private var running = false
    private var stopped = false
    private var observers: [any NSObjectProtocol] = []
    /// The input this capture started on, plus whether it changed while recording (log-only).
    private var detail: CaptureDetail?

    init() {}

    func captureDetail() async -> CaptureDetail? { detail }

    func start(_ deliver: @escaping @Sendable (CaptureInput) -> Void) async throws {
        guard self.deliver == nil, !stopped else { throw EngineError.failed("Capture already started") }
        self.deliver = deliver
        do {
            try activateSession()
            try installTapIfNeeded()
            engine.prepare()
            try engine.start()
            running = true
            detail = detectDetail()
            observeNotifications()
        } catch {
            teardown()
            throw EngineError.failed("Could not start the microphone: \(FluidErrorMapping.describe(error))")
        }
    }

    func pause() async {
        guard running else { return }
        engine.pause()
        running = false
    }

    func resume() async throws {
        guard !stopped, deliver != nil else { return }
        guard !running else { return }
        do {
            try activateSession()
            // The route may have changed while paused: rebuild the tap if the hardware format differs.
            try installTapIfNeeded()
            engine.prepare()
            try engine.start()
            running = true
        } catch {
            throw EngineError.failed("Could not resume the microphone: \(FluidErrorMapping.describe(error))")
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        teardown()
    }

    // MARK: Engine

    private func installTapIfNeeded() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw EngineError.failed("No microphone input is available")
        }
        if tapInstalled, let converter, converter.inputFormat == format { return }
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        guard let newConverter = TapConverter(inputFormat: format), let deliver else {
            throw EngineError.failed("Unsupported microphone format \(format)")
        }
        converter = newConverter
        // About 100 ms per callback at the hardware rate; the system may choose a different size.
        let bufferSize = AVAudioFrameCount(Swift.max(1024, Int(format.sampleRate / 10)))
        // iOS/macOS 27 deprecate the non-throwing installTap. Its throwing replacement is NS_REFINED_FOR_SWIFT
        // without a Swift overlay in the 27.0 SDK, so it imports as `__installTap(…, error: ())` and throws.
        try input.__installTap(onBus: 0, bufferSize: bufferSize, format: format, error: (),
                               block: Self.makeTapBlock(converter: newConverter, deliver: deliver))
        tapInstalled = true
    }

    /// Built outside the actor so the closure is not actor-isolated: Core Audio calls it on its own thread.
    private nonisolated static func makeTapBlock(converter: TapConverter,
                                                 deliver: @escaping @Sendable (CaptureInput) -> Void) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { deliver(.audio(samples)) }
        }
    }

    private func teardown() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        running = false
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        // The category outlives deactivation: leave none of the recording category behind, or later playback
        // would go to the earpiece (.playAndRecord without .defaultToSpeaker).
        try? session.setCategory(.playback, mode: .spokenAudio)
        #endif
    }

    private func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        #endif
    }

    /// Reads the current input route. Detection is log-only: it never throws, and anything unreadable is "unknown".
    private func detectDetail() -> CaptureDetail {
        #if os(iOS)
        return CaptureRouteDetection.currentDetail()
        #elseif os(macOS)
        return CaptureRouteDetection.detail(deviceID: engine.inputNode.auAudioUnit.deviceID)
        #else
        return CaptureDetail(hardwareModel: CaptureChannel.hardwareModel, input: CaptureDetail.Input.unknown)
        #endif
    }

    /// The input changed during the recording (any engine configuration change, or an iOS route change).
    private func noteRouteChanged() {
        guard deliver != nil, !stopped else { return }
        detail?.routeChanged = true
    }

    // MARK: Notifications

    private func observeNotifications() {
        guard let deliver else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
            [weak self] _ in
            Task { await self?.engineConfigurationChanged() }
        })
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // iOS 27 replaces the interruption notification with an inactive / resumption-recommendation pair.
        observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: session,
                                            queue: nil) { note in
            let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
            // Our own setActive(false) reports source .app; only the system's deactivation is an interruption.
            guard context?.source != .app else { return }
            deliver(.event(.interrupted))
        })
        observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: session,
                                            queue: nil) { note in
            let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            deliver(.event(.interruptionEnded(shouldResume: context?.recommendation == .shouldResume)))
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) {
            [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            // Our own category changes are not a new input.
            if reason != .categoryChange { Task { await self?.noteRouteChanged() } }
            guard reason == .oldDeviceUnavailable else { return }
            deliver(.event(.routeLost))
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: nil) { _ in
            deliver(.event(.mediaServicesReset))
        })
        #endif
    }

    /// The engine stops itself when the hardware configuration changes (sample rate, device). If we were
    /// capturing, rebuild the tap for the new format and restart; if that fails, report the route as lost.
    private func engineConfigurationChanged() {
        guard running, !stopped else { return }
        detail?.routeChanged = true
        log.info("Audio engine configuration changed; restarting capture")
        do {
            try installTapIfNeeded()
            engine.prepare()
            try engine.start()
        } catch {
            running = false
            log.error("Restart after configuration change failed: \(FluidErrorMapping.describe(error), privacy: .public)")
            deliver?(.event(.routeLost))
        }
    }
}
