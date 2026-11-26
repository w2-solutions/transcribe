import Foundation

// Global shortcuts (Mac only): the pure model behind Settings → Shortcuts and the hot key backends. Everything here is
// plain data and rules, tested in `swift test`; the Mac app's `Apps/Mac/Sources/Shortcuts/` files call the system APIs.

/// The three things a global shortcut can do.
public enum ShortcutAction: String, Sendable, CaseIterable, Codable {
    case toggleRecording, dictateHold, dictateToggle
}

/// The modifier keys of a shortcut. Our own bits, so the stored value never depends on Carbon or AppKit constants;
/// `carbonMask` and `init(eventFlags:keyCode:)` convert at the system boundary.
public struct ShortcutModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let function = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)
    public static let command = ShortcutModifiers(rawValue: 1 << 4)

    /// Carbon's modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`, `kEventKeyModifierFnMask`), as
    /// `RegisterEventHotKey` takes them and `CopySymbolicHotKeys` reports them.
    enum Carbon {
        static let command: UInt32 = 0x100
        static let shift: UInt32 = 0x200
        static let option: UInt32 = 0x800
        static let control: UInt32 = 0x1000
        static let function: UInt32 = 0x20000
    }

    public var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= Carbon.command }
        if contains(.shift) { mask |= Carbon.shift }
        if contains(.option) { mask |= Carbon.option }
        if contains(.control) { mask |= Carbon.control }
        if contains(.function) { mask |= Carbon.function }
        return mask
    }

    /// The inverse of `carbonMask`, for the system's own shortcuts. Other bits (caps lock, the right-hand variants)
    /// are ignored.
    public init(carbonMask: UInt32) {
        var modifiers: ShortcutModifiers = []
        if carbonMask & Carbon.command != 0 { modifiers.insert(.command) }
        if carbonMask & Carbon.shift != 0 { modifiers.insert(.shift) }
        if carbonMask & Carbon.option != 0 { modifiers.insert(.option) }
        if carbonMask & Carbon.control != 0 { modifiers.insert(.control) }
        if carbonMask & Carbon.function != 0 { modifiers.insert(.function) }
        self = modifiers
    }

    /// `CGEventFlags` / `NSEvent.ModifierFlags` bits (the two share their values).
    enum EventFlag {
        static let shift: UInt64 = 0x20000
        static let control: UInt64 = 0x40000
        static let option: UInt64 = 0x80000
        static let command: UInt64 = 0x100000
        static let secondaryFn: UInt64 = 0x800000
    }

    /// From an event's flags. The fn flag also comes with arrows, F-keys and the other `KeyCodes.fnImplied` keys when
    /// fn is not held, so for those keys it is not counted. Pass a nil `keyCode` for a flagsChanged event, whose fn flag
    /// is always the fn key itself.
    public init(eventFlags: UInt64, keyCode: UInt16?) {
        var modifiers: ShortcutModifiers = []
        if eventFlags & EventFlag.shift != 0 { modifiers.insert(.shift) }
        if eventFlags & EventFlag.control != 0 { modifiers.insert(.control) }
        if eventFlags & EventFlag.option != 0 { modifiers.insert(.option) }
        if eventFlags & EventFlag.command != 0 { modifiers.insert(.command) }
        if eventFlags & EventFlag.secondaryFn != 0, keyCode.map({ !KeyCodes.fnImplied.contains($0) }) ?? true {
            modifiers.insert(.function)
        }
        self = modifiers
    }

    /// "fn", then "⌃⌥⇧⌘" run together, separated by a space: "fn ⇧", "⌃⌥", "fn ⌃⇧". The recorder field shows it while
    /// the user holds modifiers before the key.
    public var symbols: String {
        var parts: [String] = []
        if contains(.function) { parts.append("fn") }
        var run = ""
        if contains(.control) { run += "⌃" }
        if contains(.option) { run += "⌥" }
        if contains(.shift) { run += "⇧" }
        if contains(.command) { run += "⌘" }
        if !run.isEmpty { parts.append(run) }
        return parts.joined(separator: " ")
    }

    /// "Function Shift", "Control Option", in the same order as `symbols`.
    var spokenWords: [String] {
        var words: [String] = []
        if contains(.function) { words.append("Function") }
        if contains(.control) { words.append("Control") }
        if contains(.option) { words.append("Option") }
        if contains(.shift) { words.append("Shift") }
        if contains(.command) { words.append("Command") }
        return words
    }
}

