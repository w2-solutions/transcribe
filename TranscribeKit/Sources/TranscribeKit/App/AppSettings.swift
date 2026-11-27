import Foundation
import Observation
import TranscribeCore

public enum AppearanceSetting: String, Sendable, CaseIterable {
    case system, light, dark
    public var title: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
}

public struct PipelineSettings: Sendable, Equatable {
    public var identifySpeakers: Bool
    public var recogniseVoices: Bool
    public var language: LanguageHint
    public init(identifySpeakers: Bool, recogniseVoices: Bool, language: LanguageHint) {
        self.identifySpeakers = identifySpeakers; self.recogniseVoices = recogniseVoices; self.language = language
    }
}

/// Backed by `UserDefaults`. Under `-uiTesting` the environment passes a fresh suite (`uitest-<pid>`).
@MainActor @Observable
public final class AppSettings {
    enum Key {
        static let identifySpeakers = "settings.identifySpeakers"
        static let recogniseVoices = "settings.recogniseVoices"
        static let language = "settings.language"            // "auto" or ISO 639-1 code
        static let removeFillers = "settings.removeFillers"
        static let appearance = "settings.appearance"
        static let autoCopy = "settings.autoCopy"
        static let syncEnabled = "settings.syncEnabled"
        static let recordingSource = "settings.recordingSource"   // CaptureSources raw value (Mac only)
        static let macAudioExplained = "settings.macAudioExplained"
        static let syncCloudEnvironment = "sync.cloudEnvironment"
        static let syncAudio = "settings.syncAudio"
        static let syncAudioLastSweep = "sync.audio.lastSweep"
        static let syncAudioIntroShown = "sync.audio.introShown"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The store these settings live in (the UI-test suite under `-uiTesting`), for per-Mac state kept outside
    /// AppSettings, such as `ShortcutSettings`.
    public var userDefaults: UserDefaults { defaults }

    public var identifySpeakers: Bool { didSet { defaults.set(identifySpeakers, forKey: Key.identifySpeakers) } }      // default true
    public var recogniseVoices: Bool { didSet { defaults.set(recogniseVoices, forKey: Key.recogniseVoices) } }          // default true
    public var language: LanguageHint { didSet { defaults.set(Self.encode(language), forKey: Key.language) } }           // default .automatic
    public var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: Key.removeFillers) } }               // default false
    public var appearance: AppearanceSetting { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }  // default .system
    public var autoCopy: CopyFormat { didSet { defaults.set(autoCopy.rawValue, forKey: Key.autoCopy) } }              // default .textOnly
    /// "Sync with iCloud" on this device (§8.4, D3). Off by default.
    public var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: Key.syncEnabled) } }                  // default false
    /// What New Recording captures on this Mac (Settings → Recording, the toolbar menu, File → Record From). Per
    /// device, never synced; the iPhone records the microphone only and never reads it. Default `.microphone`.
    public var recordingSource: CaptureSources {
        didSet { defaults.set(recordingSource.rawValue, forKey: Key.recordingSource) }
    }
    /// The Mac audio explainer sheet has been shown (and Continue chosen) once on this device.
    public var macAudioExplained: Bool { didSet { defaults.set(macAudioExplained, forKey: Key.macAudioExplained) } }   // default false
    /// "Sync audio" on this device: acts only while `syncEnabled` is on. Its default (`syncAudioDefault`) is on,
    /// except in Debug builds with the real engine (decision 25); the key is written only when the switch flips, so
    /// an absent key keeps reading the default.
    public var syncAudio: Bool { didSet { defaults.set(syncAudio, forKey: Key.syncAudio) } }

    /// The iCloud environment ("Development" or "Production") this device's sync state was made in; see
    /// `SyncCoordinator.cloudEnvironment`. Not a user setting.
    public var syncCloudEnvironment: String? {
        get { defaults.string(forKey: Key.syncCloudEnvironment) }
        set { defaults.set(newValue, forKey: Key.syncCloudEnvironment) }
    }

    /// When the audio orphan sweep last ran (set to now the first time audio sync runs, so the first sweep waits a
    /// week). Not a user setting.
    public var syncAudioLastSweep: Date? {
        get { defaults.object(forKey: Key.syncAudioLastSweep) as? Date }
        set { defaults.set(newValue, forKey: Key.syncAudioLastSweep) }
    }

    /// The one-time "Audio now syncs with iCloud" notice has been shown or is not needed (decision 24). Not a user
    /// setting; default false.
    public var syncAudioIntroShown: Bool {
        get { defaults.bool(forKey: Key.syncAudioIntroShown) }
        set { defaults.set(newValue, forKey: Key.syncAudioIntroShown) }
    }

    /// `syncAudioDefault`: what "Sync audio" reads while its key is absent (false in Debug real-engine runs).
    public init(defaults: UserDefaults, syncAudioDefault: Bool = true) {
        self.defaults = defaults
        identifySpeakers = defaults.object(forKey: Key.identifySpeakers) as? Bool ?? true
        recogniseVoices = defaults.object(forKey: Key.recogniseVoices) as? Bool ?? true
        language = Self.decode(defaults.string(forKey: Key.language))
        removeFillers = defaults.object(forKey: Key.removeFillers) as? Bool ?? false
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
        autoCopy = defaults.string(forKey: Key.autoCopy).flatMap(CopyFormat.init(rawValue:)) ?? .textOnly
        syncEnabled = defaults.object(forKey: Key.syncEnabled) as? Bool ?? false
        recordingSource = defaults.string(forKey: Key.recordingSource).flatMap(CaptureSources.init(rawValue:)) ?? .microphone
        macAudioExplained = defaults.object(forKey: Key.macAudioExplained) as? Bool ?? false
        syncAudio = defaults.object(forKey: Key.syncAudio) as? Bool ?? syncAudioDefault
    }

    /// What a new recording captures here: the chosen source when this engine can record Mac audio, else the
    /// microphone (the iPhone, and a Mac engine without Mac audio).
    public func effectiveRecordingSource(systemAudioAvailable: Bool) -> CaptureSources {
        systemAudioAvailable ? recordingSource : .microphone
    }

    public var pipeline: PipelineSettings {
        PipelineSettings(identifySpeakers: identifySpeakers, recogniseVoices: identifySpeakers && recogniseVoices, language: language)
    }

    static func encode(_ hint: LanguageHint) -> String {
        switch hint { case .automatic: "auto"; case .language(let code): code }
    }
    static func decode(_ raw: String?) -> LanguageHint {
        guard let raw, raw != "auto", !raw.isEmpty else { return .automatic }
        return .language(raw)
    }
}
