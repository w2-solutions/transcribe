import Foundation
import SwiftData
import TranscribeCore

/// Finds local changes by comparing each synced entity's group hashes with the base hashes in its
/// `SyncRecordState` (§8.4 flow 1, decision D4). No persistent history and no hooks in the write methods, so every
/// write path is caught, and a crash re-derives the same pending set.
///
/// - **Fast path:** the identifiers in `ModelContext.didSave`, collected while observing and processed by `flush()`.
/// - **Full scan:** every syncable entity and every state row, in chunks of 200 (launch, enable, resume, Sync Now).
///   Only a full scan can trip the mass-delete breaker.
@MainActor
final class ChangeDetector {
    struct Outcome: Equatable {
        var saves: [SyncRecordID] = []
        var deletes: [SyncRecordID] = []
        /// Set when a full scan tripped the mass-delete breaker: the deletes it held back (nothing was queued).
        var massDelete: [SyncRecordID]?
        var isEmpty: Bool { saves.isEmpty && deletes.isEmpty && massDelete == nil }
    }

    /// The breaker trips when a full scan would send more than this many deletes of one type...
    static let massDeleteMinimum = 25
    /// ...and they are more than this fraction of that type's synced rows.
    static let massDeleteFraction = 0.2
    static let scanChunk = 200

    let store: LibraryStore
    let clock: AppClock
    var context: ModelContext { store.context }
    private var projector: RecordProjector { RecordProjector(context: context) }

    private var observer: (any NSObjectProtocol)?
    private var changedIDs: Set<SyncRecordID> = []
    private var deletedTypes: Set<SyncRecordType> = []
    /// Called (on the main actor) when a save touched synced data; the coordinator debounces and flushes.
    var onCollected: (() -> Void)?

    init(store: LibraryStore, clock: AppClock) {
        self.store = store
        self.clock = clock
    }

    var hasCollected: Bool { !changedIDs.isEmpty || !deletedTypes.isEmpty }

    // MARK: Observing

