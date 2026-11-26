import CoreData
import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Writes `Fixtures/V3Library`: a store made by the V3 schema, committed so that later schema versions can prove
/// they open a V3 library (0.3.x on the owner's iPhone and Mac) without losing anything, sync state included.
///
/// The writer runs only when `TRANSCRIBE_WRITE_V3_FIXTURE` names a folder:
///
///     cd TranscribeKit && TRANSCRIBE_WRITE_V3_FIXTURE=$PWD/Tests/TranscribeKitTests/Fixtures/V3Library \
///         swift test --filter V3FixtureWriter
///
/// It names every model as `TranscribeSchemaV3.X` and sets stored fields only (never the type aliases or the computed
/// accessors), so it keeps writing a true V3 store after the aliases move to a newer schema. Every id and date is
/// fixed. `manifest.json` is read back from the written store, not from the inputs.
///
/// One exception: the sync rows' base hashes are the record projector's, computed on a scratch copy of the store
/// opened by the current build (`ModelContainerFactory`), because the projector only reads the current types. V4
/// changed no synced field, so these are the hashes a V3 build agreed with the server, and the committed fixture
/// pins them: `MigrationV4Tests.upgradeQueuesNothingToSync` fails if an upgrade would change one. (Regenerating the
/// fixture after a change to the projector's fields would no longer give a V3 build's hashes.)
@Suite("V3 fixture writer")
@MainActor
struct V3FixtureWriter {
    nonisolated static let envKey = "TRANSCRIBE_WRITE_V3_FIXTURE"
    nonisolated static var outputFolder: String? {
        ProcessInfo.processInfo.environment[envKey].flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Fixed ids and dates

    enum ID {
        static func u(_ s: String) -> UUID { UUID(uuidString: s)! }
        static let recordingA = u("A3000000-0000-4000-8000-00000000000A")   // ready, iphone, in folder "Work"
        static let recordingB = u("A3000000-0000-4000-8000-00000000000B")   // ready, mac, favourite
        static let queued = u("A3000000-0000-4000-8000-000000000012")       // queued for models (never synced)
        static let goneRecording = u("A3000000-0000-4000-8000-000000000099") // deleted: exists nowhere
        static let liam = u("B3000000-0000-4000-8000-000000000001")
        static let karan = u("B3000000-0000-4000-8000-000000000002")
        static let work = u("F3000000-0000-4000-8000-000000000001")
        static let speakerA1 = u("C3000000-0000-4000-8000-00000000A001")
        static let speakerA2 = u("C3000000-0000-4000-8000-00000000A002")
        static let speakerB1 = u("C3000000-0000-4000-8000-00000000B001")
        static let speakerB2 = u("C3000000-0000-4000-8000-00000000B002")
        static let liamNamed = u("53000000-0000-4000-8000-000000000001")       // iphone, clip
        static let karanNamed = u("53000000-0000-4000-8000-000000000002")      // iphone, no clip
        static let liamMac = u("53000000-0000-4000-8000-000000000003")         // mac, clip; its sync row must merge
        static let liamGoneSource = u("53000000-0000-4000-8000-000000000004")  // mac, its recording was deleted
        static let deletedSample = u("53000000-0000-4000-8000-000000000099")   // gone here; its delete not yet sent
        static let karanNegative = u("E3000000-0000-4000-8000-000000000001")   // mac
        static let unresolvedProfile = u("B3000000-0000-4000-8000-000000000077") // a link whose target has not arrived
    }

    /// Whole seconds from Tue 17 Nov 2026 00:00 UTC, so ISO 8601 in the manifest round-trips exactly.
    static func date(day: Int, hour: Int, minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_794_873_600 + Double((day - 17) * 86_400 + hour * 3_600 + minute * 60))
    }

    static let modelKey = EmbeddingModelID.fake.key
    static let asrModelID = "fake-parakeet"
    static let iphoneDetail = CaptureDetail(hardwareModel: "iPhone15,4", input: CaptureDetail.Input.builtInMic)
    static let macDetail = CaptureDetail(hardwareModel: "Mac16,5", input: CaptureDetail.Input.usbAudio, inputName: "Desk mic",
                                         inputModelUID: "usb:1234")
    static let accountHash = String(repeating: "3f", count: 32)
    static let engineState = Data((0..<64).map { UInt8(($0 * 7 + 3) % 256) })

