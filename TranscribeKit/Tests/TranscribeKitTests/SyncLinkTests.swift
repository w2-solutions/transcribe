import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// Links whose target arrives later (§8.4 flow 3): kept as unresolved ids, never uploaded as cleared, and resolved
    /// at `fetchFinished`.
    @Suite("Sync: links")
    @MainActor
    struct SyncLinkTests {
        /// Records made on a device that never syncs, injected into the cloud one at a time.
        @MainActor struct Source {
            let device: FakeDevice
            let recording: UUID
            let speaker: UUID
            let profile: UUID
            let sample: UUID

            init(cloud: FakeCloud) throws {
                device = try FakeDevice("S", cloud: cloud)
                recording = try device.record([SyncVoices.karan(40)])
                profile = try #require(try device.store.nameSpeaker(recordingID: recording, key: "S1", as: .newPerson(name: "Karan"),
                                                                    remember: true).profileID)
                speaker = try #require(device.recording(recording)?.speaker("S1")?.id)
                sample = try #require(device.profile(named: "Karan")?.samples.first?.id)
            }

            func record(_ type: SyncRecordType, _ id: UUID) throws -> SyncRecord {
                let e = try #require(RecordProjector(context: device.context).entity(SyncRecordID(type: type, entityID: id)))
                return RecordProjector.record(e)
            }
        }

        @Test func aSpeakerBeforeItsRecording() async throws {
            let cloud = FakeCloud()
            let source = try Source(cloud: cloud)
            let b = try FakeDevice("B", cloud: cloud)
            defer { source.device.cleanup(); b.cleanup() }
            await cloud.inject(account: "account-1", try source.record(.profile, source.profile))
            await cloud.inject(account: "account-1", try source.record(.speaker, source.speaker))
            await b.sync.enable()
            let spk = SyncRecordID(type: .speaker, entityID: source.speaker)
            let s = try #require(try b.store.speaker(id: source.speaker))
            #expect(s.recording == nil && s.profile?.id == source.profile)
            #expect(b.stateRow(spk)?.unresolvedLinks == ["recordingID": source.recording.uuidString])
            // The projection still names the recording, so nothing is sent for it.
            let projected = RecordProjector.fields(.speaker(s), unresolved: b.stateRow(spk)?.unresolvedLinks ?? [:])
            #expect(projected["recordingID"] == .string(source.recording.uuidString))
            #expect(b.stateRow(spk)?.pending == SyncPending.none)

            await cloud.inject(account: "account-1", try source.record(.recording, source.recording))
            await b.sync.syncNow()
            #expect(s.recording?.id == source.recording && b.recording(source.recording)?.speakers.count == 1)
            #expect(b.stateRow(spk)?.unresolvedLinks.isEmpty == true)
            #expect(b.recording(source.recording)?.searchText.contains("karan") == true)
            #expect(b.pending == 0)
        }

        @Test func aSampleBeforeItsProfile() async throws {
            let cloud = FakeCloud()
            let source = try Source(cloud: cloud)
            let b = try FakeDevice("B", cloud: cloud)
            defer { source.device.cleanup(); b.cleanup() }
            await cloud.inject(account: "account-1", try source.record(.sample, source.sample))
            await b.sync.enable()
            let sample = try #require(try b.context.fetch(FetchDescriptor<VoiceSample>()).first)
            #expect(sample.profile == nil)
            #expect(b.stateRow(SyncRecordID(type: .sample, entityID: source.sample))?.unresolvedLinks["profileID"] == source.profile.uuidString)
            await cloud.inject(account: "account-1", try source.record(.profile, source.profile))
            await b.sync.syncNow()
            #expect(sample.profile?.id == source.profile && b.profile(named: "Karan")?.samples.count == 1)
            #expect(b.profile(named: "Karan")?.needsResample == false)
        }

        /// One record per fetched event, speaker first: the link is resolved when the fetch finishes.
        @Test func linksAreResolvedAtFetchFinished() async throws {
            let cloud = FakeCloud()
            let source = try Source(cloud: cloud)
            let b = try FakeDevice("B", cloud: cloud)
            defer { source.device.cleanup(); b.cleanup() }
            for (type, id) in [(SyncRecordType.sample, source.sample), (.speaker, source.speaker), (.recording, source.recording),
                               (.profile, source.profile)] {
                await cloud.inject(account: "account-1", try source.record(type, id))
            }
            await b.transport.setFetchPageSize(1)
            await b.sync.enable()
            let s = try #require(try b.store.speaker(id: source.speaker))
            #expect(s.recording?.id == source.recording && s.profile?.id == source.profile)
            #expect(b.stateRows().allSatisfy { $0.unresolvedLinks.isEmpty })
            #expect(b.projections() == source.device.projections())
            #expect(b.pending == 0)
        }

        /// A local edit to a record with an unresolved link sends the link's id, never nil.
        @Test func anUnresolvedLinkIsNeverUploadedAsNil() async throws {
            let cloud = FakeCloud()
            let source = try Source(cloud: cloud)
            let b = try FakeDevice("B", cloud: cloud)
            defer { source.device.cleanup(); b.cleanup() }
            // The speaker and its recording arrive, but its profile never does (forgotten elsewhere).
            await cloud.inject(account: "account-1", try source.record(.recording, source.recording))
            await cloud.inject(account: "account-1", try source.record(.speaker, source.speaker))
            await b.sync.enable()
            let s = try #require(try b.store.speaker(id: source.speaker))
            #expect(s.profile == nil)
            // B moves a turn: the speaker's stats change and it is sent.
            let turn = try #require(b.recording(source.recording)?.transcript?.turns.first { $0.speakerKey == "S1" })
            try b.store.reassignTurn(recordingID: source.recording, turnID: turn.id, to: .newName("Guest"))
            await b.sync.syncNow()
            let sent = try #require(await cloud.record(account: "account-1",
                                                       recordName: SyncRecordID(type: .speaker, entityID: source.speaker).recordName))
            #expect(sent.fields["profileID"] == .string(source.profile.uuidString))
            #expect(sent.fields["turnCount"] == .int(Int64(s.turnCount)))
        }

        /// A target still missing after 7 days is dropped (the speaker keeps any name snapshot).
        @Test func aLinkMissingForSevenDaysIsDropped() async throws {
            let cloud = FakeCloud()
            let source = try Source(cloud: cloud)
            let b = try FakeDevice("B", cloud: cloud)
            defer { source.device.cleanup(); b.cleanup() }
            await cloud.inject(account: "account-1", try source.record(.recording, source.recording))
            await cloud.inject(account: "account-1", try source.record(.speaker, source.speaker))
            await b.sync.enable()
            let spk = SyncRecordID(type: .speaker, entityID: source.speaker)
            b.clock.advance(6 * 24 * 3600)
            await b.sync.syncNow()
            #expect(b.stateRow(spk)?.unresolvedLinks["profileID"] != nil)
            b.clock.advance(2 * 24 * 3600)
            await b.sync.syncNow()
            await b.sync.syncNow()
            #expect(b.stateRow(spk)?.unresolvedLinks.isEmpty == true)
            #expect(await cloud.record(account: "account-1", recordName: spk.recordName)?.fields["profileID"] == .null)
        }
    }
}

extension FakeTransport {
    func setFetchPageSize(_ n: Int) { fetchPageSize = n }
}
