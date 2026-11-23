import CloudKit
import Foundation
import os
import TranscribeKit

/// The real `SyncTransport` (§8.3): `CKSyncEngine` on the private database of `iCloud.ai.w2solutions.transcribe`, one
/// zone `Library`.
///
/// - Engine events become `SyncEvent`s. `handleEvent` waits until the coordinator has handled (and saved) each one
///   (`eventHandled()`), so the engine never moves its change token past data that is not yet in `Library.store`.
/// - The engine is created lazily, on the first enqueue, fetch or send after `start`: the coordinator only reaches
///   those once it is running, so no event can arrive (and be dropped) before it listens.
/// - Batches come from `RecordZoneChangeBatch(pendingChanges:recordProvider:)` (at most 250 records). The provider
///   hops to the main actor for the coordinator's record; nil (gone, frozen, no longer pending) removes the pending
///   change. A record with no system fields goes out as new.
/// - The zone is saved only when the engine starts without state (joining, or after the cloud copy was reset), so a
///   zone deleted on another device is never silently recreated here.
/// - Nothing touches CloudKit until sync starts or asks for the account. Without the container entitlement (a Mac
///   build signed to run locally) every call reads as "no account".
public actor CloudKitTransport: SyncTransport, CKSyncEngineDelegate {
    public static let containerIdentifier = "iCloud.ai.w2solutions.transcribe"

    public nonisolated let events: AsyncStream<SyncEvent>
    private let continuation: AsyncStream<SyncEvent>.Continuation
    public nonisolated let identifier: String
    private let codec: CKRecordCodec
    private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "cloudkit")

    private var container: CKContainer?
    private var noEntitlement = false
    private var engine: CKSyncEngine?
    private var started = false
    private var state: CKSyncEngine.State.Serialization?
    private var provider: (@MainActor @Sendable (SyncRecordID) -> SyncRecord?)?
    private var wantsZone = false
    /// One entry per event yielded and not yet handled; nil for events nobody waits on.
    private var ackWaiters: [CheckedContinuation<Void, Never>?] = []
    private var observer: AccountObserver?
    /// The last account seen (nil inside = no account); nil = not asked yet.
    private var knownAccount: String??

    public init(containerIdentifier: String = CloudKitTransport.containerIdentifier, codec: CKRecordCodec = CKRecordCodec()) {
        identifier = containerIdentifier
        self.codec = codec
        (events, continuation) = AsyncStream<SyncEvent>.makeStream()
    }

    // MARK: SyncTransport

    public func start(state: Data?, provider: @escaping @MainActor @Sendable (SyncRecordID) -> SyncRecord?) async {
        self.provider = provider
        self.state = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        if state != nil && self.state == nil { log.error("Saved engine state did not decode; starting fresh") }
        if let old = engine {
            engine = nil
            Task.detached { await old.cancelOperations() }
        }
        started = true
        codec.removeAllOutgoingAssets()
        armObserver()
    }

    public func stop() async {
        started = false
        provider = nil
        guard let old = engine else { return }
        engine = nil
        // Not awaited here: an event of this engine may be waiting for the coordinator, which may be what called stop.
        Task.detached { await old.cancelOperations() }
    }

    public func enqueue(saves: [SyncRecordID], deletes: [SyncRecordID]) async {
        guard started, let engine = makeEngine() else { return }
        let saveIDs = saves.map(codec.recordID), deleteIDs = deletes.map(codec.recordID)
        engine.state.remove(pendingRecordZoneChanges: saveIDs.map { .deleteRecord($0) } + deleteIDs.map { .saveRecord($0) })
        engine.state.add(pendingRecordZoneChanges: saveIDs.map { .saveRecord($0) } + deleteIDs.map { .deleteRecord($0) })
    }

    public func ensureZone() async {
        wantsZone = true
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: codec.zoneID))])
    }

    public func deleteZone() async throws {
        guard let container = openContainer(), await currentAccount(container) != nil else { throw SyncTransportError.noAccount }
        let result = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [codec.zoneID])
        if case .failure(let error)? = result.deleteResults[codec.zoneID], (error as? CKError)?.code != .zoneNotFound {
            throw error
        }
        if let engine {
            engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
            engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        }
        wantsZone = false
    }

    public func fetchChanges() async throws {
        guard started else { throw SyncTransportError.notStarted }
        guard let engine = makeEngine() else { throw SyncTransportError.noAccount }
        try await engine.fetchChanges()
    }

    public func sendChanges() async throws {
        guard started else { throw SyncTransportError.notStarted }
        guard let engine = makeEngine() else { throw SyncTransportError.noAccount }
        try await engine.sendChanges()
    }

    public func accountHash() async -> String? {
        guard let container = openContainer() else {
            knownAccount = .some(nil)
            return nil
        }
        let hash = await currentAccount(container)
        knownAccount = .some(hash)
        return hash
    }

    public func eventHandled() async {
        guard !ackWaiters.isEmpty else { return }
        ackWaiters.removeFirst()?.resume()
    }

    // MARK: Container and engine

    private func openContainer() -> CKContainer? {
        if let container { return container }
        guard !noEntitlement else { return nil }
        guard AccountObserver.hasContainerEntitlement(identifier) else {
            noEntitlement = true
            log.info("No iCloud container entitlement for \(self.identifier, privacy: .public); sync reads as signed out")
            return nil
        }
        let c = CKContainer(identifier: identifier)
        container = c
        return c
    }

    private func makeEngine() -> CKSyncEngine? {
        if let engine { return engine }
        guard started, let container = openContainer() else { return nil }
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self)
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        if wantsZone && state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: codec.zoneID))])
        }
        self.engine = engine
        return engine
    }

    /// The account hash, falling back to the last one seen when the account is available but its id cannot be read
    /// (offline). A different account signed in meanwhile is still caught: `CKSyncEngine` reports it on start.
    private func currentAccount(_ container: CKContainer) async -> String? {
        guard (try? await container.accountStatus()) == .available else { return nil }
        let key = "sync.cloudkit.accountHash.\(identifier)"
        if let id = try? await container.userRecordID() {
            let hash = AccountObserver.hash(id)
            UserDefaults.standard.set(hash, forKey: key)
            return hash
        }
        return UserDefaults.standard.string(forKey: key)
    }

    // MARK: Account changes while the engine is not running

    private func armObserver() {
        guard observer == nil else { return }
        observer = AccountObserver { [weak self] in
            guard let self else { return }
            Task { await self.accountMayHaveChanged() }
        }
    }

    /// `CKAccountChanged` arrives for many reasons; only a change of who is signed in becomes an event, and only while
    /// no engine runs (a running engine reports it itself).
    private func accountMayHaveChanged() async {
        guard engine == nil, let container = openContainer() else { return }
        let previous = knownAccount
        let now = await currentAccount(container)
        knownAccount = .some(now)
        guard case .some(let before) = previous else { return }
        switch (before, now) {
        case (nil, let hash?): post(.accountChange(.signIn(hash)))
        case (_?, nil): post(.accountChange(.signOut))
        case (let old?, let hash?) where old != hash: post(.accountChange(.switchAccounts(hash)))
        default: break
        }
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine, started else { return }
        switch event {
        case .stateUpdate(let update):
            state = update.stateSerialization
            do {
                await deliver(.stateUpdate(try JSONEncoder().encode(update.stateSerialization)))
            } catch {
                log.error("Engine state did not encode: \(error.localizedDescription, privacy: .public)")
            }

        case .accountChange(let change):
            let mapped: AccountChange
            switch change.changeType {
            case .signIn(let user):
                mapped = .signIn(AccountObserver.hash(user))
                knownAccount = .some(AccountObserver.hash(user))
            case .signOut:
                mapped = .signOut
                knownAccount = .some(nil)
            case .switchAccounts(_, let user):
                mapped = .switchAccounts(AccountObserver.hash(user))
                knownAccount = .some(AccountObserver.hash(user))
            @unknown default:
                return
            }
            await deliver(.accountChange(mapped))

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == codec.zoneID {
                let reason: ZoneDeletionReason
                switch deletion.reason {
                case .deleted: reason = .deleted
                case .purged: reason = .purged
                case .encryptedDataReset: reason = .encryptedDataReset
                @unknown default: reason = .deleted
                }
                await deliver(.zoneDeleted(reason))
            }

        case .fetchedRecordZoneChanges(let changes):
            var modifications: [SyncRecord] = []
            for modification in changes.modifications {
                do {
                    if let record = try codec.decode(modification.record) { modifications.append(record) }
                } catch {
                    log.error("Skipped fetched record \(modification.record.recordID.recordName, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            let deletions = changes.deletions.compactMap { codec.syncID($0.recordID) }
            guard !modifications.isEmpty || !deletions.isEmpty else { return }
            await deliver(.fetched(modifications: modifications, deletions: deletions))

        case .sentRecordZoneChanges(let sent):
            let event = mapSent(sent)
            codec.removeOutgoingAssets(recordNames: sent.savedRecords.map(\.recordID.recordName)
                + sent.failedRecordSaves.map(\.record.recordID.recordName))
            await deliver(event)

        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                log.error("Zone save failed: \(failure.error.localizedDescription, privacy: .public)")
            }
            for (zone, error) in sent.failedZoneDeletes {
                log.error("Zone delete of \(zone.zoneName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }

        case .didFetchChanges:
            await deliver(.fetchFinished)

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine, started else { return nil }
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.recordToSave(recordID, engine: syncEngine)
        }
    }

    /// The `CKRecord` for one pending save. Nil (the coordinator skipped it, or it is not one of ours) removes the
    /// pending change: a later local change or full scan queues it again.
    private func recordToSave(_ recordID: CKRecord.ID, engine: CKSyncEngine) async -> CKRecord? {
        if started, engine === self.engine, let provider, let id = codec.syncID(recordID), let record = await provider(id) {
            do {
                return try codec.encode(record)
            } catch {
                log.error("Could not encode \(id.recordName, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
    }

    // MARK: Mapping send results

    func mapSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) -> SyncEvent {
        var saved: [SyncRecord] = []
        for record in sent.savedRecords {
            guard let id = codec.syncID(record.recordID) else { continue }
            let decoded = (try? codec.decode(record)) ?? nil
            saved.append(decoded ?? SyncRecord(id: id, fields: [:], systemFields: CKRecordCodec.systemFields(record)))
        }
        var deleted = sent.deletedRecordIDs.compactMap { codec.syncID($0) }
        var failures: [SendFailure] = []
        for failure in sent.failedRecordSaves {
            guard let id = codec.syncID(failure.record.recordID) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord, let record = try? codec.decode(server) {
                    failures.append(.serverRecordChanged(record))
                } else {
                    failures.append(.retryable(id))
                }
            default:
                failures.append(Self.failure(id, failure.error))
            }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            guard let id = codec.syncID(recordID) else { continue }
            if error.code == .unknownItem {
                deleted.append(id)   // already gone: the delete is done
            } else {
                failures.append(Self.failure(id, error))
            }
        }
        return .sent(saved: saved, deleted: deleted, failures: failures)
    }

    static func failure(_ id: SyncRecordID, _ error: CKError) -> SendFailure {
        switch error.code {
        case .unknownItem: .unknownItem(id)
        case .zoneNotFound, .userDeletedZone: .zoneNotFound(id)
        case .quotaExceeded: .quotaExceeded(id)
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .notAuthenticated, .operationCancelled, .accountTemporarilyUnavailable, .batchRequestFailed, .serverResponseLost:
            .retryable(id)
        default: .permanent(id, "\(error.code.rawValue): \(error.localizedDescription)")
        }
    }

    // MARK: Delivery

    /// Yields an event and waits until the coordinator has handled it.
    private func deliver(_ event: SyncEvent) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ackWaiters.append(c)
            continuation.yield(event)
        }
    }

    /// Yields an event without waiting (account changes noticed outside the engine).
    private func post(_ event: SyncEvent) {
        ackWaiters.append(nil)
        continuation.yield(event)
    }
}