    // MARK: Writer (gated)

    @Test(.enabled(if: V3FixtureWriter.outputFolder != nil, "set TRANSCRIBE_WRITE_V3_FIXTURE to a folder to write the fixture"))
    func writeV3Fixture() throws {
        let fm = FileManager.default
        let output = URL(fileURLWithPath: try #require(Self.outputFolder), isDirectory: true)
        let work = fm.temporaryDirectory.appendingPathComponent("v3-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let storeURL = work.appendingPathComponent("Library.store")

        // Write the library, close, work out the agreed hashes on a scratch copy, write the sync state, close, then
        // reopen to read back the manifest; each container is released before the next step so the store is
        // checkpointed and closed when its files are copied.
        try autoreleasepool { try Self.writeLibrary(at: storeURL) }
        let hashes = try autoreleasepool { try Self.agreedHashes(of: storeURL) }
        try autoreleasepool { try Self.writeSyncState(at: storeURL, hashes: hashes) }
        let manifest = try autoreleasepool { try Self.readManifest(at: storeURL) }

        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: output.path) where name.hasPrefix("Library.store") || name == "manifest.json" {
            try fm.removeItem(at: output.appendingPathComponent(name))
        }
        for name in try fm.contentsOfDirectory(atPath: work.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: work.appendingPathComponent(name), to: output.appendingPathComponent(name))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)

        #expect(manifest.schemaVersion == "3.0.0")
        #expect(try MigrationTests.versionHashes(at: output.appendingPathComponent("Library.store")) == (try Self.v3VersionHashes()))
    }

    // MARK: Committed fixture check (always runs, except while the writer is replacing it)

    @Test(.enabled(if: V3FixtureWriter.outputFolder == nil))
    func committedFixtureIsV3() throws {
        let fm = FileManager.default
        let source = try Self.fixtureDirectory
        let manifest = try Self.decoder.decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        let root = fm.temporaryDirectory.appendingPathComponent("v3-fixture-check-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in try fm.contentsOfDirectory(atPath: source.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let storeURL = root.appendingPathComponent("Library.store")

        // The store's own metadata says V3 (the manifest cannot: it is written by the generator).
        let hashes = try MigrationTests.versionHashes(at: storeURL)
        #expect(hashes == (try Self.v3VersionHashes()))
        #expect(Set(hashes.keys) == ["Folder", "Recording", "RecordingSpeaker", "SyncAccountState", "SyncRecordState",
                                     "VoiceNegative", "VoiceProfile", "VoiceSample"])
        #expect(manifest.schemaVersion == "3.0.0" && manifest.modelKey == Self.modelKey)

