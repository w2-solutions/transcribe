import XCTest

/// Settings → iCloud on the iPhone (§8.6), over the fake iCloud (`TRANSCRIBE_SYNC=fake:<scenario>`; never CloudKit):
/// the switch is off by default and says what syncs, turning it on joins, turning it off asks whether to keep the
/// iCloud copy, and the paused states read plainly. Sync audio (on by default, acting only while sync is on) moves
/// the audio of recordings made on another device: it downloads on Wi-Fi, waits on mobile data until Download Now,
/// and a device that synced before audio sync came in is told once.
final class SyncSettingsFlowTests: FlowTestCase {
    @MainActor private func launchSettings(sync: String, seed: String = "library",
                                           extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = UITestApp.launch(seed: seed, route: "settings", sync: sync, extraEnvironment: extraEnvironment)
        app.waitFor(AX.Settings.screen, timeout: 20)
        return app
    }

    @MainActor func testSwitchIsOffByDefaultAndSaysWhatSyncs() {
        let app = launchSettings(sync: "fresh")
        let master = app.scrollTo(AX.Sync.master)
        XCTAssertFalse(master.isOn, "Sync with iCloud is off until the user turns it on")
        // Sync audio shows its stored value (on) while sync is off, but cannot be changed until sync is on.
        let audio = app.scrollTo(AX.Sync.audio)
        Wait.switchState(audio, on: true)
        Wait.check(audio, "Sync audio disabled while sync is off") { !$0.toggleControl.isEnabled }
        let explanation = app.scrollTo(AX.Sync.explanation)
        for part in ["Transcripts, audio, speaker labels, folders and voice profiles sync through your private iCloud",
                     "Audio moves on Wi-Fi as a compressed copy",
                     "A voice learned on another device is asked about first"] {
            Wait.label(explanation, contains: part)
        }
        XCTAssertFalse(app.element(AX.Sync.status).exists, "No status line while sync is off")
        XCTAssertFalse(app.element(AX.Sync.audioStatus).exists, "No audio status line while sync is off")
        XCTAssertFalse(app.element(AX.Sync.now).exists)
        XCTAssertFalse(app.element(AX.Sync.removeCloud).exists)
    }

