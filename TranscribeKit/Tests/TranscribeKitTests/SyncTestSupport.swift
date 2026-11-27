import Foundation
import SwiftData
import Synchronization
import Testing
import TranscribeCore
@testable import TranscribeFakes
@testable import TranscribeKit

/// A clock the test moves by hand.
final class TestClock: Sendable {
    private let now = Mutex(Seeds.Dates.d)
    var date: Date { now.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func set(_ date: Date) { now.withLock { $0 = date } }
    var appClock: AppClock { AppClock { [self] in self.date } }
}

/// One device in a sync test (§8.7): an in-memory store with its capture channel, a `SyncCoordinator`, a
/// `FakeTransport` on the shared `FakeCloud`, and a clock. `relaunch()` simulates an app restart on the same store.
///
/// With `audio`, the coordinator also runs audio sync over a `FakeAudioTransfer`, `CopyAudioEncoder` and
/// `FakeDeviceConditions` (kept across relaunches); `platform` decides its automatic download window.
@MainActor
final class FakeDevice {
    let name: String
    let cloud: FakeCloud
    let container: ModelContainer
    let paths: AppPaths
    let store: LibraryStore
    let settings: AppSettings
    let clock: TestClock
    private(set) var transport: FakeTransport
    private(set) var sync: SyncCoordinator
    var context: ModelContext { container.mainContext }
    let channel: String
    /// This launch runs audio sync.
    private(set) var audioOn: Bool
    let platform: DevicePlatform
    /// The device's network, power and free space (shared by every launch).
    let conditions = FakeDeviceConditions()
    /// The encoder audio sync uses (`CopyAudioEncoder` unless a test passes `AACAudioEncoder`).
    var encoder: any AudioEncoding
    /// This launch's audio transfer (nil without audio).
    private(set) var transfer: FakeAudioTransfer?
    /// Wraps each launch's `FakeAudioTransfer` before audio sync gets it (from the next `relaunch()`).
    var wrapTransfer: ((FakeAudioTransfer) -> any AudioTransfer)?

    init(_ name: String, cloud: FakeCloud, channel: String = CaptureChannel.iphone, account: String? = "account-1",
         clock: TestClock = TestClock(), audio: Bool = false, platform: DevicePlatform = .iPhone,
         encoder: any AudioEncoding = CopyAudioEncoder(), defaults: UserDefaults? = nil) throws {
        self.name = name
        self.cloud = cloud
        self.channel = channel
        self.clock = clock
        self.audioOn = audio
        self.platform = platform
        self.encoder = encoder
        container = try ModelContainerFactory.make(inMemory: true, url: nil)
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(name)-\(UUID().uuidString)"))
        try paths.prepare()
        store = LibraryStore(context: container.mainContext, paths: paths, deviceIdentity: FixedDeviceIdentity(name),
                             clock: clock.appClock, localChannel: channel)
        settings = AppSettings(defaults: defaults ?? UserDefaults(suiteName: "sync-test-\(UUID().uuidString)")!)
        transport = FakeTransport(cloud: cloud, account: account)
        sync = SyncCoordinator(store: store, transport: transport, settings: settings, clock: clock.appClock,
                               modelKey: EmbeddingModelID.fake.key)
        configure()
    }

    /// An app restart: unsaved changes are lost; a new transport restarts from the saved engine state. `audio`
    /// switches audio sync on or off for the new launch (an update from or to a build without it).
    func relaunch(account: String? = nil, audio: Bool? = nil) async {
        sync.audio?.stop()
        context.rollback()
        if let audio { audioOn = audio }
        let previous = await transport.signedInAccount
        transport = FakeTransport(cloud: cloud, account: account ?? previous)
        sync = SyncCoordinator(store: store, transport: transport, settings: settings, clock: clock.appClock,
                               modelKey: EmbeddingModelID.fake.key)
        configure()
    }

    /// Builds this launch's coordinator (with audio sync when on) and runs the launch steps audio sync relies on.
    private func configure() {
        if audioOn {
            let transfer = FakeAudioTransfer(cloud: cloud, transport: transport)
            self.transfer = transfer
            sync = SyncCoordinator(store: store, transport: transport, settings: settings, clock: clock.appClock,
                                   modelKey: EmbeddingModelID.fake.key,
                                   audio: AudioSyncDependencies(transfer: wrapTransfer?(transfer) ?? transfer, encoder: encoder,
                                                                conditions: conditions, platform: platform))
            _ = try? store.adoptStrayDownloads()
            sync.audio?.prepareOnLaunch()
        } else {
            transfer = nil
        }
        sync.debounce = .seconds(3600)   // tests flush explicitly
        sync.followUpDelays = [.seconds(3600)]   // and sync explicitly; a test that wants the follow-up shortens it
    }

