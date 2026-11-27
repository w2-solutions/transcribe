import XCTest

/// Mac audio (2026-11-26): what New Recording captures on the Mac. The fake engine offers Mac audio when the launch
/// names a fake Mac audio stream (`TRANSCRIBE_MAC_AUDIO`, which `UITestApp` sets whenever a source is given); the
/// source starts from `TRANSCRIBE_SOURCE` in this run's fresh settings. Scripts: `newVoices` (two microphone voices)
/// and `callVoices` (a local speaker, a speaker heard through Mac audio and one heard on both).
///
/// Never run while `/Applications/Transcribe.app` is open (`XCUIApplication.launch()` quits it), and never two Mac UI
/// runs at once.
final class MacRecordingSourceTests: FlowTestCase {
    private let microphone = "Microphone", both = "Microphone and Mac audio", macAudioOnly = "Mac audio only"

    @MainActor private func launch(source: String? = nil, script: String = "newVoices", macAudio: String = "granted",
                                   explained: Bool = true, mic: String? = nil, outputRoute: String? = "headphones",
                                   seed: String = "empty") -> XCUIApplication {
        let app = UITestApp.launch(seed: seed, script: script, mic: mic, source: source, macAudio: macAudio,
                                   macAudioExplained: explained, outputRoute: outputRoute)
        app.waitFor(AX.Mac.main, timeout: 20)
        return app
    }

    /// ⌘N, then the Recording window with its source line.
    @MainActor @discardableResult
    private func record(_ app: XCUIApplication, expecting line: String) -> XCUIElement {
        app.shortcut("n")
        app.waitFor(AX.Mac.recordingWindow)
        let source = app.waitFor(AX.Recording.source)
        Wait.label(source, equals: line)
        return source
    }

    @MainActor private func stop(_ app: XCUIApplication) {
        app.element(AX.Recording.stopButton).click()
        app.waitForGone(AX.Mac.recordingWindow, timeout: 15)
    }

