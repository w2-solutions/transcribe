import CoreData
import CryptoKit
import Foundation
import SwiftData
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// Writes `Fixtures/V2Library`: a store made by the V2 schema, committed so that later schema versions can prove
/// they open a V2 library without losing anything (the owner's phone runs V2).
///
/// The writer runs only when `TRANSCRIBE_WRITE_V2_FIXTURE` names a folder:
///
///     cd TranscribeKit && TRANSCRIBE_WRITE_V2_FIXTURE=$PWD/Tests/TranscribeKitTests/Fixtures/V2Library \
///         swift test --filter V2FixtureWriter
///
/// It names every model as `TranscribeSchemaV2.X` and sets stored fields only (never the type aliases, the computed
/// accessors or `ModelContainerFactory`), so it keeps writing a true V2 store after the aliases move to a newer
/// schema. Every id and date is fixed. `manifest.json` is read back from the written store, not from the inputs.
@Suite("V2 fixture writer")
@MainActor
struct V2FixtureWriter {
    nonisolated static let envKey = "TRANSCRIBE_WRITE_V2_FIXTURE"
    nonisolated static var outputFolder: String? {
        ProcessInfo.processInfo.environment[envKey].flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Fixed ids and dates

    enum ID {
        static func u(_ s: String) -> UUID { UUID(uuidString: s)! }
        static let recordingA = u("A0000000-0000-4000-8000-00000000000A")   // ready, in folder "Work"
        static let recordingB = u("A0000000-0000-4000-8000-00000000000B")   // ready, favourite
        static let recordingC = u("A0000000-0000-4000-8000-00000000000C")   // ready, movedSpeakerTracesData
        static let recordingD = u("A0000000-0000-4000-8000-00000000000D")   // ready, suggested speaker
        static let imported = u("A0000000-0000-4000-8000-000000000011")     // imported, failed
        static let queued = u("A0000000-0000-4000-8000-000000000012")       // queued for models
        static let liam = u("B0000000-0000-4000-8000-000000000001")
        static let karan = u("B0000000-0000-4000-8000-000000000002")
        static let work = u("F0000000-0000-4000-8000-000000000001")
        static let speakerA1 = u("C0000000-0000-4000-8000-00000000A001")
        static let speakerA2 = u("C0000000-0000-4000-8000-00000000A002")
        static let speakerB1 = u("C0000000-0000-4000-8000-00000000B001")
        static let speakerB2 = u("C0000000-0000-4000-8000-00000000B002")
        static let speakerC1 = u("C0000000-0000-4000-8000-00000000C001")
        static let speakerC2 = u("C0000000-0000-4000-8000-00000000C002")
        static let speakerD1 = u("C0000000-0000-4000-8000-00000000D001")
        static let speakerD2 = u("C0000000-0000-4000-8000-00000000D002")
        static let speakerD3 = u("C0000000-0000-4000-8000-00000000D003")
        static let liamNamed = u("50000000-0000-4000-8000-000000000001")
        static let liamConfirmedShort = u("50000000-0000-4000-8000-000000000002")
        static let liamStrongMatch = u("50000000-0000-4000-8000-000000000003")
        static let karanNamed = u("50000000-0000-4000-8000-000000000004")
        static let karanCorrected = u("50000000-0000-4000-8000-000000000005")
        static let karanNegativeC = u("E0000000-0000-4000-8000-000000000001")
        static let karanNegativeD = u("E0000000-0000-4000-8000-000000000002")
    }

    /// Whole seconds from Tue 17 Nov 2026 00:00 UTC, so ISO 8601 in the manifest round-trips exactly.
    static func date(day: Int, hour: Int, minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_794_873_600 + Double((day - 17) * 86_400 + hour * 3_600 + minute * 60))
    }

    static let modelKey = EmbeddingModelID.fake.key
    static let asrModelID = "fake-parakeet"

    // MARK: Writer (gated)

