import Foundation

public enum SeedName: String, Sendable, CaseIterable {
    case firstRun, empty, library, twoSpeakersUnnamed, askKaran, processingHeld, failedProcessing
    case shortKaran        // library + G: an unnamed 6.2 s voice that is Karan in another setting
    case karanFromIPhone   // library, with Karan's samples and his source recordings heard on an iPhone (§7)
    case voiceGroups       // library + Tom: three sound groups on this device, one on an iPad, a saved label
}
public enum FakeScriptName: String, Sendable, CaseIterable {
    case newVoices, knownVoices, askKaran, noSpeech, failSeparation, holdAtSeparating
    case longTalk          // 90 s of unbroken speech: fills the live transcript on the recording screen
}
/// A fake sync scenario for UI tests (`TRANSCRIBE_SYNC=fake:<scenario>`, §8.6). UI tests never touch CloudKit.
public enum FakeSyncScenario: String, Sendable, CaseIterable {
    case fresh, remoteLibrary
    /// `remoteLibrary` with the iPhone's audio in iCloud too: each recording's blob and its marker.
    case remoteLibraryWithAudio
    case signedOut, accountSwitched, zoneRemoved, duplicateKaran, massDelete
}
/// The network a fake-engine or UI-test run pretends to be on (`TRANSCRIBE_NETWORK`), for audio sync's network rules.
public enum FakeNetwork: String, Sendable {
    case wifi, cellular, lowData, offline
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
    public static let envSync = "TRANSCRIBE_SYNC"       // off | fake:<FakeSyncScenario> (fake engine and UI tests only)
    public static let envMCP = "TRANSCRIBE_MCP"                    // on (fake engine and UI tests only)
    public static let envMCPAutoAllow = "TRANSCRIBE_MCP_AUTO_ALLOW" // on (fake engine and UI tests only)
    public static let envMCPTestPort = "TRANSCRIBE_MCP_TEST_PORT"  // 1–65535
    public static let envUpdateAvailable = "TRANSCRIBE_UPDATE_AVAILABLE" // a version, e.g. 9.9.9 (fake engine and UI tests only)
    public static let envNetwork = "TRANSCRIBE_NETWORK"    // wifi | cellular | lowData | offline (fake engine and UI tests only)
    public static let envSyncAudio = "TRANSCRIBE_SYNC_AUDIO"  // "off": the switch starts off; "intro": the one-time
                                                              // notice may show (fake engine and UI tests only)

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
    /// The fake sync scenario (`TRANSCRIBE_SYNC=fake:<scenario>`); nil = off. Read only with the fake engine or
    /// `-uiTesting`, like `channel`.
    public var sync: FakeSyncScenario?
    /// Claude access for this session only (`TRANSCRIBE_MCP=on`, with a throwaway port, and optionally every pairing
    /// request allowed at once, for the smoke script, UI tests and the helper's fake launch). Read only with the fake
    /// engine or `-uiTesting`, like `channel`, and never saved. The Mac app honours these only in DEBUG builds.
    public var mcpOn: Bool
    public var mcpAutoAllow: Bool
    public var mcpTestPort: UInt16?
    /// The Mac's "Update available" reminder for this session only, as if a scheduled check had found this version
    /// (`TRANSCRIBE_UPDATE_AVAILABLE=9.9.9`, digits and dots). Read only with the fake engine or `-uiTesting`, like
    /// `channel`; the Mac app honours it only in DEBUG builds, never starts Sparkle for it and never saves it.
    public var updateAvailable: String?
    /// The network audio sync sees (`TRANSCRIBE_NETWORK`); nil = the real one. Read only with the fake engine or
    /// `-uiTesting`, like `channel`.
    public var network: FakeNetwork?
    /// "Sync audio" starts off for this run (`TRANSCRIBE_SYNC_AUDIO=off`). Read only with the fake engine or
    /// `-uiTesting`, like `channel`.
    public var syncAudioOff: Bool
    /// The one-time "Audio now syncs with iCloud" notice may show in this run (`TRANSCRIBE_SYNC_AUDIO=intro`), for the
    /// notice's UI tests. Read only with the fake engine or `-uiTesting`, like `channel`.
    public var syncAudioIntro: Bool

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
        sync = (useFakeEngine || uiTesting) ? Self.parseSync(environment[Self.envSync]) : nil
        let testRun = useFakeEngine || uiTesting
        mcpOn = testRun && Self.isOn(environment[Self.envMCP])
        mcpAutoAllow = testRun && Self.isOn(environment[Self.envMCPAutoAllow])
        mcpTestPort = testRun ? environment[Self.envMCPTestPort].flatMap { UInt16($0) }.flatMap { $0 == 0 ? nil : $0 } : nil
        updateAvailable = testRun ? Self.parseVersion(environment[Self.envUpdateAvailable]) : nil
        network = testRun ? environment[Self.envNetwork].flatMap {
            FakeNetwork(rawValue: $0.trimmingCharacters(in: .whitespaces))
        } : nil
        let syncAudio = environment[Self.envSyncAudio]?.trimmingCharacters(in: .whitespaces).lowercased()
        syncAudioOff = testRun && syncAudio == "off"
        syncAudioIntro = testRun && syncAudio == "intro"
    }
    /// "1.2.3": digits and dots, starting and ending with a digit; anything else → nil.
    private static func parseVersion(_ raw: String?) -> String? {
        guard let v = raw?.trimmingCharacters(in: .whitespaces), let first = v.first, let last = v.last,
              first.isASCII, first.isNumber, last.isASCII, last.isNumber,
              v.allSatisfy({ $0 == "." || ($0.isASCII && $0.isNumber) }) else { return nil }
        return v
    }
    /// "on", in any case, with spaces around allowed.
    private static func isOn(_ raw: String?) -> Bool { raw?.trimmingCharacters(in: .whitespaces).lowercased() == "on" }
    public static var current: LaunchConfig {
        LaunchConfig(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
    }
    /// "fake:<scenario>" → the scenario; "off", empty or unknown → nil.
    public static func parseSync(_ raw: String?) -> FakeSyncScenario? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), raw.hasPrefix("fake:") else { return nil }
        return FakeSyncScenario(rawValue: String(raw.dropFirst("fake:".count)))
    }
    public var clock: AppClock { now.map(AppClock.frozen) ?? .system }
}
