import Foundation

public enum SeedName: String, Sendable, CaseIterable {
    case firstRun, empty, library, twoSpeakersUnnamed, askKaran, processingHeld, failedProcessing
    case shortKaran        // library + G: an unnamed 6.2 s voice that is Karan in another setting
}
public enum FakeScriptName: String, Sendable, CaseIterable {
    case newVoices, knownVoices, askKaran, noSpeech, failSeparation, holdAtSeparating
    case longTalk          // 90 s of unbroken speech: fills the live transcript on the recording screen
}
public enum FakeSpeed: String, Sendable, CaseIterable { case instant, demo, frozen }
public enum FakeModelState: String, Sendable, CaseIterable { case installed, missing }

public enum LaunchRoute: Sendable, Equatable {
    case library, recording, voices, settings, modelSettings, attributions
    case transcript(String)                 // "latest" or library index "0", "1", …
    case nameSpeaker(String, SpeakerKey)    // "latest:S2"
    case voice(String)                      // profile name, case-insensitive
    /// Parses TRANSCRIBE_ROUTE: library | recording | voices | settings | models | attributions |
    /// transcript:<latest|n> | name:<latest|n>:<key> | voice:<name>
    public init?(_ raw: String) {
        let p = raw.split(separator: ":", maxSplits: 2).map(String.init)
        switch p.first {
        case "library": self = .library
        case "recording": self = .recording
        case "voices": self = .voices
        case "settings": self = .settings
        case "models": self = .modelSettings
        case "attributions": self = .attributions
        case "transcript" where p.count == 2: self = .transcript(p[1])
        case "name" where p.count == 3: self = .nameSpeaker(p[1], p[2])
        case "voice" where p.count == 2: self = .voice(p[1])
        default: return nil
        }
    }
}

public struct LaunchConfig: Sendable, Equatable {
    public static let argUseFakeEngine = "-useFakeEngine"
    public static let argUITesting = "-uiTesting"
    public static let envSeed = "TRANSCRIBE_SEED"
    public static let envScript = "TRANSCRIBE_SCRIPT"
    public static let envSpeed = "TRANSCRIBE_SPEED"
    public static let envModels = "TRANSCRIBE_MODELS"
    public static let envNow = "TRANSCRIBE_NOW"        // ISO-8601, e.g. 2026-11-18T14:31:00+11:00
    public static let envRoute = "TRANSCRIBE_ROUTE"
    public static let envMic = "TRANSCRIBE_MIC"        // granted | denied | undetermined
    public static let envChannel = "TRANSCRIBE_CHANNEL" // iphone | ipad | mac (fake engine and UI tests only)

    public var useFakeEngine: Bool
    public var uiTesting: Bool
    public var seed: SeedName?
    public var script: FakeScriptName       // default .newVoices
    public var speed: FakeSpeed             // default: .instant if uiTesting else .demo
    public var models: FakeModelState       // default .installed, but .missing when seed == .firstRun and env unset
    public var now: Date?                   // frozen clock when set
    public var route: LaunchRoute?
    public var mic: MicPermission           // default .granted (fake engine only)
    /// Overrides `CaptureChannel.current` throughout the store. Read only with the fake engine or `-uiTesting`, so a
    /// stray environment variable can never relabel the real library's voices.
    public var channel: String?

    public init(arguments: [String], environment: [String: String]) {
        useFakeEngine = arguments.contains(Self.argUseFakeEngine) || environment["TRANSCRIBE_ENGINE"] == "fake"
        uiTesting = arguments.contains(Self.argUITesting)
        seed = environment[Self.envSeed].flatMap(SeedName.init(rawValue:))
        script = environment[Self.envScript].flatMap(FakeScriptName.init(rawValue:)) ?? .newVoices
        speed = environment[Self.envSpeed].flatMap(FakeSpeed.init(rawValue:)) ?? (uiTesting ? .instant : .demo)
        models = environment[Self.envModels].flatMap(FakeModelState.init(rawValue:)) ?? (seed == .firstRun ? .missing : .installed)
        now = environment[Self.envNow].flatMap { ISO8601DateFormatter().date(from: $0) }
        route = environment[Self.envRoute].flatMap(LaunchRoute.init)
        mic = environment[Self.envMic].flatMap(MicPermission.init(rawValue:)) ?? .granted
        let rawChannel = environment[Self.envChannel]?.trimmingCharacters(in: .whitespaces).lowercased()
        channel = (useFakeEngine || uiTesting) && rawChannel?.isEmpty == false ? rawChannel : nil
    }
    public static var current: LaunchConfig {
        LaunchConfig(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
    }
    public var clock: AppClock { now.map(AppClock.frozen) ?? .system }
}
