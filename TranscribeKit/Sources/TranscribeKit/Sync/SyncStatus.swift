import Foundation

/// Why sync stopped on its own (§8.4). Stored in `SyncAccountState.pausedReasonRaw`, so raw values never change.
public enum SyncPauseReason: String, Sendable, Codable {
    case noAccount, accountChanged, quotaFull, zoneRemoved, massDelete, needsUpdate, restricted
}

/// What the Settings status line shows.
public enum SyncStatus: Sendable, Equatable {
    case off
    case joining(String)
    case idle(lastSync: Date?)
    case syncing(pending: Int)
    case paused(SyncPauseReason)

    public var isPaused: Bool { if case .paused = self { true } else { false } }
    public var pauseReason: SyncPauseReason? { if case .paused(let r) = self { r } else { nil } }

    /// "Adding N items to iCloud…" while the first upload drains.
    public static func joiningMessage(_ n: Int) -> String {
        "Adding \(n) \(n == 1 ? "item" : "items") to iCloud…"
    }
}
