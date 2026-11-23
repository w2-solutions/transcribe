import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

@Suite("WP3: device reconcile")
@MainActor
struct DeviceReconcileTests {
    /// A second store over the same container and folder, as after a restore onto another phone.
    func reopened(_ h: WP3Harness, device: String) throws -> WP3Harness {
        try WP3Harness(device: device, container: h.container, paths: h.paths)
    }

    @Test func firstLaunchRecordsTheDeviceWithoutWiping() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.library)
        #expect(try h.store.reconcileDevice() == false)
        #expect(try h.store.reconcileDevice() == false)
        #expect(try h.count(VoiceSample.self) == 5)
        #expect(h.store.storedDeviceID() == "phone-1")
    }

    @Test func anotherDeviceWipesSamplesAndTheMatcherExcludesTheProfiles() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.library)
        _ = try h.store.reconcileDevice()

        let restored = try reopened(h, device: "phone-2")
        #expect(try restored.store.reconcileDevice() == true)
        #expect(try restored.count(VoiceSample.self) == 0)
        let profiles = try restored.context.fetch(FetchDescriptor<VoiceProfile>())
        #expect(profiles.count == 2 && profiles.allSatisfy { $0.needsResample && $0.samples.isEmpty })
        // Speakers keep their names; recordings are untouched.
        #expect(try restored.recording(Seeds.ID.recordingA).sortedSpeakers.map(\.displayName) == ["Liam", "Karan"])
        #expect(restored.store.storedDeviceID() == "phone-2")
        #expect(try restored.store.reconcileDevice() == false)

        let candidates = try restored.store.matchCandidates(modelKey: EmbeddingModelID.fake.key)
        #expect(candidates.count == 2 && candidates.allSatisfy { $0.needsResample && $0.samples.isEmpty })
        let probe = SpeakerProbe(key: "S1", vector: SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 1),
                                 cleanSeconds: 12, rejectedProfileIDs: [])
        let decisions = VoiceMatcher.decide(probes: [probe], profiles: candidates, modelKey: EmbeddingModelID.fake.key)
        #expect(decisions["S1"] == .unknown(.noEligibleProfiles))
    }

    @Test func anotherDeviceWipesNegativesTracesAndCoherence() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.askKaran)
        _ = try h.store.reconcileDevice()
        try h.store.rejectSuggestion(recordingID: Seeds.ID.recordingD, key: "S2")
        let id = try h.separatedRecording(turns: SeedContent.conversationB, drafts: [
            WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .liam, cosine: 0.85, variant: 44)),
            WP3Docs.draft("S2", 2, clean: 11, vector: SyntheticVoices.vector(near: .karan, cosine: 0.8, variant: 45))])
        try h.matchLikeThePipeline(id)
        try h.store.moveAllTurns(recordingID: id, from: "S1", to: "S2")   // keeps S1's trace on the recording
        #expect(try h.count(VoiceNegative.self) == 2)   // the reject, and Liam's from the moved auto-label
        #expect(try h.recording(id).speakers.allSatisfy { $0.matchTraceData != nil && $0.vectorCoherence != nil })
        #expect(try h.recording(id).movedSpeakerTracesData != nil)

        let restored = try reopened(h, device: "phone-2")
        #expect(try restored.store.reconcileDevice() == true)
        #expect(try restored.count(VoiceNegative.self) == 0)
        let profiles = try restored.context.fetch(FetchDescriptor<VoiceProfile>())
        #expect(profiles.allSatisfy { $0.negatives.isEmpty })
        let speakers = try restored.context.fetch(FetchDescriptor<RecordingSpeaker>())
        #expect(!speakers.isEmpty && speakers.allSatisfy { $0.matchTraceData == nil && $0.vectorCoherence == nil })
        #expect(try restored.context.fetch(FetchDescriptor<Recording>()).allSatisfy { $0.movedSpeakerTracesData == nil })
    }

    @Test func namingAfterAWipeResamplesTheProfile() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        _ = try h.store.reconcileDevice()
        let restored = try reopened(h, device: "phone-2")
        _ = try restored.store.reconcileDevice()
        let liam = try #require(try restored.profile(named: "Liam"))
        #expect(liam.needsResample)
        // A recording made on this device after the restore.
        let fresh = try restored.readyRecording(turns: SeedContent.conversationB, drafts: [
            WP3Docs.draft("S1", 1, clean: 12, vector: SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 50))])
        let result = try restored.store.nameSpeaker(recordingID: fresh, key: "S1",
                                                    as: .existing(profileID: liam.id), remember: true)
        #expect(result.sampleStored && !liam.needsResample && liam.samples.count == 1)
    }

    @Test func oldDeviceSpeakerVectorsCannotReEnrolAProfile() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.twoSpeakersUnnamed)
        _ = try h.store.reconcileDevice()
        let restored = try reopened(h, device: "phone-2")
        #expect(try restored.store.reconcileDevice() == true)
        let liam = try #require(try restored.profile(named: "Liam"))
        #expect(try restored.store.sampleCandidates(for: liam.id).isEmpty)
        #expect(try restored.context.fetch(FetchDescriptor<RecordingSpeaker>()).allSatisfy { $0.vectorData == nil && !$0.canBeRemembered })
        let result = try restored.store.nameSpeaker(recordingID: Seeds.ID.recordingB, key: "S1",
                                                    as: .existing(profileID: liam.id), remember: true)
        #expect(result.skipReason == .noVector && !result.sampleStored)
        #expect(liam.needsResample && liam.samples.isEmpty)
    }

    @Test func anUnknownIdentityNeverWipes() throws {
        let h = try WP3Harness(device: "phone-1")
        defer { h.cleanup() }
        try h.seed(.library)
        _ = try h.store.reconcileDevice()
        let locked = try reopened(h, device: "")
        #expect(try locked.store.reconcileDevice() == false)
        #expect(try locked.count(VoiceSample.self) == 5)
        #expect(locked.store.storedDeviceID() == "phone-1")
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
