import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Audio sync's state rows (decision 8): facts inside `baseHashesJSON` of a row whose `typeRaw` no generic sync path
/// knows.
@Suite("Audio rows")
@MainActor
struct AudioRowsTests {
    static let id = UUID(uuidString: "A0D10000-0000-4000-8000-000000000001")!
    static let facts = AudioRowFacts(descriptor: AudioDescriptor(recordingID: id, format: .aac16kMono, bytes: 1_234_567,
                                                                 sha256: String(repeating: "0f", count: 32),
                                                                 duration: 308.640_625),
                                     marker: .onServer, markerVersion: 1, recordingSeen: true,
                                     firstSeenAt: Date(timeIntervalSince1970: 1_763_500_000.123))

    static func json(_ facts: String) -> Data { SyncSchema.sortedJSON([AudioRows.factsKey: facts]) }

    @Test func factsRoundTripInsideBaseHashes() throws {
        let row = SyncRecordState.audioRow(Self.facts, now: Seeds.Dates.d)
        #expect(row.recordName == "au.\(Self.id.uuidString)")
        #expect(row.recordName == AudioRows.recordName(Self.id))
        #expect(row.typeRaw == "AudioState")
        #expect(row.entityID == Self.id)
        #expect(row.pendingRaw == 0)
        #expect(row.systemFields == nil)
        #expect(row.unresolvedLinksJSON == nil)
        #expect(row.isAudioRow)
        #expect(row.audioFacts == Self.facts)
        // The facts sit under "~audio" in the JSON, as a JSON string.
        let dict = try JSONDecoder().decode([String: String].self, from: row.baseHashesJSON)
        #expect(Array(dict.keys) == ["~audio"])
        if case .facts(let read) = row.audioRead { #expect(read == Self.facts) } else { Issue.record("not facts") }

        // Changing the facts writes them back.
        var changed = Self.facts
        changed.marker = .deleting
        changed.recordingSeen = false
        row.audioFacts = changed
        #expect(row.audioFacts == changed)
    }

    @Test func settingFactsWritesThisBuildsVersion() {
        let row = SyncRecordState.audioRow(Self.facts, now: Seeds.Dates.d)
        var facts = Self.facts
        facts.v = 7
        row.audioFacts = facts
        #expect(row.audioFacts?.v == AudioRows.factsVersion)
        row.audioFacts = nil
        guard case .malformed = row.audioRead else { Issue.record("cleared facts read \(String(describing: row.audioRead))"); return }
    }

    @Test func rowsSurviveAStoreSaveAndFetch() throws {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let context = container.mainContext
        context.insert(SyncRecordState.audioRow(Self.facts, now: Seeds.Dates.d))
        try context.save()
        let rows = try context.fetch(FetchDescriptor<SyncRecordState>())
        #expect(rows.count == 1)
        #expect(rows.first?.audioFacts == Self.facts)
    }

    @Test func aRowThatIsNotJSONIsMalformed() {
        let row = SyncRecordState.audioRow(Self.facts, now: Seeds.Dates.d)
        row.baseHashesJSON = Data("not json".utf8)
        guard case .malformed = row.audioRead else { Issue.record("read \(String(describing: row.audioRead))"); return }
        #expect(row.audioFacts == nil)
        row.baseHashesJSON = Data("{}".utf8)                                   // no "~audio"
        guard case .malformed = row.audioRead else { Issue.record("read \(String(describing: row.audioRead))"); return }
        row.baseHashesJSON = Self.json("{\"v\":1,\"marker\":\"onServer\"}")   // this build's version, fields missing
        guard case .malformed = row.audioRead else { Issue.record("read \(String(describing: row.audioRead))"); return }
        row.baseHashesJSON = Self.json("[1,2]")
        guard case .malformed = row.audioRead else { Issue.record("read \(String(describing: row.audioRead))"); return }
    }

    @Test func aRowFromANewerBuildReadsNewer() {
        let row = SyncRecordState.audioRow(Self.facts, now: Seeds.Dates.d)
        // A later layout this build cannot decode, but with a higher v: kept, never malformed.
        row.baseHashesJSON = Self.json("{\"v\":2,\"somethingNew\":[1,2,3]}")
        guard case .newer = row.audioRead else { Issue.record("read \(String(describing: row.audioRead))"); return }
        #expect(row.audioFacts == nil)
    }

    @Test func noGenericPathCanNameAnAudioRow() {
        let row = SyncRecordState.audioRow(Self.facts, now: Seeds.Dates.d)
        #expect(row.type == nil)
        #expect(row.recordID == nil)
        #expect(SyncRecordType(rawValue: AudioRows.typeRaw) == nil)
        // The record name parses as the marker's, which is why every .audio id is routed to AudioSync first.
        #expect(SyncRecordID(recordName: row.recordName) == SyncRecordID(type: .audio, entityID: Self.id))
    }
}
