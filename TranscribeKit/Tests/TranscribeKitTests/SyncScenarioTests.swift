import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// The convergence scenarios of §8.7: each user action on one device reaches the other, then nothing is pending and
    /// both devices' projections are equal.
    @Suite("Sync: convergence scenarios")
    @MainActor
    struct SyncScenarioTests {
        @Test func name() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            _ = try t.a.store.nameSpeaker(recordingID: t.r2, key: "S2", as: .newPerson(name: "Sam"), remember: true)
            await t.settleBoth()
            let s2 = try #require(t.b.recording(t.r2)?.speaker("S2"))
            #expect(s2.label == .named && s2.profile?.name == "Sam")
            #expect(t.b.profile(named: "Sam")?.samples.count == 1)
            #expect(t.b.recording(t.r2)?.searchText.contains("sam") == true)
            expectConverged(t.devices)
        }

        @Test func confirm() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            #expect(t.b.recording(t.r2)?.speaker("S1")?.label == .suggested)
            _ = try t.b.store.confirmSuggestion(recordingID: t.r2, key: "S1")
            await t.settleBoth()
            let s1 = try #require(t.a.recording(t.r2)?.speaker("S1"))
            #expect(s1.label == .named && s1.profile?.id == t.karan)
            // The confirmed sample was heard on A's iPhone recording, though B (a Mac) confirmed it (D10).
            let confirmed = try #require(t.a.profile(named: "Karan")?.samples.first { $0.sourceSpeakerID == s1.id })
            #expect(confirmed.origin == .confirmed && confirmed.captureChannel == CaptureChannel.iphone)
            expectConverged(t.devices)
        }

        @Test func reject() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.rejectSuggestion(recordingID: t.r2, key: "S1")
            await t.settleBoth()
            let s1 = try #require(t.b.recording(t.r2)?.speaker("S1"))
            #expect(s1.label == .unnamed && s1.suggestedProfileID == nil && s1.rejectedProfileIDs == [t.karan])
            #expect(t.b.profile(named: "Karan")?.negatives.count == 1)
            expectConverged(t.devices)
        }

        @Test func reassignATurn() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let turn = try #require(t.a.recording(t.r1)?.transcript?.turns.first { $0.speakerKey == "S1" })
            try t.a.store.reassignTurn(recordingID: t.r1, turnID: turn.id, to: .newName("Guest"))
            await t.settleBoth()
            let r = try #require(t.b.recording(t.r1))
            let u1 = try #require(r.speaker("U1"))
            #expect(u1.nameSnapshot == "Guest" && u1.turnCount == 1)
            #expect(r.transcript?.turns.first { $0.id == turn.id }?.speakerKeyOverride == "U1")
            expectConverged(t.devices)
        }

        @Test func sameAs() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.b.store.moveAllTurns(recordingID: t.r2, from: "S2", to: "S1")
            await t.settleBoth()
            let r = try #require(t.a.recording(t.r2))
            #expect(r.speaker("S2") == nil && r.speakers.count == 1)
            #expect(r.transcript?.turns.allSatisfy { $0.effectiveSpeakerKey == "S1" || $0.speakerKey == nil } == true)
            #expect(t.a.count(RecordingSpeaker.self) == t.b.count(RecordingSpeaker.self))
            expectConverged(t.devices)
        }

        @Test func favourite() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.setFavourite(id: t.r1, true)
            await t.settleBoth()
            #expect(t.b.recording(t.r1)?.isFavourite == true)
            expectConverged(t.devices)
        }

        @Test func moveToAFolder() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            let folder = try t.b.store.createFolder(name: "Work")
            try t.b.store.move(recordingID: t.r1, toFolder: folder)
            await t.settleBoth()
            #expect(t.a.recording(t.r1)?.folder?.id == folder && t.a.recording(t.r1)?.folder?.name == "Work")
            expectConverged(t.devices)
        }

        @Test func rename() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.rename(id: t.r1, title: "Standup")
            try t.a.store.renameProfile(profileID: t.karan, name: "Karan S")
            await t.settleBoth()
            #expect(t.b.recording(t.r1)?.title == "Standup" && t.b.recording(t.r1)?.searchText.contains("standup") == true)
            #expect(t.b.profile(named: "Karan S") != nil)
            #expect(t.b.recording(t.r1)?.searchText.contains("karan s") == true)
            expectConverged(t.devices)
        }

        @Test func merge() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.b.store.mergeProfiles(source: t.liam, into: t.karan)
            await t.settleBoth()
            #expect(t.a.profile(named: "Liam") == nil)
            let karan = try #require(t.a.profile(named: "Karan"))
            #expect(karan.samples.count == 2)
            #expect(t.a.recording(t.r1)?.speaker("S2")?.profile?.id == t.karan)
            #expect(t.a.count(VoiceSample.self) == 2)
            expectConverged(t.devices)
        }

        @Test func forget() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.a.store.forgetProfile(t.karan)
            await t.settleBoth()
            #expect(t.b.profile(named: "Karan") == nil && t.b.count(VoiceSample.self) == 1)
            let s1 = try #require(t.b.recording(t.r1)?.speaker("S1"))
            #expect(s1.profile == nil && s1.nameSnapshot == "Karan" && s1.label == .named)
            let r2s1 = try #require(t.b.recording(t.r2)?.speaker("S1"))
            #expect(r2s1.suggestedProfileID == nil && r2s1.label == .unnamed)
            expectConverged(t.devices)
        }

        @Test func delete() async throws {
            let t = try await TwoDevices.make()
            defer { t.cleanup() }
            try t.b.store.delete(id: t.r1)
            await t.settleBoth()
            #expect(t.a.recording(t.r1) == nil)
            #expect(t.a.count(RecordingSpeaker.self) == 2)
            #expect(t.a.count(VoiceSample.self) == 2)   // samples keep their vectors
            expectConverged(t.devices)
        }
    }
}
