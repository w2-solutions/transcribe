import Foundation

// The decisions `ShortcutCenter` and `MacShortcuts` take, as plain functions so `swift test` covers them; the Mac
// files only carry them out against Carbon, the event tap and AppKit.

/// Which Carbon hot keys a re-apply unregisters and registers.
///
/// macOS refuses a combo this same process already holds under another id (`eventHotKeyExistsErr`), so a combo moving
/// from one action to another (Reset to Defaults after a swap) can only register once its old holder has let go. Every
/// unregister therefore comes before any register.
public struct CarbonPlan: Equatable, Sendable {
    /// Actions whose registered combo goes (changed, Off, or moved to the event tap), in `ShortcutAction` order.
    public let unregister: [ShortcutAction]
    /// Actions to register with their wanted combo, in `ShortcutAction` order.
    public let register: [ShortcutAction]

    /// `registered`: what each action holds now. `wanted`: what each action should hold through Carbon (actions that
    /// are Off or on the event tap are absent).
    public static func make(registered: [ShortcutAction: KeyCombo], wanted: [ShortcutAction: KeyCombo]) -> CarbonPlan {
        let actions = ShortcutAction.allCases
        return CarbonPlan(
            unregister: actions.filter { registered[$0] != nil && registered[$0] != wanted[$0] },
            register: actions.filter { wanted[$0] != nil && registered[$0] != wanted[$0] })
    }
}

/// Where Esc comes from while a dictation can be cancelled. Exactly one source, or none: two could report one press
/// twice, which would break the two-press Esc of a long dictation.
public enum EscapeSource: Equatable, Sendable {
    case none
    /// The event tap's tracker (it already runs for fn shortcuts).
    case tap
    /// A Carbon hot key on plain Esc.
    case carbon

    /// Armed only while a dictation can be cancelled, and never while the recorder field listens or another copy of
    /// Transcribe handles shortcuts.
    public static func resolve(armed: Bool, suspended: Bool, otherCopyRunning: Bool, tapRunning: Bool) -> EscapeSource {
        guard armed, !suspended, !otherCopyRunning else { return .none }
        return tapRunning ? .tap : .carbon
    }
}

/// A Carbon hold cannot see its modifiers let go before its key (Carbon reports the key's release only), so the
/// modifier state is polled while it is held. The hold ends when a required modifier is let go, but only once the poll
/// has seen them all down: if the modifier state failed to report one (fn on some keyboards), a hold would otherwise
/// end at the first poll, and Carbon's own release still ends it.
public struct HoldModifierWatch: Sendable {
    public let required: ShortcutModifiers
    private var seenDown = false

    public init(required: ShortcutModifiers) { self.required = required }

    /// True when the hold should end now.
    public mutating func observe(_ now: ShortcutModifiers) -> Bool {
        if now.isSuperset(of: required) {
            seenDown = true
            return false
        }
        return seenDown
    }
}

/// The sidebar's quiet "Shortcuts need permission" note.
public enum ShortcutPermissionNote {
    /// Only in a live run, and only until Settings → Shortcuts has been seen (`introSeen`): it points to the section,
    /// it never nags. It shows while a binding cannot work for want of a permission, or a dictation shortcut is set
    /// while Accessibility (which pasting needs) is off, so every dictation would only copy.
    public static func shows(availability: ShortcutAvailability, introSeen: Bool, statuses: [ShortcutStatus],
                             bindings: ShortcutBindings, postEventAllowed: Bool) -> Bool {
        guard availability == .live, !introSeen else { return false }
        if statuses.contains(where: \.needsPermission) { return true }
        let dictates = bindings.dictateHold != nil || bindings.dictateToggle != nil
        return dictates && !postEventAllowed
    }
}