/// What makes two shortcuts the same: the physical key and the modifiers, never the label.
public struct ComboKey: Sendable, Hashable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers
    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }
}

/// One shortcut. `keyLabel` is what the key typed in the layout the user recorded it in ("Z"); it is only for display,
/// so equality and hashing use `key` alone (a combo built by the event tap or from `CopySymbolicHotKeys`, which have no
/// label, still matches).
public struct KeyCombo: Sendable, Hashable {
    public let keyCode: UInt16
    public let modifiers: ShortcutModifiers
    public let keyLabel: String

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }

    public var key: ComboKey { ComboKey(keyCode: keyCode, modifiers: modifiers) }

    public static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.key == b.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    /// The label to show: the fixed name of a special key ("Space", "←", "F5"), else the recorded label, else a
    /// placeholder that still tells two keys apart.
    var shownKey: String {
        if let fixed = KeyCodes.label(keyCode) { return fixed }
        let trimmed = keyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Key \(keyCode)" : trimmed
    }

    /// "fn Z", "fn ⇧ X", "⌃⌥ D": fn first, then ⌃ ⌥ ⇧ ⌘ together, a space, the key.
    public var display: String {
        let mods = modifiers.symbols
        return mods.isEmpty ? shownKey : "\(mods) \(shownKey)"
    }

    /// What VoiceOver reads: "Function Shift X", "Control Option D", "Command Space".
    public var spokenLabel: String {
        (modifiers.spokenWords + [KeyCodes.spokenName(keyCode) ?? shownKey]).joined(separator: " ")
    }
}

/// macOS virtual key codes (`kVK_…`) the shortcut rules need. They name physical keys, so they do not change with the
/// keyboard layout.
public enum KeyCodes {
    public static let a: UInt16 = 0
    public static let z: UInt16 = 6
    public static let x: UInt16 = 7
    public static let c: UInt16 = 8
    public static let v: UInt16 = 9
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let forwardDelete: UInt16 = 117
    /// Right ⌘, ⌘, ⇧, caps lock, ⌥, ⌃, right ⇧, right ⌥, right ⌃ and fn (63, `kVK_Function`).
    public static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// F1–F20 in order (`kVK_F1` … `kVK_F20`).
    public static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106,
                                                64, 79, 80, 90]

    /// Events for these keys carry the fn flag (`maskSecondaryFn`) even without fn held, and fn changes their meaning:
    /// arrows 123–126, Home 115, End 119, Page Up 116, Page Down 121, Forward Delete 117, Help 114 and F1–F20.
    public static let fnImplied: Set<UInt16> = Set([123, 124, 125, 126, 115, 119, 116, 121, 117, 114] + functionKeys)

    /// The fixed label of a key whose character the layout does not give usefully; nil means "ask the layout".
    public static func label(_ keyCode: UInt16) -> String? {
        if let index = functionKeys.firstIndex(of: keyCode) { return "F\(index + 1)" }
        switch keyCode {
        case space: return "Space"
        case returnKey: return "↩"
        case 76: return "⌤"            // keypad Enter
        case tab: return "⇥"
        case escape: return "⎋"
        case delete: return "⌫"
        case forwardDelete: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 114: return "Help"
        default: return nil
        }
    }

    /// What VoiceOver says for a key whose label is a symbol; nil means the label reads well as it is.
    static func spokenName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case returnKey: "Return"
        case 76: "Enter"
        case tab: "Tab"
        case escape: "Escape"
        case delete: "Delete"
        case forwardDelete: "Forward Delete"
        case 123: "Left Arrow"
        case 124: "Right Arrow"
        case 125: "Down Arrow"
        case 126: "Up Arrow"
        default: nil
        }
    }
}

