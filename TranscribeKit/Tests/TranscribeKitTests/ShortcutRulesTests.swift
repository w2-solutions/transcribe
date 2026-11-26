import Foundation
import Testing
@testable import TranscribeKit

/// The decisions `ShortcutCenter` and `MacShortcuts` carry out: the Carbon re-registration order, the one Esc source,
/// the hold's modifier watch, the sidebar note and the Accessibility wording.
@Suite struct ShortcutRulesTests {
    static let fnZ = KeyCombo(keyCode: KeyCodes.z, modifiers: [.function], keyLabel: "Z")
    static let fnX = KeyCombo(keyCode: KeyCodes.x, modifiers: [.function], keyLabel: "X")
    static let fnShiftX = KeyCombo(keyCode: KeyCodes.x, modifiers: [.function, .shift], keyLabel: "X")
    static let ctrlOptR = KeyCombo(keyCode: 15, modifiers: [.control, .option], keyLabel: "R")

    /// Carbon as macOS behaves: one combo per process, whatever the id (`eventHotKeyExistsErr` for a second id).
    struct FakeCarbon {
        var held: [ShortcutAction: KeyCombo] = [:]
        mutating func unregister(_ action: ShortcutAction) { held[action] = nil }
        mutating func register(_ combo: KeyCombo, for action: ShortcutAction) -> Bool {
            guard !held.contains(where: { $0.key != action && $0.value == combo }) else { return false }
            held[action] = combo
            return true
        }

        /// What `ShortcutCenter.apply` does: every unregister, then every register. Returns the actions refused.
        mutating func apply(_ wanted: [ShortcutAction: KeyCombo]) -> [ShortcutAction] {
            let plan = CarbonPlan.make(registered: held, wanted: wanted)
            for action in plan.unregister { unregister(action) }
            return plan.register.filter { !register(wanted[$0]!, for: $0) }
        }
    }

    static func wanted(_ bindings: ShortcutBindings) -> [ShortcutAction: KeyCombo] {
        var map: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases { map[action] = bindings[action] }
        return map
    }

    /// The reviewer's case: recording moved to ⌃⌥R, hold moved to fn Z, then Reset to Defaults. fn Z must move from
    /// hold back to recording without either being refused.
    @Test func aComboMovingBetweenActionsRegisters() {
        var carbon = FakeCarbon()
        #expect(carbon.apply(Self.wanted(.defaults)).isEmpty)
        var swapped = ShortcutBindings.defaults
        swapped.toggleRecording = Self.ctrlOptR
        #expect(carbon.apply(Self.wanted(swapped)).isEmpty)
        swapped.dictateHold = Self.fnZ
        #expect(carbon.apply(Self.wanted(swapped)).isEmpty)
        #expect(carbon.held[.dictateHold] == Self.fnZ)

        #expect(carbon.apply(Self.wanted(.defaults)).isEmpty)
        #expect(carbon.held == Self.wanted(.defaults))
    }

    @Test func aStraightSwapRegistersBoth() {
        var carbon = FakeCarbon()
        _ = carbon.apply([.toggleRecording: Self.fnZ, .dictateHold: Self.fnX])
        #expect(carbon.apply([.toggleRecording: Self.fnX, .dictateHold: Self.fnZ]).isEmpty)
        #expect(carbon.held == [.toggleRecording: Self.fnX, .dictateHold: Self.fnZ])
    }

