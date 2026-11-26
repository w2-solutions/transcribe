import Foundation
import os
import SwiftData
import TranscribeCore

/// Audio rows, the coordinator's hooks (fetched markers, the provider, send results) and what the views and Settings
/// read. Every `.audio` id reaches these functions before any generic lookup (`AudioRows`).
extension AudioSync {
    // MARK: Rows

    func allAudioRows() -> [SyncRecordState] {
        let raw = AudioRows.typeRaw
        return (try? context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.typeRaw == raw }))) ?? []
    }

    func audioRow(_ id: UUID) -> SyncRecordState? {
        let name = AudioRows.recordName(id)
        var d = FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.recordName == name })
        d.fetchLimit = 1
        guard let row = try? context.fetch(d).first, row.isAudioRow else { return nil }
        return row
    }

    /// Audio rows by recording id, for these ids only.
    func audioRows(_ ids: [UUID]) -> [UUID: SyncRecordState] {
        let names = Array(Set(ids.map(AudioRows.recordName)))
        guard !names.isEmpty else { return [:] }
        var out: [UUID: SyncRecordState] = [:]
        var start = 0
        while start < names.count {
            let chunk = Array(names[start..<min(start + 500, names.count)])
            let rows = (try? context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { chunk.contains($0.recordName) }))) ?? []
            for row in rows where row.isAudioRow { out[row.entityID] = row }
            start += 500
        }
        return out
    }

    /// Inserts an audio row (the caller checked there is none).
    @discardableResult
    func insertRow(_ facts: AudioRowFacts) -> SyncRecordState {
        let row = SyncRecordState.audioRow(facts, now: clock.now)
        context.insert(row)
        return row
    }

    func recordingExists(_ ids: [UUID]) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let wanted = Array(Set(ids))
        let rows = (try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { wanted.contains($0.id) }))) ?? []
        return Set(rows.map(\.id))
    }

    func recording(_ id: UUID) -> Recording? {
        var d = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    func save() {
        do { try context.save() } catch {
            log.error("audio: saving the store failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Ready recordings here with a row `.onServer` and no local file.
    func cloudOnlyIDs() -> [UUID] {
        let rows = allAudioRows().compactMap { row -> UUID? in
            guard let f = row.audioFacts, f.marker == .onServer else { return nil }
            return row.entityID
        }
        guard !rows.isEmpty else { return [] }
        let wanted = rows
        let recordings = (try? context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { wanted.contains($0.id) }))) ?? []
        return recordings.filter { $0.stage == .ready && !store.hasLocalAudio($0) }
            .sorted { $0.createdAt > $1.createdAt }.map(\.id)
    }

    // MARK: Fetched markers

    /// One `context.save()`; no awaits. Never touches local files.
    func applyFetched(markers: [SyncRecord], deleted: [UUID]) {
        guard !markers.isEmpty || !deleted.isEmpty else { return }
        var rows = audioRows(markers.map(\.id.entityID) + deleted)
        let present = recordingExists(markers.map(\.id.entityID))
        let now = clock.now
        var changed = false, skipped = 0
        for record in markers {
            let id = record.id.entityID
            let version = SyncSchema.recordVersion(record)
            guard let d = AudioMarker.descriptor(record) ?? (version > SyncSchema.version ? Self.placeholder(id) : nil) else {
                skipped += 1
                continue
            }
            if let row = rows[id] {
                switch row.audioRead {
                case .newer:
                    continue
                case .malformed:
                    row.audioFacts = AudioRowFacts(descriptor: d, marker: .onServer, markerVersion: version,
                                                   recordingSeen: present.contains(id), firstSeenAt: now)
                    changed = true
                case .facts(var f):
                    guard f.marker != .deleting else { continue }   // delete wins
                    let before = f
                    f.descriptor = d
                    f.markerVersion = version
                    f.marker = .onServer
                    if present.contains(id) { f.recordingSeen = true }
                    if f != before { row.audioFacts = f; changed = true }
                }
            } else {
                rows[id] = insertRow(AudioRowFacts(descriptor: d, marker: .onServer, markerVersion: version,
                                                   recordingSeen: present.contains(id), firstSeenAt: now))
                changed = true
            }
        }
        for id in deleted {
            probed.insert(id)
            guard let row = rows[id] else { continue }
            switch row.audioRead {
            case .newer: continue
            case .facts(let f) where f.marker == .sending: continue   // this device is declaring it again
            default:
                context.delete(row)
                rows[id] = nil
                changed = true
            }
        }
        if skipped > 0 { log.error("audio: \(skipped, privacy: .public) fetched markers could not be read; skipped") }
        if changed {
            save()
            revision += 1
        }
    }

    // MARK: Sending markers

    /// Provider: rows in `.sending` only.
    func markerRecord(for id: UUID) -> SyncRecord? {
        guard !refused.contains(id), let f = audioRow(id)?.audioFacts, f.marker == .sending else { return nil }
        return AudioMarker.record(f.descriptor)
    }

    /// `.sending`, not refused this session.
    var pendingMarkerSaves: [SyncRecordID] {
        allAudioRows().compactMap { row in
            guard let f = row.audioFacts, f.marker == .sending, !refused.contains(row.entityID) else { return nil }
            return SyncRecordID(type: .audio, entityID: row.entityID)
        }.sorted { $0.recordName < $1.recordName }
    }

    /// `.deleting`.
    var pendingMarkerDeletes: [SyncRecordID] {
        allAudioRows().compactMap { row in
            guard let f = row.audioFacts, f.marker == .deleting else { return nil }
            return SyncRecordID(type: .audio, entityID: row.entityID)
        }.sorted { $0.recordName < $1.recordName }
    }

    /// Ids of `.sending` rows (blob up, marker not acknowledged).
    func unsentUploadIDs() -> [UUID] {
        allAudioRows().compactMap { row in
            guard let f = row.audioFacts, f.marker == .sending else { return nil }
            return row.entityID
        }.sorted { $0.uuidString < $1.uuidString }
    }

    /// The marker part of a send result. One save.
    func handleSent(saved: [SyncRecord], deleted: [SyncRecordID], failures: [SendFailure]) -> AudioSentEffects {
        var effects = AudioSentEffects()
        let ids = saved.map(\.id.entityID) + deleted.map(\.entityID) + failures.map(\.recordID.entityID)
        guard !ids.isEmpty else { return effects }
        var rows = audioRows(ids)
        var changed = false
        let now = clock.now

        for record in saved {
            let id = record.id.entityID
            if let row = rows[id] {
                switch row.audioRead {
                case .newer:
                    continue
                case .facts(var f):
                    guard f.marker == .sending else { continue }   // .deleting: delete wins
                    f.marker = .onServer
                    row.audioFacts = f
                    changed = true
                case .malformed:
                    guard let d = AudioMarker.descriptor(record) else { continue }
                    row.audioFacts = AudioRowFacts(descriptor: d, marker: .onServer, recordingSeen: true, firstSeenAt: now)
                    changed = true
                }
            } else if let d = AudioMarker.descriptor(record) {
                // No row (cleared meanwhile): the marker is on the server, so know it. Without a recording here the
                // delete job removes the blob first and the marker second.
                rows[id] = insertRow(AudioRowFacts(descriptor: d, marker: .onServer, recordingSeen: true, firstSeenAt: now))
                changed = true
            }
        }
        for recordID in deleted {
            let id = recordID.entityID
            probed.insert(id)
            guard let row = rows[id] else { continue }
            switch row.audioRead {
            case .newer: continue
            case .facts(let f) where f.marker == .sending: continue
            default:
                context.delete(row)
                rows[id] = nil
                changed = true
            }
        }
        for failure in failures {
            let recordID = failure.recordID
            let id = recordID.entityID
            let facts = rows[id]?.audioFacts
            switch failure {
            case .serverRecordChanged(let server):
                // Write-once: the server's marker is the marker.
                guard let row = rows[id], var f = facts, f.marker != .deleting,
                      let d = AudioMarker.descriptor(server) else { continue }
                f.descriptor = d
                f.markerVersion = SyncSchema.recordVersion(server)
                f.marker = .onServer
                row.audioFacts = f
                changed = true
                log.notice("audio marker \(recordID.recordName, privacy: .public) already on the server: taken")
            case .unknownItem:
                if facts?.marker == .sending { effects.saves.append(recordID) }
            case .zoneNotFound:
                effects.zoneGone = true
            case .quotaExceeded:
                effects.quotaFull = true
            case .retryable:
                effects.retry += 1
                switch facts?.marker {
                case .sending?: effects.saves.append(recordID)
                case .deleting?: effects.deletes.append(recordID)
                default: break
                }
            case .permanent(_, let message):
                refused.insert(id)
                effects.refused.append(message)
                log.error("audio marker \(recordID.recordName, privacy: .public) was refused: \(message, privacy: .public)")
            }
        }
        if changed {
            save()
            revision += 1
        }
        return effects
    }

    // MARK: Remove iCloud Copy

    /// Remove iCloud Copy, before deleteZone: deletes the blob of every recording this device knows of (audio rows,
    /// recordings, `rec.` rows) and every blob the listing finds. Any delete error throws. It ignores `audioMayRun`
    /// and `removing` (it is the removal). Local files are never touched.
    func removeAllFromICloud() async throws {
        var ids = Set(allAudioRows().map(\.entityID))
        ids.formUnion(((try? context.fetch(FetchDescriptor<Recording>())) ?? []).map(\.id))
        let rec = SyncRecordType.recording.rawValue
        ids.formUnion(((try? context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.typeRaw == rec }))) ?? [])
            .map(\.entityID))
        do {
            let listed = try await dependencies.transfer.listAll()
            log.notice("audio list: \(listed.count, privacy: .public) records")
            ids.formUnion(listed.map(\.recordingID))
        } catch {
            log.error("audio list failed: \(Self.describe(error), privacy: .public); removing the audio this device knows of")
        }
        let all = ids.sorted { $0.uuidString < $1.uuidString }
        var start = 0
        while start < all.count {
            let chunk = Array(all[start..<min(start + AudioPolicy.batch, all.count)])
            do {
                try await dependencies.transfer.delete(chunk)
            } catch {
                log.error("audio delete failed while removing the iCloud copy: \(Self.describe(error), privacy: .public)")
                throw error
            }
            start += AudioPolicy.batch
        }
        log.notice("audio delete \(all.count, privacy: .public) af records: the iCloud copy is being removed")
    }

    /// Remove iCloud Copy, after deleteZone: deletes every blob one more listing finds (another device's upload whose
    /// marker was saved after `removeAllFromICloud` listed and before the zone went). Best effort: errors are logged.
    func removeListedAfterZoneDelete() async {
        do {
            let ids = try await dependencies.transfer.listAll().map(\.recordingID)
            guard !ids.isEmpty else { return }
            try await dependencies.transfer.delete(ids)
            log.notice("audio delete \(ids.count, privacy: .public) af records: uploaded while the iCloud copy was removed")
        } catch {
            log.error("audio: the listing after removing the iCloud copy failed: \(Self.describe(error), privacy: .public)")
        }
    }

    // MARK: Launch

    /// Scratch clean-up; first-run sweep date. Runs at launch, after `adoptStrayDownloads` and the orphan sweep.
    func prepareOnLaunch() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.audioIncomingDirectory.path)) ?? [] {
            try? fm.removeItem(at: paths.audioIncomingDirectory.appendingPathComponent(name, isDirectory: false))
        }
        let outgoing = (try? fm.contentsOfDirectory(atPath: paths.audioOutgoingDirectory.path)) ?? []
        if !outgoing.isEmpty {
            let parsed = outgoing.map { name in (name, UUID(uuidString: String(name.prefix { $0 != "." }))) }
            let ids = parsed.compactMap(\.1)
            let present = recordingExists(ids)
            let rows = audioRows(ids)
            var removed = 0
            for (name, id) in parsed {
                guard let id, present.contains(id), rows[id] == nil else {
                    try? fm.removeItem(at: paths.audioOutgoingDirectory.appendingPathComponent(name, isDirectory: false))
                    removed += 1
                    continue
                }
            }
            if removed > 0 { log.notice("audio: \(removed, privacy: .public) staged uploads no longer needed were deleted") }
        }
        if settings.syncAudioLastSweep == nil { settings.syncAudioLastSweep = clock.now }
    }

    // MARK: Snapshot and summary

    /// What one pass of the loop works from: the recordings (id, date, length, file, channel, stage), whether each has
    /// its file, the audio rows, and the `rec.` rows.
    struct Snapshot {
        struct Item {
            let id: UUID
            let createdAt: Date
            let duration: Double
            let audioFileName: String
            let channel: String?
            let ready: Bool
            let hasFile: Bool
        }
        var recordings: [UUID: Item] = [:]
        /// Rows that read `.facts`.
        var rows: [UUID: AudioRowFacts] = [:]
        /// Rows from a newer build: a marker is known, nothing of this build acts on them.
        var newer: Set<UUID> = []
        /// `rec.` rows: acknowledged by the server (`systemFields != nil`).
        var recRows: [UUID: Bool] = [:]

        func hasRow(_ id: UUID) -> Bool { rows[id] != nil || newer.contains(id) }
    }

    /// Reads the store. With `housekeeping` (the loop's derive), also marks `recordingSeen`, deletes malformed rows
    /// (newer rows stay untouched; no row is ever deleted for age) and saves once.
    func snapshot(housekeeping: Bool) -> Snapshot {
        var s = Snapshot()
        var d = FetchDescriptor<Recording>()
        d.propertiesToFetch = [\.id, \.createdAt, \.duration, \.audioFileName, \.stageRaw, \.captureChannel]
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: paths.audioDirectory.path)) ?? [])
        for r in (try? context.fetch(d)) ?? [] {
            s.recordings[r.id] = Snapshot.Item(id: r.id, createdAt: r.createdAt, duration: r.duration,
                                               audioFileName: r.audioFileName, channel: r.captureChannel,
                                               ready: r.stage == .ready, hasFile: files.contains(r.audioFileName))
        }
        var changed = false
        for row in allAudioRows() {
            switch row.audioRead {
            case .malformed:
                if housekeeping {
                    context.delete(row)
                    changed = true
                    log.notice("audio: an unreadable audio row was deleted")
                }
            case .newer:
                s.newer.insert(row.entityID)
            case .facts(var f):
                if housekeeping, !f.recordingSeen, s.recordings[row.entityID] != nil {
                    f.recordingSeen = true
                    row.audioFacts = f
                    changed = true
                }
                s.rows[row.entityID] = f
            }
        }
        let rec = SyncRecordType.recording.rawValue
        for row in (try? context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate { $0.typeRaw == rec }))) ?? [] {
            s.recRows[row.entityID] = row.systemFields != nil
        }
        if changed {
            save()
            revision += 1
        }
        return s
    }

    /// Ready recordings this device should upload: a file here, no marker known, the `rec.` record acknowledged, not
    /// too long, under the per-launch cap. Newest first. Waits and backoff are not applied here.
    func uploadCandidates(_ s: Snapshot) -> [Snapshot.Item] {
        s.recordings.values.filter { r in
            r.ready && r.hasFile && !s.hasRow(r.id) && s.recRows[r.id] == true && !tooLong.contains(r.id)
                && uploadsThisLaunch[r.id, default: 0] < AudioPolicy.maxUploadsPerRecordingPerLaunch
        }.sorted(by: Self.newestFirst)
    }

    /// Rows whose audio this device could download now: marker on the server, a format and version this build can
    /// play, the recording ready here and its file missing.
    func downloadable(_ id: UUID, _ s: Snapshot) -> Bool {
        guard let f = s.rows[id], f.marker == .onServer, f.markerVersion == SyncSchema.version,
              f.descriptor.format.isPlayable, let r = s.recordings[id], r.ready, !r.hasFile else { return false }
        return true
    }

    /// Downloads left: automatic ones, and opened or forced ones.
    func downloadCandidates(_ s: Snapshot) -> [Snapshot.Item] {
        let now = clock.now
        return s.rows.keys.compactMap { id -> Snapshot.Item? in
            guard downloadable(id, s), let r = s.recordings[id] else { return nil }
            let wanted = forced.contains(id) || opened.contains(id)
                || AudioPolicy.autoDownloads(platform: dependencies.platform, createdAt: r.createdAt, now: now)
            return wanted ? r : nil
        }.sorted(by: Self.newestFirst)
    }

    static func newestFirst(_ a: Snapshot.Item, _ b: Snapshot.Item) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString < b.id.uuidString
    }

    /// Automatic work waits for this (nil: it may run). Sync Audio Now lifts it.
    var automaticWait: AudioDownloadWait? {
        guard !forceAnyNetwork else { return nil }
        return AudioPolicy.automaticWait(network: dependencies.conditions.network,
                                         lowPower: dependencies.conditions.lowPowerMode)
    }

    func downloadWait(_ id: UUID) -> AudioDownloadWait {
        if lowStorage.contains(id) { return .lowStorage }
        if forced.contains(id) { return .queued }
        return automaticWait ?? .queued
    }

    /// Recomputed after every job and on every pump.
    func recomputeSummary() {
        let s = snapshot(housekeeping: false)
        for r in s.recordings.values where r.ready && r.hasFile && !s.hasRow(r.id)
            && AudioPolicy.estimatedBytes(duration: r.duration) > AudioPolicy.maxUploadBytes {
            tooLong.insert(r.id)
        }
        let uploads = uploadCandidates(s)
        let downloads = downloadCandidates(s)
        var next = AudioSyncSummary(uploadsLeft: uploads.count, downloadsLeft: downloads.count, tooLong: tooLong.count,
                                    uploadBytesLeft: uploads.reduce(Int64(0)) {
                                        $0 + AudioPolicy.estimatedBytes(duration: $1.duration)
                                    })
        let now = clock.now
        let blocked = uploadsBlockedUntil.map { now < $0 } ?? false
        let uploadsCanGo = !uploads.isEmpty && !removalFailed && !blocked
        let automaticDownloads = downloads.contains { !forced.contains($0.id) && !lowStorage.contains($0.id) }
        if removalFailed {
            next.wait = .removalFailed
        } else if blocked && !uploads.isEmpty {
            next.wait = .iCloudFull
        } else if (uploadsCanGo && uploadsLowStorage) || downloads.contains(where: { lowStorage.contains($0.id) }) {
            next.wait = .lowStorage
        } else if (uploadsCanGo || automaticDownloads), let wait = automaticWait {
            next.wait = wait == .lowPower ? .lowPower : .network
        } else if uploadsCanGo && isBusy() {
            next.wait = .busy
        }
        if next != summary { summary = next }

        if settings.syncAudioIntroShown {
            if introPending { introPending = false }
        } else if introPending, !(settings.syncEnabled && settings.syncAudio) {
            // Switched off in Settings rather than on the notice: it goes for this launch, not marked seen.
            introPending = false
        } else if !introDecided, settings.syncEnabled, settings.syncAudio, coordinator?.audioMayRun == true {
            if next.uploadsLeft + next.downloadsLeft > 0 {
                introPending = true
                introDecided = true
            }
        }
    }
}
