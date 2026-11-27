import CryptoKit
import Foundation
import SwiftData
import TranscribeCore
import TranscribeKit

/// A fake sync scenario ready to run (§8.6, `TRANSCRIBE_SYNC=fake:<scenario>`): the transport on a seeded `FakeCloud`,
/// whether the "Sync with iCloud" switch starts on, and the sync bookkeeping this device's store starts with.
///
/// The cloud's records come from a throwaway in-memory "iPhone" store, projected exactly as a real iPhone would upload
/// them (`SyncSnapshot`), so the Mac (or a second iPhone) receives what it would in real life. UI tests never touch
/// CloudKit.
public struct FakeSyncSetup: Sendable {
    public let transport: FakeTransport
    /// The device's audio transfer on the same fake cloud and account (`AudioSyncDependencies.transfer`).
    public let audioTransfer: FakeAudioTransfer
    /// Every scenario but `fresh` starts with the switch on.
    public let startsOn: Bool
    private let prepareStore: @MainActor @Sendable (ModelContext, Date) throws -> Void

    init(transport: FakeTransport, startsOn: Bool,
         prepareStore: @escaping @MainActor @Sendable (ModelContext, Date) throws -> Void = { _, _ in }) {
        self.transport = transport
        self.audioTransfer = FakeAudioTransfer(cloud: transport.cloud, transport: transport)
        self.startsOn = startsOn
        self.prepareStore = prepareStore
    }

    /// Writes the scenario's sync bookkeeping (account row, state rows) to this device's store. Seeding never touches
    /// these rows, so this may run before or after the seed, but before sync starts.
    @MainActor public func prepare(_ context: ModelContext, now: Date) throws {
        try prepareStore(context, now)
        try context.save()
    }
}

public extension FakeCloud {
    /// The Apple Account every UI-test scenario is signed in to (unless it is signed out).
    static let uiTestAccount = "uitest-account"
    /// The account `accountSwitched` was synced with before.
    static let uiTestPreviousAccount = "uitest-previous-account"
    /// `duplicateKaran`: the id of the second Karan, named on the iPhone.
    static let iPhoneKaranID = UUID(uuidString: "B0000000-0000-4000-8000-0000000000A2")!
    /// `massDelete`: how many recordings this device once synced and has since lost.
    static let massDeleteCount = 30

    /// The scenario's cloud, transport and store preparation. `nil` (sync off, or no `TRANSCRIBE_SYNC`) gives an empty
    /// cloud with the UI-test account signed in, which is also `fresh`.
    @MainActor static func scenario(_ scenario: FakeSyncScenario?, clock: AppClock) -> FakeSyncSetup {
        let account = uiTestAccount
        switch scenario {
        case nil, .fresh?:
            return FakeSyncSetup(transport: FakeTransport(cloud: FakeCloud(accounts: [account: []]), account: account),
                                 startsOn: false)

        case .remoteLibrary?:
            // The iPhone's library (recordings A, B and C, Liam and Karan) is already in iCloud, without audio. Run it
            // with the `empty` seed: the same ids seeded locally would merge with it instead.
            let cloud = FakeCloud(accounts: [account: iPhoneRecords(clock: clock) { context, paths in
                try Seeds.apply(.library, context: context, paths: paths, clock: clock)
            }])
            return FakeSyncSetup(transport: FakeTransport(cloud: cloud, account: account), startsOn: true)

        case .remoteLibraryWithAudio?:
            // `remoteLibrary`, plus the iPhone's audio: each recording's WAV as a blob (`pcm16kMono`, its real
            // SHA-256) and its marker, as an iPhone with Sync audio on would have uploaded them.
            let library = iPhoneLibrary(clock: clock, withAudio: true) { context, paths in
                try Seeds.apply(.library, context: context, paths: paths, clock: clock)
            }
            let markers = library.audio.map { AudioMarker.record($0.descriptor) }
            let cloud = FakeCloud(accounts: [account: library.records + markers], audio: [account: library.audio])
            return FakeSyncSetup(transport: FakeTransport(cloud: cloud, account: account), startsOn: true)

        case .signedOut?:
            return FakeSyncSetup(transport: FakeTransport(cloud: FakeCloud(accounts: [account: []]), account: nil),
                                 startsOn: true)

        case .accountSwitched?:
            // This library was synced with another Apple Account; a different one is signed in now.
            return FakeSyncSetup(transport: FakeTransport(cloud: FakeCloud(accounts: [account: []]), account: account),
                                 startsOn: true) { context, _ in
                Self.accountRow(context).accountHash = uiTestPreviousAccount
            }

        case .zoneRemoved?:
            // Synced before; since then another device chose "Remove iCloud Copy…". The next fetch finds the zone gone.
            let cloud = FakeCloud(accounts: [account: []], removed: [account: .deleted])
            return FakeSyncSetup(transport: FakeTransport(cloud: cloud, account: account), startsOn: true) { context, _ in
                let row = Self.accountRow(context)
                row.accountHash = account
                row.zoneReady = true
                row.engineState = FakeTransport.engineState(token: FakeToken(generation: 0, seq: 0))
            }

        case .duplicateKaran?:
            // The iPhone named its own Karan before the two libraries met: after the first fetch this device has two
            // voices called Karan, and the Voices screen offers to merge them (never automatically, D13).
            let cloud = FakeCloud(accounts: [account: iPhoneRecords(clock: clock) { context, _ in
                try Self.insertIPhoneKaran(context)
            }])
            return FakeSyncSetup(transport: FakeTransport(cloud: cloud, account: account), startsOn: true)

        case .massDelete?:
            // This device synced 30 recordings that are no longer in its store (a restore from an old backup, say):
            // the launch scan would send 30 deletes, so the breaker holds them and asks.
            let records = iPhoneRecords(clock: clock) { context, _ in try Self.insertMeetings(context, count: massDeleteCount) }
            let cloud = FakeCloud(accounts: [account: records])
            return FakeSyncSetup(transport: FakeTransport(cloud: cloud, account: account), startsOn: true) { context, now in
                let row = Self.accountRow(context)
                row.accountHash = account
                row.zoneReady = true
                row.engineState = FakeTransport.engineState(token: FakeToken(generation: 0, seq: records.count))
                for (i, record) in records.enumerated() {
                    let state = SyncRecordState(recordName: record.id.recordName, type: record.id.type,
                                                entityID: record.id.entityID, now: now)
                    state.baseHashes = SyncSchema.hashes(record)
                    state.systemFields = FakeCloud.systemFields(i + 1)
                    state.pending = .none
                    context.insert(state)
                }
            }
        }
    }

