import Foundation
import Testing
@testable import TranscribeKit

/// Storage of the Mac's global shortcuts, outside AppSettings.
@MainActor @Suite struct ShortcutSettingsTests {
    let suite = "shortcuts-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    static let d = KeyCombo(keyCode: 2, modifiers: [.control, .option], keyLabel: "D")

    @Test func startsWithTheDefaults() {
        let settings = ShortcutSettings(defaults: defaults)
        #expect(settings.bindings == .defaults)
        #expect(!settings.askedPostEvent)
        #expect(!settings.introSeen)
    }

    @Test func setClearAndResetPersist() {
        let settings = ShortcutSettings(defaults: defaults)
        settings.set(Self.d, for: .dictateHold)
        settings.set(nil, for: .toggleRecording)
        #expect(settings.bindings.dictateHold == Self.d)
        #expect(settings.bindings.toggleRecording == nil)
        #expect(defaults.string(forKey: "shortcuts.toggleRecording") == "off")

        let reread = ShortcutSettings(defaults: defaults)
        #expect(reread.bindings.dictateHold == Self.d)
        #expect(reread.bindings.dictateHold?.keyLabel == "D")
        #expect(reread.bindings.toggleRecording == nil, "Off stays off; it does not fall back to the default")
        #expect(reread.bindings.dictateToggle == ShortcutBindings.defaults.dictateToggle)

        reread.resetToDefaults()
        #expect(reread.bindings == .defaults)
        for action in ShortcutAction.allCases {
            #expect(defaults.object(forKey: "shortcuts.\(action.rawValue)") == nil)
        }
        #expect(ShortcutSettings(defaults: defaults).bindings == .defaults)
    }

    @Test func garbageReadsAsTheDefault() {
        defaults.set("not json", forKey: "shortcuts.dictateHold")
        #expect(ShortcutSettings(defaults: defaults).bindings.dictateHold == ShortcutBindings.defaults.dictateHold)
    }

    @Test func flagsPersist() {
        let settings = ShortcutSettings(defaults: defaults)
        settings.askedPostEvent = true
        settings.introSeen = true
        let reread = ShortcutSettings(defaults: defaults)
        #expect(reread.askedPostEvent)
        #expect(reread.introSeen)
        // Reset touches only the bindings.
        reread.resetToDefaults()
        #expect(ShortcutSettings(defaults: defaults).introSeen)
    }

    @Test func appSettingsExposesItsStore() {
        let store = defaults
        let app = AppSettings(defaults: store)
        #expect(app.userDefaults === store)
        let shortcuts = ShortcutSettings(defaults: app.userDefaults)
        shortcuts.set(Self.d, for: .dictateToggle)
        #expect(store.string(forKey: "shortcuts.dictateToggle") != nil)
    }
}
