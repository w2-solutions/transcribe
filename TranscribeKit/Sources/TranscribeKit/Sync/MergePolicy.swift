import Foundation
import TranscribeCore

/// The three-way merge per field group (§8.4, decision D5), against the base hashes last agreed with the server.
///
/// - A group this device has not changed since the base takes the server's value.
/// - A group this device has changed keeps the local value (the device saving now wins), and is sent again.
/// - The speaker's `rejected` group, changed on both sides, becomes the union of both sides.
/// - The speaker's `stats` group, changed on both sides, keeps the local counts, and its `captureSource` becomes the
///   join of both sides (`SpeakerSource.joined`): a "Same as" on another device that made the speaker mixed is never
///   lost to a local recount.
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
        /// Both sides changed a speaker's `stats` group: keep the local counts and join the two sources.
        case keepLocalJoinSource
    }

    /// The stored `captureSource` after joining two sides. A missing value (nil) is unknown, not the microphone: a
    /// speaker of a recording that captured Mac audio always stores its source ("mic" included), and every speaker of
    /// a microphone-only recording stores nil, so nil against a value only comes from an older build (0.3.3 and
    /// earlier drop the field) or a device that fetched the speaker before it upgraded. The known side is kept then;
    /// only two values are joined.
    static func joinedSource(local: String?, server: String?) -> String? {
        guard let local else { return server }
        guard let server else { return local }
        let l = SpeakerSource(stored: local), s = SpeakerSource(stored: server)
        let joined = SpeakerSource.joined(l, s)
        return joined == l ? local : joined.rawValue
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
            } else if g == SyncSchema.Group.stats, type == .speaker, s != b {
                out[g] = .keepLocalJoinSource
            } else {
                out[g] = .keepLocal
            }
        }
        return out
    }
}
