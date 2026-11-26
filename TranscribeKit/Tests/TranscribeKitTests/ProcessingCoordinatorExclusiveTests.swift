import Foundation
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// The exclusive engine hold dictation takes (`acquireExclusiveEngine`).
@Suite("ProcessingCoordinator: exclusive engine hold")
@MainActor
struct ProcessingCoordinatorExclusiveTests {
    @Test func acquireWithNoJob() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        let hold = await p.coordinator.acquireExclusiveEngine()
        #expect(!hold.preemptedJob)
        #expect(await p.coordinator.exclusiveHoldCount == 1)
        await p.coordinator.releaseExclusiveEngine(hold)
        await p.coordinator.releaseExclusiveEngine(hold)   // twice: nothing more
        #expect(await p.coordinator.exclusiveHoldCount == 0)
    }

    @Test func aRunningJobIsPreemptedAndWaitsForItsTurn() async throws {
        let p = try await WP3Pipeline(.holdAtSeparating, seed: .empty)
        defer { p.cleanup() }
        let id = try p.record()
        await p.coordinator.enqueue(id)
        #expect(await p.waitForSeparation())

        let hold = await p.coordinator.acquireExclusiveEngine()
        #expect(hold.preemptedJob)
        // Returned only once the job's engine call had ended.
        #expect(await p.coordinator.runningID == nil)
        #expect(await p.coordinator.queuedIDs == [id])
        await p.coordinator.waitUntilIdle()
        let r = try p.h.recording(id)
        #expect(r.stage == .transcribed && r.queueReason == .waitingForTurn)
        #expect(r.attemptCount == 0, "the attempt is given back")
        #expect(await dictationWait { p.monitor.snapshot(for: id)?.phase == .queued(.waitingForTurn) })
        #expect(!p.snapshots(id).contains { $0.phase == .queued(.pausedForRecording) })

        await p.coordinator.releaseExclusiveEngine(hold)
        // Back at its checkpoint: separation again, no second transcription.
        #expect(await dictationWait { await p.engine.callCount("separateSpeakers") == 2 })
        #expect(await p.coordinator.runningID == id)
        #expect(await p.engine.callCount("transcribe") == 1)
        #expect(await p.engine.maxConcurrentCalls == 1)
        await p.coordinator.cancel(id)
    }

    @Test func noJobStartsWhileHeldAndWaitUntilIdleReturns() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        let hold = await p.coordinator.acquireExclusiveEngine()
        let id = try p.record()
        await p.coordinator.enqueue(id)
        await p.coordinator.waitUntilIdle()   // returns while held: the queue is blocked
        #expect(await p.coordinator.runningID == nil)
        #expect(await p.coordinator.queuedIDs == [id])
        #expect(try p.h.recording(id).queueReason == .waitingForTurn)
        #expect(await p.engine.callCount("transcribe") == 0)

        await p.coordinator.releaseExclusiveEngine(hold)
        let final = try #require(await p.settle(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
    }

    @Test func holdsNest() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        let first = await p.coordinator.acquireExclusiveEngine()
        let second = await p.coordinator.acquireExclusiveEngine()
        #expect(first != second)
        let id = try p.record()
        await p.coordinator.enqueue(id)
        await p.coordinator.releaseExclusiveEngine(first)
        await p.coordinator.waitUntilIdle()
        #expect(await p.coordinator.runningID == nil)
        #expect(await p.engine.callCount("transcribe") == 0)
        await p.coordinator.releaseExclusiveEngine(second)
        let final = try #require(await p.settle(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
    }

    @Test func aReleaseDuringCaptureWaitsForTheCaptureToEnd() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        await p.coordinator.suspendForCapture()
        let hold = await p.coordinator.acquireExclusiveEngine()
        let id = try p.record()
        await p.coordinator.enqueue(id)
        await p.coordinator.releaseExclusiveEngine(hold)
        await p.coordinator.waitUntilIdle()
        #expect(await p.coordinator.runningID == nil)
        #expect(await p.engine.callCount("transcribe") == 0)
        #expect(try p.h.recording(id).queueReason == .pausedForRecording)
        await p.coordinator.resumeAfterCapture()
        let final = try #require(await p.settle(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
    }

    @Test func aCaptureEndingDuringAHoldDoesNotStartJobs() async throws {
        let p = try await WP3Pipeline(.newVoices, seed: .empty)
        defer { p.cleanup() }
        await p.coordinator.suspendForCapture()
        let hold = await p.coordinator.acquireExclusiveEngine()
        let id = try p.record()
        await p.coordinator.enqueue(id)
        await p.coordinator.resumeAfterCapture()
        await p.coordinator.waitUntilIdle()
        #expect(await p.engine.callCount("transcribe") == 0)
        await p.coordinator.releaseExclusiveEngine(hold)
        let final = try #require(await p.settle(id))
        #expect(final.phase == .finished(ProcessingOutcome(unnamed: 2)))
    }
}