        // Reading it back gives the manifest exactly, and the manifest covers every case the spec lists.
        let readBack = try autoreleasepool { try Self.readManifest(at: storeURL) }
        #expect(readBack == manifest)
        #expect(manifest.counts == .init(recordings: 3, speakers: 4, profiles: 2, samples: 4, folders: 1, negatives: 1,
                                         syncRecords: 15, syncAccounts: 1))
        #expect(manifest.stages == ["queued": 1, "ready": 2])
        let samples = manifest.samples
        #expect(Set(samples.compactMap(\.captureChannel)) == [CaptureChannel.iphone, CaptureChannel.mac])
        #expect(samples.contains { $0.clipStart == nil && $0.clipEnd == nil })
        let recordingIDs = Set(manifest.recordings.map(\.id))
        #expect(samples.contains { $0.sourceRecordingID.map { !recordingIDs.contains($0) } == true })
        #expect(manifest.negatives.count == 1 && manifest.negatives[0].captureChannel == CaptureChannel.mac)
        #expect(manifest.folders.count == 1 && manifest.recordings.contains { $0.folderName == "Work" })
        #expect(manifest.recordings.allSatisfy { $0.captureChannel != nil && $0.captureDetailJSON != nil })
        #expect(manifest.speakers.allSatisfy { $0.matchTrace != nil && $0.vectorCoherence != nil })
        // Sync: every syncable row has agreed hashes and system fields; one must merge, one delete is pending, one
        // link is unresolved; the account has engine state.
        #expect(manifest.syncRecords.contains { $0.baseHashesJSON.contains("~mustMerge") && $0.pendingRaw == SyncPending.save.rawValue })
        #expect(manifest.syncRecords.contains { $0.entityID == ID.deletedSample && $0.pendingRaw == SyncPending.delete.rawValue })
        #expect(manifest.syncRecords.contains { $0.unresolvedLinksJSON != nil })
        #expect(manifest.syncRecords.allSatisfy { $0.systemFields != nil && $0.baseHashesJSON != "{}" })
        #expect(!manifest.syncRecords.contains { $0.entityID == ID.queued })
        #expect(manifest.syncAccounts == [.init(key: "default", accountHash: Self.accountHash,
                                                engineState: Self.engineState.base64EncodedString(), zoneReady: true,
                                                pausedReasonRaw: nil, lastFetchAt: Self.date(day: 21, hour: 9, minute: 0),
                                                lastSendAt: Self.date(day: 21, hour: 8, minute: 59))])
    }

    static var fixtureDirectory: URL {
        get throws { try #require(Bundle.module.url(forResource: "V3Library", withExtension: nil, subdirectory: "Fixtures")) }
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Writing the store (V3 types, stored fields only)

    typealias V3 = TranscribeSchemaV3

    static func v3Container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TranscribeSchemaV3.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
    }

    static func v3VersionHashes() throws -> [String: Data] {
        try MigrationTests.versionHashes(of: Schema(versionedSchema: TranscribeSchemaV3.self))
    }

    /// Everything but the sync state: a phone-and-Mac library after stamping, with sync on.
    static func writeLibrary(at url: URL) throws {
        let container = try v3Container(at: url)
        let context = ModelContext(container)

        let work = V3.Folder(id: ID.work, name: "Work", createdAt: date(day: 17, hour: 8, minute: 0))
        context.insert(work)

        let liam = V3.VoiceProfile(id: ID.liam, name: "Liam", colourSlot: 0, embeddingModelKey: modelKey,
                                   now: date(day: 17, hour: 9, minute: 20))
        liam.isMe = true
        let karan = V3.VoiceProfile(id: ID.karan, name: "Karan", colourSlot: 1, embeddingModelKey: modelKey,
                                    now: date(day: 17, hour: 9, minute: 25))
        context.insert(liam)
        context.insert(karan)

        // A (Tue 17 Nov 09:02, on the iPhone, in "Work"): Liam and Karan named.
        let a = recording(context, id: ID.recordingA, createdAt: date(day: 17, hour: 9, minute: 2), channel: CaptureChannel.iphone,
                          detail: iphoneDetail, turns: SeedContent.conversationA, duration: SeedContent.conversationADuration)
        a.folder = work
        let a1 = speaker(context, a, id: ID.speakerA1, key: "S1", ordinal: 1, slot: 0, clean: 14.0, total: 15.2,
                         vector: SyntheticVoices.vector(near: .liam, cosine: 0.88, variant: 21), label: .named, profile: liam,
                         coherence: 0.93, trace: trace(key: "S1", clean: 14.0, kind: .unknown, profile: nil, reason: "noEligibleProfiles",
                                                       score: nil, evidence: [], channel: CaptureChannel.iphone))
        let a2 = speaker(context, a, id: ID.speakerA2, key: "S2", ordinal: 2, slot: 1, clean: 12.5, total: 13.0,
                         vector: SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 2), label: .named, profile: karan,
                         coherence: 0.88, trace: trace(key: "S2", clean: 12.5, kind: .unknown, profile: nil, reason: "lowScore",
                                                       score: 0.05, evidence: [evidence(ID.liam, 0.05)], channel: CaptureChannel.iphone))
        finish(a)

        // B (Wed 18 Nov 14:24, on the Mac, favourite): Liam auto-labelled; a stranger the user said is not Karan,
        // whose suggestion's profile has not arrived from the other device yet.
        let b = recording(context, id: ID.recordingB, createdAt: date(day: 18, hour: 14, minute: 24), channel: CaptureChannel.mac,
                          detail: macDetail, turns: SeedContent.conversationB, duration: SeedContent.conversationBDuration)
        b.isFavourite = true
        b.hasUnseenResult = true
        let b1 = speaker(context, b, id: ID.speakerB1, key: "S1", ordinal: 1, slot: 0, clean: 11.0, total: 11.4,
                         vector: SyntheticVoices.vector(near: .liam, cosine: 0.86, variant: 5), label: .autoLabelled, profile: liam,
                         score: 0.86, margin: 0.8, coherence: 0.92,
                         trace: trace(key: "S1", clean: 11.0, kind: .auto, profile: ID.liam, reason: "auto", score: 0.86,
                                      evidence: [evidence(ID.liam, 0.86), evidence(ID.karan, 0.06)], channel: CaptureChannel.mac))
        let b2 = speaker(context, b, id: ID.speakerB2, key: "S2", ordinal: 2, slot: 1, clean: 11.5, total: 13.0,
                         vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 20), label: .unnamed,
                         coherence: 0.7, trace: trace(key: "S2", clean: 11.5, kind: .ask, profile: ID.karan, reason: "belowAuto",
                                                      score: 0.44, evidence: [evidence(ID.karan, 0.44)], channel: CaptureChannel.mac))
        b2.rejectedProfileIDs = [ID.karan]
        finish(b)

        // Queued (Fri 20 Nov 09:30, on the iPhone): recorded while the models were not ready; never synced.
        let queued = V3.Recording(id: ID.queued, createdAt: date(day: 20, hour: 9, minute: 30),
                                  audioFileName: "\(ID.queued.uuidString).wav", source: .microphone)
        context.insert(queued)
        queued.duration = 31.5
        queued.peaks = peaks(count: 60)
        queued.marks = [12.0]
        queued.stageRaw = RecordingStage.queued.rawValue
        queued.queueReasonRaw = QueueReason.modelsNotReady.rawValue
        queued.languageRaw = "en"
        queued.captureChannel = CaptureChannel.iphone
        queued.captureDetailJSON = iphoneDetail.json()

        // Samples on both channels: one with no clip, one whose recording was deleted since.
        sample(context, liam, id: ID.liamNamed, vector: SyntheticVoices.base(.liam), origin: .named,
               added: date(day: 17, hour: 9, minute: 20), seconds: 14.0, recordingID: ID.recordingA, speakerID: a1.id,
               clip: (1.0, 5.8), quote: "Hey, Karan. Um, I just want to test out if this transcription app works.",
               channel: CaptureChannel.iphone, input: iphoneDetail.input)
        sample(context, karan, id: ID.karanNamed, vector: SyntheticVoices.base(.karan), origin: .named,
               added: date(day: 17, hour: 9, minute: 25), seconds: 12.5, recordingID: ID.recordingA, speakerID: a2.id,
               clip: nil, quote: nil, channel: CaptureChannel.iphone, input: iphoneDetail.input)
        sample(context, liam, id: ID.liamMac, vector: SyntheticVoices.vector(near: .liam, cosine: 0.86, variant: 5), origin: .confirmed,
               added: date(day: 18, hour: 14, minute: 26), seconds: 11.0, recordingID: ID.recordingB, speakerID: b1.id,
               clip: (0.6, 4.9), quote: "Uh yes, testing the transcription app.", channel: CaptureChannel.mac, input: macDetail.input)
        sample(context, liam, id: ID.liamGoneSource, vector: SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 1),
               origin: .corrected, added: date(day: 19, hour: 10, minute: 6), seconds: 10.4, recordingID: ID.goneRecording,
               speakerID: UUID(uuidString: "C3000000-0000-4000-8000-00000000F001")!, clip: (10.8, 14.8), quote: nil,
               channel: CaptureChannel.mac, input: macDetail.input)

        // A negative: the stranger in B is not Karan.
        let n = V3.VoiceNegative(id: ID.karanNegative, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 20),
                                 embeddingModelKey: modelKey, addedAt: date(day: 18, hour: 15, minute: 0), speechSeconds: 11.5)
        context.insert(n)
        n.profile = karan
        n.sourceRecordingID = ID.recordingB
        n.sourceSpeakerID = b2.id
        n.captureChannel = CaptureChannel.mac
        n.captureInput = macDetail.input

        try context.save()
    }

    /// The links in each record's sync row that have not arrived: B2's suggestion names a profile not here yet.
    static let unresolvedLinks: [String: [String: String]] = [
        SyncRecordID(type: .speaker, entityID: ID.speakerB2).recordName: ["profileID": ID.unresolvedProfile.uuidString],
    ]

    /// [recordName: base hashes] for every syncable entity, as the record projector computes them, read from a
    /// scratch copy of the V3 store opened by the current build (see the type's doc comment).
    static func agreedHashes(of v3Store: URL) throws -> [String: [String: String]] {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("v3-fixture-hashes-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let dir = v3Store.deletingLastPathComponent()
        for name in try fm.contentsOfDirectory(atPath: dir.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: dir.appendingPathComponent(name), to: scratch.appendingPathComponent(name))
        }
        let container = try ModelContainerFactory.make(inMemory: false, url: scratch.appendingPathComponent("Library.store"))
        let projector = RecordProjector(context: container.mainContext)
        var out: [String: [String: String]] = [:]
        for type in SyncRecordType.allCases {
            for e in try projector.all(type) where e.isSyncable {
                let name = e.recordID.recordName
                out[name] = RecordProjector.hashes(e, unresolved: unresolvedLinks[name] ?? [:])
            }
        }
        return out
    }

    /// One row per syncable entity, all acknowledged by the server with agreed hashes, plus: Liam's Mac sample must
    /// merge (a server change skipped while it was processed), a deleted sample's delete is waiting to be sent, and B2
    /// has an unresolved link. The account row holds engine state.
    static func writeSyncState(at url: URL, hashes: [String: [String: String]]) throws {
        let container = try v3Container(at: url)
        let context = ModelContext(container)
        let updatedAt = date(day: 21, hour: 8, minute: 30)
        for (name, base) in hashes.sorted(by: { $0.key < $1.key }) {
            let id = try #require(SyncRecordID(recordName: name))
            let row = V3.SyncRecordState(recordName: name, type: id.type, entityID: id.entityID, now: updatedAt)
            context.insert(row)
            row.systemFields = Data("system-fields:\(name)".utf8)
            row.baseHashesJSON = SyncSchema.sortedJSON(base)
            if let links = unresolvedLinks[name] { row.unresolvedLinksJSON = SyncSchema.sortedJSON(links) }
            if id.entityID == ID.liamMac {
                row.baseHashesJSON = SyncSchema.sortedJSON(base.merging(["~mustMerge": "1"]) { a, _ in a })
                row.pendingRaw = SyncPending.save.rawValue
                row.updatedAt = date(day: 21, hour: 8, minute: 45)
            }
        }
        let gone = SyncRecordID(type: .sample, entityID: ID.deletedSample)
        let deleted = V3.SyncRecordState(recordName: gone.recordName, type: .sample, entityID: ID.deletedSample,
                                         now: date(day: 21, hour: 8, minute: 50))
        context.insert(deleted)
        deleted.systemFields = Data("system-fields:\(gone.recordName)".utf8)
        deleted.baseHashesJSON = SyncSchema.sortedJSON(try #require(hashes[SyncRecordID(type: .sample, entityID: ID.liamNamed).recordName]))
        deleted.pendingRaw = SyncPending.delete.rawValue

        let account = V3.SyncAccountState()
        context.insert(account)
        account.accountHash = accountHash
        account.engineState = engineState
        account.zoneReady = true
        account.lastFetchAt = date(day: 21, hour: 9, minute: 0)
        account.lastSendAt = date(day: 21, hour: 8, minute: 59)
        try context.save()
    }

    static func recording(_ context: ModelContext, id: UUID, createdAt: Date, channel: String, detail: CaptureDetail,
                          turns: [ScriptTurn], duration: TimeInterval) -> V3.Recording {
        let r = V3.Recording(id: id, createdAt: createdAt, audioFileName: "\(id.uuidString).wav", source: .microphone)
        context.insert(r)
        let doc = TranscriptDocument(words: SeedContent.allWords(turns), turns: SeedContent.speakerTurns(turns), asrModelID: asrModelID)
        r.duration = duration
        r.peaks = peaks(count: 40)
        r.stageRaw = RecordingStage.ready.rawValue
        r.transcriptData = try? doc.encoded()
        r.asrModelID = asrModelID
        r.embeddingModelKey = modelKey
        r.previewText = String(doc.plainText.replacingOccurrences(of: "\n", with: " ").prefix(200))
        r.captureChannel = channel
        r.captureDetailJSON = detail.json()
        return r
    }

    @discardableResult
    static func speaker(_ context: ModelContext, _ r: V3.Recording, id: UUID, key: SpeakerKey, ordinal: Int, slot: Int,
                        clean: Double, total: Double, vector: VoiceVector, label: SpeakerLabelState, profile: V3.VoiceProfile? = nil,
                        score: Double? = nil, margin: Double? = nil, coherence: Double, trace: Data) -> V3.RecordingSpeaker {
        let s = V3.RecordingSpeaker(id: id, key: key, ordinal: ordinal, colourSlot: slot)
        context.insert(s)
        s.recording = r
        s.cleanSeconds = clean
        s.totalSeconds = total
        s.turnCount = r.transcriptData.flatMap { try? TranscriptDocument.decode($0) }?.turns.filter { $0.speakerKey == key }.count ?? 0
        s.vectorData = vector.packed
        s.embeddingModelKey = modelKey
        s.labelRaw = label.rawValue
        s.profile = profile
        s.matchScore = score
        s.matchMargin = margin
        s.vectorCoherence = coherence
        s.matchTraceData = trace
        return s
    }

    static func sample(_ context: ModelContext, _ p: V3.VoiceProfile, id: UUID, vector: VoiceVector, origin: SampleOrigin, added: Date,
                       seconds: Double, recordingID: UUID, speakerID: UUID, clip: (Double, Double)?, quote: String?,
                       channel: String, input: String?) {
        let s = V3.VoiceSample(id: id, vector: vector, embeddingModelKey: modelKey, origin: origin, addedAt: added, speechSeconds: seconds)
        context.insert(s)
        s.profile = p
        s.sourceRecordingID = recordingID
        s.sourceSpeakerID = speakerID
        s.clipStart = clip?.0
        s.clipEnd = clip?.1
        s.quote = quote
        s.captureChannel = channel
        s.captureInput = input
    }

    /// searchText = lowercased title + transcript + speaker names (as the store builds it).
    static func finish(_ r: V3.Recording) {
        var parts: [String] = []
        if let title = r.title { parts.append(title) }
        if let doc = r.transcriptData.flatMap({ try? TranscriptDocument.decode($0) }) { parts.append(doc.plainText) }
        parts.append(contentsOf: r.speakers.sorted { $0.ordinal < $1.ordinal }.compactMap { $0.profile?.name ?? $0.nameSnapshot })
        r.searchText = parts.joined(separator: "\n").lowercased()
    }

    static func peaks(count: Int) -> [Float] { V2FixtureWriter.peaks(count: count) }

    static func evidence(_ id: UUID, _ score: Float) -> ProfileEvidence { V2FixtureWriter.evidence(id, score) }

    /// A version 2 trace (the format V3 stores hold), with the probe's channel.
    static func trace(key: SpeakerKey, clean: Double, kind: TraceKind, profile: UUID?, reason: String, score: Float?,
                      evidence: [ProfileEvidence], channel: String) -> Data {
        try! JSONEncoder().encode(MatchTrace(version: 2, key: key, cleanSeconds: clean, kind: kind, profileID: profile, reason: reason,
                                             score: score, runnerUp: nil, margin: nil, profiles: evidence, cohortSize: 0,
                                             cohortTopMean: nil, cohortTopStd: nil, autoLabelMin: 0.55, autoLabelMargin: 0.10,
                                             askMin: 0.40, probeChannel: channel))
    }

    // MARK: Manifest (read back from a store with the V3 schema)

    struct Manifest: Codable, Equatable {
        struct Counts: Codable, Equatable {
            var recordings, speakers, profiles, samples, folders, negatives, syncRecords, syncAccounts: Int
        }
        typealias Profile = V2FixtureWriter.Manifest.Profile
        typealias Speaker = V2FixtureWriter.Manifest.Speaker
        typealias FolderRow = V2FixtureWriter.Manifest.FolderRow
        struct Sample: Codable, Equatable {
            var id: UUID; var profileID: UUID?; var origin: String; var speechSeconds: Double; var embeddingModelKey: String
            var packed: String; var addedAt: Date; var sourceRecordingID: UUID?; var sourceSpeakerID: UUID?
            var clipStart: Double?; var clipEnd: Double?; var quote: String?; var captureChannel: String?; var captureInput: String?
        }
        struct Negative: Codable, Equatable {
            var id: UUID; var profileID: UUID?; var speechSeconds: Double; var embeddingModelKey: String; var packed: String
            var addedAt: Date; var sourceRecordingID: UUID?; var sourceSpeakerID: UUID?; var captureChannel: String?
            var captureInput: String?
        }
        struct RecordingRow: Codable, Equatable {
            var id: UUID; var createdAt: Date; var title: String?; var duration: Double; var audioFileName: String
            var source: String; var stage: Int; var queueReason: String?; var failureMessage: String?; var attemptCount: Int
            var isFavourite: Bool; var hasUnseenResult: Bool; var noSpeech: Bool; var language: String?; var marks: [Double]
            var peakCount: Int; var previewText: String; var searchText: String; var transcriptSHA256: String?
            var asrModelID: String?; var embeddingModelKey: String?; var folderID: UUID?; var folderName: String?
            var speakerCount: Int; var movedSpeakerTraces: String?; var captureChannel: String?; var captureDetailJSON: String?
        }
        struct SyncRecordRow: Codable, Equatable {
            var recordName: String; var typeRaw: String; var entityID: UUID; var systemFields: String?
            var baseHashesJSON: String; var pendingRaw: Int; var unresolvedLinksJSON: String?; var updatedAt: Date
        }
        struct SyncAccountRow: Codable, Equatable {
            var key: String; var accountHash: String?; var engineState: String?; var zoneReady: Bool
            var pausedReasonRaw: String?; var lastFetchAt: Date?; var lastSendAt: Date?
        }

        var schemaVersion: String
        var modelKey: String
        var counts: Counts
        /// Recordings per stage name ("ready", "queued", …).
        var stages: [String: Int]
        var profiles: [Profile]
        var samples: [Sample]
        var negatives: [Negative]
        var speakers: [Speaker]
        var recordings: [RecordingRow]
        var folders: [FolderRow]
        var syncRecords: [SyncRecordRow]
        var syncAccounts: [SyncAccountRow]
    }

    static func readManifest(at url: URL) throws -> Manifest {
        let container = try v3Container(at: url)
        let context = ModelContext(container)
        let recordings = try context.fetch(FetchDescriptor<V3.Recording>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let speakers = try context.fetch(FetchDescriptor<V3.RecordingSpeaker>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let profiles = try context.fetch(FetchDescriptor<V3.VoiceProfile>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let samples = try context.fetch(FetchDescriptor<V3.VoiceSample>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let negatives = try context.fetch(FetchDescriptor<V3.VoiceNegative>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let folders = try context.fetch(FetchDescriptor<V3.Folder>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let states = try context.fetch(FetchDescriptor<V3.SyncRecordState>()).sorted { $0.recordName < $1.recordName }
        let accounts = try context.fetch(FetchDescriptor<V3.SyncAccountState>()).sorted { $0.key < $1.key }

        var stages: [String: Int] = [:]
        for r in recordings { stages[RecordingStage(rawValue: r.stageRaw).map { "\($0)" } ?? "\(r.stageRaw)", default: 0] += 1 }

        return Manifest(
            schemaVersion: "\(TranscribeSchemaV3.versionIdentifier)",
            modelKey: modelKey,
            counts: .init(recordings: recordings.count, speakers: speakers.count, profiles: profiles.count, samples: samples.count,
                          folders: folders.count, negatives: negatives.count, syncRecords: states.count, syncAccounts: accounts.count),
            stages: stages,
            profiles: profiles.map {
                .init(id: $0.id, name: $0.name, isMe: $0.isMe, colourSlot: $0.colourSlot, createdAt: $0.createdAt, namedAt: $0.namedAt,
                      autoLabel: $0.autoLabel, embeddingModelKey: $0.embeddingModelKey, needsResample: $0.needsResample,
                      sampleCount: $0.samples.count, negativeCount: $0.negatives.count)
            },
            samples: samples.map {
                .init(id: $0.id, profileID: $0.profile?.id, origin: $0.originRaw, speechSeconds: $0.speechSeconds,
                      embeddingModelKey: $0.embeddingModelKey, packed: $0.vectorData.base64EncodedString(), addedAt: $0.addedAt,
                      sourceRecordingID: $0.sourceRecordingID, sourceSpeakerID: $0.sourceSpeakerID, clipStart: $0.clipStart,
                      clipEnd: $0.clipEnd, quote: $0.quote, captureChannel: $0.captureChannel, captureInput: $0.captureInput)
            },
            negatives: negatives.map {
                .init(id: $0.id, profileID: $0.profile?.id, speechSeconds: $0.speechSeconds, embeddingModelKey: $0.embeddingModelKey,
                      packed: $0.vectorData.base64EncodedString(), addedAt: $0.addedAt, sourceRecordingID: $0.sourceRecordingID,
                      sourceSpeakerID: $0.sourceSpeakerID, captureChannel: $0.captureChannel, captureInput: $0.captureInput)
            },
            speakers: speakers.map {
                .init(id: $0.id, recordingID: $0.recording?.id, key: $0.key, ordinal: $0.ordinal, colourSlot: $0.colourSlot,
                      label: $0.labelRaw, profileID: $0.profile?.id, suggestedProfileID: $0.suggestedProfileID,
                      rejectedProfileIDs: $0.rejectedProfileIDs, nameSnapshot: $0.nameSnapshot, cleanSeconds: $0.cleanSeconds,
                      totalSeconds: $0.totalSeconds, turnCount: $0.turnCount, matchScore: $0.matchScore, matchMargin: $0.matchMargin,
                      vector: $0.vectorData?.base64EncodedString(), embeddingModelKey: $0.embeddingModelKey,
                      vectorCoherence: $0.vectorCoherence, matchTrace: $0.matchTraceData?.base64EncodedString())
            },
            recordings: recordings.map {
                .init(id: $0.id, createdAt: $0.createdAt, title: $0.title, duration: $0.duration, audioFileName: $0.audioFileName,
                      source: $0.sourceRaw, stage: $0.stageRaw, queueReason: $0.queueReasonRaw, failureMessage: $0.failureMessage,
                      attemptCount: $0.attemptCount, isFavourite: $0.isFavourite, hasUnseenResult: $0.hasUnseenResult,
                      noSpeech: $0.noSpeech, language: $0.languageRaw, marks: $0.marks, peakCount: $0.peaks.count,
                      previewText: $0.previewText, searchText: $0.searchText,
                      transcriptSHA256: $0.transcriptData.map(V2FixtureWriter.sha256Hex), asrModelID: $0.asrModelID,
                      embeddingModelKey: $0.embeddingModelKey, folderID: $0.folder?.id, folderName: $0.folder?.name,
                      speakerCount: $0.speakers.count, movedSpeakerTraces: $0.movedSpeakerTracesData?.base64EncodedString(),
                      captureChannel: $0.captureChannel, captureDetailJSON: $0.captureDetailJSON)
            },
            folders: folders.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt, recordingCount: $0.recordings.count) },
            syncRecords: states.map {
                .init(recordName: $0.recordName, typeRaw: $0.typeRaw, entityID: $0.entityID,
                      systemFields: $0.systemFields?.base64EncodedString(), baseHashesJSON: String(decoding: $0.baseHashesJSON, as: UTF8.self),
                      pendingRaw: $0.pendingRaw, unresolvedLinksJSON: $0.unresolvedLinksJSON.map { String(decoding: $0, as: UTF8.self) },
                      updatedAt: $0.updatedAt)
            },
            syncAccounts: accounts.map {
                .init(key: $0.key, accountHash: $0.accountHash, engineState: $0.engineState?.base64EncodedString(),
                      zoneReady: $0.zoneReady, pausedReasonRaw: $0.pausedReasonRaw, lastFetchAt: $0.lastFetchAt,
                      lastSendAt: $0.lastSendAt)
            }
        )
    }
}
