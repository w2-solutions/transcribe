import XCTest

/// iCloud sync on the Mac (§8.6), over the fake iCloud (`TRANSCRIBE_SYNC=fake:<scenario>`; never CloudKit): the switch
/// and its leave dialog in the Settings window, the sidebar footer, the paused states, a library synced from the
/// iPhone (its audio not in iCloud, so no player; or in iCloud, so it downloads and plays), Sync audio off, the
/// one-time audio notice, and the duplicate-voice banner.
final class MacSyncTests: FlowTestCase {
    @MainActor private func launch(seed: String = "library", sync: String, route: String? = nil,
                                   extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = UITestApp.launch(seed: seed, route: route, sync: sync, extraEnvironment: extraEnvironment)
        app.waitFor(AX.Mac.main, timeout: 20)
        return app
    }

    @MainActor private func openSettings(_ app: XCUIApplication) {
        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
    }

    @MainActor func testSwitchOnAndOffInSettings() {
        let app = launch(sync: "fresh")
        Wait.label(app.waitFor(AX.Mac.sidebarFooter), contains: "Nothing is uploaded")
        openSettings(app)
        let master = app.scrollTo(AX.Sync.master)
        XCTAssertFalse(master.isOn, "Sync with iCloud is off until the user turns it on")
        let explanation = app.scrollTo(AX.Sync.explanation)
        Wait.label(explanation, contains: "Transcripts, audio, speaker labels, folders and voice profiles sync")
        Wait.label(explanation, contains: "Audio moves on Wi-Fi or Ethernet")
        Wait.label(explanation, contains: "asked about first")
        // Sync audio shows its stored value (on) and waits for sync.
        let audio = app.scrollTo(AX.Sync.audio)
        Wait.switchState(audio, on: true)
        Wait.check(audio, "Sync audio disabled while sync is off") { !$0.toggleControl.isEnabled }

        master.flipSwitch()
        Wait.switchState(master, on: true)
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
        Wait.label(app.element(AX.Mac.sidebarFooter), contains: "synced with iCloud")
        Wait.check(app.scrollTo(AX.Sync.audio), "Sync audio enabled while sync is on") { $0.toggleControl.isEnabled }
        app.waitFor(AX.Sync.audioStatus, timeout: 15)

        // Off asks whether to keep the iCloud copy; Cancel keeps sync on.
        app.scrollTo(AX.Sync.master).flipSwitch()
        app.button(AX.Sync.Leave.cancel, title: "Cancel").click()
        Wait.switchState(master, on: true)
        app.scrollTo(AX.Sync.master).flipSwitch()
        app.button(AX.Sync.Leave.keep, title: "Keep the iCloud Copy").click()
        Wait.switchState(master, on: false)
        app.waitForGone(AX.Sync.status)
        // The iCloud copy was kept, so the footer no longer says nothing is uploaded.
        Wait.label(app.element(AX.Mac.sidebarFooter), contains: "A copy remains in your iCloud")
    }

    @MainActor func testRemoveTheICloudCopy() {
        let app = launch(sync: "fresh")
        openSettings(app)
        let master = app.scrollTo(AX.Sync.master)
        master.flipSwitch()
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
        app.scrollTo(AX.Sync.master).flipSwitch()
        app.button(AX.Sync.Leave.remove, title: "Also Remove from iCloud").click()
        Wait.switchState(master, on: false)
        app.waitForGone(AX.Sync.status)
    }

    @MainActor func testSignedOut() {
        let app = launch(sync: "signedOut")
        Wait.label(app.waitFor(AX.Mac.sidebarFooter), contains: "Not signed in to iCloud", timeout: 15)
        // The footer opens Settings, which says the same.
        app.element(AX.Mac.sidebarFooter).click()
        app.waitFor(AX.Settings.screen)
        Wait.switchState(app.scrollTo(AX.Sync.master), on: true)
        Wait.label(app.waitFor(AX.Sync.status), contains: "Not signed in to iCloud")
    }

    @MainActor func testZoneRemovedElsewhereThenUploadedAgain() {
        let app = launch(sync: "zoneRemoved")
        Wait.label(app.waitFor(AX.Mac.sidebarFooter), contains: "iCloud sync paused", timeout: 15)
        app.assertCount(3, of: AX.Library.card)   // local data stays
        openSettings(app)
        Wait.label(app.waitFor(AX.Sync.status), contains: "removed on another device")
        let master = app.scrollTo(AX.Sync.master)
        Wait.switchState(master, on: false)        // "Turn sync on again to upload this device's library."
        master.flipSwitch()
        Wait.label(app.waitFor(AX.Sync.status), contains: "Up to date", timeout: 15)
        Wait.label(app.element(AX.Mac.sidebarFooter), contains: "synced with iCloud")
    }

