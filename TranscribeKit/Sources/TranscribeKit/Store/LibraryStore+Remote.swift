import Foundation
import SwiftData
import TranscribeCore

/// Writes that come from another device (§8.4 fetch). They go through the same helpers as local edits where a local
/// edit has side effects (`removeRecordingRow`, `forgetCleanup`), and never save: the sync applier saves each chunk
/// together with the sync state rows.
extension LibraryStore {
    // MARK: Insert

    /// A bare local entity for a record that has no local row yet. The caller then applies every group.
    /// A new recording is ready (only ready recordings sync), has its audio named "<id>.wav" and no unseen result. The
    /// audio is not on this device (not in iCloud, not downloaded yet, or not syncing here); a downloaded copy later
    /// points `audioFileName` at itself (`installDownloadedAudio`).
    ///
    /// Audio markers (`.audio`) never get here: `SyncCoordinator` hands them to `AudioSync` first.
    func remoteInsert(_ record: SyncRecord) -> SyncEntity {
        let f = record.fields
        let id = record.id.entityID
        switch record.id.type {
        case .recording:
            let source = f["source"]?.stringValue.flatMap(RecordingSource.init(rawValue:)) ?? .microphone
            let r = Recording(id: id, createdAt: f["createdAt"]?.dateValue ?? clock.now,
                              audioFileName: paths.newAudioFileName(for: id), source: source)
            context.insert(r)
            r.stage = .ready
            r.attemptCount = 0
            r.hasUnseenResult = false
            return .recording(r)
        case .speaker:
            let s = RecordingSpeaker(id: id, key: f["key"]?.stringValue ?? "S1",
                                     ordinal: Int(f["ordinal"]?.intValue ?? 1), colourSlot: Int(f["colourSlot"]?.intValue ?? 0))
            context.insert(s)
            return .speaker(s)
        case .profile:
            let p = VoiceProfile(id: id, name: f["name"]?.stringValue ?? "", colourSlot: Int(f["colourSlot"]?.intValue ?? 0),
                                 embeddingModelKey: f["embeddingModelKey"]?.stringValue ?? "",
                                 now: f["createdAt"]?.dateValue ?? clock.now)
            context.insert(p)
            return .profile(p)
        case .sample:
            let s = VoiceSample(id: id, vector: Self.placeholderVector, embeddingModelKey: f["embeddingModelKey"]?.stringValue ?? "",
                                origin: .strongMatch, addedAt: f["addedAt"]?.dateValue ?? clock.now,
                                speechSeconds: f["speechSeconds"]?.doubleValue ?? 0)
            context.insert(s)
            return .sample(s)
        case .negative:
            let n = VoiceNegative(id: id, vector: Self.placeholderVector, embeddingModelKey: f["embeddingModelKey"]?.stringValue ?? "",
                                  addedAt: f["addedAt"]?.dateValue ?? clock.now, speechSeconds: f["speechSeconds"]?.doubleValue ?? 0)
            context.insert(n)
            return .negative(n)
        case .folder:
            let fd = Folder(id: id, name: f["name"]?.stringValue ?? "", createdAt: f["createdAt"]?.dateValue ?? clock.now)
            context.insert(fd)
            return .folder(fd)
        case .groupLabel:
            // No anchor yet: the body group brings the exact bytes.
            let created = f["createdAt"]?.dateValue ?? clock.now
            let l = VoiceGroupLabel(id: id, text: f["text"]?.stringValue ?? "", createdAt: created,
                                    embeddingModelKey: f["embeddingModelKey"]?.stringValue ?? "",
                                    captureChannel: f["captureChannel"]?.stringValue ?? "", anchors: [])
            context.insert(l)
            return .groupLabel(l)
        case .audio:
            preconditionFailure("audio markers are handled by AudioSync")
        }
    }

    /// Replaced by the record's exact vector bytes as soon as the body group is applied.
    private static let placeholderVector = VoiceVector(raw: [1])!

    // MARK: Apply one group