    /// Chooses a source from File → Record From, which also starts a recording with it.
    @MainActor private func recordFromMenu(_ app: XCUIApplication, _ title: String) {
        app.menuBars.menuBarItems["File"].click()
        let submenu = app.menuItems["Record From"].firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 5), "File has Record From")
        submenu.hover()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Record From lists “\(title)”")
        item.click()
    }

    // MARK: The setting

    @MainActor func testMicrophoneIsTheDefault() {
        let app = launch()
        Wait.label(app.waitFor(AX.Mac.sidebarNewRecording), contains: microphone)
        record(app, expecting: "Recording the microphone")
        app.waitFor(AX.Recording.levelMeter)
        XCTAssertFalse(app.element(AX.Recording.levelMeterMic).exists, "One meter for the microphone")
        XCTAssertFalse(app.element(AX.Recording.levelMeterMacAudio).exists)
        stop(app)

        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
        Wait.label(app.waitFor(AX.RecordingSource.picker), contains: microphone)
        Wait.label(app.waitFor(AX.RecordingSource.footnote), contains: "Use headphones with both")
    }

    @MainActor func testBothShowsTwoMetersAndTheSourceLine() {
        let app = launch(source: "both")
        Wait.label(app.waitFor(AX.Mac.sidebarNewRecording), contains: both)
        record(app, expecting: "Recording the microphone and Mac audio")
        Wait.label(app.waitFor(AX.Recording.levelMeterMic), equals: "Microphone")
        Wait.label(app.waitFor(AX.Recording.levelMeterMacAudio), equals: "Mac audio")
        XCTAssertFalse(app.element(AX.Recording.levelMeter).exists, "Two captioned meters replace the single one")
        XCTAssertFalse(app.element(AX.Recording.headphonesHint).exists, "Headphones: no hint")
        stop(app)
        app.waitFor(AX.Transcript.screen, timeout: 15)
    }

    @MainActor func testHeadphonesHintWhenTheMacPlaysThroughItsSpeakers() {
        let app = launch(source: "both", outputRoute: "builtInSpeaker")
        record(app, expecting: "Recording the microphone and Mac audio")
        Wait.label(app.waitFor(AX.Recording.headphonesHint), equals: "Use headphones so the other side isn't recorded twice.")
        stop(app)
    }

    @MainActor func testFileMenuRecordsMacAudioOnlyAndRemembersIt() {
        let app = launch()
        recordFromMenu(app, macAudioOnly)
        app.waitFor(AX.Mac.recordingWindow)
        Wait.label(app.waitFor(AX.Recording.source), equals: "Recording Mac audio only")
        app.waitFor(AX.Recording.levelMeter)
        XCTAssertFalse(app.element(AX.Recording.levelMeterMic).exists, "Mac audio only has one meter")
        stop(app)

        // The choice is this Mac's setting now: the sidebar and Settings show it, and ⌘N uses it.
        Wait.label(app.waitFor(AX.Mac.sidebarNewRecording), contains: macAudioOnly)
        app.shortcut(",")
        Wait.label(app.waitFor(AX.RecordingSource.picker), contains: macAudioOnly)
    }

    @MainActor func testToolbarMenuStartsMacAudioOnly() {
        let app = launch()
        let menu = app.waitFor(AX.Mac.toolbarRecordSourceMenu)
        // A click records with the current source; holding opens the menu of sources.
        menu.press(forDuration: 1.0)
        let item = app.menuItems[macAudioOnly].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "The toolbar menu lists the sources")
        item.click()
        app.waitFor(AX.Mac.recordingWindow)
        Wait.label(app.waitFor(AX.Recording.source), equals: "Recording Mac audio only")
        stop(app)
    }

    @MainActor func testSourceControlsAreDisabledWhileRecording() {
        let app = launch(source: "both")
        record(app, expecting: "Recording the microphone and Mac audio")

        app.menuBars.menuBarItems["File"].click()
        let submenu = app.menuItems["Record From"].firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 5))
        XCTAssertFalse(submenu.isEnabled, "Record From is disabled while recording")
        app.typeKey(.escape, modifierFlags: [])

        app.shortcut(",")
        app.waitFor(AX.Settings.screen)
        let picker = app.waitFor(AX.RecordingSource.picker)
        Wait.enabled(picker, false)
        Wait.label(picker, contains: both)

        // Stop from the menu (the Settings window is in front), then the controls come back.
        app.shortcut(".")
        app.waitForGone(AX.Mac.toolbarRecordingPill, timeout: 15)
        Wait.enabled(picker, true)
    }

    // MARK: First use, permissions and notes

    @MainActor func testExplainerShowsOnceBeforeTheFirstMacAudioRecording() {
        let app = launch(source: "both", explained: false)
        app.shortcut("n")
        app.waitFor(AX.MacAudioExplainer.sheet)
        app.button(AX.MacAudioExplainer.cancel, title: "Cancel").click()
        app.waitForGone(AX.MacAudioExplainer.sheet)
        XCTAssertFalse(app.element(AX.Mac.recordingWindow).exists, "Cancel records nothing")

        app.shortcut("n")
        app.waitFor(AX.MacAudioExplainer.sheet)
        app.button(AX.MacAudioExplainer.continueButton, title: "Continue").click()
        app.waitForGone(AX.MacAudioExplainer.sheet)
        app.waitFor(AX.Mac.recordingWindow)
        Wait.label(app.waitFor(AX.Recording.source), equals: "Recording the microphone and Mac audio")
        stop(app)

        // Seen once: the next recording of Mac audio starts at once.
        record(app, expecting: "Recording the microphone and Mac audio")
        XCTAssertFalse(app.element(AX.MacAudioExplainer.sheet).exists)
        stop(app)
    }

    @MainActor func testMicrophoneOnlyNeverShowsTheExplainer() {
        let app = launch(explained: false)
        record(app, expecting: "Recording the microphone")
        XCTAssertFalse(app.element(AX.MacAudioExplainer.sheet).exists)
        stop(app)
    }

    @MainActor func testMicDeniedWhileRecordingBothOffersMacAudioOnly() {
        let app = launch(source: "both", mic: "denied")
        app.shortcut("n")
        app.waitFor(AX.Library.MicDenied.sheet)
        app.waitFor(AX.Library.MicDenied.importInstead)
        app.waitFor(AX.Library.MicDenied.macAudioOnly).click()
        app.waitForGone(AX.Library.MicDenied.sheet)
        app.waitFor(AX.Mac.recordingWindow)
        Wait.label(app.waitFor(AX.Recording.source), equals: "Recording Mac audio only")
        stop(app)
    }

    @MainActor func testMicDeniedWithTheMicrophoneOnlyHasNoMacAudioChoice() {
        let app = launch(mic: "denied")
        app.shortcut("n")
        app.waitFor(AX.Library.MicDenied.sheet)
        XCTAssertFalse(app.element(AX.Library.MicDenied.macAudioOnly).exists)
        app.element(AX.Library.MicDenied.close).click()
        app.waitForGone(AX.Library.MicDenied.sheet)
    }

    @MainActor func testSilentMacAudioShowsANoteWithPrivacySettings() {
        let app = launch(source: "macAudio", macAudio: "silent")
        record(app, expecting: "Recording Mac audio only")
        Wait.label(app.waitFor(AX.Recording.macAudioNote, timeout: 20),
                   equals: "No sound from Mac audio. If you turned off access, allow Transcribe in Privacy & Security.")
        // Not clicked: it would open System Settings.
        app.waitFor(AX.Recording.macAudioNoteOpenSettings)
        stop(app)
    }

    @MainActor func testLostMacAudioCarriesOnWithTheMicrophone() {
        let app = launch(source: "both", macAudio: "lost")
        record(app, expecting: "Recording the microphone and Mac audio")
        Wait.label(app.waitFor(AX.Recording.macAudioNote, timeout: 20), equals: "Mac audio stopped. Recording the microphone only.")
        XCTAssertFalse(app.element(AX.Recording.macAudioNoteOpenSettings).exists)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.textValue, timeout: 5)
        stop(app)
    }

    // MARK: The transcript

    /// A call recorded with both: the far speaker's chip carries the Mac audio glyph, and the speaker heard on both
    /// streams is named without being learned.
    @MainActor func testCallTranscriptShowsTheGlyphAndTheNotLearnedLine() {
        let app = launch(source: "both", script: "callVoices")
        record(app, expecting: "Recording the microphone and Mac audio")
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.textValue, timeout: 5)
        stop(app)
        app.waitFor(AX.Transcript.screen, timeout: 15)
        app.waitFor(AX.Transcript.turnChip(0), timeout: 15)

        // Which turns belong to which speaker is the script's business: look through the first turns.
        let turns = (0..<10).filter { app.element(AX.Transcript.turnChip($0)).exists }
        let withGlyph = turns.filter { app.element(AX.Transcript.turnSource($0)).exists }
        XCTAssertFalse(withGlyph.isEmpty, "A speaker heard through Mac audio has the glyph")
        XCTAssertLessThan(withGlyph.count, turns.count, "The local speaker has none")
        for i in withGlyph { Wait.label(app.element(AX.Transcript.turnSource(i)), equals: "Heard through Mac audio") }

        var sawNotLearned = false
        var seen = Set<String>()
        for i in turns where !withGlyph.contains(i) {
            let chip = app.element(AX.Transcript.turnChip(i))
            guard seen.insert(chip.textValue).inserted else { continue }
            chip.click()
            app.waitFor(AX.NameSpeaker.sheet)
            if app.element(AX.NameSpeaker.notLearned).waitForExistence(timeout: 2) {
                Wait.label(app.element(AX.NameSpeaker.notLearned), contains: "heard on both your microphone and Mac audio")
                XCTAssertFalse(app.element(AX.NameSpeaker.rememberToggle).exists, "Nothing to remember from a mixed voice")
                sawNotLearned = true
            }
            app.element(AX.NameSpeaker.closeButton).click()
            app.waitForGone(AX.NameSpeaker.sheet)
            if sawNotLearned { break }
        }
        XCTAssertTrue(sawNotLearned, "The speaker heard on both streams says it is not learned")
    }
}
