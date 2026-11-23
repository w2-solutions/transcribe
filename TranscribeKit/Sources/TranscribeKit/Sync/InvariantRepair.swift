import Foundation
import SwiftData
import TranscribeCore

/// Deterministic repairs after a fetch (§8.4 flow 4, decision D14). Every write is ordinary local data, so it syncs
/// like a user edit, and every device computes the same result from the same data (dates compare at millisecond
/// precision, the precision that syncs, and ties go to the smallest `uuidString`).
@MainActor
enum InvariantRepair {
    struct Result: Equatable {
        /// Saved voices that share a name (case-insensitively): the duplicate banner's names. Never merged here.
        var duplicateNames: [String] = []
        var changed = false
    }

    static func run(_ store: LibraryStore, touchedRecordings: Set<UUID>) throws -> Result {
        let context = store.context
        var result = Result()

        // 1. At most one "me": the oldest keeps it.
        let profiles = try context.fetch(FetchDescriptor<VoiceProfile>())
        let mes = profiles.filter(\.isMe).sorted(by: older)
        for p in mes.dropFirst() {
            p.isMe = false
            result.changed = true
        }

        // 2. Folders whose names match case-insensitively merge into the oldest.
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let byName = Dictionary(grouping: folders) { folderKey($0.name) }
        for (_, group) in byName where group.count > 1 {
            let sorted = group.sorted(by: older)
            let survivor = sorted[0]
            for loser in sorted.dropFirst() {
                for r in Array(loser.recordings) { r.folder = survivor }
                for r in try context.fetch(FetchDescriptor<Recording>()) where r.folder?.id == loser.id { r.folder = survivor }
                context.delete(loser)
                result.changed = true
            }
        }

        // 3. Search text for recordings whose transcript, title or speaker names changed.
        if !touchedRecordings.isEmpty {
            let ids = Array(touchedRecordings)
            for r in try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { ids.contains($0.id) })) {
                store.rebuildSearchText(r)
            }
        }

        // 4. Duplicate voice names: reported, never merged (two people can share a name).
        var seen: [String: [VoiceProfile]] = [:]
        for p in profiles where !p.isDeleted { seen[folderKey(p.name), default: []].append(p) }
        result.duplicateNames = seen.values.filter { $0.count > 1 }
            .map { $0.sorted(by: older)[0].name }
            .sorted()
        return result
    }

    static func folderKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func older(_ a: VoiceProfile, _ b: VoiceProfile) -> Bool {
        older(SyncValue.millis(a.createdAt), a.id, SyncValue.millis(b.createdAt), b.id)
    }

    static func older(_ a: Folder, _ b: Folder) -> Bool {
        older(SyncValue.millis(a.createdAt), a.id, SyncValue.millis(b.createdAt), b.id)
    }

    private static func older(_ ma: Int64, _ ia: UUID, _ mb: Int64, _ ib: UUID) -> Bool {
        ma != mb ? ma < mb : ia.uuidString < ib.uuidString
    }
}
