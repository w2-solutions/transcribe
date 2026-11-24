import Foundation
import TranscribeKit

/// One device's connection to a `FakeCloud`, behaving like `CKSyncEngine` as the sync core uses it (§8.3):
/// a pending list of saves and deletes kept in its serialised state, batches of at most 250 records built through the
/// coordinator's provider, a change token, and events delivered in order. Each event waits until the coordinator has
/// handled it (`eventHandled()`), as `CKSyncEngine` awaits its delegate.
public actor FakeTransport: SyncTransport {
    public nonisolated let events: AsyncStream<SyncEvent>
    private let continuation: AsyncStream<SyncEvent>.Continuation
    public let cloud: FakeCloud

    private var account: String?
    private var started = false
    private var provider: (@MainActor @Sendable (SyncRecordID) -> SyncRecord?)?
    private var token: FakeToken?
    private var pendingSaves: [SyncRecordID] = []
    private var pendingDeletes: [SyncRecordID] = []
    /// One entry per event yielded and not yet handled; nil for events nobody waits on.
    private var ackWaiters: [CheckedContinuation<Void, Never>?] = []
    /// Records per fetched event (the real engine also delivers a large fetch in several events).
    public var fetchPageSize = 400
    public private(set) var fetchCount = 0
    public private(set) var sendCount = 0
    /// How often one `sendChanges` tries a record. 3 by default; 1 behaves like `CKSyncEngine`, which does not send a
    /// record queued again after a merged conflict until a later send.
    public private(set) var maxAttemptsPerSend = 3

    struct EngineState: Codable {
        var token: FakeToken?
        var saves: [String]
        var deletes: [String]
    }

    public init(cloud: FakeCloud, account: String? = "account-1") {
        self.cloud = cloud
        self.account = account
        (events, continuation) = AsyncStream<SyncEvent>.makeStream()
    }

    // MARK: Test controls

    public var signedInAccount: String? { account }
    public var pendingCount: Int { pendingSaves.count + pendingDeletes.count }
    public var isStarted: Bool { started }
    public func setMaxAttemptsPerSend(_ n: Int) { maxAttemptsPerSend = max(1, n) }

    public func signOut() async {
        account = nil
        await deliver(.accountChange(.signOut))
    }

    public func signIn(_ hash: String) async {
        let previous = account
        account = hash
        await deliver(.accountChange(previous == nil ? .signIn(hash) : .switchAccounts(hash)))
    }

    // MARK: SyncTransport

    public func start(state: Data?, provider: @escaping @MainActor @Sendable (SyncRecordID) -> SyncRecord?) async {
        self.provider = provider
        let decoded = state.flatMap { try? JSONDecoder().decode(EngineState.self, from: $0) }
        token = decoded?.token
        pendingSaves = (decoded?.saves ?? []).compactMap(SyncRecordID.init(recordName:))
        pendingDeletes = (decoded?.deletes ?? []).compactMap(SyncRecordID.init(recordName:))
        started = true
    }

    public func stop() async {
        started = false
    }

    public func enqueue(saves: [SyncRecordID], deletes: [SyncRecordID]) async {
        guard started else { return }
        for id in saves {
            pendingDeletes.removeAll { $0 == id }
            if !pendingSaves.contains(id) { pendingSaves.append(id) }
        }
        for id in deletes {
            pendingSaves.removeAll { $0 == id }
            if !pendingDeletes.contains(id) { pendingDeletes.append(id) }
        }
        post(.stateUpdate(serialized()))
    }

    public func ensureZone() async {
        guard let account else { return }
        await cloud.ensureZone(account: account)
    }

    public func deleteZone() async throws {
        guard let account else { throw SyncTransportError.noAccount }
        try await cloud.deleteZone(account: account)
        token = nil
        pendingSaves = []
        pendingDeletes = []
    }

    public func fetchChanges() async throws {
        guard started else { throw SyncTransportError.notStarted }
        guard let account else { throw SyncTransportError.noAccount }
        fetchCount += 1
        switch try await cloud.fetch(account: account, token: token) {
        case .zoneDeleted(let reason):
            token = nil
            pendingSaves = []
            pendingDeletes = []
            await deliver(.zoneDeleted(reason))
        case .changes(let mods, let dels, let newToken):
            var start = 0
            while start < mods.count {
                let page = Array(mods[start..<min(start + fetchPageSize, mods.count)])
                await deliver(.fetched(modifications: page, deletions: []))
                guard started else { return }
                start += fetchPageSize
            }
            if !dels.isEmpty { await deliver(.fetched(modifications: [], deletions: dels)) }
            guard started else { return }
            token = newToken
            await deliver(.stateUpdate(serialized()))
            await deliver(.fetchFinished)
        }
    }

    public func sendChanges() async throws {
        guard started else { throw SyncTransportError.notStarted }
        guard let account else { throw SyncTransportError.noAccount }
        sendCount += 1
        // Keep sending while changes are pending (a record queued again after a merge goes out in a later batch of the
        // same send), but try one record at most `maxAttemptsPerSend` times per call.
        var batches = 0
        var attempts: [SyncRecordID: Int] = [:]
        while started, batches < 40 {
            var deletes: [SyncRecordID] = []
            for id in pendingDeletes where deletes.count < FakeCloud.batchLimit && attempts[id, default: 0] < maxAttemptsPerSend { deletes.append(id) }
            let room = FakeCloud.batchLimit - deletes.count
            var saveIDs: [SyncRecordID] = []
            for id in pendingSaves where saveIDs.count < room && attempts[id, default: 0] < maxAttemptsPerSend { saveIDs.append(id) }
            guard !deletes.isEmpty || !saveIDs.isEmpty else { break }
            batches += 1
            var saves: [SyncRecord] = []
            for id in saveIDs {
                attempts[id, default: 0] += 1
                if let provider, let record = await provider(id) {
                    saves.append(record)
                } else {
                    pendingSaves.removeAll { $0 == id }   // nil = skip: gone or not syncable
                }
            }
            for id in deletes { attempts[id, default: 0] += 1 }
            guard !saves.isEmpty || !deletes.isEmpty else { continue }
            let result = try await cloud.modify(account: account, saves: saves, deletes: deletes)
            let sentSaves = Set(saves.map(\.id)), sentDeletes = Set(deletes)
            var keep: Set<SyncRecordID> = []
            for failure in result.failures {
                switch failure {
                case .retryable(let id), .quotaExceeded(let id): keep.insert(id)
                default: break
                }
            }
            // Handled records leave the pending list unless they failed in a way the engine retries; the coordinator
            // queues them again if it needs to (after a merge, for example).
            pendingSaves.removeAll { sentSaves.contains($0) && !keep.contains($0) }
            pendingDeletes.removeAll { sentDeletes.contains($0) && !keep.contains($0) }
            await deliver(.sent(saved: result.saved, deleted: result.deleted, failures: result.failures))
            await deliver(.stateUpdate(serialized()))
            if result.failures.contains(where: { if case .zoneNotFound = $0 { true } else { false } }) { break }
        }
    }

    public func accountHash() async -> String? { account }

    public func eventHandled() async {
        guard !ackWaiters.isEmpty else { return }
        ackWaiters.removeFirst()?.resume()
    }

    // MARK: Delivery

    /// Yields an event and waits until the coordinator has handled it.
    private func deliver(_ event: SyncEvent) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ackWaiters.append(c)
            continuation.yield(event)
        }
    }

    /// Yields an event without waiting (used from inside the coordinator's own handling, where waiting would deadlock).
    private func post(_ event: SyncEvent) {
        ackWaiters.append(nil)
        continuation.yield(event)
    }

    private func serialized() -> Data {
        let state = EngineState(token: token, saves: pendingSaves.map(\.recordName), deletes: pendingDeletes.map(\.recordName))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(state)) ?? Data()
    }
}
