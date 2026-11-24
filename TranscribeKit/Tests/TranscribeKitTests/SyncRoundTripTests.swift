import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

extension SyncSuites {
    /// The canonical-value rule (§8.1): project → apply → project gives identical values and hashes for every type.
    @Suite("Sync: round trip")
    @MainActor
    struct SyncRoundTripTests {
        /// Every field set, on every type, including sub-millisecond dates and odd floats.
        func richLibrary(on d: FakeDevice) throws {
            let r1 = try d.record([SyncVoices.karan(47), SyncVoices.liam(48)])
            let p = try #require(try d.store.nameSpeaker(recordingID: r1, key: "S1", as: .newPerson(name: "Karan"), remember: true).profileID)
            _ = try d.store.nameSpeaker(recordingID: r1, key: "S2", as: .newPerson(name: "Liam"), remember: true)
            let folder = try d.store.createFolder(name: "Work")
            try d.store.move(recordingID: r1, toFolder: folder)
            try d.store.rename(id: r1, title: "Standup ✓")
            try d.store.setFavourite(id: r1, true)
            try d.store.setIsMe(profileID: p)
            try d.store.setAutoLabel(profileID: p, false)
            let r = try #require(d.recording(r1))
            r.createdAt = Date(timeIntervalSince1970: 1_763_500_000.123_456_7)   // sub-millisecond
            r.languageRaw = "en"
            r.marks = [1.5, 3.000_000_1, 1e-9]
            r.peaks = [0, 0.333_333_34, 1, -0.0]
            r.captureDetailJSON = CaptureDetail(hardwareModel: "iPhone15,4", input: "bluetoothHFP", inputName: "AirPods",
                                                inputModelUID: "uid", routeChanged: true).json()
            let s = try #require(r.speaker("S2"))
            s.rejectedProfileIDs = [UUID(), UUID()]
            s.nameSnapshot = "Old name"
            s.matchScore = 0.123_456_789
            s.matchMargin = -0.5
            s.vectorCoherence = 0.75
            try d.context.save()
            // A suggested speaker, a negative and a short sample.
            let r2 = try d.record([SyncVoices.karan(49, 0.5), SyncVoices.stranger(50)])
            try d.store.rejectSuggestion(recordingID: r2, key: "S1")
            let sample = try #require(d.profile(named: "Karan")?.samples.first)
            sample.addedAt = Date(timeIntervalSince1970: 1_763_500_001.000_9)
            sample.clipStart = 0.1
            sample.clipEnd = 2.25
            sample.captureInput = "usbAudio"
            // A recording with no transcript, title or folder.
            let r3 = try d.record([])
            _ = try d.store.finishWithoutMatching(id: r3, document: nil, noSpeech: true)
            try d.context.save()
        }

        @Test func projectApplyProjectIsIdenticalForEveryType() async throws {
            let cloud = FakeCloud()
            let a = try FakeDevice("A", cloud: cloud), b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac)
            defer { a.cleanup(); b.cleanup() }
            try richLibrary(on: a)
            let source = a.projections()
            #expect(Set(source.keys.compactMap { SyncRecordID(recordName: $0)?.type }) == Set(SyncRecordType.allCases))

            // Apply every record on B in one fetched batch, exactly as a fetch would.
            let records = source.map { SyncRecord(id: SyncRecordID(recordName: $0.key)!, fields: $0.value, systemFields: Data("x".utf8)) }
            var effects = RemoteApplier.Effects()
            try await b.sync.applier.applyFetched(modifications: records, deletions: [], effects: &effects)
            try b.sync.applier.finishFetch(touchedProfiles: effects.touchedProfiles)
            try b.context.save()
            #expect(effects.saves.isEmpty && effects.deletes.isEmpty)

            let applied = b.projections()
            #expect(applied == source)
            for (name, fields) in source {
                let id = try #require(SyncRecordID(recordName: name))
                #expect(SyncSchema.hashes(fields, type: id.type) == SyncSchema.hashes(try #require(applied[name]), type: id.type))
                // The base set on apply equals the re-projection: nothing echoes back.
                #expect(b.stateRow(id)?.baseHashes == SyncSchema.hashes(fields, type: id.type))
                #expect(b.stateRow(id)?.pending == SyncPending.none)
            }
            // And projecting A again is stable.
            #expect(a.projections() == source)
        }

