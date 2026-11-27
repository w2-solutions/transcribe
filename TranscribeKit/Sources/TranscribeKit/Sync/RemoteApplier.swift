import Foundation
import SwiftData
import TranscribeCore

/// Points where a test can make the coordinator "crash": everything written since the last save is rolled back.
public enum SyncFaultPoint: Sendable, Equatable {
    /// After a chunk of fetched records is applied, before it is saved.
    case beforeChunkSave
    /// After a send result is applied, before it is saved.
    case beforeSendResultSave
}

struct SyncCrash: Error {}

/// Applies fetched records and merges server copies (§8.4 flows 2 and 3).
///
/// A fetched modification and a `serverRecordChanged` copy go through the same three-way merge. A fetch is applied
/// in chunks of 100 records, modifications first (folders, profiles, recordings, speakers, samples, negatives, group
/// labels) and
/// deletions last, each chunk committing the entity writes and their state rows in one save.
@MainActor
final class RemoteApplier {
    static let chunkSize = 100
    /// A link whose target is still missing this long after it was recorded is dropped.
    static let unresolvedLinkLifetime: TimeInterval = 7 * 24 * 3600

    struct Effects {
        var saves: [SyncRecordID] = []
        var deletes: [SyncRecordID] = []
        var touchedProfiles: Set<UUID> = []
        var touchedRecordings: Set<UUID> = []
        var otherModelKey = false
    }

    let store: LibraryStore
    let detector: ChangeDetector
    let clock: AppClock
    /// The embedding model key of this build, when known: a fetched voice on another key means another device runs a
    /// different build.
    let modelKey: String?
    var fault: ((SyncFaultPoint) throws -> Void)?
    var context: ModelContext { store.context }
    private var projector: RecordProjector { RecordProjector(context: context) }

    init(store: LibraryStore, detector: ChangeDetector, clock: AppClock, modelKey: String?) {
        self.store = store; self.detector = detector; self.clock = clock; self.modelKey = modelKey
    }

    // MARK: Fetch

    /// Applies one fetched batch. Throws `SyncCrash` when a fault is injected (nothing of that chunk is saved).
    func applyFetched(modifications: [SyncRecord], deletions: [SyncRecordID], effects: inout Effects) async throws {
        let mods = modifications.sorted {
            $0.id.type.applyOrder != $1.id.type.applyOrder ? $0.id.type.applyOrder < $1.id.type.applyOrder
                : $0.id.recordName < $1.id.recordName
        }
        var start = 0
        while start < mods.count {
            let chunk = Array(mods[start..<min(start + Self.chunkSize, mods.count)])
            let rows = try detector.stateRows(named: chunk.map(\.id.recordName))
            let before = effects.touchedRecordings
            for record in chunk { merge(server: record, state: rows[record.id.recordName], effects: &effects) }
            refreshSearchText(effects.touchedRecordings.subtracting(before))
            try fault?(.beforeChunkSave)
            try context.save()
            start += Self.chunkSize
            await Task.yield()   // each chunk is saved: let the app breathe between chunks
        }
        let dels = deletions.sorted {
            $0.type.applyOrder != $1.type.applyOrder ? $0.type.applyOrder > $1.type.applyOrder : $0.recordName < $1.recordName
        }
        start = 0
        while start < dels.count {
            let chunk = Array(dels[start..<min(start + Self.chunkSize, dels.count)])
            let rows = try detector.stateRows(named: chunk.map(\.recordName))
            for id in chunk { applyDeletion(id, state: rows[id.recordName], effects: &effects) }
            try fault?(.beforeChunkSave)
            try context.save()
            start += Self.chunkSize
            await Task.yield()
        }
    }

    // MARK: Merge