    /// This launch's audio sync (the device must have audio on).
    var audio: AudioSync { sync.audio! }

    func cleanup() { try? FileManager.default.removeItem(at: paths.root) }

    // MARK: Building data through the store API

    /// A ready recording with one speaker per vector (S1, S2, … on conversation B), matched like the pipeline. Its
    /// audio is a 4-byte stub, or with `audioSeconds` a real 16 kHz mono WAV of that length (`SyntheticAudio`).
    @discardableResult
    func record(_ vectors: [VoiceVector?], clean: Double = 12, at date: Date? = nil, audioSeconds: Double? = nil) throws -> UUID {
        let id = UUID()
        let file = paths.newAudioFileName(for: id)
        try store.createRecording(id: id, createdAt: date ?? clock.date, audioFileName: file, source: .microphone)
        var duration: TimeInterval = 24
        if let audioSeconds {
            _ = try SyntheticAudio.write(to: paths.audioURL(fileName: file), duration: audioSeconds,
                                         segments: [(TimeRange(start: 0, end: audioSeconds), .karan)])
            duration = audioSeconds
        } else {
            try Data("RIFF".utf8).write(to: paths.audioURL(fileName: file))
        }
        try store.finishCapture(id: id, audio: CapturedAudio(url: paths.audioURL(fileName: file), duration: duration, marks: [],
                                                             peaks: [0.1, 0.5, 0.25]), language: .automatic)
        let turns = SeedContent.conversationB
        try store.checkpointTranscript(id: id, document: WP3Docs.paragraphs(turns))
        let drafts = vectors.enumerated().map { i, v in WP3Docs.draft("S\(i + 1)", i + 1, clean: clean, vector: v) }
        try store.checkpointSeparation(id: id, document: WP3Docs.speakers(turns), speakers: drafts)
        try matchLikeThePipeline(id)
        return id
    }

    @discardableResult
    func matchLikeThePipeline(_ id: UUID) throws -> ProcessingOutcome {
        let key = EmbeddingModelID.fake.key
        let run = VoiceMatcher.decideWithTrace(probes: try store.probes(for: id), profiles: try store.matchCandidates(modelKey: key),
                                               modelKey: key, policy: .default,
                                               cohort: try store.matchCohort(modelKey: key, excludingRecording: id))
        return try store.applyMatches(id: id, decisions: run.decisions, traces: run.traces, policy: .default)
    }

    func recording(_ id: UUID) -> Recording? { try? store.recording(id) }
    func profile(named name: String) -> VoiceProfile? {
        (try? context.fetch(FetchDescriptor<VoiceProfile>()))?.first { $0.name == name }
    }
    func count<T: PersistentModel>(_ type: T.Type) -> Int { (try? context.fetchCount(FetchDescriptor<T>())) ?? -1 }
    func stateRow(_ id: SyncRecordID) -> SyncRecordState? { try? sync.detector.stateRow(named: id.recordName) }
    func stateRows() -> [SyncRecordState] { (try? context.fetch(FetchDescriptor<SyncRecordState>())) ?? [] }

    // MARK: Observing