    // MARK: Building the other device's library

    /// Builds a library on a throwaway in-memory "iPhone" store (its own temporary audio folder, deleted afterwards),
    /// stamps it with the iPhone's capture channel, and returns what that iPhone would upload.
    @MainActor private static func iPhoneRecords(clock: AppClock,
                                                 _ build: (ModelContext, AppPaths) throws -> Void) -> [SyncRecord] {
        iPhoneLibrary(clock: clock, withAudio: false, build).records
    }

    /// `iPhoneRecords`, and with `withAudio` each ready recording's audio as the iPhone would have uploaded it
    /// (`CopyAudioEncoder`'s format: the WAV's bytes, `pcm16kMono`, their SHA-256), read before the folder goes.
    @MainActor private static func iPhoneLibrary(clock: AppClock, withAudio: Bool,
                                                 _ build: (ModelContext, AppPaths) throws -> Void)
        -> (records: [SyncRecord], audio: [StoredAudio]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-fake-iphone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let container = try ModelContainerFactory.make(inMemory: true, url: nil)
            let paths = AppPaths(root: root)
            try paths.prepare()
            try build(container.mainContext, paths)
            let store = LibraryStore(context: container.mainContext, paths: paths, deviceIdentity: FixedDeviceIdentity("fake-iphone"),
                                     clock: clock, localChannel: CaptureChannel.iphone)
            _ = try store.stampCaptureChannels()
            try container.mainContext.save()
            var audio: [StoredAudio] = []
            if withAudio {
                let ready = try container.mainContext.fetch(FetchDescriptor<Recording>())
                    .filter { $0.stage == .ready }.sorted { $0.id.uuidString < $1.id.uuidString }
                for r in ready {
                    guard let data = try? Data(contentsOf: paths.audioURL(fileName: r.audioFileName)) else { continue }
                    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let d = AudioDescriptor(recordingID: r.id, format: .pcm16kMono, bytes: Int64(data.count),
                                            sha256: sha, duration: r.duration)
                    audio.append(StoredAudio(descriptor: d, data: data, created: clock.now))
                }
            }
            return (try SyncSnapshot.records(container.mainContext), audio)
        } catch {
            assertionFailure("Building the fake iPhone library failed: \(error)")
            return ([], [])
        }
    }

    /// A second Karan, named on the iPhone with one 12 s sample heard there.
    @MainActor private static func insertIPhoneKaran(_ context: ModelContext) throws {
        let named = Seeds.Dates.date(19, 16, 40)
        let karan = VoiceProfile(id: iPhoneKaranID, name: "Karan", colourSlot: 3, embeddingModelKey: SeedBuilder.modelKey, now: named)
        context.insert(karan)
        let sample = VoiceSample(vector: SyntheticVoices.vector(near: .karan, cosine: 0.9, variant: 7),
                                 embeddingModelKey: SeedBuilder.modelKey, origin: .named, addedAt: named, speechSeconds: 12)
        context.insert(sample)
        sample.profile = karan
        sample.captureChannel = CaptureChannel.iphone
        sample.quote = "Yes, that's the one from the site visit."
        try context.save()
    }

    /// `count` ready, speaker-less meeting recordings (conversation B's text), one a day before 18 Nov 2026.
    @MainActor private static func insertMeetings(_ context: ModelContext, count: Int) throws {
        let turns = SeedContent.conversationB
        let document = TranscriptDocument(words: SeedContent.allWords(turns), turns: SeedContent.paragraphs(turns),
                                          asrModelID: SeedBuilder.asrModelID)
        let data = try document.encoded()
        for i in 0..<count {
            let id = UUID(uuidString: String(format: "C0000000-0000-4000-8000-%012d", i + 1))!
            let created = Seeds.Dates.date(18, 9, 0).addingTimeInterval(-Double(i + 1) * 86_400)
            let r = Recording(id: id, createdAt: created, audioFileName: "\(id.uuidString).wav", source: .microphone)
            context.insert(r)
            r.title = "Weekly check-in \(count - i)"
            r.duration = SeedContent.conversationBDuration
            r.stage = .ready
            r.transcriptData = data
            r.asrModelID = SeedBuilder.asrModelID
            r.captureChannel = CaptureChannel.iphone
        }
        try context.save()
    }

    @MainActor private static func accountRow(_ context: ModelContext) -> SyncAccountState {
        var d = FetchDescriptor<SyncAccountState>(predicate: #Predicate { $0.key == "default" })
        d.fetchLimit = 1
        if let row = try? context.fetch(d).first { return row }
        let row = SyncAccountState()
        context.insert(row)
        return row
    }
}

extension FakeTransport {
    /// Serialised engine state with this change token and nothing pending, as `stateUpdate` would deliver it.
    static func engineState(token: FakeToken) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(EngineState(token: token, saves: [], deletes: []))) ?? Data()
    }
}