    @MainActor func testSyncAudioFollowsTheMasterSwitchAndChangesTheExplanation() {
        let app = launchSettings(sync: "fresh")
        app.scrollTo(AX.Sync.master).flipSwitch()
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
        let audio = app.scrollTo(AX.Sync.audio)
        Wait.check(audio, "Sync audio enabled while sync is on") { $0.toggleControl.isEnabled }
        Wait.switchState(audio, on: true)
        app.waitFor(AX.Sync.audioStatus, timeout: 15)

        // Off: nothing is deleted anywhere, and the explanation says what that means.
        audio.flipSwitch()
        Wait.switchState(audio, on: false)
        app.waitForGone(AX.Sync.audioStatus)
        Wait.label(app.scrollTo(AX.Sync.explanation), contains: "With Sync audio off")
        Wait.label(app.scrollTo(AX.Settings.privacyRow), contains: "Audio on this iPhone only")

        // On again.
        app.scrollTo(AX.Sync.audio).flipSwitch()
        Wait.switchState(audio, on: true)
        Wait.label(app.scrollTo(AX.Sync.explanation), contains: "Transcripts, audio, speaker labels")
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
        // Sync audio is on by default, so audio goes to iCloud too.
        Wait.label(app.scrollTo(AX.Settings.privacyRow), contains: "This iPhone and your iCloud")

        // With Sync audio off, only the audio stays here.
        let off = launchSettings(sync: "fresh", extraEnvironment: ["TRANSCRIBE_SYNC_AUDIO": "off"])
        Wait.label(off.scrollTo(AX.Settings.privacyRow), contains: "On this iPhone only")
        off.scrollTo(AX.Sync.master).flipSwitch()
        Wait.label(off.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
        Wait.switchState(off.scrollTo(AX.Sync.audio), on: false)
        Wait.label(off.scrollTo(AX.Settings.privacyRow), contains: "Audio on this iPhone only")
    }

    /// A library synced from another iPhone whose audio is not in iCloud: the transcript says where the audio is and
    /// shows no player.
    @MainActor func testSyncedTranscriptHasNoPlayer() {
        let app = UITestApp.launch(seed: "empty", sync: "remoteLibrary")
        app.waitFor(AX.Library.screen, timeout: 20)
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.audioElsewhere), contains: "Audio is on your other iPhone")
        app.waitFor(AX.Transcript.copyButton)
        XCTAssertFalse(app.element(AX.Player.bar).exists, "No player without local audio")
    }

    /// The other iPhone's audio is in iCloud: on Wi-Fi it downloads by itself, the banner goes and the player plays it.
    @MainActor func testSyncedAudioDownloadsAndPlays() {
        let app = UITestApp.launch(seed: "empty", sync: "remoteLibraryWithAudio")
        app.waitFor(AX.Library.screen, timeout: 20)
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        app.waitFor(AX.Player.bar, timeout: 20)
        app.waitForGone(AX.Transcript.audioElsewhere)
        let play = app.waitFor(AX.Player.playButton)
        Wait.label(play, equals: "Play")
        play.press()
        Wait.label(play, equals: "Pause")
        play.press()
        Wait.label(play, equals: "Play")
    }

    /// On mobile data the audio waits for Wi-Fi; Download Now fetches it at once.
    @MainActor func testOnMobileDataAudioWaitsThenDownloadNow() {
        let app = UITestApp.launch(seed: "empty", sync: "remoteLibraryWithAudio",
                                   extraEnvironment: ["TRANSCRIBE_NETWORK": "cellular"])
        app.waitFor(AX.Library.screen, timeout: 20)
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.audioElsewhere, timeout: 15), contains: "It downloads on Wi-Fi", timeout: 15)
        XCTAssertFalse(app.element(AX.Player.bar).exists, "No player until the audio is here")
        let action = app.waitFor(AX.Transcript.audioBannerAction)
        Wait.label(action, equals: "Download Now")
        action.press()
        app.waitFor(AX.Player.bar, timeout: 20)
        app.waitForGone(AX.Transcript.audioElsewhere)
    }

    /// Remove iCloud Copy… with audio only in iCloud offers Download Audio First only while it can download: on mobile
    /// data it does (it goes over any network), with Sync audio off on this iPhone it does not (nothing would download).
    @MainActor func testDownloadAudioFirstOnlyWhenItCanDownload() {
        let app = launchSettings(sync: "remoteLibraryWithAudio", seed: "empty",
                                 extraEnvironment: ["TRANSCRIBE_NETWORK": "cellular"])
        Wait.label(app.scrollTo(AX.Sync.status), contains: "Up to date", timeout: 20)
        app.scrollTo(AX.Sync.removeCloud).press()
        app.waitFor(AX.Sync.removeCloudConfirm)
        app.waitFor(AX.Sync.downloadAudioFirst)

        let off = launchSettings(sync: "remoteLibraryWithAudio", seed: "empty",
                                 extraEnvironment: ["TRANSCRIBE_NETWORK": "cellular", "TRANSCRIBE_SYNC_AUDIO": "off"])
        Wait.label(off.scrollTo(AX.Sync.status), contains: "Up to date", timeout: 20)
        Wait.switchState(off.scrollTo(AX.Sync.audio), on: false)
        off.scrollTo(AX.Sync.removeCloud).press()
        off.waitFor(AX.Sync.removeCloudConfirm)
        XCTAssertFalse(off.element(AX.Sync.downloadAudioFirst).exists, "No Download Audio First while Sync audio is off")
    }

    /// A device that already synced before audio sync came in is told once that its audio now syncs; Turn Off turns
    /// Sync audio off on this device.
    @MainActor func testAudioIntroTurnOff() {
        let app = UITestApp.launch(seed: "empty", sync: "remoteLibraryWithAudio",
                                   extraEnvironment: ["TRANSCRIBE_SYNC_AUDIO": "intro"])
        let card = app.waitFor(AX.Sync.audioIntro, timeout: 20)
        Wait.label(card, contains: "Audio now syncs with iCloud")
        app.waitFor(AX.Sync.audioIntroTurnOff).press()
        app.waitForGone(AX.Sync.audioIntro)

        app.waitFor(AX.Library.settingsButton).press()
        app.waitFor(AX.Settings.screen)
        Wait.switchState(app.scrollTo(AX.Sync.audio), on: false)
        Wait.label(app.scrollTo(AX.Sync.explanation), contains: "With Sync audio off")
    }
}
