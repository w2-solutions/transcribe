import Foundation
import Testing
@testable import TranscribeKit

/// The event tap's state machine: what it swallows and what it reports.
@Suite struct HotkeyTrackerTests {
    static let z = KeyCodes.z, x = KeyCodes.x, esc = KeyCodes.escape
    static let fn: ShortcutModifiers = [.function]
    static let fnShift: ShortcutModifiers = [.function, .shift]

    static func tracker(escapeArmed: Bool = false) -> HotkeyTracker {
        var t = HotkeyTracker()
        t.bindings = ShortcutBindings.defaults.routed
        t.escapeArmed = escapeArmed
        return t
    }

    @Test func pressRepeatsAndKeyUp() {
        var t = Self.tracker()
        #expect(t.handle(.flagsChanged(Self.fn)) == (.pass, []))
        #expect(t.handle(.keyDown(Self.x, Self.fn, isRepeat: false)) == (.swallow, [.pressed(.dictateHold)]))
        for _ in 0..<5 { #expect(t.handle(.keyDown(Self.x, Self.fn, isRepeat: true)) == (.swallow, [])) }
        #expect(t.handle(.keyUp(Self.x, Self.fn)) == (.swallow, [.released(.dictateHold)]))
        #expect(t.handle(.flagsChanged([])) == (.pass, []))
        // Afterwards the key is the user's again.
        #expect(t.handle(.keyDown(Self.x, [], isRepeat: false)) == (.pass, []))
        #expect(t.handle(.keyDown(Self.x, [], isRepeat: true)) == (.pass, []))
        #expect(t.handle(.keyUp(Self.x, [])) == (.pass, []))
    }

    @Test func fnReleasedFirstEndsTheHoldButKeepsTheKey() {
        var t = Self.tracker()
        _ = t.handle(.keyDown(Self.x, Self.fn, isRepeat: false))
        // fn let go while X is still down: released at once, and flagsChanged still passes.
        #expect(t.handle(.flagsChanged([])) == (.pass, [.released(.dictateHold)]))
        // X's repeats (now without fn) and its key-up never type an "x".
        #expect(t.handle(.keyDown(Self.x, [], isRepeat: true)) == (.swallow, []))
        #expect(t.handle(.keyUp(Self.x, [])) == (.swallow, []))
        #expect(t.handle(.keyDown(Self.x, [], isRepeat: false)) == (.pass, []))
    }

    @Test func addingShiftKeepsTheHold() {
        var t = Self.tracker()
        _ = t.handle(.keyDown(Self.x, Self.fn, isRepeat: false))
        #expect(t.handle(.flagsChanged(Self.fnShift)) == (.pass, []))
        #expect(t.handle(.flagsChanged([.function, .shift, .command])) == (.pass, []))
        #expect(t.handle(.keyUp(Self.x, Self.fnShift)) == (.swallow, [.released(.dictateHold)]))
    }

    @Test func fnShiftXIsNotFnX() {
        var t = Self.tracker()
        #expect(t.handle(.keyDown(Self.x, Self.fnShift, isRepeat: false)) == (.swallow, [.pressed(.dictateToggle)]))
        #expect(t.handle(.keyUp(Self.x, Self.fnShift)) == (.swallow, [.released(.dictateToggle)]))
        #expect(t.handle(.keyDown(Self.x, Self.fn, isRepeat: false)) == (.swallow, [.pressed(.dictateHold)]))
        // Letting go of ⇧ does not end fn X's hold (fn X needs only fn).
        #expect(t.handle(.flagsChanged(Self.fn)) == (.pass, []))
        #expect(t.handle(.keyUp(Self.x, Self.fn)) == (.swallow, [.released(.dictateHold)]))
        // ⇧ let go during fn ⇧ X ends it.
        _ = t.handle(.keyDown(Self.x, Self.fnShift, isRepeat: false))
        #expect(t.handle(.flagsChanged(Self.fn)) == (.pass, [.released(.dictateToggle)]))
    }

    @Test func unboundKeysPass() {
        var t = Self.tracker()
        #expect(t.handle(.keyDown(KeyCodes.a, Self.fn, isRepeat: false)) == (.pass, []))
        #expect(t.handle(.keyUp(KeyCodes.a, Self.fn)) == (.pass, []))
        #expect(t.handle(.keyDown(Self.z, [], isRepeat: false)) == (.pass, []))
        #expect(t.handle(.keyDown(Self.z, [.function, .command], isRepeat: false)) == (.pass, []), "extra modifiers: not a match")
        #expect(t.handle(.keyDown(Self.z, [.function], isRepeat: true)) == (.pass, []), "a repeat it never owned")
        #expect(t.handle(.keyUp(Self.z, [])) == (.pass, []))
    }

    @Test func resetReleasesAndForgets() {
        var t = Self.tracker()
        #expect(t.handle(.reset) == (.pass, []))
        _ = t.handle(.keyDown(Self.x, Self.fn, isRepeat: false))
        #expect(t.handle(.reset) == (.pass, [.released(.dictateHold)]))
        #expect(t.handle(.reset) == (.pass, []))
        // The key is no longer owned: its key-up passes.
        #expect(t.handle(.keyUp(Self.x, Self.fn)) == (.pass, []))
    }

    @Test func escapeOnlyWhenArmedAndPlain() {
        var off = Self.tracker()
        #expect(off.handle(.keyDown(Self.esc, [], isRepeat: false)) == (.pass, []))
        #expect(off.handle(.keyUp(Self.esc, [])) == (.pass, []))

        var on = Self.tracker(escapeArmed: true)
        #expect(on.handle(.keyDown(Self.esc, [], isRepeat: false)) == (.swallow, [.escape]))
        #expect(on.handle(.keyDown(Self.esc, [], isRepeat: true)) == (.swallow, []))
        #expect(on.handle(.keyUp(Self.esc, [])) == (.swallow, []))
        // ⌘Esc (Force Quit's neighbour) and fn Esc are someone else's.
        #expect(on.handle(.keyDown(Self.esc, [.command], isRepeat: false)) == (.pass, []))
        #expect(on.handle(.keyUp(Self.esc, [.command])) == (.pass, []))
        #expect(on.handle(.keyDown(Self.esc, Self.fn, isRepeat: false)) == (.pass, []))
    }

    @Test func escapeDuringAHoldKeepsTheHold() {
        var t = Self.tracker(escapeArmed: true)
        _ = t.handle(.keyDown(Self.x, Self.fn, isRepeat: false))
        // Esc with fn held is not plain, so it passes; plain Esc after fn is let go has already released.
        #expect(t.handle(.keyDown(Self.esc, Self.fn, isRepeat: false)) == (.pass, []))
        #expect(t.handle(.keyUp(Self.x, Self.fn)) == (.swallow, [.released(.dictateHold)]))
    }

    @Test func secondMatchWhileHolding() {
        var t = Self.tracker()
        _ = t.handle(.keyDown(Self.x, Self.fn, isRepeat: false))
        #expect(t.handle(.keyDown(Self.z, Self.fn, isRepeat: false))
                == (.swallow, [.released(.dictateHold), .pressed(.toggleRecording)]))
        // X is still owned, but no longer the held key: its key-up is swallowed with no event.
        #expect(t.handle(.keyUp(Self.x, Self.fn)) == (.swallow, []))
        #expect(t.handle(.keyUp(Self.z, Self.fn)) == (.swallow, [.released(.toggleRecording)]))
    }

    @Test func emptyBindingsPassEverything() {
        var t = HotkeyTracker()
        #expect(t.handle(.keyDown(Self.x, Self.fn, isRepeat: false)) == (.pass, []))
        #expect(t.handle(.keyDown(Self.x, Self.fn, isRepeat: true)) == (.pass, []))
        #expect(t.handle(.keyUp(Self.x, Self.fn)) == (.pass, []))
        #expect(t.handle(.keyDown(Self.esc, [], isRepeat: false)) == (.pass, []))
        #expect(t.handle(.flagsChanged(Self.fn)) == (.pass, []))
    }

    @Test func bindingsFollowTheSettings() {
        var t = HotkeyTracker()
        var b = ShortcutBindings.defaults
        b.dictateHold = KeyCombo(keyCode: 2, modifiers: [.control, .option], keyLabel: "D")
        t.bindings = b.routed
        #expect(t.handle(.keyDown(Self.x, Self.fn, isRepeat: false)) == (.pass, []))
        #expect(t.handle(.keyDown(2, [.control, .option], isRepeat: false)) == (.swallow, [.pressed(.dictateHold)]))
        #expect(t.handle(.flagsChanged([.control])) == (.pass, [.released(.dictateHold)]))
    }
}
