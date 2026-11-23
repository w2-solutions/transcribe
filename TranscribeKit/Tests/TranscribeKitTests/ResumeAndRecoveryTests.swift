import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("WP3: resume and recovery")
@MainActor
struct ResumeAndRecoveryTests {
    @Test func resumeFromTranscribedSkipsTranscribe() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        try p.h.store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(SeedContent.conversationB))
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
        #expect(await p.engine.callCount("transcribe") == 0)
        #expect(await p.engine.callCount("separateSpeakers") == 1)
        // The first snapshot of the resumed job already shows step 1 done.
        let firstRunning = p.snapshots(id).first { $0.phase == .running }
        #expect(firstRunning?.steps.first?.state == .done)
    }

    @Test func resumeFromSeparatedOnlyMatches() async throws {
        let p = try await WP3Pipeline(.knownVoices, seed: .library)
        defer { p.cleanup() }
        let id = try p.record()
        try p.h.store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(SeedContent.conversationA))
        try p.h.store.checkpointSeparation(id: id, document: WP3Docs.speakers(SeedContent.conversationA), speakers: [
            WP3Docs.draft("S1", 1, clean: 14, turns: 2, vector: SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 3)),
            WP3Docs.draft("S2", 2, clean: 4.6, vector: SyntheticVoices.vector(near: .karan, cosine: 0.71, variant: 4)),
        ])
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(autoLabelled: 2)) && final.voicesFound == 2)
        #expect(await p.engine.callCount("transcribe") == 0)
        #expect(await p.engine.callCount("separateSpeakers") == 0)
    }

    @Test func cancelDuringSeparatingLeavesTranscribed() async throws {
        let p = try await WP3Pipeline(.holdAtSeparating, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        await p.coordinator.enqueue(id)
        #expect(await p.waitForSeparation())
        #expect(await wp3WaitFor { (try? p.h.recording(id).stage) == .separating })
        #expect(await wp3WaitFor { p.monitor.snapshot(for: id)?.steps.map(\.axValue) == ["done", "inProgress", "waiting"] })
        #expect(p.monitor.snapshot(for: id)?.stepCounterText == "Step 2 of 3")
        // The last progress report (0.6) reaches the monitor even though nothing follows it.
        #expect(await wp3WaitFor { p.monitor.snapshot(for: id)?.steps[1].state == .active(fraction: 0.6) })
        #expect(p.monitor.snapshot(for: id)?.steps[1].subtitle == "Listening for different voices · 60%")

        await p.coordinator.suspendForCapture()
        await p.coordinator.waitUntilIdle()
        let r = try p.h.recording(id)
        #expect(r.stage == .transcribed && r.queueReason == .pausedForRecording && r.transcript != nil)
        #expect(r.attemptCount == 0)
        #expect(await wp3WaitFor { p.monitor.snapshot(for: id)?.phase == .queued(.pausedForRecording) })
        #expect(p.monitor.snapshot(for: id)?.steps.map(\.axValue) == ["done", "waiting", "waiting"])
        #expect(p.background.endResults == [false])
        #expect(await p.coordinator.queuedIDs == [id])
    }

    @Test func capturePreemptionParksAndResumesTheJob() async throws {
        let p = try await WP3Pipeline(.holdAtSeparating, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        await p.coordinator.enqueue(id)
        #expect(await p.waitForSeparation())
        await p.coordinator.suspendForCapture()
        #expect(await p.coordinator.runningID == nil)

        // Nothing starts while capture is active.
        let during = try p.record()
        await p.coordinator.enqueue(during)
        await p.coordinator.waitUntilIdle()
        #expect(try p.h.recording(during).queueReason == .pausedForRecording)
        #expect(await p.engine.callCount("transcribe") == 1)

        await p.coordinator.resumeAfterCapture()
        // The parked job resumes first, at separation, without transcribing again.
        #expect(await wp3WaitFor { await p.engine.callCount("separateSpeakers") >= 2 })
        #expect(await p.coordinator.runningID == id)
        #expect(await p.engine.callCount("transcribe") == 1)
        #expect(await p.engine.maxConcurrentCalls == 1)
        await p.coordinator.cancel(id)
        await p.coordinator.cancel(during)
    }

    @Test func captureThenStopRunsTheNewRecording() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        await p.coordinator.suspendForCapture()
        let id = try p.record()
        await p.coordinator.resumeAfterCapture()
        let final = try #require(await p.run(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
    }

    @Test func killDuringSeparatingThenRelaunchResumesAtSeparation() async throws {
        // processingHeld = what the store holds after the app died during `holdAtSeparating`:
        // stage .separating, paragraphs saved, no speakers.
        let h = try WP3Harness()
        defer { h.cleanup() }
        try h.seed(.processingHeld)
        let p = try await WP3Pipeline(.newVoices, harness: h)
        await p.coordinator.recoverOnLaunch()
        let final = try #require(await p.settle(Seeds.ID.recordingE))
        #expect(final.phase == .finished(ProcessingOutcome(autoLabelled: 2)))
        #expect(await p.engine.callCount("transcribe") == 0)
        #expect(await p.engine.callCount("separateSpeakers") == 1)
        let r = try h.recording(Seeds.ID.recordingE)
        #expect(r.stage == .ready && r.sortedSpeakers.map(\.displayName) == ["Liam", "Karan"])
    }

    @Test func aRunTheOSKillsCountsAsAnAttemptAndRecoveryGivesUpAfterThree() async throws {
        let h = try WP3Harness()
        defer { h.cleanup() }
        let script = FakeScript.named(.holdAtSeparating)
        let heavy = try h.queuedRecording(createdAt: Seeds.Dates.a, script: script, writeAudio: true)
        let later = try h.queuedRecording(createdAt: Seeds.Dates.d, script: FakeScript.named(.newVoices), writeAudio: true)
        // Three launches, each killed mid-separation: the process dies, so nothing after the kill is written.
        for launch in 1...3 {
            let p = try await WP3Pipeline(.holdAtSeparating, harness: h)
            if launch == 1 { await p.coordinator.enqueue(heavy) } else { await p.coordinator.recoverOnLaunch() }
            #expect(await p.waitForSeparation())
            #expect(await p.coordinator.runningID == heavy)        // oldest first, every launch
            #expect(try h.recording(heavy).attemptCount == launch)
            await p.coordinator.cancel(heavy)                      // stands in for the kill: no store writes follow
            await p.coordinator.cancel(later)
            await p.coordinator.waitUntilIdle()
            #expect(try h.recording(heavy).attemptCount == launch)
        }
        // The fourth launch gives up on it and gets on with the next recording.
        let p = try await WP3Pipeline(.newVoices, harness: h)
        await p.coordinator.recoverOnLaunch()
        let final = try #require(await p.settle(later))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
        let r = try h.recording(heavy)
        #expect(r.stage == .failed && r.failureMessage == "Couldn't finish processing")
        #expect(try h.recording(later).stage == .ready && h.recording(later).attemptCount == 0)
        #expect(await p.engine.callCount("separateSpeakers") == 1)
    }

    @Test func preemptionGivesTheAttemptBack() async throws {
        let p = try await WP3Pipeline(.holdAtSeparating, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        await p.coordinator.enqueue(id)
        #expect(await p.waitForSeparation())
        #expect(try p.h.recording(id).attemptCount == 1)
        p.background.expireLatest()
        #expect(await wp3WaitFor { (try? p.h.recording(id).queueReason) == .pausedByBackgroundExpiry })
        await p.coordinator.waitUntilIdle()
        #expect(try p.h.recording(id).attemptCount == 0)
    }

    @Test func backgroundExpiryParksTheJobUntilTheAppIsActive() async throws {
        let p = try await WP3Pipeline(.holdAtSeparating, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        await p.coordinator.enqueue(id)
        #expect(await p.waitForSeparation())
        p.background.expireLatest()
        #expect(await wp3WaitFor { (try? p.h.recording(id).queueReason) == .pausedByBackgroundExpiry })
        await p.coordinator.waitUntilIdle()
        #expect(try p.h.recording(id).stage == .transcribed)
        #expect(await p.coordinator.runningID == nil && p.background.endResults == [false])
        #expect(await wp3WaitFor { p.monitor.snapshot(for: id)?.phase == .queued(.pausedByBackgroundExpiry) })

        await p.coordinator.appBecameActive()
        #expect(await wp3WaitFor { await p.engine.callCount("separateSpeakers") >= 2 })
        #expect(await p.engine.callCount("transcribe") == 1)
        await p.coordinator.cancel(id)
    }

    // MARK: RecoveryPlanner

    nonisolated static let planCases: [(RecordingStage, Int, Bool, String)] = [
        (.capturing, 0, true, "repair"),
        (.capturing, 0, false, "discard"),
        (.queued, 0, false, "fail:Audio file is missing"),
        (.separating, 3, false, "fail:Audio file is missing"),
        (.transcribing, 3, true, "fail:Couldn't finish processing"),
        (.matching, 4, true, "fail:Couldn't finish processing"),
        (.queued, 0, true, "requeue"),
        (.transcribed, 2, true, "requeue"),
        (.separated, 1, true, "requeue"),
        (.ready, 0, true, "none"),
        (.failed, 3, true, "none"),
    ]

    @Test(arguments: planCases)
    func recoveryPlannerTable(_ c: (RecordingStage, Int, Bool, String)) {
        let id = UUID()
        let snap = RecoverySnapshot(id: id, stage: c.0, audioFileName: "a.wav", attemptCount: c.1,
                                    hasTranscript: c.0 >= .transcribed, audioExists: c.2)
        let expected: RecoveryAction? = switch c.3 {
        case "repair": .repairAndQueue(id)
        case "discard": .discard(id)
        case "requeue": .requeue(id)
        case "none": nil
        default: .fail(id, message: String(c.3.dropFirst(5)))
        }
        #expect(RecoveryPlanner.action(for: snap) == expected)
        #expect(RecoveryPlanner.plan([snap]) == (expected.map { [$0] } ?? []))
    }

    @Test func plannerKeepsInputOrder() {
        let ids = (0..<3).map { _ in UUID() }
        let snaps = ids.map { RecoverySnapshot(id: $0, stage: .queued, audioFileName: "a", attemptCount: 0, hasTranscript: false, audioExists: true) }
        #expect(RecoveryPlanner.plan(snaps).map(\.recordingID) == ids)
    }

    // MARK: recoverOnLaunch

    @Test func recoverOnLaunchRepairsAnInterruptedCapture() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        let id = UUID()
        let fileName = p.h.paths.newAudioFileName(for: id)
        try p.h.store.createRecording(id: id, createdAt: Seeds.Dates.d, audioFileName: fileName, source: .microphone)
        let url = p.h.paths.audioURL(fileName: fileName)
        _ = try SyntheticAudio.write(to: url, duration: 24, segments: p.script.audioSegments)
        // A crash before the final header patch: sizes are zero and the last frame is cut in half.
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 4); try handle.write(contentsOf: Data(count: 4))
        try handle.seek(toOffset: 40); try handle.write(contentsOf: Data(count: 4))
        try handle.truncate(atOffset: UInt64(44 + 24 * 16_000 * 2 - 1))
        try handle.close()

        await p.coordinator.recoverOnLaunch()
        let final = try #require(await p.settle(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
        let r = try p.h.recording(id)
        #expect(abs(r.duration - 24) < 0.01 && r.peaks.count == 200 && r.peaks.contains { $0 > 0 })
        #expect(r.stage == .ready)
    }

    @Test func recoverOnLaunchDiscardsFailsAndRequeues() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        // Capture with no audio at all → discarded.
        let noAudio = UUID()
        try p.h.store.createRecording(id: noAudio, createdAt: Seeds.Dates.d, audioFileName: "gone.wav", source: .microphone)
        // Capture with under a second of audio → discarded.
        let tiny = UUID()
        let tinyName = p.h.paths.newAudioFileName(for: tiny)
        try p.h.store.createRecording(id: tiny, createdAt: Seeds.Dates.d, audioFileName: tinyName, source: .microphone)
        _ = try SyntheticAudio.write(to: p.h.paths.audioURL(fileName: tinyName), duration: 0.5, segments: [])
        // Queued but its audio vanished → failed.
        let lost = try p.h.queuedRecording()
        // Gave up already → failed.
        let tired = try p.record()
        for _ in 0..<3 { _ = try p.h.store.incrementAttempt(id: tired) }
        // Waiting at a checkpoint → finished.
        let waiting = try p.record()

        await p.coordinator.recoverOnLaunch()
        _ = await p.settle(waiting)
        #expect(throws: StoreError.self) { try p.h.store.snapshot(of: noAudio) }
        #expect(throws: StoreError.self) { try p.h.store.snapshot(of: tiny) }
        #expect(!FileManager.default.fileExists(atPath: p.h.paths.audioURL(fileName: tinyName).path))
        #expect(try p.h.recording(lost).stage == .failed && p.h.recording(lost).failureMessage == "Audio file is missing")
        #expect(try p.h.recording(tired).stage == .failed && p.h.recording(tired).failureMessage == "Couldn't finish processing")
        #expect(try p.h.recording(waiting).stage == .ready)
        #expect(await p.engine.callCount("transcribe") == 1)
    }
}