    /// The three-way merge of a server copy into the local entity (or a new local entity).
    ///
    /// - The entity's recording is being processed here: skipped, base unchanged. The row keeps its (now old) system
    ///   fields, is marked must-merge and pending a save, so once the recording is ready it is sent even if processing
    ///   changed nothing; that save meets `serverRecordChanged` and merges then (the fetch token has moved on, so
    ///   nothing else would bring the skipped change back), or `unknownItem` if the record was deleted meanwhile.
    /// - The entity is gone here but the row knows the server: delete wins, the delete is (re)queued.
    /// - Otherwise each group is merged (`MergePolicy`); the new base is the server's hashes, except that applied
    ///   groups take the local re-projection (so an applied value never echoes back).
    func merge(server: SyncRecord, state: SyncRecordState?, effects: inout Effects) {
        let id = server.id
        noteModelKey(server, effects: &effects)
        let serverHashes = SyncSchema.hashes(server)
        if let e = projector.entity(id) {
            if e.isProcessingLocally {
                if let row = state, row.pending == .none || row.pending == .save {
                    row.markMustMergeWithServer()   // keeps the old change tag: see `mustMergeWithServer`
                    row.pending = .save
                    row.updatedAt = clock.now
                }
                return
            }
            let row = state ?? newRow(id)
            var unresolved = row.unresolvedLinks
            let local = RecordProjector.hashes(e, unresolved: unresolved)
            let actions = MergePolicy.decide(type: id.type, local: local, base: row.baseHashes, server: serverHashes)
            var applied: Set<String> = []
            for g in SyncSchema.groupNames(id.type) {
                switch actions[g] ?? .same {
                case .takeServer:
                    store.remoteApply(group: g, of: server, to: e, unresolved: &unresolved)
                    // A speaker source the server lacks (a record an older build created) is kept here, not
                    // cleared; leaving the group's base at the server's hash sends it back to the server.
                    if g == SyncSchema.Group.stats, case .speaker(let s) = e, s.captureSource != nil,
                       server.fields["captureSource"]?.stringValue == nil {
                        touch(e, effects: &effects)
                        continue
                    }
                    applied.insert(g)
                    touch(e, effects: &effects)
                case .union:
                    if case .speaker(let s) = e {
                        let theirs = (server.fields["rejectedProfileIDs"]?.stringsValue ?? []).compactMap(UUID.init(uuidString:))
                        s.rejectedProfileIDs = LibraryStore.sortedIDs(s.rejectedProfileIDs + theirs)
                    }
                case .keepLocalJoinSource:
                    if case .speaker(let s) = e {
                        s.captureSource = MergePolicy.joinedSource(local: s.captureSource,
                                                                   server: server.fields["captureSource"]?.stringValue)
                    }
                case .same, .keepLocal:
                    break
                }
            }
            row.unresolvedLinks = unresolved
            let after = RecordProjector.hashes(e, unresolved: unresolved)
            var base = serverHashes
            for g in applied { base[g] = after[g] }
            row.baseHashes = base
            row.systemFields = server.systemFields
            row.updatedAt = clock.now
            switch row.pending {
            case .delete, .parkedDelete:
                break
            case .none, .save:
                if after != base {
                    row.pending = .save
                    effects.saves.append(id)
                } else {
                    row.pending = .none
                }
            }
            return
        }
        if let row = state, row.pending == .delete || row.pending == .parkedDelete || !row.isFresh {
            // Deleted on this device after it last agreed with the server: delete wins. A delete already confirmed
            // here is queued again. One not yet confirmed (made while sync was not running, so no scan has counted
            // it) is left to the full scan that follows every fetch, so the mass-delete breaker counts it and can
            // hold it with the others; sending it now would get past "Restore them from iCloud".
            row.systemFields = server.systemFields
            if row.pending == .delete {
                effects.deletes.append(id)
            }
            row.updatedAt = clock.now
            return
        }
        let e = store.remoteInsert(server)
        var unresolved: [String: String] = [:]
        for g in SyncSchema.groupNames(id.type) { store.remoteApply(group: g, of: server, to: e, unresolved: &unresolved) }
        let row = state ?? newRow(id)
        row.unresolvedLinks = unresolved
        row.baseHashes = RecordProjector.hashes(e, unresolved: unresolved)
        row.systemFields = server.systemFields
        row.pending = .none
        row.updatedAt = clock.now
        touch(e, effects: &effects)
    }