/// The user's shortcuts. A nil binding is Off.
public struct ShortcutBindings: Sendable, Equatable {
    public var toggleRecording: KeyCombo?
    public var dictateHold: KeyCombo?
    public var dictateToggle: KeyCombo?

    public init(toggleRecording: KeyCombo?, dictateHold: KeyCombo?, dictateToggle: KeyCombo?) {
        self.toggleRecording = toggleRecording; self.dictateHold = dictateHold; self.dictateToggle = dictateToggle
    }

    public subscript(_ action: ShortcutAction) -> KeyCombo? {
        get {
            switch action {
            case .toggleRecording: toggleRecording
            case .dictateHold: dictateHold
            case .dictateToggle: dictateToggle
            }
        }
        set {
            switch action {
            case .toggleRecording: toggleRecording = newValue
            case .dictateHold: dictateHold = newValue
            case .dictateToggle: dictateToggle = newValue
            }
        }
    }

    /// The bindings that are on, by key. The validator never lets two actions share a combo; if stored values did, the
    /// first action in `ShortcutAction.allCases` keeps it.
    public var routed: [ComboKey: ShortcutAction] {
        var map: [ComboKey: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            if let combo = self[action], map[combo.key] == nil { map[combo.key] = action }
        }
        return map
    }

    /// fn Z, fn X and fn ⇧ X: no system shortcut uses them (checked against `CopySymbolicHotKeys` and Apple's list).
    public static let defaults = ShortcutBindings(
        toggleRecording: KeyCombo(keyCode: KeyCodes.z, modifiers: [.function], keyLabel: "Z"),
        dictateHold: KeyCombo(keyCode: KeyCodes.x, modifiers: [.function], keyLabel: "X"),
        dictateToggle: KeyCombo(keyCode: KeyCodes.x, modifiers: [.function, .shift], keyLabel: "X"))
}

/// The stored form of one binding: "off", or JSON such as `{"key":6,"label":"Z","mods":["fn"],"v":1}`.
public enum ShortcutCodec {
    public static let off = "off"
    static let version = 1

    private struct Stored: Codable {
        var v: Int
        var key: UInt16
        var mods: [String]
        var label: String
    }

