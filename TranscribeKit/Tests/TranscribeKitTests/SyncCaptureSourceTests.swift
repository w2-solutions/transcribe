import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension FakeDevice {
    /// A ready Both recording on `callConversation` (Liam on the microphone, a stranger through Mac audio, a blend of
    /// the two heard on both), matched like the pipeline.
    @discardableResult
    func recordCall(sources: [SpeakerKey: SpeakerSource] = ["S1": .mic, "S2": .system, "S3": .mixed]) throws -> UUID {
        let id = UUID()
        let file = paths.newAudioFileName(for: id)
        try store.createRecording(id: id, createdAt: clock.date, audioFileName: file, source: .microphone)
        try Data("RIFF".utf8).write(to: paths.audioURL(fileName: file))
        let detail = CaptureDetail(hardwareModel: "Mac15,3", input: CaptureDetail.Input.micAndSystem,
                                   sources: CaptureDetail.Sources.both, outputRoute: CaptureDetail.OutputRoute.headphones)
        try store.finishCapture(id: id, audio: CapturedAudio(url: paths.audioURL(fileName: file), duration: 40, marks: [],
                                                             peaks: [0.1, 0.5], detail: detail), language: .automatic)
        let turns = SeedContent.callConversation
        try store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(turns))
        let vectors: [SpeakerKey: VoiceVector] = ["S1": SyncVoices.liam(34), "S2": SyncVoices.stranger(35),
                                                  "S3": SyntheticVoices.mix([(.liam, 0.6), (.stranger, 0.6)], variant: 36)]
        let drafts = ["S1", "S2", "S3"].enumerated().map { i, key in
            var d = WP3Docs.draft(key, i + 1, clean: 12, turns: 2, vector: vectors[key])
            d.source = sources[key]
            return d
        }
        try store.checkpointSeparation(id: id, document: WP3Docs.speakers(turns), speakers: drafts)
        try matchLikeThePipeline(id)
        return id
    }
}

/// `RecordingSpeaker.captureSource` (schema V5, decision D1) syncs in the speaker's `stats` group: it reaches the other
/// device, survives edits there, joins on a conflict, and a nil value hashes exactly as before the field existed.
@Suite("Sync: a speaker's capture source")
@MainActor
struct SyncCaptureSourceTests {
    @Test func captureSourceReachesTheOtherDeviceAndSurvivesEdits() async throws {
        let t = try await TwoDevices.make()
        defer { t.cleanup() }
        let call = try t.b.recordCall()   // B is the Mac
        await t.settleBoth()
        let onA = try #require(t.a.recording(call))
        #expect(onA.sortedSpeakers.map(\.captureSource) == ["mic", "system", "mixed"])
        #expect(try t.a.store.probes(for: call).map(\.askOnly) == [false, false, true])
        expectConverged(t.devices)

        // Naming the call voice on the iPhone: the sample keeps the Mac's channel and says it came through Mac audio.
        let named = try t.a.store.nameSpeaker(recordingID: call, key: "S2", as: .newPerson(name: "Tom"), remember: true)
        #expect(named.sampleStored)
        // Edits that rewrite other groups of the speakers: a rename, a name, and a turn moved between speakers.
        try t.a.store.rename(id: call, title: "Teams call")
        _ = try t.b.store.nameSpeaker(recordingID: call, key: "S1", as: .existing(profileID: t.liam), remember: true)
        await t.settleBoth()
        let turn = try #require(t.b.recording(call)?.transcript?.turns.first { $0.speakerKey == "S1" })
        try t.b.store.reassignTurn(recordingID: call, turnID: turn.id, to: .speaker("S2"))
        await t.settleBoth()
        for d in t.devices {
            let r = try #require(d.recording(call))
            #expect(r.sortedSpeakers.map(\.captureSource) == ["mic", "system", "mixed"], "\(d.name)")
            let tom = try #require(d.profile(named: "Tom"))
            #expect(tom.samples.count == 1)
            #expect(tom.samples.first?.captureChannel == CaptureChannel.mac)
            #expect(tom.samples.first?.captureInput == CaptureDetail.Input.systemAudio)
        }
        expectConverged(t.devices)
    }