    private func newRow(_ id: SyncRecordID) -> SyncRecordState {
        let row = SyncRecordState(recordName: id.recordName, type: id.type, entityID: id.entityID, now: clock.now)
        context.insert(row)
        return row
    }

    private func touch(_ e: SyncEntity, effects: inout Effects) {
        switch e {
        case .recording(let r): effects.touchedRecordings.insert(r.id)
        case .speaker(let s): if let r = s.recording { effects.touchedRecordings.insert(r.id) }
        case .profile(let p):
            effects.touchedProfiles.insert(p.id)
            for s in p.speakers { if let r = s.recording { effects.touchedRecordings.insert(r.id) } }   // names in search text
        case .sample(let s): if let p = s.profile { effects.touchedProfiles.insert(p.id) }
        case .negative(let n): if let p = n.profile { effects.touchedProfiles.insert(p.id) }
        case .folder, .groupLabel: break   // a label changes no profile state: its group is worked out when drawn
        }
    }

    private func noteModelKey(_ record: SyncRecord, effects: inout Effects) {
        guard let modelKey else { return }
        switch record.id.type {
        case .profile, .sample, .negative:
            if let key = record.fields["embeddingModelKey"]?.stringValue, key != modelKey { effects.otherModelKey = true }
        default:
            break
        }
    }

    // MARK: Delete

    /// A delete from the server: delete wins over any local edit. An entity whose recording is being processed here
    /// waits as a parked delete, applied once the recording is ready.
    func applyDeletion(_ id: SyncRecordID, state: SyncRecordState?, effects: inout Effects) {
        if let e = projector.entity(id) {
            if e.isProcessingLocally {
                let row = state ?? newRow(id)
                row.pending = .parkedDelete
                row.updatedAt = clock.now
                return
            }
            switch e {
            case .sample(let s): if let p = s.profile { effects.touchedProfiles.insert(p.id) }
            case .negative(let n): if let p = n.profile { effects.touchedProfiles.insert(p.id) }
            case .speaker(let s): if let r = s.recording { effects.touchedRecordings.insert(r.id) }
            default: break
            }
            store.remoteDelete(e)
        }
        if let state { context.delete(state) }
    }

    /// Rebuilds the search text of recordings whose transcript, title or speaker names may have changed.
    func refreshSearchText(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let wanted = Array(ids)
        for r in (try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { wanted.contains($0.id) }))) ?? [] {
            store.rebuildSearchText(r)
        }
    }

    // MARK: Fetch finished

    /// Resolves links whose targets have arrived (or drops ones missing for 7 days) and recomputes `needsResample`.
    /// Returns the recordings whose speakers gained a link (their search text names those speakers).
    @discardableResult
    func finishFetch(touchedProfiles: Set<UUID>) throws -> Set<UUID> {
        var linked: Set<UUID> = []
        let rows = try context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.unresolvedLinksJSON != nil }))
        for row in rows {
            guard let id = row.recordID, let e = projector.entity(id) else { continue }
            var links = row.unresolvedLinks
            for (field, raw) in links.sorted(by: { $0.key < $1.key }) {
                if LibraryStore.linkIsSet(field: field, on: e) {
                    links.removeValue(forKey: field)
                } else if let target = UUID(uuidString: raw), store.resolveLink(field: field, targetID: target, on: e) {
                    links.removeValue(forKey: field)
                    if case .speaker(let s) = e, let r = s.recording { linked.insert(r.id) }
                } else if clock.now.timeIntervalSince(row.updatedAt) >= Self.unresolvedLinkLifetime {
                    links.removeValue(forKey: field)
                }
            }
            if links != row.unresolvedLinks { row.unresolvedLinks = links }
        }
        if !touchedProfiles.isEmpty {
            let ids = Array(touchedProfiles)
            for p in try context.fetch(FetchDescriptor<VoiceProfile>(predicate: #Predicate { ids.contains($0.id) })) {
                store.recomputeNeedsResample(p)
            }
        }
        return linked
    }
}
