import Foundation
import TranscribeKit

/// An in-memory stand-in for the private CloudKit database (§8.3), shared by several `FakeTransport`s (devices).
///
/// It models what the sync core depends on:
/// - one `Library` zone per Apple Account, with a change tag (an Int) per record; `systemFields` is that tag as Data
/// - a change feed per client token (the latest state of each record changed since the token)
/// - `serverRecordChanged` for a stale or missing tag on an existing record, and `unknownItem` for a tag on a record
///   the server no longer has
/// - `zoneNotFound`, zone delete and purge, and `encryptedDataReset`
/// - account switching (each account has its own database)
/// - quota and network-failure injection, and the 250-record batch limit
/// - audio blobs (`af.<id>`) per account in the default zone, which no change feed sees, moved only by
///   `FakeAudioTransfer` (`FakeCloud+Audio.swift`)
public actor FakeCloud {
    public struct Stored: Sendable, Equatable {
        public var fields: [String: SyncValue]
        public var tag: Int
    }

    struct Database {
        var zoneExists = false
        /// Bumped whenever the zone is deleted: tokens of an older generation see `zoneDeleted`.
        var generation = 0
        var deletionReason: ZoneDeletionReason = .deleted
        var records: [String: Stored] = [:]
        /// recordName → sequence number of its last change (save or delete).
        var changed: [String: Int] = [:]
        var seq = 0
        var nextTag = 0
    }

    public enum FetchResult: Sendable {
        case zoneDeleted(ZoneDeletionReason)
        case changes(modifications: [SyncRecord], deletions: [SyncRecordID], token: FakeToken)
    }

    public struct ModifyResult: Sendable {
        public var saved: [SyncRecord] = []
        public var deleted: [SyncRecordID] = []
        public var failures: [SendFailure] = []
    }

    public enum CloudError: Error, Sendable, Equatable { case batchTooLarge(Int) }

    public static let batchLimit = 250

    private var databases: [String: Database] = [:]
    public private(set) var quotaFull = false
    public private(set) var networkDown = false
    public private(set) var largestBatch = 0
    public private(set) var modifyCalls = 0
    /// Record names whose next save fails with `.retryable` once.
    private var retryOnce: Set<String> = []

    // Audio (`FakeCloud+Audio.swift`). The blobs are in each account's default zone: they survive a `Library` zone
    // delete, go with a purge, and become unreadable after an encrypted-data reset.
    var audioStore: [String: [UUID: StoredAudio]] = [:]
    var audioQuota: Int64?
    var audioFailures: [AudioOp: [UUID: AudioTransferError]] = [:]
    var corruptDownloads: Set<UUID> = []
    var lostReplies: Set<UUID> = []
    var unreadableProbes: Set<UUID> = []
    var audioIndexExists = true
    var audioHook: (@Sendable (AudioOp, UUID) async -> Void)?
    var audioNow: @Sendable () -> Date = { Date() }
    var injectedAudioFailuresTaken = 0
    var audioBlobsDeleted = 0

    public init() {}

    /// A cloud that already holds records, for the UI-test scenarios (`FakeCloud+Scenarios.swift`): each account's
    /// records are saved in order as `inject` would (change tags 1, 2, 3 …), then the zones in `removed` are deleted as
    /// another device would. `audio` holds each account's blobs (a removed zone treats them as `removeZone` does).
    /// Synchronous, so the app can build it before its first frame.
    init(accounts: [String: [SyncRecord]], removed: [String: ZoneDeletionReason] = [:],
         audio: [String: [StoredAudio]] = [:]) {
        var dbs: [String: Database] = [:]
        for (account, records) in accounts {
            var db = Database()
            db.zoneExists = true
            for record in records {
                db.nextTag += 1
                db.records[record.id.recordName] = Stored(fields: record.fields, tag: db.nextTag)
                db.seq += 1
                db.changed[record.id.recordName] = db.seq
            }
            dbs[account] = db
        }
        var blobs: [String: [UUID: StoredAudio]] = [:]
        for (account, stored) in audio {
            blobs[account] = Dictionary(stored.map { ($0.descriptor.recordingID, $0) }, uniquingKeysWith: { _, b in b })
        }
        for (account, reason) in removed {
            var db = dbs[account] ?? Database()
            db.zoneExists = false
            db.records = [:]
            db.changed = [:]
            db.generation += 1
            db.deletionReason = reason
            dbs[account] = db
            blobs[account] = Self.audio(blobs[account] ?? [:], afterZoneRemoval: reason)
        }
        databases = dbs
        audioStore = blobs
    }

    // MARK: Test controls

    public func setQuotaFull(_ on: Bool) { quotaFull = on }
    public func setNetworkDown(_ on: Bool) { networkDown = on }
    public func failOnce(_ recordName: String) { retryOnce.insert(recordName) }

    /// Deletes (or purges, or resets the encrypted data of) an account's zone, as another device or iCloud would.
    /// Audio blobs live in the default zone: `.deleted` keeps them, `.purged` drops them, `.encryptedDataReset`
    /// makes them unreadable.
    public func removeZone(account: String, reason: ZoneDeletionReason) {
        var db = databases[account] ?? Database()
        db.zoneExists = false
        db.records = [:]
        db.changed = [:]
        db.generation += 1
        db.deletionReason = reason
        databases[account] = db
        if let blobs = audioStore[account] { audioStore[account] = Self.audio(blobs, afterZoneRemoval: reason) }
    }

    /// The current records of an account, by record name (fields only).
    public func records(account: String) -> [String: [String: SyncValue]] {
        (databases[account]?.records ?? [:]).mapValues(\.fields)
    }

    public func record(account: String, recordName: String) -> SyncRecord? {
        guard let stored = databases[account]?.records[recordName], let id = SyncRecordID(recordName: recordName) else { return nil }
        return SyncRecord(id: id, fields: stored.fields, systemFields: Self.systemFields(stored.tag))
    }

    public func zoneExists(account: String) -> Bool { databases[account]?.zoneExists ?? false }

    /// The change sequence of an account: unchanged across a round means nothing was written.
    public func sequence(account: String) -> Int { databases[account]?.seq ?? 0 }

    /// Writes a record as another device would (creates the zone if needed).
    public func inject(account: String, _ record: SyncRecord) {
        var db = databases[account] ?? Database()
        db.zoneExists = true
        db.nextTag += 1
        db.records[record.id.recordName] = Stored(fields: record.fields, tag: db.nextTag)
        db.seq += 1
        db.changed[record.id.recordName] = db.seq
        databases[account] = db
    }

    /// Deletes a record as another device would.
    public func injectDelete(account: String, _ id: SyncRecordID) {
        guard var db = databases[account] else { return }
        db.records.removeValue(forKey: id.recordName)
        db.seq += 1
        db.changed[id.recordName] = db.seq
        databases[account] = db
    }

    // MARK: Transport API

    func ensureZone(account: String) {
        var db = databases[account] ?? Database()
        db.zoneExists = true
        databases[account] = db
    }

    /// Which of `ids` have a `rec.<id>` record in the account's `Library` zone; nil when the zone is gone.
    func recordingRecords(account: String, ids: [UUID]) -> Set<UUID>? {
        guard let db = databases[account], db.zoneExists else { return nil }
        return Set(ids.filter { db.records[SyncRecordID(type: .recording, entityID: $0).recordName] != nil })
    }

    /// The `Library` zone only: audio blobs in the default zone stay (Remove iCloud Copy deletes them first).
    func deleteZone(account: String) throws {
        if networkDown { throw SyncTransportError.networkUnavailable }
        removeZone(account: account, reason: .deleted)
    }

    func fetch(account: String, token: FakeToken?) throws -> FetchResult {
        if networkDown { throw SyncTransportError.networkUnavailable }
        let db = databases[account] ?? Database()
        if let token, token.generation != db.generation { return .zoneDeleted(db.deletionReason) }
        let since = token?.seq ?? 0
        var mods: [SyncRecord] = [], dels: [SyncRecordID] = []
        for (name, seq) in db.changed.sorted(by: { $0.value < $1.value }) where seq > since {
            guard let id = SyncRecordID(recordName: name) else { continue }
            if let stored = db.records[name] {
                mods.append(SyncRecord(id: id, fields: stored.fields, systemFields: Self.systemFields(stored.tag)))
            } else {
                dels.append(id)
            }
        }
        return .changes(modifications: mods, deletions: dels, token: FakeToken(generation: db.generation, seq: db.seq))
    }

    func modify(account: String, saves: [SyncRecord], deletes: [SyncRecordID]) throws -> ModifyResult {
        if networkDown { throw SyncTransportError.networkUnavailable }
        let size = saves.count + deletes.count
        guard size <= Self.batchLimit else { throw CloudError.batchTooLarge(size) }
        largestBatch = max(largestBatch, size)
        modifyCalls += 1
        var db = databases[account] ?? Database()
        var result = ModifyResult()
        guard db.zoneExists else {
            result.failures = saves.map { .zoneNotFound($0.id) } + deletes.map { .zoneNotFound($0) }
            return result
        }
        for record in saves {
            let name = record.id.recordName
            if retryOnce.remove(name) != nil { result.failures.append(.retryable(record.id)); continue }
            if quotaFull { result.failures.append(.quotaExceeded(record.id)); continue }
            let existing = db.records[name]
            if let tagData = record.systemFields {
                guard let existing else { result.failures.append(.unknownItem(record.id)); continue }
                guard Self.tag(tagData) == existing.tag else {
                    result.failures.append(.serverRecordChanged(
                        SyncRecord(id: record.id, fields: existing.fields, systemFields: Self.systemFields(existing.tag))))
                    continue
                }
            } else if let existing {
                result.failures.append(.serverRecordChanged(
                    SyncRecord(id: record.id, fields: existing.fields, systemFields: Self.systemFields(existing.tag))))
                continue
            }
            let fields = Self.saving(record, over: existing?.fields)
            db.nextTag += 1
            db.records[name] = Stored(fields: fields, tag: db.nextTag)
            db.seq += 1
            db.changed[name] = db.seq
            result.saved.append(SyncRecord(id: record.id, fields: fields, systemFields: Self.systemFields(db.nextTag)))
        }
        for id in deletes {
            if db.records.removeValue(forKey: id.recordName) != nil {
                db.seq += 1
                db.changed[id.recordName] = db.seq
            }
            result.deleted.append(id)
        }
        databases[account] = db
        return result
    }

    /// The fields a save leaves on the server, as CloudKit and `CKRecordCodec.encode` do: a field added after its
    /// group was agreed (`SyncSchema.addedFields`) is never sent while null, so the server keeps the value it had
    /// (review 2026-11-26). Every other field is sent with each save and replaces the server's.
    static func saving(_ record: SyncRecord, over existing: [String: SyncValue]?) -> [String: SyncValue] {
        var fields = record.fields
        for name in SyncSchema.addedFields(record.id.type) where (fields[name] ?? .null) == .null {
            if let kept = existing?[name], kept != .null { fields[name] = kept } else { fields.removeValue(forKey: name) }
        }
        return fields
    }

    static func systemFields(_ tag: Int) -> Data { Data("tag:\(tag)".utf8) }
    static func tag(_ data: Data) -> Int? {
        guard let s = String(data: data, encoding: .utf8), s.hasPrefix("tag:") else { return nil }
        return Int(s.dropFirst(4))
    }
}

/// A fake change token: the zone generation and the last change sequence seen.
public struct FakeToken: Codable, Sendable, Equatable {
    public var generation: Int
    public var seq: Int
}