    /// Writes one group of `record` into `e`. A link whose target does not exist yet sets the relationship to nil and
    /// is kept in `unresolved` ([field: uuidString]); a link that resolves (or is cleared) leaves `unresolved`.
    /// Search text is not rebuilt here: the applier rebuilds it once per touched recording (it decodes the transcript).
    func remoteApply(group: String, of record: SyncRecord, to e: SyncEntity, unresolved: inout [String: String]) {
        let v = SyncSchema.values(record.fields, group: group, type: record.id.type)
        typealias G = SyncSchema.Group
        switch (e, group) {
        case (.recording(let r), G.meta):
            if let d = v["createdAt"]?.dateValue { r.createdAt = d }
            if let s = v["source"]?.stringValue { r.sourceRaw = s }
            r.captureChannel = v["captureChannel"]?.stringValue
            r.captureDetailJSON = v["captureDetail"]?.stringValue
            r.languageRaw = v["language"]?.stringValue
        case (.recording(let r), G.title):
            r.title = v["title"]?.stringValue
        case (.recording(let r), G.fav):
            r.isFavourite = v["isFavourite"]?.boolValue ?? false
        case (.recording(let r), G.folder):
            r.folder = resolve("folderID", v, &unresolved) { id in try? self.folder(id) }
        case (.recording(let r), G.result):
            r.duration = v["duration"]?.doubleValue ?? 0
            r.noSpeech = v["noSpeech"]?.boolValue ?? false
            r.marks = v["marks"]?.doublesValue ?? []
            r.peaks = v["peaks"]?.bytesValue.map(SyncValue.unpackFloats) ?? []
            r.asrModelID = v["asrModelID"]?.stringValue
            r.embeddingModelKey = v["embeddingModelKey"]?.stringValue
            r.transcriptData = v["transcript"]?.assetValue
            r.previewText = Self.previewText(r.transcript)

        case (.speaker(let s), G.ident):
            s.recording = resolve("recordingID", v, &unresolved) { id in try? self.recording(id) }
            if let key = v["key"]?.stringValue { s.key = key }
            if let o = v["ordinal"]?.intValue { s.ordinal = Int(o) }
            if let c = v["colourSlot"]?.intValue { s.colourSlot = Int(c) }
            s.cleanSeconds = v["cleanSeconds"]?.doubleValue ?? 0
            s.vectorData = v["vector"]?.bytesValue
            s.embeddingModelKey = v["embeddingModelKey"]?.stringValue
            s.vectorCoherence = v["vectorCoherence"]?.doubleValue
        case (.speaker(let s), G.stats):
            s.turnCount = Int(v["turnCount"]?.intValue ?? 0)
            s.totalSeconds = v["totalSeconds"]?.doubleValue ?? 0
        case (.speaker(let s), G.label):
            if let l = v["label"]?.stringValue { s.labelRaw = l }
            s.profile = resolve("profileID", v, &unresolved) { id in try? self.profile(id) }
            s.suggestedProfileID = v["suggestedProfileID"]?.uuidValue
            s.nameSnapshot = v["nameSnapshot"]?.stringValue
            s.matchScore = v["matchScore"]?.doubleValue
            s.matchMargin = v["matchMargin"]?.doubleValue
            if let r = s.recording, r.hasUnseenResult, !r.speakers.contains(where: { $0.label == .autoLabelled }) {
                r.hasUnseenResult = false
            }
        case (.speaker(let s), G.rejected):
            s.rejectedProfileIDs = Self.sortedIDs((v["rejectedProfileIDs"]?.stringsValue ?? []).compactMap(UUID.init(uuidString:)))

        case (.profile(let p), G.name):
            if let n = v["name"]?.stringValue { p.name = n }
            if let d = v["namedAt"]?.dateValue { p.namedAt = d }
        case (.profile(let p), G.me):
            p.isMe = v["isMe"]?.boolValue ?? false
        case (.profile(let p), G.auto):
            p.autoLabel = v["autoLabel"]?.boolValue ?? true
        case (.profile(let p), G.colour):
            if let c = v["colourSlot"]?.intValue { p.colourSlot = Int(c) }
        case (.profile(let p), G.meta):
            if let d = v["createdAt"]?.dateValue { p.createdAt = d }
        case (.profile(let p), G.model):
            if let k = v["embeddingModelKey"]?.stringValue { p.embeddingModelKey = k }

        case (.sample(let s), G.body):
            s.profile = resolve("profileID", v, &unresolved) { id in try? self.profile(id) }
            if let bytes = v["vector"]?.bytesValue { s.vectorData = bytes }
            if let k = v["embeddingModelKey"]?.stringValue { s.embeddingModelKey = k }
            if let o = v["origin"]?.stringValue { s.originRaw = o }
            if let d = v["addedAt"]?.dateValue { s.addedAt = d }
            s.speechSeconds = v["speechSeconds"]?.doubleValue ?? 0
            s.sourceRecordingID = v["sourceRecordingID"]?.uuidValue
            s.sourceSpeakerID = v["sourceSpeakerID"]?.uuidValue
            s.clipStart = v["clipStart"]?.doubleValue
            s.clipEnd = v["clipEnd"]?.doubleValue
            s.quote = v["quote"]?.stringValue
            s.captureChannel = v["captureChannel"]?.stringValue
            s.captureInput = v["captureInput"]?.stringValue
        case (.negative(let n), G.body):
            n.profile = resolve("profileID", v, &unresolved) { id in try? self.profile(id) }
            if let bytes = v["vector"]?.bytesValue { n.vectorData = bytes }
            if let k = v["embeddingModelKey"]?.stringValue { n.embeddingModelKey = k }
            if let d = v["addedAt"]?.dateValue { n.addedAt = d }
            n.speechSeconds = v["speechSeconds"]?.doubleValue ?? 0
            n.sourceRecordingID = v["sourceRecordingID"]?.uuidValue
            n.sourceSpeakerID = v["sourceSpeakerID"]?.uuidValue
            n.captureChannel = v["captureChannel"]?.stringValue
            n.captureInput = v["captureInput"]?.stringValue

        case (.groupLabel(let l), G.body):
            l.profile = resolve("profileID", v, &unresolved) { id in try? self.profile(id) }
            l.text = v["text"]?.stringValue ?? ""
            if let d = v["createdAt"]?.dateValue { l.createdAt = d }
            if let d = v["editedAt"]?.dateValue { l.editedAt = d }
            l.embeddingModelKey = v["embeddingModelKey"]?.stringValue ?? ""
            l.captureChannel = v["captureChannel"]?.stringValue ?? ""
            l.anchorVectorData = v["anchor"]?.bytesValue ?? Data()   // the exact bytes: never decoded and packed again
            l.anchorDimension = Int(v["anchorDimension"]?.intValue ?? 0)

        case (.folder(let f), G.name):
            if let n = v["name"]?.stringValue { f.name = n }
        case (.folder(let f), G.meta):
            if let d = v["createdAt"]?.dateValue { f.createdAt = d }

        default:
            break   // a group this build does not know (never sent by a build with the same `sv`)
        }
    }