    /// Every syncable entity's projection, by record name (the state the devices must agree on).
    func projections() -> [String: [String: SyncValue]] {
        let projector = RecordProjector(context: context)
        let rows = Dictionary(stateRows().map { ($0.recordName, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: [String: SyncValue]] = [:]
        for type in SyncRecordType.libraryCases {
            for e in (try? projector.all(type)) ?? [] where e.isSyncable {
                out[e.recordID.recordName] = RecordProjector.fields(e, unresolved: rows[e.recordID.recordName]?.unresolvedLinks ?? [:])
            }
        }
        return out
    }

    /// Rows still waiting to send.
    var pending: Int { sync.pendingCount() }
}

/// Syncs every device in turn until a whole round changes nothing in the cloud and nothing is pending.
@MainActor
func settle(_ devices: [FakeDevice], account: String = "account-1", rounds: Int = 12) async {
    var last = -1
    for _ in 0..<rounds {
        for d in devices { await d.sync.syncNow() }
        let seq = await devices[0].cloud.sequence(account: account)
        let pending = devices.map(\.pending).reduce(0, +)
        if seq == last && pending == 0 { return }
        last = seq
    }
}

/// `settle`, then every audio device drains its job loop, until the cloud's records, its audio and every device's
/// pending count stop changing.
@MainActor
func settleAudio(_ devices: [FakeDevice], account: String = "account-1", rounds: Int = 12) async {
    var last: (Int, [UUID: String], Int)?
    for _ in 0..<rounds {
        await settle(devices, account: account)
        for d in devices where d.audioOn { await d.audio.drain() }
        let cloud = devices[0].cloud
        let seq = await cloud.sequence(account: account)
        let blobs = await cloud.audio(account: account).mapValues(\.descriptor.sha256)
        let pending = devices.map(\.pending).reduce(0, +)
        if let last, last.0 == seq, last.1 == blobs, last.2 == pending, pending == 0 { return }
        last = (seq, blobs, pending)
    }
}

/// Audio has converged: every audio device with sync on has the audio of every ready recording that has a marker;
/// the cloud's blobs are exactly its markers; no marker names a recording no device has.
///
/// With `complete` (a settled run where every device has sync and Sync audio on), also: every ready recording that
/// every device holds has its marker and its blob in iCloud, the blob's sha256 is the marker's, and every audio device
/// holds its audio (an iPhone within its 30-day window; recordings too long to upload excepted). So audio that never
/// reached iCloud, or never came down, is caught too.
@MainActor
func expectAudioConverged(_ devices: [FakeDevice], account: String = "account-1", complete: Bool = false,
                          sourceLocation: SourceLocation = #_sourceLocation) async {
    guard let cloud = devices.first?.cloud else { return }
    let records = await cloud.records(account: account)
    var markerSHA: [UUID: String] = [:]
    for (name, record) in records {
        guard let id = SyncRecordID(recordName: name), id.type == .audio else { continue }
        if case .string(let sha)? = record["sha256"] { markerSHA[id.entityID] = sha } else { markerSHA[id.entityID] = "" }
    }
    let markers = Set(markerSHA.keys)
    let stored = await cloud.audio(account: account)
    let blobs = Set(stored.keys)
    #expect(blobs == markers, "blobs \(blobs.count) vs markers \(markers.count)", sourceLocation: sourceLocation)
    var everyRecording: Set<UUID> = []
    for d in devices {
        everyRecording.formUnion(((try? d.context.fetch(FetchDescriptor<Recording>())) ?? []).map(\.id))
    }
    #expect(markers.isSubset(of: everyRecording), "a marker names a recording no device has", sourceLocation: sourceLocation)
    for d in devices where d.audioOn && d.settings.syncEnabled && d.settings.syncAudio {
        for r in (try? d.context.fetch(FetchDescriptor<Recording>())) ?? [] where r.stage == .ready && markers.contains(r.id) {
            #expect(d.store.hasLocalAudio(r), "\(d.name) lacks the audio of \(r.id)", sourceLocation: sourceLocation)
        }
    }
    guard complete else { return }
    var readyEverywhere: Set<UUID>?
    for d in devices {
        let ready = Set(((try? d.context.fetch(FetchDescriptor<Recording>())) ?? []).filter { $0.stage == .ready }.map(\.id))
        readyEverywhere = readyEverywhere.map { $0.intersection(ready) } ?? ready
    }
    let tooLong = devices.reduce(into: Set<UUID>()) { $0.formUnion($1.audioOn ? $1.audio.tooLong : []) }
    for id in (readyEverywhere ?? []).subtracting(tooLong).sorted(by: { $0.uuidString < $1.uuidString }) {
        #expect(markers.contains(id), "no marker for \(id)", sourceLocation: sourceLocation)
        #expect(blobs.contains(id), "no blob for \(id)", sourceLocation: sourceLocation)
        if let blob = stored[id], let sha = markerSHA[id] {
            #expect(blob.descriptor.sha256 == sha, "the marker of \(id) names another blob", sourceLocation: sourceLocation)
        }
        for d in devices where d.audioOn {
            #expect(d.settings.syncEnabled && d.settings.syncAudio, "\(d.name) is not settled with audio on",
                    sourceLocation: sourceLocation)
            guard let r = d.recording(id) else { continue }
            guard AudioPolicy.autoDownloads(platform: d.platform, createdAt: r.createdAt, now: d.clock.date) else { continue }
            #expect(d.store.hasLocalAudio(r), "\(d.name) never got the audio of \(id)", sourceLocation: sourceLocation)
        }
    }
}

/// Every device holds the same projections.
@MainActor
func expectConverged(_ devices: [FakeDevice], sourceLocation: SourceLocation = #_sourceLocation) {
    guard let first = devices.first else { return }
    let reference = first.projections()
    for d in devices.dropFirst() {
        let other = d.projections()
        let missing = Set(reference.keys).subtracting(other.keys).sorted()
        let extra = Set(other.keys).subtracting(reference.keys).sorted()
        var differing: [String] = []
        for (name, fields) in reference where other[name] != nil && other[name] != fields {
            let keys = fields.keys.filter { fields[$0] != other[name]?[$0] }.sorted()
            differing.append("\(name) \(keys)")
        }
        #expect(missing.isEmpty && extra.isEmpty && differing.isEmpty,
                "\(first.name) vs \(d.name): missing \(missing), extra \(extra), differing \(differing.sorted())",
                sourceLocation: sourceLocation)
    }
    for d in devices { #expect(d.pending == 0, "\(d.name) still has \(d.pending) pending", sourceLocation: sourceLocation) }
}

enum SyncVoices {
    static func karan(_ variant: Int, _ cosine: Float = 0.9) -> VoiceVector { SyntheticVoices.vector(near: .karan, cosine: cosine, variant: variant) }
    static func liam(_ variant: Int, _ cosine: Float = 0.9) -> VoiceVector { SyntheticVoices.vector(near: .liam, cosine: cosine, variant: variant) }
    static func stranger(_ variant: Int, _ cosine: Float = 0.9) -> VoiceVector {
        SyntheticVoices.vector(near: .stranger, cosine: cosine, variant: variant)
    }
}

/// Two devices sharing one library made on A (an iPhone); B is a Mac. Both have sync on and have settled.
///
/// - `r1`: S1 named Karan (one 12 s named sample), S2 named Liam a second later (Karan is the older profile).
/// - `r2`: S1 a quieter Karan (0.45 to his sample): suggested Karan; S2 a stranger, unnamed.
@MainActor
struct TwoDevices {
    let cloud: FakeCloud
    let a: FakeDevice
    let b: FakeDevice
    let r1: UUID
    let r2: UUID
    let karan: UUID
    let liam: UUID

