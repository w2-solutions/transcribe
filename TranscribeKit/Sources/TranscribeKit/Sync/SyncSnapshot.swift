import Foundation
import SwiftData

/// A whole store as the records it would upload (§8.2), for fakes and tests: the UI-test sync scenarios build a
/// library on a throwaway "other device" store and put its records in a `FakeCloud`. The app never calls this.
public enum SyncSnapshot {
    /// Every syncable entity (ready recordings and their speakers, every profile, sample, negative and folder), parents
    /// first, without system fields.
    @MainActor public static func records(_ context: ModelContext) throws -> [SyncRecord] {
        let projector = RecordProjector(context: context)
        let order: [SyncRecordType] = [.folder, .profile, .recording, .speaker, .sample, .negative]
        var out: [SyncRecord] = []
        for type in order {
            let entities = try projector.all(type).filter(\.isSyncable)
            out += entities.map { RecordProjector.record($0) }.sorted { $0.id.recordName < $1.id.recordName }
        }
        return out
    }
}
