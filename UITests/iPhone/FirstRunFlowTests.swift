import XCTest

/// First launch: the models ship in the app; only the on-device setup runs (`firstRun`: fake models `missing`, a
/// slow first prepare, 20 s at `demo` speed, short steps first: voice recognition 0.5 s, speaker separation 0.5 s,
/// transcription 19 s). The Library shows the setup card from 1.5 s into setup until it is ready.
final class FirstRunFlowTests: FlowTestCase {
    private let headline = AX.Setup.id(AX.Setup.library, .headline)
    private let step = AX.Setup.id(AX.Setup.library, .step)
    private let progress = AX.Setup.id(AX.Setup.library, .progress)

    /// The setup bar's value, "34%" → 34 (-1 when unreadable).
    @MainActor private func percent(_ element: XCUIElement) -> Int {
        Int(((element.value as? String) ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
    }

    /// Every query here costs about a second on a simulator clone, and setup lasts 20 s, so each element is read
    /// once (no separate wait before a label check) and the step 3 check, the longest stage (19 s), comes last.
    @MainActor func testFirstLaunchShowsSetupProgress() {
        let app = UITestApp.launch(seed: "firstRun", speed: "demo")
        app.waitFor(AX.Library.modelsCard, timeout: 20)
        Wait.label(app.element(headline), contains: "Getting ready on this iPhone")
        // Steps 1 and 2 last 1 s together, before the card shows; then "Setting up transcription" (no step count).
        Wait.label(app.element(step), contains: "Setting up")
        // A first install has no times measured on this device: the hedged line, never a time left.
        Wait.label(app.element(AX.Setup.id(AX.Setup.library, .typicalTime)), contains: "can take a little while")
        XCTAssertFalse(app.element(AX.Setup.id(AX.Setup.library, .timeLeft)).exists, "No time left on a first install")
        Wait.label(app.element(AX.Setup.id(AX.Setup.library, .recordNote)), contains: "You can record now")
        XCTAssertFalse(app.element(AX.Library.modelsDownloadButton).exists, "Nothing to download")

        let bar = app.element(progress)
        let first = percent(bar)
        XCTAssertGreaterThanOrEqual(first, 0, "The bar reads as a percentage: \(String(describing: bar.value))")
        Wait.check(bar, "the bar moves on from \(first)%", timeout: 6) { self.percent($0) > first }

        Wait.check(app.element(step), "the transcription step, with no step count", timeout: 15) {
            $0.label.contains("Setting up transcription") && !$0.label.contains("Step")
        }

        // Ready: the card says so briefly, then goes.
        app.waitForGone(AX.Library.modelsCard, timeout: 30)
        app.waitFor(AX.Library.settingsButton).press()
        app.waitFor(AX.Settings.screen)
        Wait.label(app.waitFor(AX.Settings.modelRow), contains: "Parakeet", timeout: 10)
    }

    /// A recording made during setup waits, says so, then finishes on its own once setup is done.
    @MainActor func testRecordingWaitsForFirstPrepare() {
        let app = UITestApp.launch(seed: "firstRun", script: "newVoices", speed: "demo")
        app.waitFor(AX.Library.recordButton, timeout: 20).press()
        app.waitFor(AX.Recording.screen)
        Wait.label(app.waitFor(AX.Recording.liveTextNote), contains: "Live text starts when setup finishes.")
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.label, timeout: 5)
        app.element(AX.Recording.stopButton).press()

        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Processing.heading), contains: "Waiting for setup to finish")
        app.waitFor(AX.Setup.id(AX.Setup.processing, .progress))

        // Back on the Library the setup card counts it and the recording's card waits too. Both are read in one
        // check: on a slow simulator clone setup may be close to done by now.
        app.goBack()
        let status = app.element(AX.Library.cardStatus(0))
        Wait.check(app.waitFor(AX.Setup.id(AX.Setup.library, .waitingNote)), "the waiting recording is counted") { note in
            note.label.contains("1 recording will be processed when setup finishes.")
                && status.exists && status.label.contains("Waiting for setup")
        }

