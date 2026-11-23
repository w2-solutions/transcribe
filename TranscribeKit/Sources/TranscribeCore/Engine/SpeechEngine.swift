import Foundation

public enum EngineKind: String, Sendable { case fluid, fake }

public struct EngineInfo: Sendable, Equatable {
    public let kind: EngineKind
    public let asrDisplayName: String           // "Parakeet"
    public let asrModelID: String               // "parakeet-tdt-0.6b-v3-coreml@7dd20fe6" / "fake-parakeet"
    public let embeddingModel: EmbeddingModelID
    public init(kind: EngineKind, asrDisplayName: String, asrModelID: String, embeddingModel: EmbeddingModelID) {
        self.kind = kind; self.asrDisplayName = asrDisplayName; self.asrModelID = asrModelID
        self.embeddingModel = embeddingModel
    }
}

/// The speech models ship inside the app (read-only), so there is nothing to download or remove:
/// only the on-device prepare (load + Neural Engine compile + warm-up) runs.
public enum ModelStatus: Sendable, Equatable {
    case installed          // shipped in the app, not loaded yet
    case preparing          // loading + ANE compile + warm-up
    case ready
    case failed(String)
}

public extension ModelStatus {
    /// The bundled model files are missing or damaged in this copy of the app.
    static let missingFromAppMessage = "Speech models are missing from this copy of Transcribe. Install it again to fix this."
}

public enum LanguageHint: Sendable, Hashable, Codable {
    case automatic
    case language(String)   // ISO 639-1, from Languages.parakeetV3
}

public enum MicPermission: String, Sendable, Equatable { case undetermined, granted, denied }

public struct RecordingRequest: Sendable {
    public var audioURL: URL          // destination: 16 kHz mono Int16 WAV
    public var liveText: Bool         // false when models not ready
    public var language: LanguageHint
    public init(audioURL: URL, liveText: Bool, language: LanguageHint) {
        self.audioURL = audioURL; self.liveText = liveText; self.language = language
    }
}

public struct LiveText: Sendable, Equatable {
    public var confirmed: String
    public var volatile: String
    public init(confirmed: String = "", volatile: String = "") { self.confirmed = confirmed; self.volatile = volatile }
    public var isEmpty: Bool { confirmed.isEmpty && volatile.isEmpty }
}

public enum PauseReason: Sendable, Equatable { case user, interruption, routeLost }
public enum LiveTextUnavailableReason: Sendable, Equatable { case modelsNotReady, pausedInBackground, failed(String) }
public enum RecordingEndReason: Sendable, Equatable { case lowStorage, mediaServicesReset, failed(String) }

public enum RecordingEvent: Sendable, Equatable {
    case tick(elapsed: TimeInterval, level: Float)   // ~20 Hz; elapsed excludes pauses; level 0...1 smoothed
    case liveText(LiveText)
    case liveTextUnavailable(LiveTextUnavailableReason)
    case paused(PauseReason)
    case resumed
    case endedBySystem(RecordingEndReason)           // capture stopped; caller must still call stop()
}

public struct CapturedAudio: Sendable, Equatable {
    public var url: URL
    public var duration: TimeInterval
    public var marks: [TimeInterval]      // audio-timeline offsets
    public var peaks: [Float]             // <= 200 bins, 0...1
    /// The hardware and input route it was captured with (log-only); nil when unknown.
    public var detail: CaptureDetail?
    public init(url: URL, duration: TimeInterval, marks: [TimeInterval], peaks: [Float], detail: CaptureDetail? = nil) {
        self.url = url; self.duration = duration; self.marks = marks; self.peaks = peaks; self.detail = detail
    }
}

/// One live capture session. Single consumer of `events` (RecorderController).
public protocol LiveRecording: AnyObject, Sendable {
    var events: AsyncStream<RecordingEvent> { get }
    func pause() async
    func resume() async
    func markMoment() async -> TimeInterval
    func setLiveTextEnabled(_ enabled: Bool) async
    /// Finalises the WAV header and finishes live ASR. Capture has ended once this returns or throws:
    /// a session is never stopped twice.
    func stop() async throws -> CapturedAudio
    func discard() async                           // stops and deletes the file
}

public enum EngineError: Error, Sendable, Equatable {
    case modelsMissing
    case noSpeech              // diarizer found no speech (FluidAudio .noSpeechDetected)
    case tooShort              // audio below ASR minimum
    case microphoneDenied
    case cancelled
    case failed(String)
}

/// What the app talks to. Real: FluidSpeechEngine. Fake: FakeSpeechEngine.
/// Every model-using call is made by at most one caller at a time (ProcessingCoordinator guarantees it).
public protocol SpeechEngine: Sendable {
    var info: EngineInfo { get }

    // Models
    func modelStatus() async -> ModelStatus
    func prepareModels() async throws                 // load + 1 s silent warm-up; idempotent

    // Microphone
    func microphonePermission() async -> MicPermission
    func requestMicrophonePermission() async -> Bool

    // Capture (works without models; live text only when models are ready and request.liveText)
    func startRecording(_ request: RecordingRequest) async throws -> any LiveRecording

    // Post-processing, always one after the other
    func transcribe(_ audio: URL, language: LanguageHint,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedWord]
    func separateSpeakers(_ audio: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> SpeakerSeparation
    /// One normalised vector per span, same order. Spans must be inside the file.
    func embedVoice(_ audio: URL, spans: [TimeRange]) async throws -> [VoiceVector]
}
