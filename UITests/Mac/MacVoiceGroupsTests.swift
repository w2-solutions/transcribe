import XCTest

/// Voice sample groups (§7) on the Mac: Tom's voice in the detail column with the `voiceGroups` seed, channel `mac`.
/// Tom's ten samples by `sortedSamples` index: Close {0, 1, 5} (labelled, plays sample 0), Group 2 {2, 3, 4}, Group 3
/// {6, 7} on this Mac, and {8, 9} on an iPad (its only group, unlabelled, so no group header). Sample 3's recording is
/// gone, sample 4 has no clip, and the iPad samples' audio stayed on the iPad.
final class MacVoiceGroupsTests: FlowTestCase {
    private let channel = "mac"

    @MainActor private func launchTom() -> XCUIApplication {
        let app = UITestApp.launch(seed: "voiceGroups", route: "voice:Tom", channel: channel)
        app.waitFor(AX.VoiceDetail.screen, timeout: 20)
        Wait.label(app.waitFor(AX.VoiceDetail.name), equals: "Tom")
        return app
    }

    @MainActor func testGroupsAndSavedLabelShow() {
        let app = launchTom()
        Wait.label(app.waitFor(AX.VoiceDetail.samplesNote), contains: "Samples that sound alike are grouped")
        Wait.label(app.waitFor(AX.Voices.sampleGroup(channel)), equals: "On this Mac · 8")
        Wait.label(app.waitFor(AX.VoiceDetail.group(channel, 0)), equals: "Close · 3")
        Wait.label(app.waitFor(AX.VoiceDetail.group(channel, 1)), equals: "Group 2 · 3")
        Wait.label(app.waitFor(AX.VoiceDetail.group(channel, 2)), equals: "Group 3 · 2")
        XCTAssertFalse(app.element(AX.VoiceDetail.group(channel, 3)).exists, "Three groups on this Mac")
        Wait.label(app.waitFor(AX.VoiceDetail.groupSubtitle(channel, 0)), equals: "From \u{201C}Kitchen chat\u{201D}")
        Wait.label(app.waitFor(AX.VoiceDetail.groupLabelButton(channel, 0)), equals: "Edit label Close")
        Wait.label(app.waitFor(AX.VoiceDetail.groupLabelButton(channel, 1)), equals: "Label Group 2")

        // The iPad's only group is unlabelled: its channel header and rows, with no group header.
        Wait.label(app.waitFor(AX.Voices.sampleGroup("ipad")), equals: "On your iPad · 2")
        app.waitFor(AX.VoiceDetail.sample(9))
        XCTAssertFalse(app.element(AX.VoiceDetail.group("ipad", 0)).exists, "A channel's sole unlabelled group has no header")
        XCTAssertFalse(app.element(AX.VoiceDetail.ungrouped(channel)).exists, "Every sample is grouped")
        app.assertCount(10, of: AX.VoiceDetail.sample)
    }

    @MainActor func testLabelAGroup() {
        let app = launchTom()
        app.scrollTo(AX.VoiceDetail.groupLabelButton(channel, 1)).click()
        let field = app.dialogTextField(AX.VoiceDetail.GroupLabel.field)
        field.click()
        field.typeText("Far")
        Wait.check(field, "the label field to read Far") { ($0.value as? String) == "Far" }
        app.button(AX.VoiceDetail.GroupLabel.save, title: "Save").click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "The alert closes")

        Wait.label(app.element(AX.VoiceDetail.group(channel, 1)), equals: "Far · 3")
        Wait.label(app.element(AX.VoiceDetail.groupLabelButton(channel, 1)), equals: "Edit label Far")
        Wait.label(app.element(AX.VoiceDetail.group(channel, 0)), equals: "Close · 3")
        Wait.label(app.element(AX.VoiceDetail.group(channel, 2)), equals: "Group 3 · 2")

        // The label is saved in the library: leaving Tom's voice and opening it again still shows it. (A UI-test
        // launch has an in-memory library, so a relaunch cannot check this; the store tests cover the save.)
        app.waitFor(AX.Voices.profile("liam")).click()
        Wait.label(app.element(AX.VoiceDetail.name), equals: "Liam")
        app.waitFor(AX.Voices.profile("tom")).click()
        Wait.label(app.waitFor(AX.VoiceDetail.name), equals: "Tom")
        Wait.label(app.waitFor(AX.VoiceDetail.group(channel, 1)), equals: "Far · 3")
        Wait.label(app.waitFor(AX.VoiceDetail.group(channel, 0)), equals: "Close · 3")
    }

    @MainActor func testRemoveLabel() {
        let app = launchTom()
        app.scrollTo(AX.VoiceDetail.groupLabelButton(channel, 0)).click()
        let field = app.dialogTextField(AX.VoiceDetail.GroupLabel.field)
        Wait.check(field, "the field to be prefilled with Close") { ($0.value as? String) == "Close" }
        app.button(AX.VoiceDetail.GroupLabel.remove, title: "Remove Label").click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "The alert closes")

        Wait.label(app.element(AX.VoiceDetail.group(channel, 0)), equals: "Group 1 · 3")
        Wait.label(app.element(AX.VoiceDetail.groupLabelButton(channel, 0)), equals: "Label Group 1")
        Wait.label(app.element(AX.VoiceDetail.group(channel, 1)), equals: "Group 2 · 3")
    }

    @MainActor func testPlayGroup() {
        let app = launchTom()
        let play = app.scrollTo(AX.VoiceDetail.groupPlay(channel, 0))
        Wait.label(play, equals: "Play a clip from Close")
        play.click()
        Wait.label(play, contains: "Pause", timeout: 3)
        // The group plays its first representative, sample 0 (4.45 s from “Kitchen chat”).
        Wait.label(app.element(AX.VoiceDetail.samplePlay(0)), contains: "Pause sample")
        play.click()
        Wait.label(play, equals: "Play a clip from Close")
    }

    @MainActor func testHonestStates() {
        let app = launchTom()
        Wait.label(app.waitFor(AX.VoiceDetail.samplePlay(0)), contains: "Play sample: ")
        Wait.label(app.waitFor(AX.VoiceDetail.samplePlay(3)), contains: "Recording deleted")
        Wait.label(app.waitFor(AX.VoiceDetail.samplePlay(4)), contains: "No clip saved")
        Wait.label(app.waitFor(AX.VoiceDetail.samplePlay(8)), contains: "Audio is on your iPad")
        Wait.label(app.waitFor(AX.VoiceDetail.samplePlay(9)), contains: "Audio is on your iPad")
        // A playable sample never reads as unavailable.
        let first = app.element(AX.VoiceDetail.samplePlay(0)).textValue
        for caption in ["Recording deleted", "No clip saved", "Audio is on"] {
            XCTAssertFalse(first.contains(caption), "Sample 0 can play: \(first)")
        }
    }
}
