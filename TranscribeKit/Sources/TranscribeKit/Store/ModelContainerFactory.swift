import Foundation
import os
import SwiftData

public enum ModelContainerFactory {
    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "store")

    /// Marker written next to the store once it has been opened by the V2 schema.
    static let v2MarkerName = "Library.schema-v2"
    /// One-time copy of the V1 store taken before the first V2 open (never deleted by this build).
    static let backupBaseName = "Library.pre-v2-backup.store"

    /// inMemory for -uiTesting and tests; otherwise AppPaths.storeURL.
    ///
    /// On disk, a store that has not been opened by V2 yet is copied to `Library.pre-v2-backup.store` (with its
    /// `-wal` and `-shm`) before the container opens it. The lightweight V1 → V2 migration is transactional, so a
    /// failed copy is logged and does not stop the launch.
    ///
    /// Both configurations pass `cloudKitDatabase: .none` explicitly: the store is never mirrored by SwiftData's
    /// CloudKit integration, even once the app gains an iCloud entitlement (sync, if any, runs over CKSyncEngine).
    @MainActor public static func make(inMemory: Bool, url: URL?) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TranscribeSchemaV2.self)
        if !inMemory, let url { backUpBeforeFirstV2Open(storeURL: url) }
        let config = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, url: url!, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: TranscribeMigrationPlan.self, configurations: [config])
        if !inMemory, let url { writeV2Marker(storeURL: url) }
        return container
    }

    static func markerURL(storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(v2MarkerName, isDirectory: false)
    }

    static func backupURL(storeURL: URL, suffix: String = "") -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(backupBaseName + suffix, isDirectory: false)
    }

    private static func backUpBeforeFirstV2Open(storeURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path), !fm.fileExists(atPath: markerURL(storeURL: storeURL).path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            let destination = backupURL(storeURL: storeURL, suffix: suffix)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                log.error("Store backup before V2 failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func writeV2Marker(storeURL: URL) {
        let marker = markerURL(storeURL: storeURL)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            try Data("2.0.0\n".utf8).write(to: marker, options: .atomic)
        } catch {
            log.error("Could not write the V2 store marker: \(error.localizedDescription, privacy: .public)")
        }
    }
}
