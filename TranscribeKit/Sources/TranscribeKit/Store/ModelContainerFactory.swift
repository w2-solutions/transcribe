import Foundation
import SwiftData

public enum ModelContainerFactory {
    /// inMemory for -uiTesting and tests; otherwise AppPaths.storeURL.
    @MainActor public static func make(inMemory: Bool, url: URL?) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TranscribeSchemaV1.self)
        let config = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: url!)
        return try ModelContainer(for: schema, migrationPlan: TranscribeMigrationPlan.self, configurations: [config])
    }
}