    private static let names: [(ShortcutModifiers, String)] = [
        (.function, "fn"), (.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd"),
    ]

    public static func encode(_ combo: KeyCombo?) -> String {
        guard let combo else { return off }
        let stored = Stored(v: version, key: combo.keyCode,
                            mods: names.filter { combo.modifiers.contains($0.0) }.map(\.1), label: combo.keyLabel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(stored), let text = String(data: data, encoding: .utf8) else { return off }
        return text
    }

    /// Nothing stored, garbage, an unknown version or an unknown modifier name gives `fallback` (the default
    /// binding); "off" gives nil.
    public static func decode(_ text: String?, default fallback: KeyCombo?) -> KeyCombo? {
        guard let text else { return fallback }
        if text == off { return nil }
        guard let data = text.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.v == version, stored.key < 128 else { return fallback }
        var modifiers: ShortcutModifiers = []
        for name in stored.mods {
            guard let match = names.first(where: { $0.1 == name }) else { return fallback }
            modifiers.insert(match.0)
        }
        return KeyCombo(keyCode: stored.key, modifiers: modifiers, keyLabel: stored.label)
    }
}

/// Why a recorded shortcut cannot be used.
public enum ShortcutProblem: Sendable, Equatable {
    case needsModifiers
    case modifierOnly
    case fnChangesKey
    case escapeReserved
    case usedByMacOS
    /// The title of the Transcribe menu command that already uses it.
    case usedByTranscribe(String)
    /// The other action that already uses it.
    case duplicate(ShortcutAction)
}

public enum ShortcutValidator {
    /// Shortcuts macOS itself uses that might not be listed by `CopySymbolicHotKeys` (or that the sandbox hides from
    /// it): the Globe (fn) shortcuts, window tiling, Spotlight, input sources, the app switcher and screenshots.
    public static let macOSReserved: Set<ComboKey> = {
        var set: Set<ComboKey> = []
        // fn + A C D E F H M N Q, ` and \.
        for code: UInt16 in [0, 8, 2, 14, 3, 4, 46, 45, 12, 50, 42] { set.insert(ComboKey(keyCode: code, modifiers: [.function])) }
        set.insert(ComboKey(keyCode: 0, modifiers: [.function, .shift]))
        // fn ⌃ F, C, R: window tiling.
        for code: UInt16 in [3, 8, 15] { set.insert(ComboKey(keyCode: code, modifiers: [.function, .control])) }
        set.insert(ComboKey(keyCode: KeyCodes.space, modifiers: [.command]))
        set.insert(ComboKey(keyCode: KeyCodes.space, modifiers: [.control]))
        set.insert(ComboKey(keyCode: KeyCodes.space, modifiers: [.control, .command]))
        set.insert(ComboKey(keyCode: KeyCodes.tab, modifiers: [.command]))
        set.insert(ComboKey(keyCode: 50, modifiers: [.command]))
        for code: UInt16 in [20, 21, 23] { set.insert(ComboKey(keyCode: code, modifiers: [.shift, .command])) }   // ⇧⌘3/4/5
        set.insert(ComboKey(keyCode: 12, modifiers: [.control, .command]))   // Lock Screen
        set.insert(ComboKey(keyCode: 3, modifiers: [.control, .command]))    // Full Screen
        return set
    }()

    /// The Mac app's own menu shortcuts, with the command's title.
    public static let appMenu: [ComboKey: String] = [
        ComboKey(keyCode: 45, modifiers: [.command]): "New Recording",
        ComboKey(keyCode: 47, modifiers: [.command]): "Stop Recording",
        ComboKey(keyCode: 31, modifiers: [.command]): "Import Audio",
        ComboKey(keyCode: 8, modifiers: [.shift, .command]): "Copy Transcript",
        ComboKey(keyCode: 3, modifiers: [.command]): "Find",
        ComboKey(keyCode: 15, modifiers: [.command]): "Sync Now",
        ComboKey(keyCode: 43, modifiers: [.command]): "Settings",
        ComboKey(keyCode: 12, modifiers: [.command]): "Quit Transcribe",
        ComboKey(keyCode: 13, modifiers: [.command]): "Close",
        ComboKey(keyCode: 4, modifiers: [.command]): "Hide Transcribe",
        ComboKey(keyCode: 4, modifiers: [.option, .command]): "Hide Others",
        ComboKey(keyCode: 46, modifiers: [.command]): "Minimize",
    ]

    /// The first rule `combo` breaks as the binding for `action`, or nil when it can be saved. Recording the action's
    /// own current binding again is fine.
    public static func validate(_ combo: KeyCombo, for action: ShortcutAction, in bindings: ShortcutBindings,
                                systemCombos: Set<ComboKey>) -> ShortcutProblem? {
        let mods = combo.modifiers
        if KeyCodes.modifierKeys.contains(combo.keyCode) { return .modifierOnly }
        if combo.keyCode == KeyCodes.escape { return .escapeReserved }
        let strong = [ShortcutModifiers.control, .option, .command].filter { mods.contains($0) }.count
        if !mods.contains(.function) && strong < 2 { return .needsModifiers }
        if mods.contains(.function) && (KeyCodes.fnImplied.contains(combo.keyCode) || combo.keyCode == KeyCodes.delete) {
            return .fnChangesKey
        }
        if macOSReserved.contains(combo.key) || systemCombos.contains(combo.key) { return .usedByMacOS }
        if let title = appMenu[combo.key] { return .usedByTranscribe(title) }
        for other in ShortcutAction.allCases where other != action && bindings[other] == combo {
            return .duplicate(other)
        }
        return nil
    }
}

/// Which backend registers a shortcut.
public enum ShortcutRouting {
    /// Whether fn shortcuts go through Carbon (`RegisterEventHotKey` with `kEventKeyModifierFnMask`, no permission)
    /// rather than an active event tap (needs Accessibility). Liam's hardware check on 2026-11-26 (macOS 27, MacBook
    /// keyboard, an unsandboxed probe): a Carbon fn Z fired on press and release and no "z" reached the focused app.
    /// The event tap stays built as a fallback; this constant alone picks one.
    public static let fnViaCarbon = true

    public enum Backend: Sendable, Equatable { case carbon, eventTap }

    /// Shortcuts without fn always use Carbon.
    public static func backend(for combo: KeyCombo, fnViaCarbon: Bool = fnViaCarbon) -> Backend {
        guard combo.modifiers.contains(.function) else { return .carbon }
        return fnViaCarbon ? .carbon : .eventTap
    }

    /// Whether any binding that is on goes through the event tap (which needs Accessibility to notice it at all).
    public static func usesEventTap(_ bindings: ShortcutBindings, fnViaCarbon: Bool = fnViaCarbon) -> Bool {
        ShortcutAction.allCases.contains { action in
            bindings[action].map { backend(for: $0, fnViaCarbon: fnViaCarbon) == .eventTap } ?? false
        }
    }
}

/// What a backend reports.
public enum BackendEvent: Equatable, Sendable {
    case pressed(ShortcutAction)
    case released(ShortcutAction)
    case escape
}

/// What the app does in response.
public enum ShortcutCommand: Equatable, Sendable {
    case toggleMeeting, holdBegan, holdEnded, toggleDictation, cancelDictation
}

/// Turns backend events into commands. Backends can repeat a press (Carbon after a re-register, the tap after a
/// reset) or report a release they never saw pressed; neither reaches the app.
public struct ShortcutDispatch: Sendable {
    private var down: Set<ShortcutAction> = []

    public init() {}

    public mutating func receive(_ event: BackendEvent) -> ShortcutCommand? {
        switch event {
        case .escape:
            return .cancelDictation
        case .pressed(let action):
            guard down.insert(action).inserted else { return nil }
            switch action {
            case .toggleRecording: return .toggleMeeting
            case .dictateHold: return .holdBegan
            case .dictateToggle: return .toggleDictation
            }
        case .released(let action):
            guard down.remove(action) != nil else { return nil }
            return action == .dictateHold ? .holdEnded : nil
        }
    }

    /// Forgets every key that is down (suspend, sleep, a re-registration). A hold in progress ends.
    public mutating func reset() -> [ShortcutCommand] {
        defer { down.removeAll() }
        return down.contains(.dictateHold) ? [.holdEnded] : []
    }
}

/// Each binding's state, shown in Settings → Shortcuts.
public enum ShortcutStatus: Equatable, Sendable {
    case active, off, needsAccessibility, needsInputMonitoring, needsRelaunch,
         takenByAnotherApp, otherCopyRunning, offInTestRuns, simulated

    /// The statuses the sidebar note asks the user to fix.
    public var needsPermission: Bool { self == .needsAccessibility || self == .needsInputMonitoring }
}

/// Whether this run registers real shortcuts.
public enum ShortcutAvailability: Equatable, Sendable {
    case live, simulated, offTestRun

    /// Simulation wins; otherwise a UI-test or fake-engine run is off (so a by-hand fake-engine run never registers
    /// shortcuts beside the user's own Transcribe); otherwise live.
    public static func resolve(uiTesting: Bool, useFakeEngine: Bool, simulation: Bool) -> ShortcutAvailability {
        if simulation { return .simulated }
        if uiTesting || useFakeEngine { return .offTestRun }
        return .live
    }
}

/// Wording for Settings → Shortcuts, the sidebar note and the menus (Mac only). The HUD's wording is `DictationHUD`.
public enum ShortcutCopy {
    public static let sectionTitle = "Shortcuts"
    public static let off = "Off"
    public static let typeShortcut = "Type shortcut…"
    public static let resetToDefaults = "Reset to Defaults"
    public static let menuItem = "Shortcuts…"
    public static let copyLastDictation = "Copy Last Dictation"
    public static let sidebarNote = "Shortcuts need permission"

    public static func title(_ action: ShortcutAction) -> String {
        switch action {
        case .toggleRecording: "Start or stop a recording"
        case .dictateHold: "Dictate (hold to talk)"
        case .dictateToggle: "Dictate hands-free"
        }
    }

    public static func subtitle(_ action: ShortcutAction) -> String {
        switch action {
        case .toggleRecording: "Works from any app"
        case .dictateHold: "Hold, speak, let go to paste"
        case .dictateToggle: "Press to start, press again to paste. Esc cancels."
        }
    }

    /// The SF Symbol of each row.
    public static func symbol(_ action: ShortcutAction) -> String {
        switch action {
        case .toggleRecording: "record.circle"
        case .dictateHold: "mic.fill"
        case .dictateToggle: "mic.badge.plus"
        }
    }

    public static func problemMessage(_ problem: ShortcutProblem) -> String {
        switch problem {
        case .needsModifiers: "Use fn, or two of ⌃ ⌥ ⌘, with the key."
        case .modifierOnly: "Add a key to the modifiers."
        case .fnChangesKey: "fn changes what this key does. Choose another key."
        case .escapeReserved: "Esc cancels dictation. Choose another key."
        case .usedByMacOS: "macOS already uses this shortcut."
        case .usedByTranscribe(let title): "Transcribe uses this shortcut for \(title)."
        case .duplicate(let action): "Already used for “\(title(action))”."
        }
    }

    /// The line under a row, shown in red; nil while the shortcut works, is Off or is simulated.
    public static func statusMessage(_ status: ShortcutStatus) -> String? {
        switch status {
        case .active, .off, .simulated: nil
        case .needsAccessibility: "Needs Accessibility access (below)."
        case .needsInputMonitoring: "Needs Input Monitoring (below)."
        case .needsRelaunch: "Quit and reopen Transcribe to finish turning this on."
        case .takenByAnotherApp: "Another app uses this shortcut. Choose another."
        case .otherCopyRunning: "Another copy of Transcribe is handling shortcuts."
        case .offInTestRuns: "Shortcuts are off in test runs."
        }
    }

    // Permissions
    public static let accessibilityTitle = "Accessibility"
    public static let inputMonitoringTitle = "Input Monitoring"
    public static let clipboardTitle = "Clipboard"
    public static let allowed = "Allowed"
    public static let notAllowed = "Not allowed"
    public static let allow = "Allow…"
    public static let keepClipboard = "Keep my clipboard…"
    public static let clipboardNote = "Without this, dictated text replaces what was on your clipboard. Choose Always Allow when macOS asks, so Transcribe can put it back after pasting."
    /// Why Accessibility is needed. fn shortcuts need it only when they go through the event tap
    /// (`ShortcutRouting.fnViaCarbon` false); through Carbon they need no permission, and only pasting uses it.
    public static func accessibilityNote(eventTapInUse: Bool) -> String {
        eventTapInUse
            ? "Dictation pastes by pressing ⌘V for you, and fn shortcuts need this to work in other apps. macOS lists it as Accessibility. Transcribe uses it only to notice these shortcuts and to paste your dictation."
            : "Dictation pastes by pressing ⌘V for you. macOS lists this as Accessibility. Transcribe uses it only to paste your dictation."
    }
    public static let keyboardNote = "No fn key, or one macOS can't see (some external keyboards)? Choose a shortcut with two of ⌃ ⌥ ⌘, or turn Caps Lock into 🌐 Globe in System Settings › Keyboard › Keyboard Shortcuts › Modifier Keys."
    public static let privacy = "Shortcuts work while Transcribe is open, even behind other apps. Transcribe watches only for these key combinations; it never records, stores or sends anything else you type. Dictation stays on this Mac: it is transcribed here, its audio is deleted straight away, and it is never added to your recordings or synced. The text goes only to the app you are typing in, through the clipboard, which Transcribe puts back afterwards when macOS allows it."
}