    @Test func planTouchesOnlyWhatChanged() {
        let registered: [ShortcutAction: KeyCombo] = [.toggleRecording: Self.fnZ, .dictateHold: Self.fnX,
                                                      .dictateToggle: Self.fnShiftX]
        #expect(CarbonPlan.make(registered: registered, wanted: registered) == CarbonPlan(unregister: [], register: []))
        // Hold turned Off, toggle moved: both unregister; only toggle registers.
        let plan = CarbonPlan.make(registered: registered,
                                   wanted: [.toggleRecording: Self.fnZ, .dictateToggle: Self.ctrlOptR])
        #expect(plan == CarbonPlan(unregister: [.dictateHold, .dictateToggle], register: [.dictateToggle]))
        // A registration that failed earlier is not in `registered`, so it is tried again.
        #expect(CarbonPlan.make(registered: [:], wanted: [.dictateHold: Self.fnX])
                == CarbonPlan(unregister: [], register: [.dictateHold]))
    }

    @Test func escapeHasOneSourceAtMost() {
        #expect(EscapeSource.resolve(armed: false, suspended: false, otherCopyRunning: false, tapRunning: false) == .none)
        #expect(EscapeSource.resolve(armed: true, suspended: false, otherCopyRunning: false, tapRunning: false) == .carbon)
        #expect(EscapeSource.resolve(armed: true, suspended: false, otherCopyRunning: false, tapRunning: true) == .tap)
        #expect(EscapeSource.resolve(armed: true, suspended: true, otherCopyRunning: false, tapRunning: true) == .none)
        #expect(EscapeSource.resolve(armed: true, suspended: false, otherCopyRunning: true, tapRunning: false) == .none)
    }

    @Test func aHoldEndsWhenAModifierIsLetGoOnlyAfterItWasSeenDown() {
        var watch = HoldModifierWatch(required: [.function, .shift])
        let ends = [
            watch.observe([]),                          // fn not reported yet: never end at the first poll
            watch.observe([.function]),
            watch.observe([.function, .shift]),         // seen down
            watch.observe([.function, .shift, .command]),
            watch.observe([.function]),                 // ⇧ let go: the hold ends
        ]
        #expect(ends == [false, false, false, false, true])
    }

    @Test func permissionNoteRules() {
        let bindings = ShortcutBindings.defaults
        let fine: [ShortcutStatus] = [.active, .active, .active]
        func shows(_ availability: ShortcutAvailability = .live, introSeen: Bool = false,
                   statuses: [ShortcutStatus] = fine, bindings: ShortcutBindings = bindings, post: Bool = true) -> Bool {
            ShortcutPermissionNote.shows(availability: availability, introSeen: introSeen, statuses: statuses,
                                         bindings: bindings, postEventAllowed: post)
        }
        #expect(!shows())
        #expect(shows(post: false), "dictation could only copy")
        #expect(shows(statuses: [.active, .needsAccessibility, .active]))
        #expect(shows(statuses: [.needsInputMonitoring]))
        #expect(!shows(statuses: [.takenByAnotherApp]))
        #expect(!shows(introSeen: true, statuses: [.needsAccessibility], post: false), "seen once: never again")
        #expect(!shows(.simulated, post: false))
        #expect(!shows(.offTestRun, post: false))
        let meetingOnly = ShortcutBindings(toggleRecording: Self.fnZ, dictateHold: nil, dictateToggle: nil)
        #expect(!shows(bindings: meetingOnly, post: false), "no dictation: nothing to paste")
    }

    @Test func accessibilityNoteFollowsRouting() {
        #expect(!ShortcutRouting.usesEventTap(.defaults, fnViaCarbon: true))
        #expect(ShortcutRouting.usesEventTap(.defaults, fnViaCarbon: false))
        let noFn = ShortcutBindings(toggleRecording: Self.ctrlOptR, dictateHold: nil, dictateToggle: nil)
        #expect(!ShortcutRouting.usesEventTap(noFn, fnViaCarbon: false))

        let carbon = ShortcutCopy.accessibilityNote(eventTapInUse: false)
        #expect(!carbon.contains("fn"))
        #expect(carbon.contains("only to paste your dictation"))
        let tap = ShortcutCopy.accessibilityNote(eventTapInUse: true)
        #expect(tap.contains("fn shortcuts need this"))
        #expect(tap.contains("notice these shortcuts"))
    }
}