    /// "Same as" across streams on one device while the other recounts the same speaker: the counts follow the device
    /// that saved last, and the source joins to mixed on both.
    @Test func sameAsOnOneDeviceAndARecountOnTheOtherEndMixed() async throws {
        let t = try await TwoDevices.make()
        defer { t.cleanup() }
        let call = try t.b.recordCall(sources: ["S1": .mic, "S2": .system, "S3": .system])
        await t.settleBoth()
        // B: S2 (Mac audio) is the same person as S1 (microphone): S1 becomes mixed.
        try t.b.store.moveAllTurns(recordingID: call, from: "S2", to: "S1")
        #expect(t.b.recording(call)?.speaker("S1")?.source == .mixed)
        // A, before hearing of it: one of S1's turns moves to S3, which changes S1's counts.
        let turn = try #require(t.a.recording(call)?.transcript?.turns.first { $0.speakerKey == "S1" })
        try t.a.store.reassignTurn(recordingID: call, turnID: turn.id, to: .speaker("S3"))
        await t.b.sync.syncNow()
        await t.a.sync.syncNow()
        await t.settleBoth()
        for d in t.devices { #expect(d.recording(call)?.speaker("S1")?.source == .mixed, "\(d.name)") }
        expectConverged(t.devices)
    }

    @Test func aNilSourceHashesAsBeforeTheFieldExisted() throws {
        let id = SyncRecordID(type: .speaker, entityID: UUID())
        let old: [String: SyncValue] = ["turnCount": .int(2), "totalSeconds": .double(12.5), "sv": .int(1)]
        // A record from 0.3.3 (no such field) and a V5 record with it nil hash the same, group for group.
        #expect(SyncSchema.hashes(old, type: .speaker) == SyncSchema.hashes(old.merging(["captureSource": .null]) { $1 },
                                                                             type: .speaker))
        // The stats hash is the one 0.3.3 computed: its fields were turnCount and totalSeconds only.
        let v33 = SyncSchema.hash(["turnCount": .int(2), "totalSeconds": .double(12.5)])
        #expect(SyncSchema.hashes(old, type: .speaker)[SyncSchema.Group.stats] == v33)
        // A value changes the stats group only.
        let system = SyncSchema.hashes(old.merging(["captureSource": .string("system")]) { $1 }, type: .speaker)
        let before = SyncSchema.hashes(old, type: .speaker)
        #expect(Set(system.keys.filter { system[$0] != before[$0] }) == [SyncSchema.Group.stats])
        #expect(SyncSchema.groups(.speaker)[SyncSchema.Group.stats]?.contains("captureSource") == true)
        _ = id
    }

    @Test func aRecordWithoutTheFieldReadsAsTheMicrophone() async throws {
        let t = try await TwoDevices.make()
        defer { t.cleanup() }
        let call = try t.b.recordCall()
        await t.settleBoth()
        // An older build re-creating S2's record from scratch (it never knew the field): A reads it as the microphone.
        let s2 = try #require(t.b.recording(call)?.speaker("S2"))
        let name = SyncRecordID(type: .speaker, entityID: s2.id).recordName
        let server = try #require(await t.cloud.record(account: "account-1", recordName: name))
        var fields = server.fields
        fields.removeValue(forKey: "captureSource")
        fields["turnCount"] = .int(3)
        await t.cloud.inject(account: "account-1", SyncRecord(id: server.id, fields: fields))
        await t.a.sync.syncNow()
        #expect(t.a.recording(call)?.speaker("S2")?.captureSource == nil)
        #expect(t.a.recording(call)?.speaker("S2")?.source == .mic)
    }

    @Test func mergePolicyJoinsSourcesWhenBothSidesChangedStats() {
        let base = ["ident": "i0", "stats": "s0", "label": "l0", "rejected": "r0"]
        let both = MergePolicy.decide(type: .speaker, local: ["ident": "i0", "stats": "s1", "label": "l0", "rejected": "r0"],
                                      base: base, server: ["ident": "i0", "stats": "s2", "label": "l0", "rejected": "r0"])
        #expect(both["stats"] == .keepLocalJoinSource)
        let localOnly = MergePolicy.decide(type: .speaker, local: ["ident": "i0", "stats": "s1", "label": "l0", "rejected": "r0"],
                                           base: base, server: base)
        #expect(localOnly["stats"] == .keepLocal)
        #expect(MergePolicy.joinedSource(local: nil, server: nil) == nil)
        #expect(MergePolicy.joinedSource(local: nil, server: "mic") == nil)           // both the microphone: unchanged
        #expect(MergePolicy.joinedSource(local: "system", server: "system") == "system")
        #expect(MergePolicy.joinedSource(local: nil, server: "system") == "mixed")
        #expect(MergePolicy.joinedSource(local: "mixed", server: "mic") == "mixed")
    }
}