    @Test(.enabled(if: V2FixtureWriter.outputFolder != nil, "set TRANSCRIBE_WRITE_V2_FIXTURE to a folder to write the fixture"))
    func writeV2Fixture() throws {
        let fm = FileManager.default
        let output = URL(fileURLWithPath: try #require(Self.outputFolder), isDirectory: true)
        let work = fm.temporaryDirectory.appendingPathComponent("v2-fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let storeURL = work.appendingPathComponent("Library.store")

        // Write, close, then reopen to read back the manifest; each container is released before the next step so
        // the store is checkpointed and closed when its files are copied.
        try autoreleasepool { try Self.writeStore(at: storeURL) }
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

        #expect(manifest.schemaVersion == "2.0.0")
        #expect(try Self.versionHashes(at: output.appendingPathComponent("Library.store")) == (try Self.v2VersionHashes()))
    }

    // MARK: Committed fixture check (always runs, except while the writer is replacing it)

    @Test(.enabled(if: V2FixtureWriter.outputFolder == nil))
    func committedFixtureIsV2() throws {
        let fm = FileManager.default
        let source = try #require(Bundle.module.url(forResource: "V2Library", withExtension: nil, subdirectory: "Fixtures"))
        let manifest = try JSONDecoder.fixture.decode(Manifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
        let root = fm.temporaryDirectory.appendingPathComponent("v2-fixture-check-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in try fm.contentsOfDirectory(atPath: source.path) where name.hasPrefix("Library.store") {
            try fm.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let storeURL = root.appendingPathComponent("Library.store")

        // The store's own metadata says V2 (the manifest cannot: it is written by the generator).
        let hashes = try Self.versionHashes(at: storeURL)
        #expect(hashes == (try Self.v2VersionHashes()))
        #expect(Set(hashes.keys) == ["Folder", "Recording", "RecordingSpeaker", "VoiceNegative", "VoiceProfile", "VoiceSample"])
        #expect(manifest.schemaVersion == "2.0.0" && manifest.modelKey == Self.modelKey)

        // Reading it back gives the manifest exactly, and the manifest covers every case the spec lists.
        let readBack = try autoreleasepool { try Self.readManifest(at: storeURL) }
        #expect(readBack == manifest)
        #expect(manifest.counts == .init(recordings: 6, speakers: 9, profiles: 2, samples: 5, folders: 1, negatives: 2))
        #expect(manifest.stages == ["failed": 1, "queued": 1, "ready": 4])
        let liam = try #require(manifest.profiles.first { $0.id == ID.liam })
        #expect(liam.isMe && liam.name == "Liam")
        #expect(Set(manifest.samples.filter { $0.profileID == ID.liam }.map(\.origin)) == ["named", "confirmed", "strongMatch"])
        #expect(manifest.samples.contains { $0.profileID == ID.liam && $0.origin == "confirmed" && $0.speechSeconds < 10 })
        #expect(Set(manifest.samples.filter { $0.profileID == ID.karan }.map(\.origin)) == ["named", "corrected"])
        #expect(manifest.negatives.count == 2 && manifest.negatives.allSatisfy { $0.profileID == ID.karan })
        let ready = manifest.recordings.filter { $0.stage == RecordingStage.ready.rawValue }
        #expect(ready.contains { $0.folderName == "Work" })
        #expect(ready.contains { $0.isFavourite })
        #expect(ready.contains { $0.movedSpeakerTraces != nil })
        #expect(manifest.speakers.contains { $0.label == SpeakerLabelState.suggested.rawValue && !$0.rejectedProfileIDs.isEmpty })
        #expect(manifest.recordings.contains { $0.source == RecordingSource.imported.rawValue })
        #expect(manifest.recordings.contains { $0.stage == RecordingStage.queued.rawValue })
        #expect(manifest.speakers.allSatisfy { $0.matchTrace != nil && $0.vectorCoherence != nil })
    }

    // MARK: Writing the store (V2 types, stored fields only)

    typealias V2 = TranscribeSchemaV2

    static func v2Container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TranscribeSchemaV2.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
    }

    static func writeStore(at url: URL) throws {
        let container = try v2Container(at: url)
        let context = ModelContext(container)

        let work = V2.Folder(id: ID.work, name: "Work", createdAt: date(day: 17, hour: 8, minute: 0))
        context.insert(work)

        let liam = V2.VoiceProfile(id: ID.liam, name: "Liam", colourSlot: 0, embeddingModelKey: modelKey,
                                   now: date(day: 17, hour: 9, minute: 20))
        liam.isMe = true
        let karan = V2.VoiceProfile(id: ID.karan, name: "Karan", colourSlot: 1, embeddingModelKey: modelKey,
                                    now: date(day: 18, hour: 14, minute: 25))
        context.insert(liam)
        context.insert(karan)

        // C (Tue 17 Nov 09:02): Liam named; an unnamed stranger the user said is not Karan; a third speaker the user
        // merged into S1 ("Same as"), whose trace is kept on the recording.
        let c = recording(context, id: ID.recordingC, createdAt: date(day: 17, hour: 9, minute: 2),
                          turns: SeedContent.conversationA, duration: SeedContent.conversationADuration)
        c.movedSpeakerTracesData = try JSONEncoder().encode([
            MovedSpeakerTrace(key: "S3", ordinal: 3, cleanSeconds: 2.4, coherence: 0.42, movedTo: "S1", rejectedProfileIDs: [],
                              trace: matchTrace(key: "S3", clean: 2.4, kind: .unknown, profile: nil, reason: "tooShort",
                                                score: nil, runnerUp: nil, margin: nil, evidence: [])),
        ])
        let c1 = speaker(context, c, id: ID.speakerC1, key: "S1", ordinal: 1, slot: 0, clean: 14.0, total: 15.2,
                         vector: SyntheticVoices.vector(near: .liam, cosine: 0.88, variant: 21), label: .named, profile: liam,
                         coherence: 0.93, trace: trace(key: "S1", clean: 14.0, kind: .unknown, profile: nil, reason: "noEligibleProfiles",
                                                       score: nil, runnerUp: nil, margin: nil, evidence: []))
        let c2 = speaker(context, c, id: ID.speakerC2, key: "S2", ordinal: 2, slot: 1, clean: 42, total: 45,
                         vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 20), label: .unnamed,
                         coherence: 0.88, trace: trace(key: "S2", clean: 42, kind: .ask, profile: ID.karan, reason: "belowAuto",
                                                       score: 0.44, runnerUp: 0.12, margin: 0.32,
                                                       evidence: [evidence(ID.karan, 0.44), evidence(ID.liam, 0.12)]))
        c2.rejectedProfileIDs = [ID.karan]
        finish(c)

        // B (Wed 18 Nov 14:24, favourite): Liam confirmed (a short sample), Karan named.
        let b = recording(context, id: ID.recordingB, createdAt: date(day: 18, hour: 14, minute: 24),
                          turns: SeedContent.conversationB, duration: SeedContent.conversationBDuration)
        b.isFavourite = true
        let b1 = speaker(context, b, id: ID.speakerB1, key: "S1", ordinal: 1, slot: 0, clean: 6.0, total: 11.4,
                         vector: SyntheticVoices.vector(near: .liam, cosine: 0.90, variant: 1), label: .named, profile: liam,
                         coherence: 0.81, trace: trace(key: "S1", clean: 6.0, kind: .ask, profile: ID.liam, reason: "belowAuto",
                                                       score: 0.52, runnerUp: nil, margin: nil, evidence: [evidence(ID.liam, 0.52)]))
        let b2 = speaker(context, b, id: ID.speakerB2, key: "S2", ordinal: 2, slot: 1, clean: 11.5, total: 13.0,
                         vector: SyntheticVoices.vector(near: .karan, cosine: 0.90, variant: 2), label: .named, profile: karan,
                         coherence: 0.9, trace: trace(key: "S2", clean: 11.5, kind: .unknown, profile: nil, reason: "lowScore",
                                                      score: 0.05, runnerUp: nil, margin: nil, evidence: [evidence(ID.liam, 0.05)]))
        finish(b)

        // A (Wed 18 Nov 14:29, in "Work", unseen result): Liam auto-labelled; S2 auto-labelled as Liam, corrected to Karan.
        let a = recording(context, id: ID.recordingA, createdAt: date(day: 18, hour: 14, minute: 29),
                          turns: SeedContent.conversationA, duration: SeedContent.conversationADuration)
        a.folder = work
        a.hasUnseenResult = true
        speaker(context, a, id: ID.speakerA1, key: "S1", ordinal: 1, slot: 0, clean: 14.1, total: 14.5,
                vector: SyntheticVoices.vector(near: .liam, cosine: 0.82, variant: 3), label: .autoLabelled, profile: liam,
                score: 0.82, margin: 0.7, coherence: 0.95,
                trace: trace(key: "S1", clean: 14.1, kind: .auto, profile: ID.liam, reason: "auto", score: 0.82, runnerUp: 0.12,
                             margin: 0.7, evidence: [evidence(ID.liam, 0.82), evidence(ID.karan, 0.12)]))
        let a2 = speaker(context, a, id: ID.speakerA2, key: "S2", ordinal: 2, slot: 1, clean: 10.4, total: 10.8,
                         vector: SyntheticVoices.vector(near: .karan, cosine: 0.71, variant: 4), label: .named, profile: karan,
                         coherence: 0.77,
                         trace: trace(key: "S2", clean: 10.4, kind: .auto, profile: ID.liam, reason: "auto", score: 0.58,
                                      runnerUp: 0.31, margin: 0.27, evidence: [evidence(ID.liam, 0.58), evidence(ID.karan, 0.31)]))
        a2.rejectedProfileIDs = [ID.liam]
        finish(a)

        // D (Thu 19 Nov 10:05, unseen result): Liam auto-labelled (strong match sample); S2 "Is this Karan?" after the
        // user said it is not Liam; S3 a stranger the user said is not Karan.
        let d = recording(context, id: ID.recordingD, createdAt: date(day: 19, hour: 10, minute: 5),
                          turns: SeedContent.conversationB, duration: SeedContent.conversationBDuration)
        d.hasUnseenResult = true
        let d1 = speaker(context, d, id: ID.speakerD1, key: "S1", ordinal: 1, slot: 0, clean: 11.0, total: 11.4,
                         vector: SyntheticVoices.vector(near: .liam, cosine: 0.86, variant: 5), label: .autoLabelled, profile: liam,
                         score: 0.86, margin: 0.8, coherence: 0.92,
                         trace: trace(key: "S1", clean: 11.0, kind: .auto, profile: ID.liam, reason: "auto", score: 0.86,
                                      runnerUp: 0.06, margin: 0.8, evidence: [evidence(ID.liam, 0.86), evidence(ID.karan, 0.06)]))
        let d2 = speaker(context, d, id: ID.speakerD2, key: "S2", ordinal: 2, slot: 1, clean: 11.5, total: 13.0,
                         vector: SyntheticVoices.vector(near: .karan, cosine: 0.47, variant: 6), label: .suggested,
                         score: 0.47, coherence: 0.7,
                         trace: trace(key: "S2", clean: 11.5, kind: .ask, profile: ID.karan, reason: "belowAuto", score: 0.47,
                                      runnerUp: 0.1, margin: 0.37, evidence: [evidence(ID.karan, 0.47), evidence(ID.liam, 0.1)]))
        d2.suggestedProfileID = ID.karan
        d2.rejectedProfileIDs = [ID.liam]
        let d3 = speaker(context, d, id: ID.speakerD3, key: "S3", ordinal: 3, slot: 2, clean: 8.0, total: 8.6,
                         vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 22), label: .unnamed,
                         coherence: 0.66,
                         trace: trace(key: "S3", clean: 8.0, kind: .ask, profile: ID.karan, reason: "belowAuto", score: 0.41,
                                      runnerUp: 0.02, margin: 0.39, evidence: [evidence(ID.karan, 0.41), evidence(ID.liam, 0.02)]))
        d3.rejectedProfileIDs = [ID.karan]
        finish(d)

        // Imported (Fri 20 Nov 08:00): a file that failed to process; paragraphs only, no speakers.
        let imported = V2.Recording(id: ID.imported, createdAt: date(day: 20, hour: 8, minute: 0),
                                    audioFileName: "\(ID.imported.uuidString).wav", source: .imported)
        context.insert(imported)
        imported.title = "Imported memo"
        imported.duration = SeedContent.conversationBDuration
        imported.peaks = peaks(count: 48)
        imported.stageRaw = RecordingStage.failed.rawValue
        imported.failureMessage = "Couldn't finish processing"
        imported.attemptCount = 3
        imported.transcriptData = try TranscriptDocument(words: SeedContent.allWords(SeedContent.conversationB),
                                                         turns: SeedContent.paragraphs(SeedContent.conversationB),
                                                         asrModelID: asrModelID).encoded()
        imported.asrModelID = asrModelID
        finish(imported)

        // Queued (Fri 20 Nov 09:30): recorded while the models were not ready; nothing transcribed yet.
        let queued = V2.Recording(id: ID.queued, createdAt: date(day: 20, hour: 9, minute: 30),
                                  audioFileName: "\(ID.queued.uuidString).wav", source: .microphone)
        context.insert(queued)
        queued.duration = 31.5
        queued.peaks = peaks(count: 60)
        queued.marks = [12.0]
        queued.stageRaw = RecordingStage.queued.rawValue
        queued.queueReasonRaw = QueueReason.modelsNotReady.rawValue
        queued.languageRaw = "en"

        // Samples: Liam named (12 s), confirmed (6 s, short), strong match; Karan named and corrected.
        sample(context, liam, id: ID.liamNamed, vector: SyntheticVoices.base(.liam), origin: .named, added: date(day: 17, hour: 9, minute: 20),
               seconds: 12.0, from: c1, clip: (1.0, 5.8), quote: "Hey, Karan. Um, I just want to test out if this transcription app works.")
        sample(context, liam, id: ID.liamConfirmedShort, vector: SyntheticVoices.vector(near: .liam, cosine: 0.9, variant: 1),
               origin: .confirmed, added: date(day: 18, hour: 14, minute: 26), seconds: 6.0, from: b1, clip: (0.6, 4.9), quote: nil)
        sample(context, liam, id: ID.liamStrongMatch, vector: SyntheticVoices.vector(near: .liam, cosine: 0.86, variant: 5),
               origin: .strongMatch, added: date(day: 19, hour: 10, minute: 6), seconds: 11.0, from: d1, clip: nil, quote: nil)
        sample(context, karan, id: ID.karanNamed, vector: SyntheticVoices.base(.karan), origin: .named, added: date(day: 18, hour: 14, minute: 25),
               seconds: 11.5, from: b2, clip: (7.05, 10.0), quote: "Uh yes, testing the transcription app.")
        sample(context, karan, id: ID.karanCorrected, vector: SyntheticVoices.vector(near: .karan, cosine: 0.71, variant: 4),
               origin: .corrected, added: date(day: 18, hour: 14, minute: 35), seconds: 10.4, from: a2, clip: (10.8, 14.8), quote: nil)

        // Negatives: two voices the user said are not Karan.
        negative(context, karan, id: ID.karanNegativeC, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 20),
                 added: date(day: 18, hour: 15, minute: 0), seconds: 12.0, from: c2)
        negative(context, karan, id: ID.karanNegativeD, vector: SyntheticVoices.vector(near: .stranger, cosine: 0.9, variant: 22),
                 added: date(day: 19, hour: 10, minute: 10), seconds: 8.0, from: d3)

        try context.save()
    }