        @Test func canonicalValues() throws {
            let date = Date(timeIntervalSince1970: 1_763_500_000.123_6)
            #expect(SyncValue.date(date) == .dateMillis(1_763_500_000_124))
            for ms: Int64 in [0, 1, 999, 1_763_500_000_123, 1_763_500_000_999, 4_102_444_800_001] {
                #expect(SyncValue.date(SyncValue.dateFrom(millis: ms)) == .dateMillis(ms))
            }
            let floats: [Float] = [0, -0.0, 1, .leastNonzeroMagnitude, 0.1, .greatestFiniteMagnitude]
            #expect(SyncValue.unpackFloats(SyncValue.packFloats(floats)).map(\.bitPattern) == floats.map(\.bitPattern))
            #expect(SyncValue.bool(true) == .int(1) && SyncValue.bool(false) == .int(0))
            #expect(SyncValue.string(nil as String?) == .null)
            #expect(SyncValue.uuids([UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!,
                                     UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!])
                    == .strings(["A0000000-0000-4000-8000-000000000001", "B0000000-0000-4000-8000-000000000002"]))
        }

        @Test func syncValueJSONIsExactAndSorted() throws {
            let values: [String: SyncValue] = ["z": .double(.nan), "a": .double(-0.0), "m": .doubles([0.1, 1e300]), "n": .null,
                                               "b": .bytes(Data([0, 255])), "s": .strings(["x"]), "t": .dateMillis(5),
                                               "i": .int(-3), "asset": .asset(Data("{}".utf8)), "str": .string("é")]
            let data = SyncSchema.sortedJSON(values)
            let back = try JSONDecoder().decode([String: SyncValue].self, from: data)
            if case .double(let d) = back["a"]! { #expect(d.bitPattern == (-0.0).bitPattern) } else { Issue.record("a") }
            if case .double(let d) = back["z"]! { #expect(d.isNaN) } else { Issue.record("z") }
            #expect(back["m"] == values["m"] && back["b"] == values["b"] && back["asset"] == values["asset"] && back["str"] == values["str"])
            #expect(SyncSchema.sortedJSON(back) == data)
            // A missing field hashes like `.null`, so an older record without a new optional field is no change.
            #expect(SyncSchema.hashes(["title": .null], type: .recording)["title"] == SyncSchema.hashes([:], type: .recording)["title"])
        }

        /// The bytes that are hashed are valid JSON with sorted keys, and decode to the same values.
        @Test func hashedBytesAreTheCanonicalJSON() throws {
            let values: [String: SyncValue] = ["title": .string("Quote \" back\\slash \n tab\t é ✓"), "fav": .int(1), "n": .null,
                                               "d": .double(0.1), "ds": .doubles([-0.0, 2]), "t": .dateMillis(-5), "b": .bytes(Data([1, 2, 3])),
                                               "ss": .strings(["b", "a\u{01}"]), "a": .asset(Data(repeating: 7, count: 300))]
            let bytes = SyncSchema.canonicalJSON(values)
            let back = try JSONDecoder().decode([String: SyncValue].self, from: Data(bytes))
            #expect(back == values)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            #expect(Set(object.keys) == Set(values.keys))
            // Hashes are lowercase hex SHA-256.
            let h = SyncSchema.hash(values)
            #expect(h.count == 64 && h.allSatisfy { "0123456789abcdef".contains($0) })
        }

        @Test func recordNames() {
            let id = UUID()
            for type in SyncRecordType.allCases {
                let rid = SyncRecordID(type: type, entityID: id)
                #expect(rid.recordName == "\(type.prefix).\(id.uuidString)")
                #expect(SyncRecordID(recordName: rid.recordName) == rid)
            }
            #expect(SyncRecordID(recordName: "xx.\(id.uuidString)") == nil)
            #expect(SyncRecordID(recordName: "rec.not-a-uuid") == nil)
            // Every field of every type is in exactly one group.
            for type in SyncRecordType.allCases {
                let fields = SyncSchema.groups(type).values.flatMap { $0 }
                #expect(Set(fields).count == fields.count)
            }
        }
    }
}
