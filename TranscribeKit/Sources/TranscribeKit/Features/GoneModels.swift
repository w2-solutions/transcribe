import Foundation
import SwiftData

/// Models that went away while a screen showed them (§8.4: another device deleted them and sync applied the delete,
/// or this device deleted them elsewhere).
///
/// Sync deletes in the main context the views read, so `@Query` results drop the model at the next save. A view that
/// still holds the instance (a row being removed, an open sheet, a pushed screen) does not trap on macOS 27 or
/// iOS 27, but reads stale values: after the save the instance has no context, its attributes keep their last values
/// and its relationships read empty (`GoneModelsTests`). So views check `isGone` before they show a model, and the
/// router drops screens and sheets of recordings and voices that are gone.
public enum GoneModels {
    /// True once `model` was deleted from its context: deleted and not yet saved, or saved and detached.
    /// A model that was never inserted also has no context; views only ever get inserted ones.
    @MainActor public static func isGone(_ model: some PersistentModel) -> Bool {
        model.isDeleted || model.modelContext == nil
    }

    /// The ids in `before` that are no longer in `after` (what an `onChange` of a query's ids saw go).
    public static func removed(before: [UUID], after: [UUID]) -> Set<UUID> {
        Set(before).subtracting(after)
    }

    /// A navigation path without the first screen `isGone` matches and everything pushed after it, so the user lands on
    /// the screen they came from. Unchanged when nothing matches.
    public static func prune<Route>(_ path: [Route], where isGone: (Route) -> Bool) -> [Route] {
        guard let first = path.firstIndex(where: isGone) else { return path }
        return Array(path[..<first])
    }
}
