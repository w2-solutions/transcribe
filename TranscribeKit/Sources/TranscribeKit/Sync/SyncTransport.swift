import Foundation

/// The sync core's view of the server (§8.3). `CloudKitTransport` (TranscribeCloudKit) wraps `CKSyncEngine`;
/// `FakeTransport` (TranscribeFakes) runs over an in-memory `FakeCloud`. Nothing in `Sync/` imports CloudKit.
///
/// Events arrive on `events`, in order, and the coordinator handles them one at a time. After handling each event
/// (its writes saved) the coordinator calls `eventHandled()`, so a transport can wait for that before it moves on,
/// as `CKSyncEngine` awaits its delegate's `handleEvent`.
public protocol SyncTransport: AnyObject, Sendable {
    var events: AsyncStream<SyncEvent> { get }
    /// `provider` is called for each pending save when a batch is built; nil = skip (entity gone / not syncable).
    func start(state: Data?, provider: @escaping @MainActor @Sendable (SyncRecordID) -> SyncRecord?) async
    func stop() async
    func enqueue(saves: [SyncRecordID], deletes: [SyncRecordID]) async
    func ensureZone() async
    func deleteZone() async throws
    func fetchChanges() async throws
    func sendChanges() async throws
    func accountHash() async -> String?          // nil = no account / restricted
    /// The coordinator has finished (and saved) the oldest event it was given. Default: nothing to wait for.
    func eventHandled() async
}

public extension SyncTransport {
    func eventHandled() async {}
}

public enum SyncEvent: Sendable {
    case stateUpdate(Data)
    case accountChange(AccountChange)            // .signIn(hash), .signOut, .switchAccounts(hash)
    case fetched(modifications: [SyncRecord], deletions: [SyncRecordID])
    case fetchFinished
    case sent(saved: [SyncRecord], deleted: [SyncRecordID], failures: [SendFailure])
    case zoneDeleted(ZoneDeletionReason)         // .deleted, .purged, .encryptedDataReset
}

public enum SendFailure: Sendable, Equatable {
    case serverRecordChanged(SyncRecord)         // the server copy, with its system fields
    case unknownItem(SyncRecordID)
    case zoneNotFound(SyncRecordID)
    case quotaExceeded(SyncRecordID)
    case retryable(SyncRecordID)
    case permanent(SyncRecordID, String)

    public var recordID: SyncRecordID {
        switch self {
        case .serverRecordChanged(let r): r.id
        case .unknownItem(let id), .zoneNotFound(let id), .quotaExceeded(let id), .retryable(let id), .permanent(let id, _): id
        }
    }
}

public enum SyncTransportError: Error, Sendable, Equatable {
    case networkUnavailable
    case notStarted
    case noAccount
}