    static func make(syncB: Bool = true) async throws -> TwoDevices {
        let cloud = FakeCloud()
        let clock = TestClock()
        let a = try FakeDevice("A", cloud: cloud, channel: CaptureChannel.iphone, clock: clock)
        let b = try FakeDevice("B", cloud: cloud, channel: CaptureChannel.mac, clock: clock)
        let r1 = try a.record([SyncVoices.karan(30), SyncVoices.liam(31)])
        let karan = try #require(try a.store.nameSpeaker(recordingID: r1, key: "S1", as: .newPerson(name: "Karan"), remember: true).profileID)
        clock.advance(1)   // Karan is the older profile
        let liam = try #require(try a.store.nameSpeaker(recordingID: r1, key: "S2", as: .newPerson(name: "Liam"), remember: true).profileID)
        clock.advance(60)
        let r2 = try a.record([SyncVoices.karan(32, 0.5), SyncVoices.stranger(33)])
        #expect(a.recording(r2)?.speaker("S1")?.label == .suggested)
        await a.sync.enable()
        if syncB {
            await b.sync.enable()
            await settle([a, b])
        }
        return TwoDevices(cloud: cloud, a: a, b: b, r1: r1, r2: r2, karan: karan, liam: liam)
    }

    var devices: [FakeDevice] { [a, b] }
    func cleanup() { a.cleanup(); b.cleanup() }
    func settleBoth() async { await settle([a, b]) }
}

/// Every sync suite runs inside this one, one test at a time. They do a lot of main-actor work, and the app's
/// real-time tests (recording timers, background expiry) share the main actor with them.
@Suite("Sync", .serialized)
enum SyncSuites {}
