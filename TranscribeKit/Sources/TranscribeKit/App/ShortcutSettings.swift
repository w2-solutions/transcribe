import Foundation
import Observation

/// The Mac's global shortcuts (Settings → Shortcuts). Stored per Mac in the same `UserDefaults` as `AppSettings`
/// (`AppSettings.userDefaults`, so a UI-test run gets its own suite), never synced, and kept out of `AppSettings` so the
/// iPhone app never sees them. Each binding is one `ShortcutCodec` string; a missing key means the default.
@MainActor @Observable
public final class ShortcutSettings {
    enum Key {
        static func binding(_ action: ShortcutAction) -> String { "shortcuts.\(action.rawValue)" }
        static let askedPostEvent = "shortcuts.askedPostEvent"
        static let introSeen = "shortcuts.introSeen"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public private(set) var bindings: ShortcutBindings

    /// The Allow… button has asked macOS for Accessibility once. Not a user setting.
    public var askedPostEvent: Bool { didSet { defaults.set(askedPostEvent, forKey: Key.askedPostEvent) } }
    /// Settings → Shortcuts has been opened, which hides the sidebar's permission note. Not a user setting.
    public var introSeen: Bool { didSet { defaults.set(introSeen, forKey: Key.introSeen) } }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        bindings = Self.read(defaults)
        askedPostEvent = defaults.bool(forKey: Key.askedPostEvent)
        introSeen = defaults.bool(forKey: Key.introSeen)
    }

    /// Saves one binding; nil is Off (stored as "off", so it stays off rather than going back to the default).
    public func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        defaults.set(ShortcutCodec.encode(combo), forKey: Key.binding(action))
        bindings[action] = combo
    }

    /// Forgets every binding, so each reads as its default.
    public func resetToDefaults() {
        for action in ShortcutAction.allCases { defaults.removeObject(forKey: Key.binding(action)) }
        bindings = .defaults
    }

    private static func read(_ defaults: UserDefaults) -> ShortcutBindings {
        var bindings = ShortcutBindings.defaults
        for action in ShortcutAction.allCases {
            bindings[action] = ShortcutCodec.decode(defaults.string(forKey: Key.binding(action)),
                                                    default: ShortcutBindings.defaults[action])
        }
        return bindings
    }
}
