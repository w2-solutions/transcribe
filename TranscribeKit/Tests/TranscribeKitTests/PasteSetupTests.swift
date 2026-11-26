import Foundation
import Testing
@testable import TranscribeKit

/// The guided Accessibility setup for pasting: what it shows, when it offers a relaunch, and when it polls.
@Suite struct PasteSetupTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func notStartedUntilSettingsIsOpened() {
        let setup = PasteSetup()
        #expect(setup.stage(allowed: false, now: t0) == .notStarted)
        #expect(!setup.shouldPoll(allowed: false, now: t0))
    }

    @Test func allowedWinsAtEveryStage() {
        var setup = PasteSetup()
        #expect(setup.stage(allowed: true, now: t0) == .allowed)
        setup.openedSettings(now: t0)
        setup.appBecameActive(now: t0 + 1)
        #expect(setup.stage(allowed: true, now: t0 + 60) == .allowed)
        #expect(!setup.shouldPoll(allowed: true, now: t0 + 1))
    }

    @Test func waitsWhileTheUserIsInSystemSettings() {
        var setup = PasteSetup()
        setup.openedSettings(now: t0)
        #expect(setup.stage(allowed: false, now: t0 + 30) == .waiting)
        #expect(setup.shouldPoll(allowed: false, now: t0 + 30))
    }

    @Test func offersARelaunchOnlyAfterComingBackAndAShortWait() {
        var setup = PasteSetup()
        setup.openedSettings(now: t0)
        setup.appBecameActive(now: t0 + 10)
        #expect(setup.stage(allowed: false, now: t0 + 11) == .waiting)
        #expect(setup.stage(allowed: false, now: t0 + 10 + PasteSetup.relaunchHintDelay) == .offerRelaunch)
    }

    @Test func comingBackBeforeOpeningSettingsDoesNotCount() {
        var setup = PasteSetup()
        setup.appBecameActive(now: t0)
        setup.openedSettings(now: t0 + 1)
        #expect(setup.stage(allowed: false, now: t0 + 30) == .waiting)
    }

    @Test func onlyTheFirstReturnCounts() {
        var setup = PasteSetup()
        setup.openedSettings(now: t0)
        setup.appBecameActive(now: t0 + 5)
        setup.appBecameActive(now: t0 + 20)
        #expect(setup.returnedAt == t0 + 5)
    }

    @Test func openingSettingsAgainWaitsAfresh() {
        var setup = PasteSetup()
        setup.openedSettings(now: t0)
        setup.appBecameActive(now: t0 + 5)
        #expect(setup.stage(allowed: false, now: t0 + 10) == .offerRelaunch)
        setup.openedSettings(now: t0 + 11)
        #expect(setup.stage(allowed: false, now: t0 + 12) == .waiting)
        #expect(setup.returnedAt == nil)
    }

    @Test func pollingStopsAfterTheLimit() {
        var setup = PasteSetup()
        setup.openedSettings(now: t0)
        #expect(setup.shouldPoll(allowed: false, now: t0 + PasteSetup.pollLimit - 1))
        #expect(!setup.shouldPoll(allowed: false, now: t0 + PasteSetup.pollLimit))
    }

    @Test func doneNamesTheHoldShortcut() {
        let fnX = KeyCombo(keyCode: KeyCodes.x, modifiers: [.function], keyLabel: "X")
        #expect(PasteSetupCopy.done(holdShortcut: fnX.display).contains(fnX.display))
        #expect(PasteSetupCopy.done(holdShortcut: nil) == "Pasting is on.")
    }
}
