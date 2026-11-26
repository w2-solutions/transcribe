import Foundation

/// The event tap's state machine (Mac only): which key events to swallow and which `BackendEvent`s they make. Pure, so
/// the tap's callback only converts the `CGEvent`, calls `handle` under a lock and returns the disposition.
///
/// A key that started a shortcut is "owned" until its key-up: its repeats and its key-up are swallowed too, so the app
/// in front never sees half a shortcut. A hold ends as soon as one of its modifiers is let go (fn released before X),
/// but the key stays owned so its later repeats and key-up never type a stray "x". flagsChanged is never swallowed:
/// other apps (and macOS's own fn handling) must always see modifiers change.
public struct HotkeyTracker: Sendable {
    public enum Input: Equatable, Sendable {
        case keyDown(UInt16, ShortcutModifiers, isRepeat: Bool)
        case keyUp(UInt16, ShortcutModifiers)
        case flagsChanged(ShortcutModifiers)
        /// The tap was disabled by a timeout or user input, the Mac slept, or the bindings changed.
        case reset
    }

    public enum Disposition: Equatable, Sendable { case pass, swallow }

    /// The bindings this tap handles. Empty passes everything (while the recorder field listens).
    public var bindings: [ComboKey: ShortcutAction] = [:]
    /// Whether a plain Esc is swallowed and reported (only while a dictation can be cancelled).
    public var escapeArmed = false

    private struct Held: Sendable {
        var keyCode: UInt16
        var action: ShortcutAction
        var required: ShortcutModifiers
    }

    private var held: Held?
    private var owned: Set<UInt16> = []

    public init() {}

    public mutating func handle(_ input: Input) -> (Disposition, [BackendEvent]) {
        switch input {
        case .keyDown(let keyCode, let modifiers, let isRepeat):
            if isRepeat { return (owned.contains(keyCode) ? .swallow : .pass, []) }
            if keyCode == KeyCodes.escape, modifiers.isEmpty, escapeArmed {
                owned.insert(keyCode)
                return (.swallow, [.escape])
            }
            guard let action = bindings[ComboKey(keyCode: keyCode, modifiers: modifiers)] else { return (.pass, []) }
            var events: [BackendEvent] = []
            if let old = held { events.append(.released(old.action)) }
            held = Held(keyCode: keyCode, action: action, required: modifiers)
            owned.insert(keyCode)
            events.append(.pressed(action))
            return (.swallow, events)

        case .keyUp(let keyCode, _):
            guard owned.remove(keyCode) != nil else { return (.pass, []) }
            if let current = held, current.keyCode == keyCode {
                held = nil
                return (.swallow, [.released(current.action)])
            }
            return (.swallow, [])

        case .flagsChanged(let modifiers):
            if let current = held, !modifiers.isSuperset(of: current.required) {
                held = nil
                return (.pass, [.released(current.action)])
            }
            return (.pass, [])

        case .reset:
            let events: [BackendEvent] = held.map { [.released($0.action)] } ?? []
            held = nil
            owned.removeAll()
            return (.pass, events)
        }
    }
}