    @MainActor func testRemoteLibraryShowsWhereTheAudioIs() {
        let app = launch(seed: "empty", sync: "remoteLibrary")
        // The iPhone's three recordings arrive; their audio is not in iCloud, so it is only on the iPhone.
        app.assertCount(3, of: AX.Library.card, timeout: 20)
        app.openCard(1)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.audioElsewhere), contains: "Audio is on your iPhone")
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")
        app.waitFor(AX.Transcript.copyButton)
        XCTAssertFalse(app.element(AX.Player.bar).exists, "No player without local audio")
        XCTAssertFalse(app.element(AX.Player.playButton).exists)

        // Karan's samples were heard on the iPhone: his profile groups them under that device.
        app.element(AX.Mac.sidebarVoices).click()
        app.waitFor(AX.Voices.profile("karan")).click()
        Wait.label(app.waitFor(AX.Voices.sampleGroup("iphone")), contains: "On your iPhone · 2")
    }

    /// The iPhone's audio is in iCloud: the Mac downloads it by itself, then the player, Playback → Play and Karan's
    /// voice samples all play it.
    @MainActor func testRemoteAudioDownloadsAndPlays() {
        let app = launch(seed: "empty", sync: "remoteLibraryWithAudio")
        app.assertCount(3, of: AX.Library.card, timeout: 20)
        app.openCard(1)
        app.waitFor(AX.Transcript.screen)
        app.waitFor(AX.Player.bar, timeout: 20)
        app.waitForGone(AX.Transcript.audioElsewhere)
        Wait.label(app.element(AX.Transcript.turnChip(1)), equals: "Karan")

        app.menuBars.menuBarItems["Playback"].click()
        let play = app.menuBars.menuItems["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "No Playback → Play")
        XCTAssertTrue(play.isEnabled, "Playback → Play works once the audio is here")
        app.typeKey(.escape, modifierFlags: [])

        let playButton = app.waitFor(AX.Player.playButton)
        playButton.click()
        Wait.label(playButton, equals: "Pause", timeout: 3)
        playButton.click()
        Wait.label(playButton, equals: "Play", timeout: 3)

        // Karan's samples come from the iPhone's recordings, whose audio is here now.
        app.element(AX.Mac.sidebarVoices).click()
        app.waitFor(AX.Voices.profile("karan")).click()
        let sample = app.scrollTo(AX.VoiceDetail.samplePlay(0))
        Wait.label(sample, contains: "Play sample: ", timeout: 15)
        sample.click()
        Wait.label(sample, contains: "Pause sample", timeout: 3)
    }

    /// Sync audio off on this Mac: the iPhone's audio is in iCloud, and the transcript says how to play it here.
    @MainActor func testSyncAudioOffSaysTurnItOn() {
        let app = launch(seed: "empty", sync: "remoteLibraryWithAudio", extraEnvironment: ["TRANSCRIBE_SYNC_AUDIO": "off"])
        app.assertCount(3, of: AX.Library.card, timeout: 20)
        app.openCard(1)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.audioElsewhere, timeout: 15), contains: "Turn on Sync audio", timeout: 15)
        XCTAssertFalse(app.element(AX.Player.bar).exists, "Nothing downloads with Sync audio off")
        XCTAssertFalse(app.element(AX.Transcript.audioBannerAction).exists)
    }

    /// A Mac that already synced before audio sync came in is told once that its audio now syncs; OK keeps Sync audio
    /// on and the notice does not come back.
    @MainActor func testAudioIntroOK() {
        let app = launch(seed: "empty", sync: "remoteLibraryWithAudio", extraEnvironment: ["TRANSCRIBE_SYNC_AUDIO": "intro"])
        let card = app.waitFor(AX.Sync.audioIntro, timeout: 20)
        Wait.label(card, contains: "Audio now syncs with iCloud")
        app.waitFor(AX.Sync.audioIntroOK).click()
        app.waitForGone(AX.Sync.audioIntro)
        openSettings(app)
        Wait.switchState(app.scrollTo(AX.Sync.audio), on: true)
    }

    @MainActor func testDuplicateVoiceBannerOpensTheMergeSheet() {
        let app = launch(sync: "duplicateKaran", route: "voices")
        app.waitFor(AX.Mac.voiceList, timeout: 20)
        Wait.label(app.waitFor(AX.Voices.duplicateBanner, timeout: 15), contains: "Karan appears twice")
        app.element(AX.Voices.duplicateBannerMerge).click()
        app.waitFor(AX.VoiceDetail.Merge.sheet)
        app.waitFor(AX.VoiceDetail.Merge.target("karan")).click()
        app.button(AX.VoiceDetail.Merge.confirm, title: "Merge").click()
        app.waitForGone(AX.VoiceDetail.Merge.sheet)
        app.waitForGone(AX.Voices.duplicateBanner)
    }

    @MainActor func testAccountChangeAsksFirst() {
        let app = launch(sync: "accountSwitched")
        app.waitFor(AX.Sync.Account.sheet, timeout: 15)
        app.element(AX.Sync.Account.merge).click()
        app.waitForGone(AX.Sync.Account.sheet)
        Wait.label(app.element(AX.Mac.sidebarFooter), contains: "synced with iCloud", timeout: 15)
    }

    @MainActor func testMassDeleteAsksThenRestores() {
        let app = launch(sync: "massDelete")
        Wait.label(app.waitFor(AX.Sync.MassDelete.sheet, timeout: 15), contains: "30 items are missing")
        app.element(AX.Sync.MassDelete.restore).click()
        app.waitForGone(AX.Sync.MassDelete.sheet)
        Wait.label(app.element(AX.Mac.sidebarFooter), contains: "synced with iCloud", timeout: 15)
        app.waitFor(AX.Library.card(3))   // the restored recordings are back beside the three seeded ones
    }
}
