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
/// - `fetchChanges` (Sync Now, coming to the front, the in-front timer) asks the engine and then catches up with its
///   own `recordZoneChanges` from a change token of its own. On real devices the engine's `fetchChanges` finished
///   without asking the server when no push had arrived (2026-11-24), so a missed push left a device stale. Records
///   reach the coordinator through the same events either way; one older than a copy already seen this session is
///   dropped, so the catch-up never undoes a newer save or fetch.
/// - Every send and fetch outcome is logged (subsystem `ai.w2solutions.transcribe`, category `cloudkit`) with record
///   types, record names (a type prefix and a UUID) and CKError codes as public. Field values never are.
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
    /// The newest server modification date seen this session, by record name (fetched, saved or conflict copies).
    private var newestSeen: [String: Date] = [:]
    private var catchingUp = false
    private var catchUpTokenKey: String { "sync.cloudkit.catchUpToken.\(identifier).\(codec.zoneID.zoneName)" }

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
        // A fresh engine fetches everything again; so does the catch-up.
        if self.state == nil { saveCatchUpToken(nil) }
        newestSeen = [:]
        log.notice("Started (\(self.state == nil ? "fresh" : "saved state", privacy: .public))")
        // Pushes come from a database subscription the engine makes. Log whether one exists (2026-11-24: no pushes).
        if let database = container?.privateCloudDatabase {
            let log = log
            Task.detached {
                do {
                    let all = try await database.allSubscriptions()
                    let kinds = all.map { "\($0.subscriptionType.rawValue):\($0.notificationInfo?.shouldSendContentAvailable == true ? "silent" : "not-silent")" }
                    log.notice("iCloud subscriptions: \(all.count, privacy: .public) [\(kinds.joined(separator: ", "), privacy: .public)]")
                } catch {
                    log.error("Could not list iCloud subscriptions: \(Self.describe(error), privacy: .public)")
                }
            }
        }
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
        log.notice("Fetch requested")
        var engineError: (any Error)?
        do {
            try await engine.fetchChanges()
        } catch {
            engineError = error
            log.error("Engine fetch failed: \(Self.describe(error), privacy: .public)")
        }
        guard started, engine === self.engine else { return }
        try await catchUp(engine.database)
        if let engineError { throw engineError }
    }

    public func sendChanges() async throws {
        guard started else { throw SyncTransportError.notStarted }
        guard let engine = makeEngine() else { throw SyncTransportError.noAccount }
        log.notice("Send requested: \(engine.state.pendingRecordZoneChanges.count, privacy: .public) pending record changes")
        do {
            try await engine.sendChanges()
        } catch {
            log.error("Engine send failed: \(Self.describe(error), privacy: .public)")
            throw error
        }
    }

    // MARK: Catch-up fetch

    /// Fetches the zone's changes since this transport's own token, without the engine, and delivers them like the
    /// engine's. The token is saved only after the coordinator has handled (and saved) each page.
    private func catchUp(_ database: CKDatabase) async throws {
        guard !catchingUp else { return }
        catchingUp = true
        defer { catchingUp = false }
        var token = loadCatchUpToken()
        var pages = 0, total = 0, removed = 0, stale = 0
        while started {
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                       deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: codec.zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                log.notice("Catch-up token expired; fetching the zone from the start")
                token = nil
                saveCatchUpToken(nil)
                continue
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // The engine reports a deleted zone itself (`fetchedDatabaseChanges`); nothing to catch up.
                log.notice("Catch-up: zone not found (\(Self.describe(error), privacy: .public))")
                saveCatchUpToken(nil)
                return
            } catch {
                log.error("Catch-up fetch failed: \(Self.describe(error), privacy: .public)")
                throw error
            }
            pages += 1
            var modifications: [SyncRecord] = []
            var deletedByRefetch: [SyncRecordID] = []
            // A record that could not be fetched at all: the token must not move past it.
            var incomplete = false
            for (recordID, result) in page.modificationResultsByID {
                let why: String
                switch result {
                case .success(let modification):
                    let record = modification.record
                    guard isNewest(record) else { stale += 1; continue }
                    do {
                        if let decoded = try codec.decode(record) { modifications.append(decoded) }
                        continue
                    } catch {
                        why = String(describing: error)
                    }
                case .failure(let error):
                    why = Self.describe(error)
                }
                // Like the engine path: an asset's file may be unreadable here, so fetch the record again by id.
                switch await refetch(recordID) {
                case .record(let record):
                    log.notice("Catch-up refetched \(recordID.recordName, privacy: .public) (\(why, privacy: .public))")
                    modifications.append(record)
                case .gone:
                    if let id = codec.syncID(recordID) { deletedByRefetch.append(id) }
                case .unreadable(let again):
                    log.error("Catch-up skipped \(recordID.recordName, privacy: .public): \(why, privacy: .public); refetch: \(again, privacy: .public)")
                case .failed(let again):
                    log.error("Catch-up could not read \(recordID.recordName, privacy: .public): \(why, privacy: .public); refetch: \(again, privacy: .public). Will retry")
                    incomplete = true
                }
            }
            let deletions = page.deletions.compactMap { codec.syncID($0.recordID) } + deletedByRefetch
            total += modifications.count
            removed += deletions.count
            if !modifications.isEmpty || !deletions.isEmpty {
                await deliver(.fetched(modifications: modifications, deletions: deletions))
            }
            guard started else { return }
            // Stop here with the old token: the next catch-up fetches this page again (applying a record twice merges).
            if incomplete { break }
            token = page.changeToken
            saveCatchUpToken(token)
            if !page.moreComing { break }
        }
        guard started else { return }
        log.notice("Catch-up fetch: \(total, privacy: .public) changed, \(removed, privacy: .public) deleted, \(stale, privacy: .public) older than seen, \(pages, privacy: .public) pages")
        if total > 0 || removed > 0 { await deliver(.fetchFinished) }
    }

    private func loadCatchUpToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: catchUpTokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveCatchUpToken(_ token: CKServerChangeToken?) {
        guard let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            UserDefaults.standard.removeObject(forKey: catchUpTokenKey)
            return
        }
        UserDefaults.standard.set(data, forKey: catchUpTokenKey)
    }

    /// False for a copy older than one already seen this session (a fetch that raced a newer save or fetch); notes
    /// the date of a newer one.
    private func isNewest(_ record: CKRecord) -> Bool {
        guard let date = record.modificationDate else { return true }
        let name = record.recordID.recordName
        if let seen = newestSeen[name], date < seen {
            log.notice("Dropped an older copy of \(name, privacy: .public)")
            return false
        }
        newestSeen[name] = date
        return true
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
            log.notice("Engine fetched database changes: \(changes.modifications.count, privacy: .public) zones changed, \(changes.deletions.count, privacy: .public) deleted")
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
            log.notice("Engine fetched \(changes.modifications.count, privacy: .public) changed and \(changes.deletions.count, privacy: .public) deleted records")
            var modifications: [SyncRecord] = []
            for modification in changes.modifications {
                guard isNewest(modification.record) else { continue }
                do {
                    if let record = try codec.decode(modification.record) { modifications.append(record) }
                } catch {
                    // The change token moves past this batch, so a record that does not decode (an asset file not
                    // readable) is fetched again by id now rather than lost.
                    let name = modification.record.recordID.recordName
                    switch await refetch(modification.record.recordID) {
                    case .record(let record): modifications.append(record)
                    case .gone: break
                    case .unreadable(let why), .failed(let why):
                        log.error("Skipped fetched record \(name, privacy: .public): \(String(describing: error), privacy: .public); refetch: \(why, privacy: .public)")
                    }
                }
            }
            let deletions = changes.deletions.compactMap { codec.syncID($0.recordID) }
            guard !modifications.isEmpty || !deletions.isEmpty else { return }
            await deliver(.fetched(modifications: modifications, deletions: deletions))

        case .sentRecordZoneChanges(let sent):
            log.notice("Engine sent: \(sent.savedRecords.count, privacy: .public) saved, \(sent.deletedRecordIDs.count, privacy: .public) deleted, \(sent.failedRecordSaves.count, privacy: .public) saves and \(sent.failedRecordDeletes.count, privacy: .public) deletes failed")
            let event = await mapSent(sent, engine: syncEngine)
            codec.removeOutgoingAssets(recordNames: sent.savedRecords.map(\.recordID.recordName)
                + sent.failedRecordSaves.map(\.record.recordID.recordName))
            await deliver(event)

        case .sentDatabaseChanges(let sent):
            log.notice("Engine sent database changes: \(sent.savedZones.count, privacy: .public) zones saved, \(sent.deletedZoneIDs.count, privacy: .public) deleted")
            for failure in sent.failedZoneSaves {
                log.error("Zone save of \(failure.zone.zoneID.zoneName, privacy: .public) failed: \(Self.describe(failure.error), privacy: .public)")
            }
            for (zone, error) in sent.failedZoneDeletes {
                log.error("Zone delete of \(zone.zoneName, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            }

        case .didFetchChanges:
            log.notice("Engine finished fetching")
            await deliver(.fetchFinished)

        case .willFetchChanges:
            log.notice("Engine will fetch")
        case .willFetchRecordZoneChanges(let e):
            log.notice("Engine will fetch zone \(e.zoneID.zoneName, privacy: .public)")
        case .didFetchRecordZoneChanges(let e):
            if let error = e.error {
                log.error("Engine fetch of zone \(e.zoneID.zoneName, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            } else {
                log.notice("Engine fetched zone \(e.zoneID.zoneName, privacy: .public)")
            }
        case .willSendChanges(let e):
            log.notice("Engine will send (\(String(describing: e.context.reason), privacy: .public))")
        case .didSendChanges(let e):
            log.notice("Engine finished sending (\(String(describing: e.context.reason), privacy: .public))")

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
        log.notice("Building a batch (\(String(describing: context.reason), privacy: .public)) from \(pending.count, privacy: .public) pending")
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
        log.notice("Skipped \(recordID.recordName, privacy: .public): nothing to send")
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        return nil
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                        syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        log.notice("Engine fetch starting (\(String(describing: context.reason), privacy: .public))")
        return context.options
    }

    // MARK: Mapping send results

    /// A `serverRecordChanged` whose server copy does not decode is never reported as retryable: `CKSyncEngine` drops
    /// that pending save and expects the app to merge and re-add it. CloudKit leaves the conflict copy's asset fields
    /// without files (`CKAsset.fileURL` is nil), so a Recording with a transcript never decodes as delivered: the
    /// record is fetched again by id (with its assets) and that copy is merged.
    func mapSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) async -> SyncEvent {
        var saved: [SyncRecord] = []
        for record in sent.savedRecords {
            guard let id = codec.syncID(record.recordID) else { continue }
            if let date = record.modificationDate { newestSeen[record.recordID.recordName] = date }
            let decoded = (try? codec.decode(record)) ?? nil
            saved.append(decoded ?? SyncRecord(id: id, fields: [:], systemFields: CKRecordCodec.systemFields(record)))
        }
        var deleted = sent.deletedRecordIDs.compactMap { codec.syncID($0) }
        var failures: [SendFailure] = []
        for failure in sent.failedRecordSaves {
            guard let id = codec.syncID(failure.record.recordID) else { continue }
            log.error("Save of \(failure.record.recordType, privacy: .public) \(id.recordName, privacy: .public) failed: \(Self.describe(failure.error), privacy: .public)")
            switch failure.error.code {
            case .serverRecordChanged:
                if let date = failure.error.serverRecord?.modificationDate { newestSeen[id.recordName] = date }
                if let server = failure.error.serverRecord, let record = try? codec.decode(server) {
                    failures.append(.serverRecordChanged(record))
                    continue
                }
                switch await refetch(failure.record.recordID) {
                case .record(let record):
                    failures.append(.serverRecordChanged(record))
                case .gone:
                    failures.append(.unknownItem(id))   // deleted meanwhile: delete wins
                case .failed(let why):
                    // Offline or busy: keep the save pending in the engine, which retries it (and this refetch) later.
                    log.error("Refetching \(id.recordName, privacy: .public) after a conflict failed: \(why, privacy: .public)")
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    failures.append(.retryable(id))
                case .unreadable(let why):
                    failures.append(.permanent(id, "The server copy cannot be read: \(why)"))
                }
            default:
                let mapped = Self.failure(id, failure.error)
                // The coordinator queues it again as well; adding a pending change twice is harmless.
                if case .retryable = mapped { engine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]) }
                failures.append(mapped)
            }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            guard let id = codec.syncID(recordID) else { continue }
            log.error("Delete of \(id.type.rawValue, privacy: .public) \(id.recordName, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            if error.code == .unknownItem {
                deleted.append(id)   // already gone: the delete is done
            } else {
                failures.append(Self.failure(id, error))
            }
        }
        return .sent(saved: saved, deleted: deleted, failures: failures)
    }

    enum Refetched {
        case record(SyncRecord)
        /// The server no longer has it.
        case gone
        /// Fetched, but it still does not decode (a corrupt asset): retrying would not help.
        case unreadable(String)
        /// Not fetched (network, rate limit …): worth retrying later.
        case failed(String)
    }

    /// One record fetched again by id, assets included, and decoded.
    func refetch(_ recordID: CKRecord.ID) async -> Refetched {
        guard let database = container?.privateCloudDatabase else { return .failed("no container") }
        let result: Result<CKRecord, any Error>
        do {
            guard let r = try await database.records(for: [recordID])[recordID] else { return .gone }
            result = r
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let ck):
            do {
                guard let record = try codec.decode(ck) else { return .unreadable("not a Library record") }
                return .record(record)
            } catch {
                return .unreadable(String(describing: error))
            }
        case .failure(let error):
            if (error as? CKError)?.code == .unknownItem { return .gone }
            return .failed(error.localizedDescription)
        }
    }

    /// "CKError 14 serverRecordChanged" plus retry-after and partial errors' codes, for the log. Never field values.
    static func describe(_ error: any Error) -> String {
        guard let ck = error as? CKError else { return String(describing: error) }
        var text = "CKError \(ck.code.rawValue) \(codeName(ck.code))"
        if let after = ck.retryAfterSeconds { text += " retryAfter=\(after)s" }
        if let partial = ck.partialErrorsByItemID, !partial.isEmpty {
            let items = partial.prefix(20).map { key, value -> String in
                let name = (key as? CKRecord.ID)?.recordName ?? (key as? CKRecordZone.ID)?.zoneName ?? "\(key)"
                let code = (value as? CKError).map { "\($0.code.rawValue) \(codeName($0.code))" } ?? "?"
                return "\(name)=\(code)"
            }
            text += " partial[\(partial.count)]: " + items.sorted().joined(separator: ", ")
        }
        return text
    }

    static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .constraintViolation: "constraintViolation"
        case .operationCancelled: "operationCancelled"
        case .changeTokenExpired: "changeTokenExpired"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .serverResponseLost: "serverResponseLost"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        default: "code"
        }
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
