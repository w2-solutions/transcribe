import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The microphone a voice was heard through, as the class of the capturing device (§6.1, decision D8).
///
/// Every recording, voice sample and voice negative carries one of these strings. The input route (built-in,
/// Bluetooth, USB, Continuity) and the hardware model are kept separately in `CaptureDetail`, for the matching log
/// only: AirPods on the same iPhone stay on the "iphone" channel, and a new iPhone model is still "iphone".
public enum CaptureChannel {
    public static let iphone = "iphone", ipad = "ipad", mac = "mac"

    /// This device's channel: "mac" on macOS; on iOS "ipad" when the hardware model starts with "iPad", else
    /// "iphone". `LaunchConfig.channel` overrides it in the fake engine and UI tests (applied by `AppEnvironment`).
    public static var current: String { channel(forHardwareModel: hardwareModel) }

    /// The channel for a hardware model string on this platform.
    public static func channel(forHardwareModel model: String) -> String {
        #if os(macOS)
        return mac
        #else
        return model.hasPrefix("iPad") ? ipad : iphone
        #endif
    }

    /// The hardware model, such as "iPhone15,4" or "Mac15,3": `hw.machine` on iOS (the simulator's
    /// `SIMULATOR_MODEL_IDENTIFIER`, since `hw.machine` there is the host's CPU), `hw.model` on macOS.
    /// "unknown" when it cannot be read.
    public static let hardwareModel: String = {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #endif
        #if os(macOS)
        return sysctlString("hw.model") ?? "unknown"
        #else
        return sysctlString("hw.machine") ?? "unknown"
        #endif
    }()

    static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        return value.isEmpty ? nil : value
        #else
        return nil
        #endif
    }
}

/// How a recording was captured: the hardware and the input route. Log-only (§6.1): it never changes matching.
/// Stored as JSON in `Recording.captureDetailJSON`; `input` is also copied to each sample's `captureInput`.
///
/// `sources` and `outputRoute` (Mac audio, 2026-11-26) are optional and log-only too. Both are nil for a
/// microphone-only recording, and nil keys are left out of the JSON, so a microphone-only detail encodes byte for
/// byte as it did before they existed (and builds that do not know them ignore them when decoding).
public struct CaptureDetail: Codable, Sendable, Equatable {
    /// Values of `input`.
    public enum Input {
        public static let builtInMic = "builtInMic", headsetMic = "headsetMic", bluetoothHFP = "bluetoothHFP"
        public static let usbAudio = "usbAudio", continuity = "continuity", aggregate = "aggregate", virtual = "virtual"
        public static let imported = "imported", unknown = "unknown", fake = "fake"
        /// Mac audio only (the system output, through a process tap), and the microphone mixed with Mac audio.
        public static let systemAudio = "systemAudio", micAndSystem = "micAndSystem"
    }

    /// Values of `sources`: what a recording captured (`CaptureSources.detailValue`). nil means "mic".
    public enum Sources {
        public static let mic = "mic", system = "system", both = "both"
    }

    /// Values of `outputRoute`: where the Mac's sound was playing while Mac audio was recorded (log-only).
    public enum OutputRoute {
        public static let builtInSpeaker = "builtInSpeaker", headphones = "headphones", bluetooth = "bluetooth"
        public static let other = "other"
    }

    public var hardwareModel: String          // "iPhone15,4", "Mac15,3"
    public var input: String?                 // one of `Input`
    public var inputName: String?             // device name (never exported to the matching log)
    public var inputModelUID: String?         // macOS kAudioDevicePropertyModelUID / iOS port uid
    public var routeChanged: Bool             // input changed during the recording
    public var sources: String?               // one of `Sources`; nil = microphone only (log-only)
    public var outputRoute: String?           // one of `OutputRoute`; only when Mac audio was recorded (log-only)

    public init(hardwareModel: String, input: String?, inputName: String? = nil, inputModelUID: String? = nil,
                routeChanged: Bool = false, sources: String? = nil, outputRoute: String? = nil) {
        self.hardwareModel = hardwareModel; self.input = input; self.inputName = inputName
        self.inputModelUID = inputModelUID; self.routeChanged = routeChanged
        self.sources = sources; self.outputRoute = outputRoute
    }

    /// What the recording captured; a missing or unknown `sources` reads as the microphone.
    public var captureSources: CaptureSources { CaptureSources(detailValue: sources) }

    /// Compact JSON with sorted keys (deterministic, so the same detail always gives the same string).
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil for nil, empty or unreadable JSON.
    public static func decode(_ s: String?) -> CaptureDetail? {
        guard let s, !s.isEmpty else { return nil }
        return try? JSONDecoder().decode(CaptureDetail.self, from: Data(s.utf8))
    }
}