    /// A link field: the target when it exists; nil (and the id kept in `unresolved`) when it has not arrived.
    private func resolve<T>(_ field: String, _ v: [String: SyncValue], _ unresolved: inout [String: String],
                            lookup: (UUID) -> T?) -> T? {
        guard let raw = v[field]?.stringValue, let id = UUID(uuidString: raw) else {
            unresolved.removeValue(forKey: field)
            return nil
        }
        if let target = lookup(id) {
            unresolved.removeValue(forKey: field)
            return target
        }
        unresolved[field] = raw
        return nil
    }

    static func sortedIDs(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    /// The card preview: the first ~200 characters of the transcript (as `setTranscript` writes it).
    static func previewText(_ document: TranscriptDocument?) -> String {
        guard let document else { return "" }
        let flat = document.turns.isEmpty
            ? document.words.map(\.text).joined(separator: " ")
            : document.turns.map(\.text).joined(separator: " ")
        return String(flat.prefix(200))
    }

    // MARK: Link resolution

    /// Sets a link whose target has now arrived. Returns false when the target is still missing.
    func resolveLink(field: String, targetID: UUID, on e: SyncEntity) -> Bool {
        switch (e, field) {
        case (.recording(let r), "folderID"):
            guard let f = try? folder(targetID) else { return false }
            r.folder = f
        case (.speaker(let s), "recordingID"):
            guard let r = try? recording(targetID) else { return false }
            s.recording = r
        case (.speaker(let s), "profileID"):
            guard let p = try? profile(targetID) else { return false }
            s.profile = p
        case (.sample(let s), "profileID"):
            guard let p = try? profile(targetID) else { return false }
            s.profile = p
        case (.negative(let n), "profileID"):
            guard let p = try? profile(targetID) else { return false }
            n.profile = p
        case (.groupLabel(let l), "profileID"):
            guard let p = try? profile(targetID) else { return false }
            l.profile = p
        default:
            return true   // an unknown field: drop it
        }
        return true
    }

    /// Whether the relationship behind a link field is set locally (then any unresolved id for it is stale).
    static func linkIsSet(field: String, on e: SyncEntity) -> Bool {
        switch (e, field) {
        case (.recording(let r), "folderID"): r.folder != nil
        case (.speaker(let s), "recordingID"): s.recording != nil
        case (.speaker(let s), "profileID"): s.profile != nil
        case (.sample(let s), "profileID"): s.profile != nil
        case (.negative(let n), "profileID"): n.profile != nil
        case (.groupLabel(let l), "profileID"): l.profile != nil
        default: false
        }
    }

    // MARK: Delete

    /// Applies a delete from another device with the same side effects as the local delete (§8.4):
    /// a recording's audio file and speakers go with it (samples stay); a profile is forgotten (its speakers keep the
    /// name, suggestions and rejections of it are cleared). Does not save.
    func remoteDelete(_ e: SyncEntity) {
        switch e {
        case .recording(let r):
            removeRecordingRow(r)
        case .speaker(let s):
            let r = s.recording
            r?.speakers.removeAll { $0.id == s.id }
            context.delete(s)
            if let r {
                r.hasUnseenResult = r.hasUnseenResult && r.speakers.contains { $0.label == .autoLabelled }
                rebuildSearchText(r)
            }
        case .profile(let p):
            forgetCleanup(p)
        case .sample(let s):
            s.profile?.samples.removeAll { $0.id == s.id }
            context.delete(s)
        case .negative(let n):
            n.profile?.negatives.removeAll { $0.id == n.id }
            context.delete(n)
        case .folder(let f):
            for r in f.recordings { r.folder = nil }
            context.delete(f)
        case .groupLabel(let l):
            l.profile?.groupLabels.removeAll { $0.id == l.id }
            context.delete(l)
        }
    }

    /// After samples arrive or leave from another device: a profile with no sample on its model but with speakers
    /// needs a new sample; one with a sample on its model does not. A profile with neither is left as it was.
    func recomputeNeedsResample(_ p: VoiceProfile) {
        let hasSample = p.samples.contains { $0.embeddingModelKey == p.embeddingModelKey }
        if hasSample {
            if p.needsResample { p.needsResample = false }
        } else if !p.speakers.isEmpty {
            if !p.needsResample { p.needsResample = true }
        }
    }
}
