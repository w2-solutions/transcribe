import Foundation

/// The three-way merge per field group (§8.4, decision D5), against the base hashes last agreed with the server.
///
/// - A group this device has not changed since the base takes the server's value.
/// - A group this device has changed keeps the local value (the device saving now wins), and is sent again.
/// - The speaker's `rejected` group, changed on both sides, becomes the union of both sides.
///
/// No clocks are involved, so the result never depends on clock skew.
enum MergePolicy {
    enum Action: Equatable {
        /// Local and server already agree.
        case same
        /// Take the server's value for this group.
        case takeServer
        /// Keep the local value; it is re-sent.
        case keepLocal
        /// Both sides changed the `rejected` group: write the union.
        case union
    }

    /// One decision per group of `type`. `base` empty means the record was never agreed with the server, so every
    /// local group counts as changed (a local entity meeting a server copy it never saw keeps its own values).
    static func decide(type: SyncRecordType, local: [String: String], base: [String: String],
                       server: [String: String]) -> [String: Action] {
        var out: [String: Action] = [:]
        for g in SyncSchema.groupNames(type) {
            let l = local[g], s = server[g], b = base[g]
            if l == s {
                out[g] = .same
            } else if l == b {
                out[g] = .takeServer
            } else if g == SyncSchema.Group.rejected, type == .speaker, s != b {
                out[g] = .union
            } else {
                out[g] = .keepLocal
            }
        }
        return out
    }
}
