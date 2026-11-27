import Foundation
import Testing
@testable import TranscribeKit

/// Global shortcuts: the bindings, their identity, wording, storage codec, validation, routing and availability.
@Suite struct ShortcutsTests {
    static func combo(_ code: UInt16, _ mods: ShortcutModifiers, _ label: String = "") -> KeyCombo {
        KeyCombo(keyCode: code, modifiers: mods, keyLabel: label)
    }

    // MARK: Defaults and wording

    @Test func defaultsAreFnZFnXAndFnShiftX() {
        let d = ShortcutBindings.defaults
        #expect(d.toggleRecording?.key == ComboKey(keyCode: 6, modifiers: [.function]))
        #expect(d.dictateHold?.key == ComboKey(keyCode: 7, modifiers: [.function]))
        #expect(d.dictateToggle?.key == ComboKey(keyCode: 7, modifiers: [.function, .shift]))
        #expect(d.toggleRecording?.display == "fn Z")
        #expect(d.dictateHold?.display == "fn X")
        #expect(d.dictateToggle?.display == "fn ⇧ X")
        #expect(d.toggleRecording?.spokenLabel == "Function Z")
        #expect(d.dictateHold?.spokenLabel == "Function X")
        #expect(d.dictateToggle?.spokenLabel == "Function Shift X")
        #expect(d.routed == [ComboKey(keyCode: 6, modifiers: [.function]): .toggleRecording,
                             ComboKey(keyCode: 7, modifiers: [.function]): .dictateHold,
                             ComboKey(keyCode: 7, modifiers: [.function, .shift]): .dictateToggle])
    }

    @Test func displayAndSpokenLabel() {
        #expect(Self.combo(2, [.control, .option], "D").display == "⌃⌥ D")
        #expect(Self.combo(2, [.control, .option], "D").spokenLabel == "Control Option D")
        #expect(Self.combo(4, [.option, .command], "H").display == "⌥⌘ H")
        #expect(Self.combo(4, [.option, .command], "H").spokenLabel == "Option Command H")
        #expect(Self.combo(KeyCodes.space, [.control, .option]).display == "⌃⌥ Space")
        #expect(Self.combo(KeyCodes.space, [.control, .option]).spokenLabel == "Control Option Space")
        #expect(Self.combo(KeyCodes.returnKey, [.control, .command]).display == "⌃⌘ ↩")
        #expect(Self.combo(KeyCodes.returnKey, [.control, .command]).spokenLabel == "Control Command Return")
        #expect(Self.combo(96, [.control, .option]).display == "⌃⌥ F5")
        #expect(Self.combo(96, [.control, .option]).spokenLabel == "Control Option F5")
        #expect(Self.combo(7, [.function, .control, .option, .shift, .command], "X").display == "fn ⌃⌥⇧⌘ X")
        #expect(Self.combo(7, [.function, .control, .option, .shift, .command], "X").spokenLabel
                == "Function Control Option Shift Command X")
        // A key with no fixed name and no recorded label still shows something that tells keys apart.
        #expect(Self.combo(7, [.function]).display == "fn Key 7")
    }

    @Test func keyLabels() {
        #expect(KeyCodes.label(122) == "F1")
        #expect(KeyCodes.label(90) == "F20")
        #expect(KeyCodes.label(KeyCodes.tab) == "⇥")
        #expect(KeyCodes.label(KeyCodes.escape) == "⎋")
        #expect(KeyCodes.label(KeyCodes.delete) == "⌫")
        #expect(KeyCodes.label(123) == "←")
        #expect(KeyCodes.label(KeyCodes.z) == nil, "letters come from the keyboard layout")
        #expect(KeyCodes.functionKeys.count == 20)
        #expect(KeyCodes.fnImplied.isSuperset(of: Set(KeyCodes.functionKeys)))
        #expect(KeyCodes.fnImplied.isSuperset(of: [123, 124, 125, 126, 115, 119, 116, 121, 117, 114]))
        #expect(!KeyCodes.fnImplied.contains(KeyCodes.z))
    }

    @Test func carbonMaskBothWays() {
        #expect(ShortcutModifiers.command.carbonMask == 0x100)
        #expect(ShortcutModifiers.shift.carbonMask == 0x200)
        #expect(ShortcutModifiers.option.carbonMask == 0x800)
        #expect(ShortcutModifiers.control.carbonMask == 0x1000)
        #expect(ShortcutModifiers.function.carbonMask == 0x20000)
        let all: ShortcutModifiers = [.function, .control, .option, .shift, .command]
        #expect(all.carbonMask == 0x21B00)
        for raw in 0..<32 {
            let mods = ShortcutModifiers(rawValue: raw)
            #expect(ShortcutModifiers(carbonMask: mods.carbonMask) == mods)
        }
        // Caps lock (0x400) and the right-hand bits are ignored.
        #expect(ShortcutModifiers(carbonMask: 0x20000 | 0x400 | 0x2000) == [.function])
    }

    @Test func eventFlagsCountFnOnlyForOrdinaryKeys() {
        let fn: UInt64 = 0x800000, shift: UInt64 = 0x20000, cmd: UInt64 = 0x100000
        #expect(ShortcutModifiers(eventFlags: fn, keyCode: KeyCodes.z) == [.function])
        #expect(ShortcutModifiers(eventFlags: fn | shift, keyCode: KeyCodes.x) == [.function, .shift])
        #expect(ShortcutModifiers(eventFlags: fn, keyCode: 123) == [], "an arrow carries the fn flag without fn held")
        #expect(ShortcutModifiers(eventFlags: fn | cmd, keyCode: 96) == [.command])
        #expect(ShortcutModifiers(eventFlags: fn, keyCode: nil) == [.function], "flagsChanged: the fn key itself")
        #expect(ShortcutModifiers(eventFlags: 0x40000 | 0x80000, keyCode: 2) == [.control, .option])
    }

    // MARK: Identity

    @Test func identityIgnoresTheLabel() {
        let a = Self.combo(6, [.function], "Z")
        let b = Self.combo(6, [.function], "Y")     // the same key recorded under a German layout
        let bare = Self.combo(6, [.function])
        #expect(a == b)
        #expect(a == bare)
        #expect(a.hashValue == b.hashValue)
        #expect(a.hashValue == bare.hashValue)
        #expect(Set([a, b, bare]).count == 1)
        #expect(a != Self.combo(6, [.function, .shift], "Z"))
        #expect(a != Self.combo(7, [.function], "Z"))

        // The tap builds a combo with no label; it still finds the binding.
        let routed = ShortcutBindings.defaults.routed
        #expect(routed[bare.key] == .toggleRecording)
        let byCombo: [KeyCombo: ShortcutAction] = [a: .toggleRecording]
        #expect(byCombo[bare] == .toggleRecording)
        #expect(ShortcutBindings.defaults == ShortcutBindings(toggleRecording: bare, dictateHold: Self.combo(7, [.function]),
                                                               dictateToggle: Self.combo(7, [.function, .shift])))
    }

    @Test func subscriptReadsAndWritesEachAction() {
        var b = ShortcutBindings.defaults
        b[.dictateHold] = nil
        #expect(b.dictateHold == nil)
        #expect(b.routed.count == 2)
        b[.toggleRecording] = Self.combo(2, [.control, .option], "D")
        #expect(b[.toggleRecording]?.display == "⌃⌥ D")
        #expect(b.routed[ComboKey(keyCode: 2, modifiers: [.control, .option])] == .toggleRecording)
    }

    // MARK: Codec

    @Test func codecRoundTrips() {
        let combos = [Self.combo(6, [.function], "Z"), Self.combo(7, [.function, .shift], "X"),
                      Self.combo(2, [.control, .option, .shift, .command], "D"), Self.combo(KeyCodes.space, [.control, .option], "")]
        for combo in combos {
            let text = ShortcutCodec.encode(combo)
            let back = ShortcutCodec.decode(text, default: nil)
            #expect(back == combo)
            #expect(back?.keyLabel == combo.keyLabel)
            #expect(back?.modifiers == combo.modifiers)
        }
        #expect(ShortcutCodec.encode(Self.combo(6, [.function], "Z")) == #"{"key":6,"label":"Z","mods":["fn"],"v":1}"#)
    }

    @Test func codecOffAndFallbacks() {
        let fallback = Self.combo(6, [.function], "Z")
        #expect(ShortcutCodec.encode(nil) == "off")
        #expect(ShortcutCodec.decode("off", default: fallback) == nil)
        #expect(ShortcutCodec.decode(nil, default: fallback) == fallback, "nothing stored → the default")
        for garbage in ["", "{", "null", "[]", "zzz", #"{"v":2,"key":6,"mods":["fn"],"label":"Z"}"#,
                        #"{"key":6,"mods":["fn"],"label":"Z"}"#, #"{"v":1,"key":6,"mods":["hyper"],"label":"Z"}"#,
                        #"{"v":1,"key":900,"mods":["fn"],"label":"Z"}"#, #"{"v":1,"key":-1,"mods":["fn"],"label":"Z"}"#] {
            #expect(ShortcutCodec.decode(garbage, default: fallback) == fallback, "\(garbage)")
            #expect(ShortcutCodec.decode(garbage, default: fallback)?.keyLabel == "Z")
        }
        #expect(ShortcutCodec.decode("garbage", default: nil) == nil)
    }

    // MARK: Validator

    static func validate(_ combo: KeyCombo, for action: ShortcutAction = .dictateHold,
                         in bindings: ShortcutBindings = .defaults, system: Set<ComboKey> = []) -> ShortcutProblem? {
        ShortcutValidator.validate(combo, for: action, in: bindings, systemCombos: system)
    }

    @Test func validCombos() {
        #expect(Self.validate(Self.combo(2, [.control, .option], "D")) == nil)
        #expect(Self.validate(Self.combo(2, [.option, .command], "D")) == nil)
        #expect(Self.validate(Self.combo(2, [.control, .command, .shift], "D")) == nil)
        #expect(Self.validate(Self.combo(16, [.function], "Y")) == nil)
        #expect(Self.validate(Self.combo(KeyCodes.space, [.control, .option])) == nil)
    }

    @Test func modifierOnlyComesFirst() {
        for code in KeyCodes.modifierKeys {
            #expect(Self.validate(Self.combo(code, [])) == .modifierOnly)
            #expect(Self.validate(Self.combo(code, [.function, .control, .option])) == .modifierOnly)
        }
    }

    @Test func escapeIsReserved() {
        #expect(Self.validate(Self.combo(KeyCodes.escape, [])) == .escapeReserved)
        #expect(Self.validate(Self.combo(KeyCodes.escape, [.control, .option])) == .escapeReserved)
        #expect(Self.validate(Self.combo(KeyCodes.escape, [.function])) == .escapeReserved)
    }

    @Test func needsFnOrTwoStrongModifiers() {
        #expect(Self.validate(Self.combo(2, [])) == .needsModifiers)
        #expect(Self.validate(Self.combo(2, [.shift])) == .needsModifiers)
        #expect(Self.validate(Self.combo(45, [.command])) == .needsModifiers, "⌘N")
        #expect(Self.validate(Self.combo(2, [.control])) == .needsModifiers, "plain ⌃ + key")
        #expect(Self.validate(Self.combo(2, [.option])) == .needsModifiers)
        #expect(Self.validate(Self.combo(2, [.command, .shift])) == .needsModifiers, "⇧ does not count")
        #expect(Self.validate(Self.combo(2, [.control, .shift])) == .needsModifiers)
    }

    @Test func fnChangesArrowsFKeysAndDelete() {
        #expect(Self.validate(Self.combo(123, [.function])) == .fnChangesKey)
        #expect(Self.validate(Self.combo(96, [.function])) == .fnChangesKey)
        #expect(Self.validate(Self.combo(115, [.function, .shift])) == .fnChangesKey)
        #expect(Self.validate(Self.combo(KeyCodes.delete, [.function])) == .fnChangesKey)
        #expect(Self.validate(Self.combo(KeyCodes.forwardDelete, [.function])) == .fnChangesKey)
        // Without fn, an F-key with two strong modifiers is fine.
        #expect(Self.validate(Self.combo(96, [.control, .option])) == nil)
    }

    @Test func macOSShortcutsAreRefused() {
        for code: UInt16 in [0, 8, 2, 14, 3, 4, 46, 45, 12, 50, 42] {
            #expect(Self.validate(Self.combo(code, [.function])) == .usedByMacOS, "fn + \(code)")
        }
        #expect(Self.validate(Self.combo(0, [.function, .shift])) == .usedByMacOS)
        for code: UInt16 in [3, 8, 15] {
            #expect(Self.validate(Self.combo(code, [.function, .control])) == .usedByMacOS, "fn ⌃ + \(code)")
        }
        #expect(Self.validate(Self.combo(KeyCodes.space, [.control, .command])) == .usedByMacOS)
        #expect(Self.validate(Self.combo(12, [.control, .command])) == .usedByMacOS, "Lock Screen")
        #expect(Self.validate(Self.combo(3, [.control, .command])) == .usedByMacOS)
        // Anything the system lists is refused too.
        let listed = ComboKey(keyCode: 2, modifiers: [.control, .option])
        #expect(Self.validate(Self.combo(2, [.control, .option], "D"), system: [listed]) == .usedByMacOS)
        #expect(Self.validate(Self.combo(16, [.function], "Y"), system: [ComboKey(keyCode: 16, modifiers: [.function])]) == .usedByMacOS)
    }

    @Test func transcribeMenuShortcutsAreRefused() {
        #expect(Self.validate(Self.combo(4, [.option, .command], "H")) == .usedByTranscribe("Hide Others"))
        #expect(ShortcutCopy.problemMessage(.usedByTranscribe("Hide Others")) == "Transcribe uses this shortcut for Hide Others.")
        #expect(ShortcutValidator.appMenu[ComboKey(keyCode: 45, modifiers: [.command])] == "New Recording")
    }

    @Test func duplicatesAndTheActionsOwnBinding() {
        var bindings = ShortcutBindings.defaults
        let d = Self.combo(2, [.control, .option], "D")
        bindings.dictateHold = d
        #expect(Self.validate(d, for: .dictateToggle, in: bindings) == .duplicate(.dictateHold))
        #expect(ShortcutCopy.problemMessage(.duplicate(.dictateHold)) == "Already used for “Dictate (hold to talk)”.")
        // Recording the same combo for its own action again is fine, whatever label it gets this time.
        #expect(Self.validate(Self.combo(2, [.control, .option], "Ð"), for: .dictateHold, in: bindings) == nil)
        #expect(Self.validate(Self.combo(6, [.function]), for: .toggleRecording) == nil)
        #expect(Self.validate(Self.combo(6, [.function]), for: .dictateHold) == .duplicate(.toggleRecording))
        // An action set to Off conflicts with nothing.
        bindings.toggleRecording = nil
        #expect(Self.validate(Self.combo(6, [.function]), for: .dictateHold, in: bindings) == nil)
    }

    @Test func problemMessages() {
        #expect(ShortcutCopy.problemMessage(.needsModifiers) == "Use fn, or two of ⌃ ⌥ ⌘, with the key.")
        #expect(ShortcutCopy.problemMessage(.modifierOnly) == "Add a key to the modifiers.")
        #expect(ShortcutCopy.problemMessage(.fnChangesKey) == "fn changes what this key does. Choose another key.")
        #expect(ShortcutCopy.problemMessage(.escapeReserved) == "Esc cancels dictation. Choose another key.")
        #expect(ShortcutCopy.problemMessage(.usedByMacOS) == "macOS already uses this shortcut.")
        #expect(ShortcutCopy.title(.toggleRecording) == "Start or stop a recording")
        #expect(ShortcutCopy.title(.dictateHold) == "Dictate (hold to talk)")
        #expect(ShortcutCopy.title(.dictateToggle) == "Dictate hands-free")
    }

    @Test func statusMessages() {
        #expect(ShortcutCopy.statusMessage(.active) == nil)
        #expect(ShortcutCopy.statusMessage(.off) == nil)
        #expect(ShortcutCopy.statusMessage(.simulated) == nil)
        #expect(ShortcutCopy.statusMessage(.offInTestRuns) == "Shortcuts are off in test runs.")
        #expect(ShortcutCopy.statusMessage(.otherCopyRunning) == "Another copy of Transcribe is handling shortcuts.")
        #expect(ShortcutCopy.statusMessage(.needsRelaunch) == "Quit and reopen Transcribe to finish turning this on.")
        #expect(ShortcutStatus.needsAccessibility.needsPermission)
        #expect(ShortcutStatus.needsInputMonitoring.needsPermission)
        #expect(!ShortcutStatus.offInTestRuns.needsPermission)
        #expect(!ShortcutStatus.takenByAnotherApp.needsPermission)
    }

    // MARK: Routing and availability

    @Test func routing() {
        let plain = Self.combo(2, [.control, .option], "D")
        let fn = Self.combo(6, [.function], "Z")
        #expect(ShortcutRouting.backend(for: plain, fnViaCarbon: false) == .carbon)
        #expect(ShortcutRouting.backend(for: plain, fnViaCarbon: true) == .carbon)
        #expect(ShortcutRouting.backend(for: fn, fnViaCarbon: false) == .eventTap)
        #expect(ShortcutRouting.backend(for: fn, fnViaCarbon: true) == .carbon)
        #expect(ShortcutRouting.backend(for: fn) == (ShortcutRouting.fnViaCarbon ? .carbon : .eventTap))
    }

    @Test func availability() {
        #expect(ShortcutAvailability.resolve(uiTesting: false, useFakeEngine: false, simulation: false) == .live)
        #expect(ShortcutAvailability.resolve(uiTesting: true, useFakeEngine: false, simulation: false) == .offTestRun)
        #expect(ShortcutAvailability.resolve(uiTesting: false, useFakeEngine: true, simulation: false) == .offTestRun,
                "a by-hand fake-engine run must not register shortcuts beside the real app")
        #expect(ShortcutAvailability.resolve(uiTesting: true, useFakeEngine: true, simulation: false) == .offTestRun)
        #expect(ShortcutAvailability.resolve(uiTesting: true, useFakeEngine: true, simulation: true) == .simulated)
        #expect(ShortcutAvailability.resolve(uiTesting: false, useFakeEngine: true, simulation: true) == .simulated)
        #expect(ShortcutAvailability.resolve(uiTesting: false, useFakeEngine: false, simulation: true) == .simulated)
    }
}