    func startObserving() {
        guard observer == nil else { return }
        let key = ModelContext.NotificationKey.self
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) {
            [weak self] note in
            let info = note.userInfo ?? [:]
            let inserted = info[key.insertedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            let updated = info[key.updatedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            let deleted = info[key.deletedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            let work: @MainActor @Sendable () -> Void = { self?.collect(changed: inserted + updated, deleted: deleted) }
            if Thread.isMainThread { MainActor.assumeIsolated { work() } } else { Task { @MainActor in work() } }
        }
    }

    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        discardCollected()
    }

    func discardCollected() {
        changedIDs = []
        deletedTypes = []
    }

    private func collect(changed: [PersistentIdentifier], deleted: [PersistentIdentifier]) {
        var touched = false
        // Read the entity ids now, while the saved objects certainly exist; the flush looks them up again by id.
        for pid in changed where RecordProjector.type(entityName: pid.entityName) != nil {
            guard let e = RecordProjector.entity(for: context.model(for: pid)) else { continue }
            changedIDs.insert(e.recordID)
            touched = true
        }
        for id in deleted {
            guard let type = RecordProjector.type(entityName: id.entityName) else { continue }
            deletedTypes.insert(type)
            touched = true
        }
        if touched { onCollected?() }
    }

    // MARK: Fast path

    /// Processes what `didSave` collected since the last flush. Saves the state rows (one save) and returns what to
    /// hand to the transport.
    @discardableResult
    func flush() throws -> Outcome {
        guard hasCollected else { return Outcome() }
        var entities: [SyncRecordID: SyncEntity] = [:]
        for id in changedIDs { if let e = projector.entity(id) { entities[id] = e } }
        var deleteTypes = deletedTypes
        // Derived links: a recording's speakers follow its stage; a deleted profile or folder nullifies links.
        for e in Array(entities.values) {
            if case .recording(let r) = e { for s in r.speakers { entities[SyncEntity.speaker(s).recordID] = .speaker(s) } }
        }
        if deleteTypes.contains(.profile) {
            for e in try projector.all(.speaker) { entities[e.recordID] = e }
        }
        if deleteTypes.contains(.folder) {
            for e in try projector.all(.recording) { entities[e.recordID] = e }
        }
        if deleteTypes.contains(.recording) { deleteTypes.insert(.speaker) }
        if deleteTypes.contains(.profile) { deleteTypes.formUnion([.sample, .negative, .groupLabel]) }
        discardCollected()

        var outcome = Outcome()
        var states = try stateRows(named: entities.keys.map(\.recordName))
        for type in deleteTypes { for row in try stateRows(type: type) { states[row.recordName] = row } }
        var changed = false
        for e in entities.values.sorted(by: { $0.recordID.recordName < $1.recordID.recordName }) {
            changed = evaluate(e, state: states[e.recordID.recordName], into: &outcome).changed || changed
        }
        for type in deleteTypes.sorted(by: { $0.applyOrder < $1.applyOrder }) {
            let existing = try projector.allIDs(type)
            let rows = states.values.filter { $0.typeRaw == type.rawValue && !existing.contains($0.entityID) }
            for row in rows.sorted(by: { $0.recordName < $1.recordName }) {
                changed = markMissing(row, into: &outcome) || changed
            }
        }
        if changed || context.hasChanges { try context.save() }
        return outcome
    }

    // MARK: Full scan

    /// Compares every syncable entity and every state row. Rows already pending are handed to the transport again
    /// (its own pending list may have been lost). With the breaker tripped, nothing is queued and no delete is marked.
    func fullScan() async throws -> Outcome {
        _ = try flush()
        var outcome = Outcome()
        var allStates = try stateRows()
        var changed = false
        for type in SyncRecordType.allCases.sorted(by: { $0.applyOrder < $1.applyOrder }) {
            let entities = try projector.all(type).sorted { $0.recordID.recordName < $1.recordID.recordName }
            var start = 0
            while start < entities.count {
                let chunk = entities[start..<min(start + Self.scanChunk, entities.count)]
                for e in chunk where !e.model.isDeleted {
                    let result = evaluate(e, state: allStates[e.recordID.recordName], into: &outcome)
                    changed = result.changed || changed
                    if let created = result.created { allStates[created.recordName] = created }
                }
                start += Self.scanChunk
                if start < entities.count { await Task.yield() }
            }
        }

        // Missing entities: deletes, counted per type for the breaker before anything is marked.
        var newDeletes: [SyncRecordType: [SyncRecordState]] = [:]
        var holdSpeakerDeletes: Bool?
        for type in SyncRecordType.allCases {
            let existing = try projector.allIDs(type)
            for row in allStates.values where row.typeRaw == type.rawValue && !existing.contains(row.entityID) {
                switch row.pending {
                case .delete:
                    if let id = row.recordID { outcome.deletes.append(id) }
                case .parkedDelete:
                    context.delete(row)
                    changed = true
                case .none, .save:
                    if type == .speaker {
                        if holdSpeakerDeletes == nil { holdSpeakerDeletes = try syncedRecordingIsProcessing() }
                        if holdSpeakerDeletes == true { continue }
                    }
                    newDeletes[type, default: []].append(row)
                }
            }
        }
        let tripped = newDeletes.contains { type, rows in
            let synced = allStates.values.filter { $0.typeRaw == type.rawValue && $0.systemFields != nil }.count
            return rows.count > Self.massDeleteMinimum && Double(rows.count) > Self.massDeleteFraction * Double(synced)
        }
        if tripped {
            outcome.massDelete = newDeletes.values.flatMap { $0 }.compactMap(\.recordID)
                .sorted { $0.recordName < $1.recordName }
            outcome.saves = []
            outcome.deletes = []
            if changed || context.hasChanges { try context.save() }
            return outcome
        }
        for row in newDeletes.values.flatMap({ $0 }).sorted(by: { $0.recordName < $1.recordName }) {
            changed = markMissing(row, into: &outcome) || changed
        }
        // Rows already pending go to the transport again; their entity's current state decides.
        let queued = Set(outcome.saves + outcome.deletes)
        for row in allStates.values where row.pending == .save {
            guard let id = row.recordID, !queued.contains(id), !row.isDeleted else { continue }
            if let e = projector.entity(id), e.isSyncable { outcome.saves.append(id) }
        }
        outcome.saves.sort { $0.recordName < $1.recordName }
        outcome.deletes.sort { $0.recordName < $1.recordName }
        if changed || context.hasChanges { try context.save() }
        return outcome
    }

    /// Marks the given rows (held back by the breaker) as pending deletes.
    func confirmDeletes(_ ids: [SyncRecordID]) throws -> [SyncRecordID] {
        var outcome = Outcome()
        let rows = try stateRows(named: ids.map(\.recordName))
        for id in ids {
            guard let row = rows[id.recordName], projector.entity(id) == nil else { continue }
            _ = markMissing(row, into: &outcome)
        }
        try context.save()
        return outcome.deletes
    }

    // MARK: Per-row decisions

    /// An entity that exists: a frozen one is left alone; a parked remote delete is applied once its recording is
    /// ready; otherwise a changed hash (or no row) means a pending save. Returns whether a row changed.
    private func evaluate(_ e: SyncEntity, state: SyncRecordState?,
                          into outcome: inout Outcome) -> (changed: Bool, created: SyncRecordState?) {
        if let state, state.pending == .parkedDelete {
            guard !e.isProcessingLocally else { return (false, nil) }
            store.remoteDelete(e)
            context.delete(state)
            return (true, nil)
        }
        guard e.isSyncable else { return (false, nil) }
        guard let state else {
            let row = SyncRecordState(recordName: e.recordID.recordName, type: e.recordID.type, entityID: e.recordID.entityID,
                                      now: clock.now)
            row.pending = .save
            context.insert(row)
            outcome.saves.append(e.recordID)
            return (true, row)
        }
        return (evaluateExisting(e, state: state, into: &outcome), nil)
    }

    private func evaluateExisting(_ e: SyncEntity, state: SyncRecordState, into outcome: inout Outcome) -> Bool {
        if state.pending == .delete { return false }   // delete wins
        let hashes = RecordProjector.hashes(e, unresolved: state.unresolvedLinks)
        if hashes != state.baseHashes {
            outcome.saves.append(e.recordID)
            if state.pending != .save {
                state.pending = .save
                state.updatedAt = clock.now
                return true
            }
        } else if state.pending == .save, !state.mustMergeWithServer {
            state.pending = .none   // changed and changed back before it was sent
            state.updatedAt = clock.now
            return true
        }
        return false
    }

    /// A row whose entity is gone: the delete is sent (a parked remote delete just ends). Speaker deletes wait while a
    /// synced recording is being processed again here, since re-separation replaces every speaker of it.
    private func markMissing(_ row: SyncRecordState, into outcome: inout Outcome) -> Bool {
        guard let id = row.recordID else { return false }
        switch row.pending {
        case .delete:
            outcome.deletes.append(id)
            return false
        case .parkedDelete:
            context.delete(row)
            return true
        case .none, .save:
            if id.type == .speaker, (try? syncedRecordingIsProcessing()) == true { return false }
            row.pending = .delete
            row.updatedAt = clock.now
            outcome.deletes.append(id)
            return true
        }
    }

    /// Some recording that has synced before is going through processing again on this device.
    func syncedRecordingIsProcessing() throws -> Bool {
        let ready = RecordingStage.ready.rawValue, queued = RecordingStage.queued.rawValue
        let processing = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate {
            $0.stageRaw >= queued && $0.stageRaw < ready
        }))
        guard !processing.isEmpty else { return false }
        let names = processing.map { SyncRecordID(type: .recording, entityID: $0.id).recordName }
        return try !stateRows(named: names).isEmpty
    }

    // MARK: State rows

    func stateRows() throws -> [String: SyncRecordState] {
        Dictionary(try context.fetch(FetchDescriptor<SyncRecordState>()).map { ($0.recordName, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    func stateRows(named names: [String]) throws -> [String: SyncRecordState] {
        guard !names.isEmpty else { return [:] }
        var out: [String: SyncRecordState] = [:]
        var start = 0
        while start < names.count {
            let chunk = Array(names[start..<min(start + 500, names.count)])
            for row in try context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { chunk.contains($0.recordName) })) {
                out[row.recordName] = row
            }
            start += 500
        }
        return out
    }

    func stateRows(type: SyncRecordType) throws -> [SyncRecordState] {
        let raw = type.rawValue
        return try context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.typeRaw == raw }))
    }

    func stateRow(named name: String) throws -> SyncRecordState? {
        var d = FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.recordName == name })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }
}
