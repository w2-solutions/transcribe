import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// The old launch check wiped every voice when the install id changed (a restore onto another device). V3 replaces
/// it with `stampCaptureChannels()` (§6.4): a different device or install id must never delete anything.
@Suite("WP3: device reconcile (no wipe)")
@MainActor
struct DeviceReconcileTests {
    /// A second store over the same container and folder, as after a restore onto another device.
    func reopened(_ h: WP3Harness, device: String, channel: String = CaptureChannel.iphone) throws -> WP3Harness {
        try WP3Harness(device: device, container: h.container, paths: h.paths, channel: channel)
    }

    /// Everything the old wipe removed, counted.
    struct VoiceState: Equatable {
        var samples, negatives, vectors, coherences, traces, movedTraces, needsResample: Int
    }

    func voiceState(_ h: WP3Harness) throws -> VoiceState {
        let speakers = try h.context.fetch(FetchDescriptor<RecordingSpeaker>())
        return VoiceState(
            samples: try h.count(VoiceSample.self), negatives: try h.count(VoiceNegative.self),
            vectors: speakers.filter { $0.vectorData != nil }.count,
            coherences: speakers.filter { $0.vectorCoherence != nil }.count,
            traces: speakers.filter { $0.matchTraceData != nil }.count,
            movedTraces: try h.context.fetch(FetchDescriptor<Recording>()).filter { $0.movedSpeakerTracesData != nil }.count,
            needsResample: try h.context.fetch(FetchDescriptor<VoiceProfile>()).filter(\.needsResample).count)
    }

    @Test func firstLaunchRecordsTheDeviceWithoutWiping() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.library, stamp: false)
        #expect(try h.store.stampCaptureChannels() > 0)
        #expect(try h.store.stampCaptureChannels() == 0)
        #expect(try h.count(VoiceSample.self) == 5)
        #expect(h.store.storedDeviceID() == "phone-1")
    }

    @Test func anotherDeviceWipesNothing() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.library, stamp: false)
        _ = try h.store.stampCaptureChannels()
        let before = try voiceState(h)
        #expect(before.samples == 5 && before.vectors > 0)

        let restored = try reopened(h, device: "phone-2", channel: CaptureChannel.mac)
        #expect(try restored.store.stampCaptureChannels() == 0)
        #expect(try voiceState(restored) == before)
        // The stored id is informational: it still names the first device.
        #expect(restored.store.storedDeviceID() == "phone-1")
        // The rows keep the channel of the device that made them.
        #expect(try restored.context.fetch(FetchDescriptor<VoiceSample>()).allSatisfy { $0.captureChannel == CaptureChannel.iphone })
        #expect(try restored.recording(Seeds.ID.recordingA).sortedSpeakers.map(\.displayName) == ["Liam", "Karan"])

        let candidates = try restored.store.matchCandidates(modelKey: EmbeddingModelID.fake.key)
        #expect(candidates.count == 2 && candidates.allSatisfy { !$0.needsResample && !$0.samples.isEmpty })
    }

    @Test func anotherDeviceKeepsNegativesTracesAndCoherence() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.askKaran, stamp: false)
        _ = try h.store.stampCaptureChannels()
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        let id = try h.separatedRecording(turns: SeedContent.conversationB, drafts: [
            WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .liam, cosine: 0.85, variant: 44)),
            WP3Docs.draft("S2", 2, clean: 11, vector: SyntheticVoices.vector(near: .karan, cosine: 0.8, variant: 45))])
        try h.matchLikeThePipeline(id)
        try h.store.moveAllTurns(recordingID: id, from: "S1", to: "S2")   // keeps S1's trace on the recording
        let before = try voiceState(h)
        #expect(before.negatives == 2 && before.traces > 0 && before.coherences > 0 && before.movedTraces == 1)

        let restored = try reopened(h, device: "phone-2")
        _ = try restored.store.stampCaptureChannels()
        #expect(try voiceState(restored) == before)
    }

    @Test func anUnknownIdentityRecordsNothingAndWipesNothing() throws {
        let h = try WP3Harness(device: "")
        defer { h.cleanup() }
        try h.seed(.library, stamp: false)
        _ = try h.store.stampCaptureChannels()
        #expect(h.store.storedDeviceID() == nil)
        #expect(try h.count(VoiceSample.self) == 5)

        let unlocked = try reopened(h, device: "phone-1")
        _ = try unlocked.store.stampCaptureChannels()
        #expect(unlocked.store.storedDeviceID() == "phone-1")
        #expect(try unlocked.count(VoiceSample.self) == 5)
    }

    /// Writes to the login Keychain, so it only runs when asked: TRANSCRIBE_KEYCHAIN_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIBE_KEYCHAIN_TESTS"] == "1"))
    func keychainIdentityIsStable() {
        let identity = KeychainDeviceIdentity(service: "ai.w2solutions.transcribe.tests.\(UUID().uuidString)", account: "install-id")
        defer { identity.reset() }
        let first = identity.installID()
        #expect(UUID(uuidString: first) != nil)
        #expect(identity.installID() == first)
        identity.reset()
        let second = identity.installID()
        #expect(UUID(uuidString: second) != nil && second != first)
    }
}