/// Backend events to app commands.
@Suite struct ShortcutDispatchTests {
    @Test func eachCommand() {
        var d = ShortcutDispatch()
        #expect(d.receive(.pressed(.toggleRecording)) == .toggleMeeting)
        #expect(d.receive(.released(.toggleRecording)) == nil)
        #expect(d.receive(.pressed(.dictateHold)) == .holdBegan)
        #expect(d.receive(.released(.dictateHold)) == .holdEnded)
        #expect(d.receive(.pressed(.dictateToggle)) == .toggleDictation)
        #expect(d.receive(.released(.dictateToggle)) == nil)
        #expect(d.receive(.escape) == .cancelDictation)
    }

    @Test func duplicatePressIsIgnored() {
        var d = ShortcutDispatch()
        #expect(d.receive(.pressed(.dictateHold)) == .holdBegan)
        #expect(d.receive(.pressed(.dictateHold)) == nil)
        #expect(d.receive(.pressed(.toggleRecording)) == .toggleMeeting)
        #expect(d.receive(.pressed(.toggleRecording)) == nil)
        #expect(d.receive(.released(.dictateHold)) == .holdEnded)
        #expect(d.receive(.released(.dictateHold)) == nil)
    }

    @Test func releaseWithNoPressIsIgnored() {
        var d = ShortcutDispatch()
        #expect(d.receive(.released(.dictateHold)) == nil)
        #expect(d.receive(.released(.toggleRecording)) == nil)
        #expect(d.receive(.released(.dictateToggle)) == nil)
    }

    @Test func resetWhileHolding() {
        var d = ShortcutDispatch()
        _ = d.receive(.pressed(.dictateHold))
        _ = d.receive(.pressed(.toggleRecording))
        #expect(d.reset() == [.holdEnded])
        #expect(d.reset() == [])
        #expect(d.receive(.released(.dictateHold)) == nil, "the hold already ended")
        #expect(d.receive(.pressed(.toggleRecording)) == .toggleMeeting, "keys are forgotten")
    }

    @Test func togglePressReleasePress() {
        var d = ShortcutDispatch()
        #expect(d.receive(.pressed(.dictateToggle)) == .toggleDictation)
        #expect(d.receive(.released(.dictateToggle)) == nil)
        #expect(d.receive(.pressed(.dictateToggle)) == .toggleDictation)
    }
}
