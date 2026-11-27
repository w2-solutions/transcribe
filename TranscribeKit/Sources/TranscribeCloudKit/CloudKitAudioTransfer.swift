import CloudKit
import Foundation
import os
import TranscribeKit

/// The real `AudioTransfer`: `AudioFile` records (`af.<UUID>`) in the private database's default zone of
/// `iCloud.ai.w2solutions.transcribe`, moved by direct CloudKit operations outside the sync engine (decision 1).
///
/// - Metadata calls never fetch the asset: `probe` asks for `CKAudioCodec.metadataKeys` and `recordingRecordsExist`
///   for no keys at all (`desiredKeys = []`). Only `download` and `probeFully` fetch every key.
/// - `upload` is create-only (`.ifServerRecordUnchanged`, no system fields): a blob already there comes back as
///   `.alreadyThere` with the server's descriptor, never overwritten.
/// - `download` moves CloudKit's staged asset file to the destination inside the operation's per-record result block,
///   because the system deletes staged files whenever it likes.
/// - Explicit operations (`probe`, `probeFully`, `recordingRecordsExist`, `upload`, `download`) carry their own
///   `CKOperation.Configuration` and `CKOperationGroup`; `delete` and `listAll` use the async conveniences inside
///   `CKDatabase.configuredWith(configuration:group:body:)`. Transfers run at `.userInitiated` when the user asked for
///   them and `.utility` otherwise (default QoS is discretionary and pauses in Low Power Mode on iPhone); automatic
///   transfers may not use mobile data. Metadata calls run at `.utility` on any network.
/// - Cancelling the task cancels the operation. As with `FakeAudioTransfer`, a task cancelled before a request sends
///   nothing, and one cancelled while it ran throws `.cancelled` even when the request went through (its effect stays).
/// - The container is opened on the first call. Without the container entitlement (a Mac build signed to run locally,
///   `swift test`) every method throws `.noAccount` and nothing touches CloudKit.
/// - Logs (subsystem `ai.w2solutions.transcribe`, category `cloudkit`, all public): record names (`af.<UUID>`),
///   sizes rounded to 0.1 MB, times, counts, `AudioTransferError` case names and CKError codes. Never a sha256 or a
///   recording's duration.
/// - Every method throws `AudioTransferError` only.
public actor CloudKitAudioTransfer: AudioTransfer {
    public nonisolated let identifier: String
    public nonisolated let codec: CKAudioCodec
    /// The zone holding `rec.<UUID>` records (`recordingRecordsExist`).
    public nonisolated let libraryZoneID: CKRecordZone.ID

    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "cloudkit")
    private var container: CKContainer?
    private var noEntitlement = false

    public init(containerIdentifier: String = CloudKitTransport.containerIdentifier, codec: CKAudioCodec = CKAudioCodec(),
                libraryZoneID: CKRecordZone.ID = CKRecordCodec.zoneID) {
        identifier = containerIdentifier
        self.codec = codec
        self.libraryZoneID = libraryZoneID
    }

    // MARK: AudioTransfer

    public func probe(_ ids: [UUID]) async throws -> [UUID: AudioPresence] {
        let database = try openDatabase()
        let ids = Self.unique(ids)
        guard !ids.isEmpty else { return [:] }
        let start = ContinuousClock.now
        do {
            let answer = try await Self.probe(ids, codec: codec, in: database)
            try Self.checkCancelled()
            let present = answer.values.filter { if case .present = $0 { true } else { false } }.count
            let unreadable = answer.values.filter { $0 == .unreadable }.count
            Self.log.notice("audio probe: \(ids.count, privacy: .public) asked, \(present, privacy: .public) present, \(unreadable, privacy: .public) unreadable in \(Self.seconds(since: start), privacy: .public)")
            return answer
        } catch {
            throw Self.failed("audio probe (\(ids.count) asked)", error)
        }
    }

    public func probeFully(_ id: UUID) async throws -> AudioPresence {
        let database = try openDatabase()
        try Self.checkCancelled()
        let recordID = codec.recordID(id)
        let codec = self.codec
        do {
            let outcome = await Self.fetch(
                [recordID], desiredKeys: nil, in: database, configuration: Self.configuration(nil),
                group: Self.group("audio-probe", send: .kilobytes, receive: .unknown, configuration: Self.configuration(nil))
            ) { record -> AudioPresence in
                // Only the scalars matter here: the staged asset is discarded at once.
                if let file = (record[CKAudioCodec.Key.audio] as? CKAsset)?.fileURL { try? FileManager.default.removeItem(at: file) }
                return codec.decode(record)
            }
            let presence: AudioPresence
            switch outcome.results[recordID] {
            case .success(let p)?: presence = p
            case .failure(let error)? where Self.code(error) == .unknownItem: presence = .absent
            case .failure(let error)?: throw error
            case nil: throw outcome.operationError ?? AudioTransferError.retryable(retryAfter: nil)
            }
            try Self.checkCancelled()
            Self.log.notice("audio probe (full) \(recordID.recordName, privacy: .public): \(Self.name(presence), privacy: .public)")
            return presence
        } catch {
            throw Self.failed("audio probe (full) \(recordID.recordName)", error)
        }
    }

    public func recordingRecordsExist(_ ids: [UUID]) async throws -> Set<UUID> {
        let database = try openDatabase()
        let ids = Self.unique(ids)
        guard !ids.isEmpty else { return [] }
        let chunks = Self.chunks(ids)
        let configuration = Self.configuration(nil)
        let group = Self.group("audio-check", send: .kilobytes, receive: .kilobytes, quantity: chunks.count,
                               configuration: configuration)
        do {
            var exist = Set<UUID>()
            for chunk in chunks {
                try Self.checkCancelled()
                let recordIDs = recordingCheckIDs(chunk)
                let outcome: FetchOutcome<Bool>
                do {
                    outcome = await Self.fetch(recordIDs, desiredKeys: [], in: database, configuration: configuration,
                                                   group: group) { _ in true }
                    if let error = outcome.operationError, Self.code(error) != .partialFailure { throw error }
                } catch where Self.isZoneGone(error) {
                    throw AudioTransferError.zoneMissing
                }
                for (id, recordID) in zip(chunk, recordIDs) {
                    switch outcome.results[recordID] {
                    case .success?: exist.insert(id)
                    case .failure(let error)? where Self.code(error) == .unknownItem: continue
                    case .failure(let error)? where Self.isZoneGone(error): throw AudioTransferError.zoneMissing
                    case .failure(let error)?: throw error
                    // Never read a missing answer as "absent": the sweep would delete that recording's audio.
                    case nil: throw AudioTransferError.retryable(retryAfter: nil)
                    }
                }
            }
            try Self.checkCancelled()
            Self.log.notice("audio check: \(ids.count, privacy: .public) asked, \(exist.count, privacy: .public) recordings exist")
            return exist
        } catch {
            throw Self.failed("audio check (\(ids.count) asked)", error)
        }
    }

    public func upload(_ file: URL, descriptor: AudioDescriptor, options: AudioTransferOptions,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> AudioUploadOutcome {
        let database = try openDatabase()
        try Self.checkCancelled()
        let record = codec.encode(descriptor, file: file)
        let name = record.recordID.recordName
        let start = ContinuousClock.now
        do {
            let configuration = Self.configuration(options)
            let saved = try await Self.save(
                record, in: database, configuration: configuration,
                group: Self.group("audio-upload", send: CKAudioCodec.transferSize(options.expectedBytes), receive: .kilobytes,
                                  configuration: configuration),
                progress: progress)
            let outcome: AudioUploadOutcome
            switch saved {
            case .success:
                outcome = .uploaded
            case .failure(let error) where Self.code(error) == .serverRecordChanged:
                outcome = .alreadyThere(try await serverDescriptor(error, id: descriptor.recordingID, in: database))
            case .failure(let error):
                throw error
            }
            try Self.checkCancelled()
            progress(1)
            switch outcome {
            case .uploaded:
                Self.log.notice("audio upload \(name, privacy: .public): \(Self.megabytes(descriptor.bytes), privacy: .public) in \(Self.seconds(since: start), privacy: .public)")
            case .alreadyThere(let server):
                Self.log.notice("audio upload \(name, privacy: .public): already in iCloud (\(Self.megabytes(server.bytes), privacy: .public))")
            }
            return outcome
        } catch {
            throw Self.failed("audio upload \(name)", error)
        }
    }

    public func download(_ id: UUID, to destination: URL, options: AudioTransferOptions,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> AudioDescriptor {
        let database = try openDatabase()
        try Self.checkCancelled()
        let recordID = codec.recordID(id)
        let codec = self.codec
        let start = ContinuousClock.now
        do {
            let configuration = Self.configuration(options)
            let outcome = await Self.fetch(
                [recordID], desiredKeys: nil, in: database, configuration: configuration,
                group: Self.group("audio-download", send: .kilobytes, receive: CKAudioCodec.transferSize(options.expectedBytes),
                                  configuration: configuration),
                progress: progress
            ) { record -> AudioDescriptor in
                // Inside the per-record result block: CloudKit's staged file may be gone once the operation ends.
                let asset = record[CKAudioCodec.Key.audio] as? CKAsset
                guard case .present(let descriptor) = codec.decode(record) else {
                    if let file = asset?.fileURL { try? FileManager.default.removeItem(at: file) }
                    throw AudioTransferError.other(code: 0)
                }
                try Self.adopt(asset: asset, to: destination)
                return descriptor
            }
            let descriptor: AudioDescriptor
            switch outcome.results[recordID] {
            case .success(let d)?: descriptor = d
            case .failure(let error)?: throw error
            case nil: throw outcome.operationError ?? AudioTransferError.retryable(retryAfter: nil)
            }
            try Self.checkCancelled()
            progress(1)
            Self.log.notice("audio download \(recordID.recordName, privacy: .public): \(Self.megabytes(descriptor.bytes), privacy: .public) in \(Self.seconds(since: start), privacy: .public)")
            return descriptor
        } catch {
            throw Self.failed("audio download \(recordID.recordName)", error)
        }
    }

    public func delete(_ ids: [UUID]) async throws {
        let database = try openDatabase()
        let ids = Self.unique(ids)
        guard !ids.isEmpty else { return }
        let chunks = Self.chunks(ids)
        let configuration = Self.configuration(nil)
        let group = Self.group("audio-delete", send: .kilobytes, receive: .kilobytes, quantity: chunks.count,
                               configuration: configuration)
        var deleted = 0
        do {
            for chunk in chunks {
                try Self.checkCancelled()
                let recordIDs = chunk.map(codec.recordID)
                let results = try await database.configuredWith(configuration: configuration, group: group) { db in
                    try await db.modifyRecords(saving: [], deleting: recordIDs, atomically: false).deleteResults
                }
                for recordID in recordIDs {
                    switch results[recordID] {
                    case .success?: deleted += 1
                    case .failure(let error)? where Self.code(error) == .unknownItem: deleted += 1   // already gone
                    case .failure(let error)?: throw error
                    case nil: throw AudioTransferError.retryable(retryAfter: nil)
                    }
                }
            }
            try Self.checkCancelled()
            Self.log.notice("audio delete \(ids.count, privacy: .public) af records")
        } catch {
            throw Self.failed("audio delete (\(deleted) of \(ids.count) done)", error)
        }
    }

    public func listAll() async throws -> [AudioListing] {
        let database = try openDatabase()
        try Self.checkCancelled()
        let configuration = Self.configuration(nil)
        let group = Self.group("audio-list", send: .kilobytes, receive: .kilobytes, configuration: configuration)
        let codec = self.codec
        do {
            let (listings, skipped) = try await database.configuredWith(configuration: configuration, group: group) { db in
                let keys = [CKAudioCodec.Key.schema]
                let query = CKQuery(recordType: CKAudioCodec.recordType, predicate: NSPredicate(value: true))
                var page = try await db.records(matching: query, inZoneWith: CKAudioCodec.zoneID, desiredKeys: keys)
                var listings: [AudioListing] = [], skipped = 0
                while true {
                    for (recordID, result) in page.matchResults {
                        guard let id = codec.recordingID(recordID), case .success(let record) = result else {
                            skipped += 1
                            continue
                        }
                        // A record always has a creation date once saved; "now" keeps one without it from looking old.
                        listings.append(AudioListing(recordingID: id, created: record.creationDate ?? Date()))
                    }
                    guard let cursor = page.queryCursor else { break }
                    try Task.checkCancellation()
                    page = try await db.records(continuingMatchFrom: cursor, desiredKeys: keys)
                }
                return (listings, skipped)
            }
            try Self.checkCancelled()
            Self.log.notice("audio list: \(listings.count, privacy: .public) records, \(skipped, privacy: .public) skipped")
            return listings
        } catch where Self.code(error) == .invalidArguments {
            // A TRUEPREDICATE query needs a QUERYABLE recordName index on AudioFile (§2.2 step 2).
            throw Self.failed("audio list", AudioTransferError.indexMissing, cause: error)
        } catch {
            throw Self.failed("audio list", error)
        }
    }

    // MARK: Container

    /// The private database, or `.noAccount` without the container entitlement (nothing touches CloudKit then).
    private func openDatabase() throws -> CKDatabase {
        if let container { return container.privateCloudDatabase }
        guard !noEntitlement, AccountObserver.hasContainerEntitlement(identifier) else {
            if !noEntitlement {
                noEntitlement = true
                Self.log.info("No iCloud container entitlement for \(self.identifier, privacy: .public); audio sync reads as signed out")
            }
            throw AudioTransferError.noAccount
        }
        let c = CKContainer(identifier: identifier)
        container = c
        return c.privateCloudDatabase
    }

    // MARK: Requests

    /// The record ids `recordingRecordsExist` asks for: `rec.<UUID>` in the `Library` zone.
    nonisolated func recordingCheckIDs(_ ids: [UUID]) -> [CKRecord.ID] {
        ids.map { CKRecord.ID(recordName: SyncRecordID(type: .recording, entityID: $0).recordName, zoneID: libraryZoneID) }
    }

    /// Metadata probes, 200 ids per operation. A per-record `unknownItem` is `.absent`; a missing answer throws.
    private static func probe(_ ids: [UUID], codec: CKAudioCodec, in database: CKDatabase) async throws -> [UUID: AudioPresence] {
        let chunks = chunks(ids)
        let configuration = configuration(nil)
        let group = group("audio-probe", send: .kilobytes, receive: .kilobytes, quantity: chunks.count,
                          configuration: configuration)
        var answer: [UUID: AudioPresence] = [:]
        for chunk in chunks {
            try checkCancelled()
            let recordIDs = chunk.map(codec.recordID)
            let outcome = await fetch(recordIDs, desiredKeys: CKAudioCodec.metadataKeys, in: database,
                                          configuration: configuration, group: group) { codec.decode($0) }
            if let error = outcome.operationError, code(error) != .partialFailure { throw error }
            for (id, recordID) in zip(chunk, recordIDs) {
                switch outcome.results[recordID] {
                case .success(let presence)?: answer[id] = presence
                case .failure(let error)? where code(error) == .unknownItem: answer[id] = .absent
                case .failure(let error)?: throw error
                case nil: throw AudioTransferError.retryable(retryAfter: nil)
                }
            }
        }
        return answer
    }

    /// The descriptor of the blob a create-only save collided with: from the conflict's server copy (its scalars are
    /// there; only its asset has no file), else from a metadata probe.
    private func serverDescriptor(_ error: any Error, id: UUID, in database: CKDatabase) async throws -> AudioDescriptor {
        if let server = (error as? CKError)?.serverRecord, case .present(let d) = codec.decode(server) { return d }
        switch try await Self.probe([id], codec: codec, in: database)[id] {
        case .present(let d)?: return d
        // Deleted since the collision: saving again later creates it.
        case .absent?, nil: throw AudioTransferError.retryable(retryAfter: nil)
        // The blob there cannot be read (CloudKit's serverRecordChanged code): the caller confirms and replaces it.
        case .unreadable?: throw AudioTransferError.other(code: CKError.Code.serverRecordChanged.rawValue)
        }
    }

    /// What a fetch operation returned: each record's transformed result, and the operation's own error.
    struct FetchOutcome<T: Sendable>: Sendable {
        var results: [CKRecord.ID: Result<T, any Error>]
        var operationError: (any Error)?
    }

    /// One `CKFetchRecordsOperation`. `transform` runs inside the per-record result block, on CloudKit's queue, while
    /// any staged asset file still exists.
    static func fetch<T: Sendable>(_ recordIDs: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?, in database: CKDatabase,
                                   configuration: CKOperation.Configuration, group: CKOperationGroup,
                                   progress: (@Sendable (Double) -> Void)? = nil,
                                   transform: @escaping @Sendable (CKRecord) throws -> T) async -> FetchOutcome<T> {
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
        operation.desiredKeys = desiredKeys
        operation.configuration = configuration
        operation.group = group
        let results = OSAllocatedUnfairLock<[CKRecord.ID: Result<T, any Error>]>(initialState: [:])
        if let progress {
            operation.perRecordProgressBlock = { @Sendable _, fraction in progress(fraction) }
        }
        operation.perRecordResultBlock = { @Sendable recordID, result in
            let mapped: Result<T, any Error> = result.flatMap { record in Result { try transform(record) } }
            results.withLock { $0[recordID] = mapped }
        }
        let operationError = await run(operation, in: database) { done in operation.fetchRecordsResultBlock = done }
        return FetchOutcome(results: results.withLock { $0 }, operationError: operationError)
    }

    /// One create-only `CKModifyRecordsOperation` for `record`; the record's own result (or the operation's error).
    static func save(_ record: CKRecord, in database: CKDatabase, configuration: CKOperation.Configuration,
                     group: CKOperationGroup, progress: @escaping @Sendable (Double) -> Void) async throws -> Result<Void, any Error> {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = false
        operation.configuration = configuration
        operation.group = group
        let saved = OSAllocatedUnfairLock<Result<Void, any Error>?>(initialState: nil)
        operation.perRecordProgressBlock = { @Sendable _, fraction in progress(fraction) }
        operation.perRecordSaveBlock = { @Sendable _, result in
            saved.withLock { $0 = result.map { _ in () } }
        }
        let operationError = await run(operation, in: database) { done in operation.modifyRecordsResultBlock = done }
        if let result = saved.withLock({ $0 }) { return result }
        throw operationError ?? AudioTransferError.retryable(retryAfter: nil)
    }

    /// Adds `operation` to `database` and waits for its final block (`install` sets it); the operation's error, nil on
    /// success. Cancelling the task cancels the operation, which then ends with `operationCancelled`.
    static func run(_ operation: CKDatabaseOperation, in database: CKDatabase,
                    install: (@escaping @Sendable (Result<Void, any Error>) -> Void) -> Void) async -> (any Error)? {
        let handle = CancelHandle(operation)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
                install { @Sendable result in
                    switch result {
                    case .success: continuation.resume(returning: nil)
                    case .failure(let error): continuation.resume(returning: error)
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Lets the cancellation handler (any thread) cancel the operation; `Operation.cancel()` is thread-safe.
    final class CancelHandle: @unchecked Sendable {
        private let operation: Operation
        init(_ operation: Operation) { self.operation = operation }
        func cancel() { operation.cancel() }
    }

    /// Moves a fetched asset's staged file to `destination` (replacing anything there). Runs inside the per-record
    /// result block. An asset without a file is a broken blob (`.other(0)`, as `FakeAudioTransfer` reports an
    /// unreadable one); a staged file that vanished first is worth retrying, and leaves the destination as it was.
    static func adopt(asset: CKAsset?, to destination: URL) throws {
        guard let source = asset?.fileURL else { throw AudioTransferError.other(code: 0) }
        let fm = FileManager.default
        // Checked before anything at the destination is replaced.
        guard fm.fileExists(atPath: source.path) else { throw AudioTransferError.retryable(retryAfter: nil) }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: source, to: destination)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) {
                throw AudioTransferError.retryable(retryAfter: nil)
            }
            throw AudioTransferError.other(code: ns.code)
        }
    }

    // MARK: Configuration

    /// Transfers: QoS `.userInitiated` for work the user asked for, `.utility` otherwise; mobile data only when
    /// `options` allow it. nil (probes, checks, deletes and the listing, which move kilobytes) is `.userInitiated` on any
    /// network: Download Now, Sync Audio Now and Remove iCloud Copy wait on them, and `CKOperation.h` documents only
    /// `.default` as discretionary (paused in Low Power Mode), so these never risk being held behind a lower class.
    static func configuration(_ options: AudioTransferOptions?) -> CKOperation.Configuration {
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = options.map { $0.userInitiated ? .userInitiated : .utility } ?? .userInitiated
        configuration.allowsCellularAccess = options?.allowsMetered ?? true
        return configuration
    }

    /// A group with a fixed, non-personal name (`audio-upload`, `audio-download`, `audio-delete`, `audio-list`,
    /// `audio-probe`, `audio-check`) and the expected transfer sizes.
    static func group(_ name: String, send: CKOperationGroup.TransferSize, receive: CKOperationGroup.TransferSize,
                      quantity: Int = 1, configuration: CKOperation.Configuration) -> CKOperationGroup {
        let group = CKOperationGroup()
        group.name = name
        group.expectedSendSize = send
        group.expectedReceiveSize = receive
        group.quantity = max(quantity, 1)
        group.defaultConfiguration = configuration
        return group
    }

    // MARK: Helpers

    static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func chunks(_ ids: [UUID]) -> [[UUID]] {
        stride(from: 0, to: ids.count, by: AudioPolicy.batch).map { Array(ids[$0 ..< min($0 + AudioPolicy.batch, ids.count)]) }
    }

    static func checkCancelled() throws {
        if Task.isCancelled { throw AudioTransferError.cancelled }
    }

    static func code(_ error: any Error) -> CKError.Code? { (error as? CKError)?.code }

    static func isZoneGone(_ error: any Error) -> Bool {
        code(error) == .zoneNotFound || code(error) == .userDeletedZone
    }

    /// Logs a failure and returns the `AudioTransferError` to throw.
    static func failed(_ what: String, _ error: any Error, cause: (any Error)? = nil) -> AudioTransferError {
        let mapped = CKAudioCodec.error(error)
        let underlying = cause ?? error
        let detail = underlying is CKError ? " (\(CloudKitTransport.describe(underlying)))" : ""
        if mapped == .cancelled {
            log.notice("\(what, privacy: .public) cancelled")
        } else {
            log.error("\(what, privacy: .public) failed: \(name(mapped), privacy: .public)\(detail, privacy: .public)")
        }
        return mapped
    }

    /// The case name for the log ("retryable after 30 s", "other 14").
    static func name(_ error: AudioTransferError) -> String {
        switch error {
        case .noAccount: "noAccount"
        case .networkUnavailable: "networkUnavailable"
        case .quotaExceeded: "quotaExceeded"
        case .notFound: "notFound"
        case .tooLarge: "tooLarge"
        case .cancelled: "cancelled"
        case .indexMissing: "indexMissing"
        case .zoneMissing: "zoneMissing"
        case .sourceChanged: "sourceChanged"
        case .retryable(let after): after.map { "retryable after \(Int($0.rounded())) s" } ?? "retryable"
        case .other(let code): "other \(code)"
        }
    }

    static func name(_ presence: AudioPresence) -> String {
        switch presence {
        case .present: "present"
        case .absent: "absent"
        case .unreadable: "unreadable"
        }
    }

    /// "14.2 MB" (rounded to 0.1 MB).
    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    static func seconds(since start: ContinuousClock.Instant) -> String {
        let d = ContinuousClock.now - start
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.1f s", s)
    }
}
