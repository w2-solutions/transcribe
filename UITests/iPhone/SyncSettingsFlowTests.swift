import XCTest

/// Settings → iCloud on the iPhone (§8.6), over the fake iCloud (`TRANSCRIBE_SYNC=fake:<scenario>`; never CloudKit):
/// the switch is off by default and says what syncs, turning it on joins, turning it off asks whether to keep the
/// iCloud copy, and the paused states read plainly.
final class SyncSettingsFlowTests: FlowTestCase {
    @MainActor private func launchSettings(sync: String, seed: String = "library") -> XCUIApplication {
        let app = UITestApp.launch(seed: seed, route: "settings", sync: sync)
        app.waitFor(AX.Settings.screen, timeout: 20)
        return app
    }

    @MainActor func testSwitchIsOffByDefaultAndSaysWhatSyncs() {
        let app = launchSettings(sync: "fresh")
        let master = app.scrollTo(AX.Sync.master)
        XCTAssertFalse(master.isOn, "Sync with iCloud is off until the user turns it on")
        let explanation = app.scrollTo(AX.Sync.explanation)
        for part in ["Transcripts, speaker labels, folders and voice profiles sync through your private iCloud",
                     "Audio stays on the device that recorded it",
                     "A voice learned on another device is asked about first"] {
            Wait.label(explanation, contains: part)
        }
        XCTAssertFalse(app.element(AX.Sync.status).exists, "No status line while sync is off")
        XCTAssertFalse(app.element(AX.Sync.now).exists)
        XCTAssertFalse(app.element(AX.Sync.removeCloud).exists)
    }

    @MainActor func testTurnOnThenOffKeepingTheICloudCopy() {
        let app = launchSettings(sync: "fresh")
        let master = app.scrollTo(AX.Sync.master)
        master.flipSwitch()
        Wait.switchState(master, on: true)
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
        app.scrollTo(AX.Sync.now)
        app.scrollTo(AX.Sync.removeCloud)

        // Off asks first, offering both choices. (The iOS 27 dialog is a popover: no Cancel button, a tap outside
        // dismisses it. The Mac test covers Cancel.)
        app.scrollTo(AX.Sync.master).flipSwitch()
        app.waitFor(AX.Sync.Leave.remove)
        app.waitFor(AX.Sync.Leave.keep).press()
        Wait.switchState(master, on: false)
        app.waitForGone(AX.Sync.status)
    }

    @MainActor func testTurnOffAndRemoveTheICloudCopy() {
        let app = launchSettings(sync: "fresh")
        let master = app.scrollTo(AX.Sync.master)
        master.flipSwitch()
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)

        app.scrollTo(AX.Sync.master).flipSwitch()
        app.waitFor(AX.Sync.Leave.remove).press()
        Wait.switchState(master, on: false)
        app.waitForGone(AX.Sync.status)

        // On again: this device's library goes up to the (now empty) iCloud again.
        master.flipSwitch()
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
    }

    @MainActor func testSignedOutReadsPlainly() {
        let app = launchSettings(sync: "signedOut")
        let master = app.scrollTo(AX.Sync.master)
        Wait.switchState(master, on: true)
        Wait.label(app.waitFor(AX.Sync.status), contains: "Not signed in to iCloud")
    }

    @MainActor func testAccountChangeAsksBeforeUploading() {
        let app = launchSettings(sync: "accountSwitched")
        // The question comes up by itself at launch; keeping sync paused leaves a way back in Settings.
        app.waitFor(AX.Sync.Account.sheet, timeout: 15)
        app.waitFor(AX.Sync.Account.keepPaused).press()
        app.waitForGone(AX.Sync.Account.sheet)
        Wait.label(app.scrollTo(AX.Sync.status), contains: "different iCloud account")

        app.scrollTo(AX.Sync.review).press()
        app.waitFor(AX.Sync.Account.merge).press()
        app.waitForGone(AX.Sync.Account.sheet)
        Wait.label(app.scrollTo(AX.Sync.status), contains: "Up to date", timeout: 15)
    }

    @MainActor func testPrivacyFollowsTheSwitch() {
        let app = launchSettings(sync: "fresh")
        let privacy = app.scrollTo(AX.Settings.privacyRow)
        Wait.label(privacy, contains: "On this iPhone only")
        app.scrollTo(AX.Sync.master).flipSwitch()
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
        Wait.label(app.scrollTo(AX.Settings.privacyRow), contains: "Audio on this iPhone only")
    }

    /// A library synced from another iPhone: the transcript says where the audio is and shows no player.
    @MainActor func testSyncedTranscriptHasNoPlayer() {
        let app = UITestApp.launch(seed: "empty", sync: "remoteLibrary")
        app.waitFor(AX.Library.screen, timeout: 20)
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.audioElsewhere), contains: "Audio is on your other iPhone")
        app.waitFor(AX.Transcript.copyButton)
        XCTAssertFalse(app.element(AX.Player.bar).exists, "No player without local audio")
    }
}
