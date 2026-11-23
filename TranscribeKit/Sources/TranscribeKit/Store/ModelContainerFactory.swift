import Foundation
import os
import SwiftData

public enum ModelContainerFactory {
    private static let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "store")

    /// The schema version this build opens the store with (`TranscribeSchemaV3`).
    static let currentVersion = 3
    /// Marker written next to the store once it has been opened by the current schema: `Library.schema-v3`.
    static let markerName = "Library.schema-v\(currentVersion)"
    /// One-time copy of the store taken before the first open by the current schema: `Library.pre-v3-backup.store`
    /// (never deleted by this build). Markers and backups of earlier versions (`Library.schema-v2`,
    /// `Library.pre-v2-backup.store`) are left on disk untouched.
    static let backupBaseName = "Library.pre-v\(currentVersion)-backup.store"

    /// inMemory for -uiTesting and tests; otherwise AppPaths.storeURL.
    ///
    /// On disk, a store that has not been opened by the current schema yet is copied to
    /// `Library.pre-v3-backup.store` (with its `-wal` and `-shm`) before the container opens it. The lightweight
    /// migrations are transactional, so a failed copy is logged and does not stop the launch.
    ///
    /// Both configurations pass `cloudKitDatabase: .none` explicitly: the store is never mirrored by SwiftData's
    /// CloudKit integration, even once the app gains an iCloud entitlement (sync, if any, runs over CKSyncEngine).
    @MainActor public static func make(inMemory: Bool, url: URL?) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TranscribeSchemaV3.self)
        if !inMemory, let url { backUpBeforeFirstOpen(storeURL: url) }
        let config = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, url: url!, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: TranscribeMigrationPlan.self, configurations: [config])
        if !inMemory, let url { writeMarker(storeURL: url) }
        return container
    }

    static func markerURL(storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(markerName, isDirectory: false)
    }

    static func backupURL(storeURL: URL, suffix: String = "") -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(backupBaseName + suffix, isDirectory: false)
    }

    private static func backUpBeforeFirstOpen(storeURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path), !fm.fileExists(atPath: markerURL(storeURL: storeURL).path) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            let destination = backupURL(storeURL: storeURL, suffix: suffix)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                log.error("Store backup before V\(currentVersion) failed for \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func writeMarker(storeURL: URL) {
        let marker = markerURL(storeURL: storeURL)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            try Data("\(currentVersion).0.0\n".utf8).write(to: marker, options: .atomic)
        } catch {
            log.error("Could not write the V\(currentVersion) store marker: \(error.localizedDescription, privacy: .public)")
        }
    }
}