        // The waiting recording then finishes on its own with two unnamed speakers.
        app.waitFor(AX.Library.cardNameLink(0), timeout: 45)
        app.waitForGone(AX.Library.modelsCard, timeout: 10)
        app.openCard(0)
        app.waitFor(AX.Transcript.screen)
        Wait.label(app.waitFor(AX.Transcript.newVoicesBanner), contains: "2 new voices", timeout: 10)
    }

    /// While a recording waits for setup nothing of it has started: no step row spins, the setup line is labelled
    /// as setup, the transcript placeholder does not promise "a moment", and the leave button says where it goes.
    /// Its own test, so these reads (about a second each) do not delay the Library checks above past the setup.
    @MainActor func testAWaitingRecordingShowsThatNothingHasStarted() {
        let app = UITestApp.launch(seed: "firstRun", script: "newVoices", speed: "demo")
        app.waitFor(AX.Library.recordButton, timeout: 20).press()
        app.waitFor(AX.Recording.screen)
        let elapsed = app.waitFor(AX.Recording.elapsed)
        Wait.label(elapsed, changesFrom: elapsed.label, timeout: 5)
        app.element(AX.Recording.stopButton).press()
        Wait.label(app.waitFor(AX.Processing.heading), contains: "Waiting for setup to finish")
        // One snapshot of the whole screen, read at once: element queries take a second or more each here, and
        // setup would be over before a chain of them finished.
        guard let screen = try? app.snapshot() else { return XCTFail("No accessibility snapshot") }
        func find(_ id: String, in node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if node.identifier == id { return node }
            for child in node.children { if let hit = find(id, in: child) { return hit } }
            return nil
        }
        func text(_ id: String) -> String { find(id, in: screen).map { "\($0.label)|\($0.value ?? "")" } ?? "<missing>" }
        XCTAssertTrue(text(AX.Processing.heading).contains("Waiting for setup to finish"),
                      "still waiting when read: \(text(AX.Processing.heading))")
        for slug in ["transcribing", "separating", "matching"] {
            XCTAssertEqual(find(AX.Processing.step(slug), in: screen)?.value as? String, "waiting", "\(slug) waits")
        }
        XCTAssertTrue(text(AX.Processing.continueInBackground).contains("Back to Recordings"),
                      text(AX.Processing.continueInBackground))
        XCTAssertTrue(text(AX.Transcript.pendingPlaceholder).contains("Transcribing starts when setup finishes."),
                      text(AX.Transcript.pendingPlaceholder))
        XCTAssertTrue(text(AX.Setup.id(AX.Setup.processing, .step)).contains("Setup in progress"),
                      text(AX.Setup.id(AX.Setup.processing, .step)))
        // Then it is processed on its own.
        app.waitForGone(AX.Setup.id(AX.Setup.processing, .progress), timeout: 40)
    }

    /// A relaunch of the same install prepares warm (well under the reveal delay): no card, no flash.
    @MainActor func testWarmLaunchShowsNoSetupCard() {
        let app = UITestApp.launch(seed: "library", speed: "demo")
        app.waitFor(AX.Library.card(0), timeout: 20)
        let card = app.element(AX.Library.modelsCard)
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: card)
        XCTAssertEqual(XCTWaiter().wait(for: [appeared], timeout: 3), .timedOut, "No setup card on a warm launch")
        app.waitFor(AX.Library.settingsButton).press()
        Wait.label(app.waitFor(AX.Settings.modelRow), contains: "Parakeet")
    }

    /// Leaving mid-setup: setup pauses while away and carries on from where it was on return.
    ///
    /// The app holds a short background task while it prepares, and the simulator grants it (about 30 s), so the
    /// running stage keeps going while the app is away. The simulator build has no Background Inference, so, as on a
    /// phone without it, a Neural Engine stage that ran while the app was away is dropped and setup pauses. The app
    /// leaves during transcription (step 3, 19 s), the long stage, and comes back before it ends; the stage then
    /// ends in front, is dropped, and setup carries on at once, warm ("Carrying on where it left off." shows only
    /// briefly, with the share of the bar earned so far kept), so the card may already be gone when it is checked.
    @MainActor func testSetupCarriesOnAfterLeaving() {
        let app = UITestApp.launch(seed: "firstRun", speed: "demo")
        app.waitFor(AX.Library.modelsCard, timeout: 20)
        Wait.label(app.element(step), contains: "Setting up transcription")
        XCUIDevice.shared.press(.home)
        // Away for a while (the short task keeps the app running meanwhile; it is not suspended).
        _ = app.wait(for: .runningBackgroundSuspended, timeout: 10)
        app.activate()

        let resumed = app.element(AX.Setup.id(AX.Setup.library, .resumedNote))
        let card = app.element(AX.Library.modelsCard)
        let either = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { resumed.exists || !card.exists }
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [either], timeout: 20), .completed, "setup carried on after the return")
        if resumed.exists {
            XCTAssertTrue(resumed.label.contains("Carrying on where it left off."))
            let after = percent(app.element(progress))
            XCTAssertGreaterThanOrEqual(after, 25, "The work done before leaving is kept (\(after)%)")
        }
        app.waitForGone(AX.Library.modelsCard, timeout: 40)
        app.waitFor(AX.Library.settingsButton).press()
        Wait.label(app.waitFor(AX.Settings.modelRow), contains: "Parakeet", timeout: 10)
    }
}
