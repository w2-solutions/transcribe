import Foundation
import Testing
@testable import TranscribeKit

/// The `au.<id>` marker record, the audio record type and the transfer format (§3.1, §3.3).
@Suite("Audio marker")
struct AudioMarkerTests {
    static let descriptor = AudioDescriptor(recordingID: UUID(), format: .aac16kMono, bytes: 14_400_000,
                                            sha256: String(repeating: "c3", count: 32), duration: 3_600.25)

    @Test func recordAndDescriptorRoundTrip() {
        let record = AudioMarker.record(Self.descriptor)
        #expect(record.id == SyncRecordID(type: .audio, entityID: Self.descriptor.recordingID))
        #expect(record.id.recordName == "au.\(Self.descriptor.recordingID.uuidString)")
        #expect(record.systemFields == nil)
        #expect(record.fields == ["bytes": .int(14_400_000), "sha256": .string(Self.descriptor.sha256),
                                  "format": .string("aac-lc/16000/1"), "duration": .double(3_600.25), "sv": .int(1)])
        #expect(SyncSchema.recordVersion(record) == 1)
        #expect(AudioMarker.descriptor(record) == Self.descriptor)
    }

    @Test func aMissingOrMistypedFieldGivesNil() {
        let record = AudioMarker.record(Self.descriptor)
        for field in ["bytes", "sha256", "format", "duration"] {
            var missing = record
            missing.fields.removeValue(forKey: field)
            #expect(AudioMarker.descriptor(missing) == nil, "\(field) missing")
            var mistyped = record
            mistyped.fields[field] = .null
            #expect(AudioMarker.descriptor(mistyped) == nil, "\(field) null")
        }
        var wrong = record
        wrong.fields["bytes"] = .double(1)
        #expect(AudioMarker.descriptor(wrong) == nil)
        // Not a marker at all.
        let folder = SyncRecord(id: SyncRecordID(type: .folder, entityID: Self.descriptor.recordingID), fields: record.fields)
        #expect(AudioMarker.descriptor(folder) == nil)
        // A later build's marker keeps its fields and says its version.
        var later = record
        later.fields["sv"] = .int(2)
        later.fields["extra"] = .string("x")
        #expect(AudioMarker.descriptor(later) == Self.descriptor)
        #expect(SyncSchema.recordVersion(later) == 2)
    }

    @Test func groupsAreTheSchemasAndHaveNoLinks() {
        #expect(SyncSchema.groups(.audio) == AudioMarker.groups)
        #expect(SyncSchema.groups(.audio) == ["body": ["bytes", "sha256", "format", "duration"]])
        #expect(SyncSchema.linkFields(.audio).isEmpty)
        // Every field of the marker is in its one group.
        let record = AudioMarker.record(Self.descriptor)
        #expect(Set(record.fields.keys).subtracting(["sv"]) == Set(SyncSchema.groups(.audio).values.flatMap { $0 }))
    }

    @Test func theAudioTypeIsNoLibraryEntity() {
        #expect(SyncRecordType.audio.rawValue == "RecordingAudio")
        #expect(SyncRecordType.audio.prefix == "au")
        #expect(SyncRecordType.audio.applyOrder == 7)
        #expect(!SyncRecordType.audio.isLibraryEntity)
        #expect(SyncRecordType.libraryCases == [.recording, .speaker, .profile, .sample, .negative, .folder, .groupLabel])
        #expect(SyncRecordType.libraryCases.allSatisfy { $0.isLibraryEntity })
        #expect(Set(SyncRecordType.allCases) == Set(SyncRecordType.libraryCases + [.audio]))
        // Apply orders stay distinct.
        #expect(Set(SyncRecordType.allCases.map(\.applyOrder)).count == SyncRecordType.allCases.count)
        // An audio blob's prefix is no record type.
        #expect(SyncRecordID(recordName: "af.\(UUID().uuidString)") == nil)
        // `ChangeDetector`'s full scan iterates `allCases`, `.audio` included: it is safe only because no state row
        // carries `.audio`'s `typeRaw`. Audio rows use a foreign one, which no record type has.
        #expect(SyncRecordType(rawValue: AudioRows.typeRaw) == nil)
        #expect(AudioRows.typeRaw != SyncRecordType.audio.rawValue)
        let row = SyncRecordState.audioRow(AudioRowFacts(descriptor: Self.descriptor, marker: .onServer, recordingSeen: true,
                                                         firstSeenAt: Date()), now: Date())
        #expect(row.typeRaw == AudioRows.typeRaw)
        #expect(row.recordID == nil)
    }

    @Test @MainActor func theProjectorHasNothingForAMarker() throws {
        let container = try ModelContainerFactory.make(inMemory: true, url: nil)
        let projector = RecordProjector(context: container.mainContext)
        #expect(projector.entity(SyncRecordID(type: .audio, entityID: UUID())) == nil)
        #expect(try projector.all(.audio).isEmpty)
        #expect(try projector.allIDs(.audio).isEmpty)
    }

    @Test func formatsMapToFileExtensions() {
        #expect(AudioFormat.aac16kMono.rawValue == "aac-lc/16000/1")
        #expect(AudioFormat.pcm16kMono.rawValue == "pcm-s16le/16000/1")
        #expect(AudioFormat.aac16kMono.fileExtension == "m4a")
        #expect(AudioFormat.pcm16kMono.fileExtension == "wav")
        #expect(AudioFormat(rawValue: "aac-lc/48000/2").fileExtension == "m4a")
        #expect(AudioFormat(rawValue: "opus/16000/1").fileExtension == nil)
        #expect(!AudioFormat(rawValue: "opus/16000/1").isPlayable)
        #expect(AudioFormat.aac16kMono.isPlayable && AudioFormat.pcm16kMono.isPlayable)
        #expect(AudioFormat(fileExtension: "m4a") == .aac16kMono)
        #expect(AudioFormat(fileExtension: "M4A") == .aac16kMono)
        #expect(AudioFormat(fileExtension: "wav") == .pcm16kMono)
        #expect(AudioFormat(fileExtension: "mp3") == nil)
        #expect(AudioFormat(fileExtension: "") == nil)
    }

    @Test func descriptorsEncodeTheFormatAsItsRawValue() throws {
        let data = try JSONEncoder().encode(Self.descriptor)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"format\":\"aac-lc\\/16000\\/1\""))
        #expect(try JSONDecoder().decode(AudioDescriptor.self, from: data) == Self.descriptor)
    }
}