    static func recording(_ context: ModelContext, id: UUID, createdAt: Date, turns: [ScriptTurn], duration: TimeInterval) -> V2.Recording {
        let r = V2.Recording(id: id, createdAt: createdAt, audioFileName: "\(id.uuidString).wav", source: .microphone)
        context.insert(r)
        let doc = TranscriptDocument(words: SeedContent.allWords(turns), turns: SeedContent.speakerTurns(turns), asrModelID: asrModelID)
        r.duration = duration
        r.peaks = peaks(count: 40)
        r.stageRaw = RecordingStage.ready.rawValue
        r.transcriptData = try? doc.encoded()
        r.asrModelID = asrModelID
        r.embeddingModelKey = modelKey
        r.previewText = String(doc.plainText.replacingOccurrences(of: "\n", with: " ").prefix(200))
        return r
    }

    @discardableResult
    static func speaker(_ context: ModelContext, _ r: V2.Recording, id: UUID, key: SpeakerKey, ordinal: Int, slot: Int,
                        clean: Double, total: Double, vector: VoiceVector, label: SpeakerLabelState, profile: V2.VoiceProfile? = nil,
                        score: Double? = nil, margin: Double? = nil, coherence: Double, trace: Data) -> V2.RecordingSpeaker {
        let s = V2.RecordingSpeaker(id: id, key: key, ordinal: ordinal, colourSlot: slot)
        context.insert(s)
        s.recording = r
        s.cleanSeconds = clean
        s.totalSeconds = total
        s.turnCount = transcript(of: r)?.turns.filter { $0.speakerKey == key }.count ?? 0
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

    static func sample(_ context: ModelContext, _ p: V2.VoiceProfile, id: UUID, vector: VoiceVector, origin: SampleOrigin, added: Date,
                       seconds: Double, from speaker: V2.RecordingSpeaker, clip: (Double, Double)?, quote: String?) {
        let s = V2.VoiceSample(id: id, vector: vector, embeddingModelKey: modelKey, origin: origin, addedAt: added, speechSeconds: seconds)
        context.insert(s)
        s.profile = p
        s.sourceRecordingID = speaker.recording?.id
        s.sourceSpeakerID = speaker.id
        s.clipStart = clip?.0
        s.clipEnd = clip?.1
        s.quote = quote
    }

    static func negative(_ context: ModelContext, _ p: V2.VoiceProfile, id: UUID, vector: VoiceVector, added: Date, seconds: Double,
                         from speaker: V2.RecordingSpeaker) {
        let n = V2.VoiceNegative(id: id, vector: vector, embeddingModelKey: modelKey, addedAt: added, speechSeconds: seconds)
        context.insert(n)
        n.profile = p
        n.sourceRecordingID = speaker.recording?.id
        n.sourceSpeakerID = speaker.id
    }

    /// searchText = lowercased title + transcript + speaker names (as the store builds it).
    static func finish(_ r: V2.Recording) {
        var parts: [String] = []
        if let title = r.title { parts.append(title) }
        if let doc = transcript(of: r) { parts.append(doc.plainText) }
        parts.append(contentsOf: r.speakers.sorted { $0.ordinal < $1.ordinal }.compactMap { $0.profile?.name ?? $0.nameSnapshot })
        r.searchText = parts.joined(separator: "\n").lowercased()
    }

    static func transcript(of r: V2.Recording) -> TranscriptDocument? {
        r.transcriptData.flatMap { try? TranscriptDocument.decode($0) }
    }

    static func peaks(count: Int) -> [Float] {
        (0..<count).map { Float((($0 * 37) % 100)) / 100 }
    }

    static func evidence(_ id: UUID, _ score: Float) -> ProfileEvidence {
        ProfileEvidence(profileID: id, score: score, trustedTop: score, trustedScore: score, trustedCount: 1, untrustedCount: 0,
                        askOnly: false, negativeMax: nil, blocked: false, cohortMax: nil)
    }

    static func trace(key: SpeakerKey, clean: Double, kind: TraceKind, profile: UUID?, reason: String, score: Float?,
                      runnerUp: Float?, margin: Float?, evidence: [ProfileEvidence]) -> Data {
        try! JSONEncoder().encode(matchTrace(key: key, clean: clean, kind: kind, profile: profile, reason: reason, score: score,
                                             runnerUp: runnerUp, margin: margin, evidence: evidence))
    }

    static func matchTrace(key: SpeakerKey, clean: Double, kind: TraceKind, profile: UUID?, reason: String, score: Float?,
                           runnerUp: Float?, margin: Float?, evidence: [ProfileEvidence]) -> MatchTrace {
        // Version 1: the trace format V2 stores held (MatchTrace v2 arrived with capture channels in stage 6).
        MatchTrace(version: 1, key: key, cleanSeconds: clean, kind: kind, profileID: profile, reason: reason, score: score,
                   runnerUp: runnerUp, margin: margin, profiles: evidence, cohortSize: 0, cohortTopMean: nil,
                   cohortTopStd: nil, autoLabelMin: 0.55, autoLabelMargin: 0.10, askMin: 0.40)
    }

    // MARK: Manifest (read back from a store with the V2 schema)

    struct Manifest: Codable, Equatable {
        struct Counts: Codable, Equatable { var recordings, speakers, profiles, samples, folders, negatives: Int }
        struct Profile: Codable, Equatable {
            var id: UUID; var name: String; var isMe: Bool; var colourSlot: Int; var createdAt: Date; var namedAt: Date
            var autoLabel: Bool; var embeddingModelKey: String; var needsResample: Bool; var sampleCount: Int; var negativeCount: Int
        }
        struct Sample: Codable, Equatable {
            var id: UUID; var profileID: UUID?; var origin: String; var speechSeconds: Double; var embeddingModelKey: String
            var packed: String; var addedAt: Date; var sourceRecordingID: UUID?; var sourceSpeakerID: UUID?
            var clipStart: Double?; var clipEnd: Double?; var quote: String?
        }
        struct Negative: Codable, Equatable {
            var id: UUID; var profileID: UUID?; var speechSeconds: Double; var embeddingModelKey: String; var packed: String
            var addedAt: Date; var sourceRecordingID: UUID?; var sourceSpeakerID: UUID?
        }
        struct Speaker: Codable, Equatable {
            var id: UUID; var recordingID: UUID?; var key: String; var ordinal: Int; var colourSlot: Int; var label: String
            var profileID: UUID?; var suggestedProfileID: UUID?; var rejectedProfileIDs: [UUID]; var nameSnapshot: String?
            var cleanSeconds: Double; var totalSeconds: Double; var turnCount: Int; var matchScore: Double?; var matchMargin: Double?
            var vector: String?; var embeddingModelKey: String?; var vectorCoherence: Double?; var matchTrace: String?
        }
        struct RecordingRow: Codable, Equatable {
            var id: UUID; var createdAt: Date; var title: String?; var duration: Double; var audioFileName: String
            var source: String; var stage: Int; var queueReason: String?; var failureMessage: String?; var attemptCount: Int
            var isFavourite: Bool; var hasUnseenResult: Bool; var noSpeech: Bool; var language: String?; var marks: [Double]
            var peakCount: Int; var previewText: String; var searchText: String; var transcriptSHA256: String?
            var asrModelID: String?; var embeddingModelKey: String?; var folderID: UUID?; var folderName: String?
            var speakerCount: Int; var movedSpeakerTraces: String?
        }
        struct FolderRow: Codable, Equatable { var id: UUID; var name: String; var createdAt: Date; var recordingCount: Int }

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
    }

    static func readManifest(at url: URL) throws -> Manifest {
        let container = try v2Container(at: url)
        let context = ModelContext(container)
        let recordings = try context.fetch(FetchDescriptor<V2.Recording>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let speakers = try context.fetch(FetchDescriptor<V2.RecordingSpeaker>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let profiles = try context.fetch(FetchDescriptor<V2.VoiceProfile>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let samples = try context.fetch(FetchDescriptor<V2.VoiceSample>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let negatives = try context.fetch(FetchDescriptor<V2.VoiceNegative>()).sorted { $0.id.uuidString < $1.id.uuidString }
        let folders = try context.fetch(FetchDescriptor<V2.Folder>()).sorted { $0.id.uuidString < $1.id.uuidString }

        var stages: [String: Int] = [:]
        for r in recordings { stages[RecordingStage(rawValue: r.stageRaw).map { "\($0)" } ?? "\(r.stageRaw)", default: 0] += 1 }

        return Manifest(
            schemaVersion: "\(TranscribeSchemaV2.versionIdentifier)",
            modelKey: modelKey,
            counts: .init(recordings: recordings.count, speakers: speakers.count, profiles: profiles.count, samples: samples.count,
                          folders: folders.count, negatives: negatives.count),
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
                      clipEnd: $0.clipEnd, quote: $0.quote)
            },
            negatives: negatives.map {
                .init(id: $0.id, profileID: $0.profile?.id, speechSeconds: $0.speechSeconds, embeddingModelKey: $0.embeddingModelKey,
                      packed: $0.vectorData.base64EncodedString(), addedAt: $0.addedAt, sourceRecordingID: $0.sourceRecordingID,
                      sourceSpeakerID: $0.sourceSpeakerID)
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
                      transcriptSHA256: $0.transcriptData.map(sha256Hex), asrModelID: $0.asrModelID,
                      embeddingModelKey: $0.embeddingModelKey, folderID: $0.folder?.id, folderName: $0.folder?.name,
                      speakerCount: $0.speakers.count, movedSpeakerTraces: $0.movedSpeakerTracesData?.base64EncodedString())
            },
            folders: folders.map { .init(id: $0.id, name: $0.name, createdAt: $0.createdAt, recordingCount: $0.recordings.count) }
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Store metadata

    static func versionHashes(at storeURL: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: storeURL)
        return try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
    }

    /// The entity version hashes of a fresh store written by the frozen V2 schema.
    static func v2VersionHashes() throws -> [String: Data] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library.store")
        try autoreleasepool {
            let container = try v2Container(at: url)
            try ModelContext(container).save()
        }
        return try versionHashes(at: url)
    }
}

private extension JSONDecoder {
    static var fixture: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
