import Foundation
import Observation
import os
import SwiftData
import TranscribeCore

/// Runs sync for one device (§8.4): local change detection, sending, fetching and merging, account and zone changes,
/// the mass-delete breaker, and the On/Off switch. It talks to the server only through a `SyncTransport`, so all of
/// it runs in `swift test` over `FakeTransport`.
///
/// Every write it makes goes to `Library.store`, and the sync state rows are saved in the same `context.save()` as the
/// data they describe (decision D2).
@MainActor @Observable
public final class SyncCoordinator {
    public private(set) var status: SyncStatus
    /// A fetched record had a different embedding model key, or a record schema (`sv`) this build cannot read.
    public private(set) var otherDeviceNeedsUpdate = false
    /// Saved voices that share a name (`DuplicateVoiceBanner`). Never merged automatically (D13).
    public private(set) var duplicateNames: [String] = []
    /// While paused for a mass delete: how many records the breaker held back.
    public private(set) var heldDeleteCount = 0
    /// The last failed fetch or send, or records the server did not take; cleared by a sync round that goes through.
    public private(set) var lastError: SyncProblem?

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let transport: any SyncTransport
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let clock: AppClock
    @ObservationIgnored let detector: ChangeDetector
    @ObservationIgnored let applier: RemoteApplier
    /// The local change debounce (§8.4: 1 s).
    @ObservationIgnored public var debounce: Duration = .seconds(1)
    /// Waits before the coordinator's own follow-up sync after a send left work behind (a merged conflict, a record to
    /// retry, a failed send), one per attempt in a row; the last repeats. `CKSyncEngine` does not reliably send these
    /// again by itself.
    @ObservationIgnored public var followUpDelays: [Duration] = [.seconds(3), .seconds(15), .seconds(60), .seconds(300)]
    /// The iCloud environment this build talks to ("Development" for Debug builds, "Production" for TestFlight and
    /// the Developer ID Mac app). `AppEnvironment` sets it from the Info.plist when the transport is real CloudKit;
    /// nil with a fake iCloud (tests, UI tests, the fake engine), where there is no environment to change.
    @ObservationIgnored public var cloudEnvironment: String?
    /// While the app is in front: how often it checks iCloud, as a safety net for a push that is late or lost
    /// (Liam, 2026-11-24: every 60 s in front, never in the background). Pushes remain the fast path.
    @ObservationIgnored public var foregroundPollInterval: Duration = .seconds(60)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Coming to the front again within this long after the last refresh does not fetch again.
    @ObservationIgnored public var minRefreshGap: Duration = .seconds(10)

    @ObservationIgnored private(set) var running = false
    @ObservationIgnored private(set) var crashed = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private(set) var followUpTask: Task<Void, Never>?
    @ObservationIgnored private var followUpAttempt = 0
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var refreshing = false
    /// `start` or `enable` is between its first await and running: a refresh then would start sync a second time.
    @ObservationIgnored private var starting = false
    /// Counts `noteProblem` calls, so a round can tell whether it went through.
    @ObservationIgnored private var problemCount = 0
    /// Hashes of the projection handed to the transport, by record name, until its send result arrives.
    @ObservationIgnored private var inFlight: [String: [String: String]] = [:]
    @ObservationIgnored private var heldDeletes: [SyncRecordID] = []
    @ObservationIgnored private var fetchTouchedProfiles: Set<UUID> = []
    @ObservationIgnored private var deletedZoneItself = false
    /// After a record from a newer build: engine state is no longer saved, so the next launch fetches it again.
    @ObservationIgnored private var ignoreStateUpdates = false
    /// Tests: throw at a fault point to simulate a crash there (nothing since the last save survives).
    @ObservationIgnored var fault: ((SyncFaultPoint) throws -> Void)? {
        didSet { applier.fault = fault }
    }
    @ObservationIgnored private let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "sync")

    public convenience init(store: LibraryStore, transport: any SyncTransport, settings: AppSettings, clock: AppClock) {
        self.init(store: store, transport: transport, settings: settings, clock: clock, modelKey: nil)
    }

    /// `modelKey`: this build's embedding model key, used only to notice another device on a different build.
    public init(store: LibraryStore, transport: any SyncTransport, settings: AppSettings, clock: AppClock, modelKey: String?) {
        self.store = store
        self.transport = transport
        self.settings = settings
        self.clock = clock
        let detector = ChangeDetector(store: store, clock: clock)
        self.detector = detector
        self.applier = RemoteApplier(store: store, detector: detector, clock: clock, modelKey: modelKey)
        if !settings.syncEnabled {
            status = .off
        } else if let reason = Self.accountRow(store.context, create: false)?.pausedReason {
            status = .paused(reason)
        } else {
            status = .idle(lastSync: Self.accountRow(store.context, create: false)?.lastSendAt)
        }
        detector.onCollected = { [weak self] in self?.scheduleFlush() }
    }

    var context: ModelContext { store.context }

    /// Sync is off and the iCloud copy was kept ("Keep the iCloud Copy"): transcripts and voices synced earlier are
    /// still in iCloud and on the other devices.
    public var keepsCloudCopy: Bool {
        !settings.syncEnabled && Self.accountRow(context, create: false)?.accountHash != nil
    }

    /// The signed-in account is the one this library synced with, so its `Library` zone is this library's copy.
    private func ownsSignedInZone() async -> Bool {
        switch account.pausedReason {
        case .accountChanged?, .zoneRemoved?: return false
        default: break
        }
        guard let stored = account.accountHash, let current = await transport.accountHash() else { return false }
        return stored == current
    }

    // MARK: Public flows

    /// At launch, when the switch is on: resume on the same account, or pause (no account, another account, or the
    /// iCloud copy was removed elsewhere).
    public func start() async {
        guard settings.syncEnabled else { status = .off; return }
        guard !crashed else { return }
        if running { await sync(fullScan: true); return }
        guard !starting else { return }   // already starting (the launch's start and an activation's)
        starting = true
        defer { starting = false }
        ensureEventLoop()
        let account = self.account
        if account.pausedReason == .zoneRemoved { status = .paused(.zoneRemoved); return }
        resetIfCloudEnvironmentChanged()
        guard let hash = await transport.accountHash() else { pause(.noAccount); return }
        if let stored = account.accountHash, stored != hash { pause(.accountChanged); return }
        await run(hash: hash, joining: account.accountHash == nil)
    }

    /// Off → On, the first merge: fetch everything, then upload what only this device has.
    public func enable() async {
        guard !crashed else { return }
        settings.syncEnabled = true
        starting = true
        defer { starting = false }
        ensureEventLoop()
        if !running { resetIfCloudEnvironmentChanged() }
        guard let hash = await transport.accountHash() else { pause(.noAccount); return }
        if let stored = account.accountHash, stored != hash { pause(.accountChanged); return }
        if running { await sync(fullScan: true); return }
        await run(hash: hash, joining: true)
    }

    /// Development and Production are separate iCloud databases. Sync state made in one (change tags, the engine's
    /// tokens) is wrong in the other, and sending with it would look like "the server deleted this", which deletes the
    /// local copy. So a build for the other environment (a Debug build replaced by TestFlight, or back) forgets the
    /// sync state and joins again: local data is untouched and merges with whatever that environment holds.
    private func resetIfCloudEnvironmentChanged() {
        guard let current = cloudEnvironment else { return }
        let stored = settings.syncCloudEnvironment
        guard stored != current else { return }
        let account = self.account
        if account.accountHash != nil || account.engineState != nil {
            log.notice("iCloud environment changed (\(stored ?? "unknown", privacy: .public) to \(current, privacy: .public)); forgetting sync state and joining again")
            clearSyncState()
        }
        settings.syncCloudEnvironment = current
    }

    /// On → Off. "Keep the iCloud copy" keeps every state row and the engine state, so turning sync on again on the
    /// same account sends the deletes made meanwhile. "Also remove from iCloud" deletes the zone and all sync state.
    /// Local data is never touched.
    ///
    /// The zone is deleted only on the Apple Account this library synced with. Signed in to another account (paused
    /// for an account change), signed out, or after the copy was removed elsewhere, "remove" only forgets this
    /// device's sync state: the zone of whoever is signed in now belongs to that account's devices.
    public func disable(removeCloudCopy: Bool) async throws {
        if removeCloudCopy, await ownsSignedInZone() {
            deletedZoneItself = true
            if !running { await transport.start(state: account.engineState, provider: provider) }
            try await transport.deleteZone()
        }
        stopRunning()
        await transport.stop()
        if removeCloudCopy { clearSyncState() }
        settings.syncEnabled = false
        account.pausedReason = nil
        try? context.save()
        status = .off
    }

    /// After `.paused(.accountChanged)`: merge adds this library to the new account's iCloud; otherwise sync stays
    /// paused. Nothing is uploaded to a different Apple Account without this consent.
    public func resolveAccountChange(merge: Bool) async {
        guard status == .paused(.accountChanged) else { return }
        guard merge else { return }
        stopRunning()
        await transport.stop()
        clearSyncState()
        await enable()
    }

    /// After `.paused(.massDelete)`: confirm sends the held deletes; otherwise the deleted items are restored from
    /// iCloud (their state rows forget the server and everything is fetched again).
    public func resolveMassDelete(confirm: Bool) async {
        guard status == .paused(.massDelete) else { return }
        let held = heldDeletes
        heldDeletes = []
        heldDeleteCount = 0
        account.pausedReason = nil
        status = .idle(lastSync: account.lastSendAt)
        if confirm {
            do {
                let deletes = try detector.confirmDeletes(held)
                await transport.enqueue(saves: [], deletes: deletes)
            } catch {
                log.error("Confirming deletes failed: \(error.localizedDescription, privacy: .public)")
            }
            await sync(fullScan: true)
        } else {
            let rows = (try? detector.stateRows(named: held.map(\.recordName))) ?? [:]
            for row in rows.values {
                row.systemFields = nil
                row.baseHashes = [:]
                row.pending = .none
                row.updatedAt = clock.now
            }
            account.engineState = nil
            try? context.save()
            await transport.stop()
            await transport.start(state: nil, provider: provider)
            await sync(fullScan: true)
        }
    }

    /// Fetch, scan everything, send. Also retries after a full quota or a missing account.
    public func syncNow() async {
        await sync(fullScan: true)
    }

    /// The user asked for the latest (pull to refresh, the Mac's Sync Now command): fetch and send now, without the
    /// full scan `syncNow` does.
    public func refreshNow() async {
        guard settings.syncEnabled, !crashed, !starting else { return }
        log.notice("Refresh (asked)")
        lastRefresh = ContinuousClock.now
        await sync(fullScan: false)
    }

    // MARK: In front

    /// The app came to the front (true) or left it (false). Coming to the front syncs once, to catch up on anything
    /// that changed meanwhile, and then checks every `foregroundPollInterval` while the app stays in front. Leaving the
    /// front stops the checks: nothing syncs on a timer in the background. Each check runs in its own task, so
    /// leaving the front never cancels a sync half-way.
    public func setForeground(_ active: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard active else { return }
        Task { await self.refresh(fullScan: true) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.foregroundPollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                Task { await self.refresh(fullScan: false) }
            }
        }
    }

    /// An iCloud push arrived: fetch and send now, whatever the poll timing. `CKSyncEngine` should fetch on a push by
    /// itself, but its own fetch has not reached the server reliably (2026-11-24), so the app also does it.
    public func remoteChangeNotified() async {
        guard settings.syncEnabled, running, !crashed, !starting, !status.isPaused else { return }
        log.notice("Refresh (push)")
        lastRefresh = ContinuousClock.now
        await sync(fullScan: false)
    }

    /// One catch-up sync, skipped within `minRefreshGap` of the last one, while another runs, or while sync starts.
    /// `fullScan` (coming to the front) also scans and retries a pause the next sync can end (full quota, no account);
    /// the timer's check only fetches and sends, and does nothing while paused.
    func refresh(fullScan: Bool) async {
        guard settings.syncEnabled, !crashed, !starting, !refreshing else { return }
        if status.isPaused {
            guard fullScan else { return }
        } else {
            guard running else { return }
        }
        let now = ContinuousClock.now
        if let lastRefresh, now - lastRefresh < minRefreshGap { return }
        lastRefresh = now
        refreshing = true
        defer { refreshing = false }
        log.notice("Refresh (\(fullScan ? "in front" : "timer", privacy: .public))")
        await sync(fullScan: fullScan)
    }

    // MARK: Problems and follow-ups

    private func noteProblem(_ message: String) {
        problemCount += 1
        lastError = SyncProblem(message: message, at: clock.now)
    }

    /// A round with no new problem and nothing left to send ends the shown problem and the follow-up backoff.
    private func roundWentThrough(since mark: Int) {
        guard problemCount == mark, running, !crashed, !status.isPaused, pendingCount() == 0 else { return }
        if lastError != nil { log.notice("Sync went through; clearing the last problem") }
        lastError = nil
        followUpAttempt = 0
    }

    /// The coordinator's own sync a little later, after a send left work behind. Never runs inside an event handler
    /// (the engine waits for that handler), and backs off while the problem lasts.
    private func scheduleFollowUp() {
        guard running, !crashed, followUpTask == nil, let last = followUpDelays.last else { return }
        let delay = followUpAttempt < followUpDelays.count ? followUpDelays[followUpAttempt] : last
        followUpAttempt += 1
        log.notice("Follow-up sync in \(delay.description, privacy: .public) (attempt \(self.followUpAttempt, privacy: .public))")
        followUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.followUpTask = nil
            guard self.running, !self.crashed, !self.status.isPaused else { return }
            await self.sync(fullScan: false)
        }
    }

    // MARK: Running

    func sync(fullScan: Bool) async {
        guard settings.syncEnabled, !crashed else { return }
        if case .paused(let reason) = status {
            switch reason {
            case .quotaFull, .noAccount, .needsUpdate, .restricted:
                account.pausedReason = nil
                status = .idle(lastSync: account.lastSendAt)
                if !running { await start(); return }
            case .accountChanged, .zoneRemoved, .massDelete:
                return
            }
        }
        guard running else { await start(); return }
        let mark = problemCount
        await flushAndEnqueue()
        await fetch()
        guard running, !status.isPaused else { return }
        if fullScan {
            guard await scanAndEnqueue() else { return }
        } else {
            await flushAndEnqueue()
        }
        await sendAll()
        roundWentThrough(since: mark)
    }

    private func run(hash: String, joining: Bool) async {
        account.pausedReason = nil
        try? context.save()
        ignoreStateUpdates = false
        deletedZoneItself = false
        await transport.ensureZone()
        account.zoneReady = true
        await transport.start(state: account.engineState, provider: provider)
        running = true
        detector.startObserving()
        status = .idle(lastSync: account.lastSendAt)
        await fetch()
        guard running, !status.isPaused else { return }
        guard await scanAndEnqueue() else { return }
        account.accountHash = hash
        try? context.save()
        if joining {
            let n = pendingCount()
            if n > 0 { status = .joining(SyncStatus.joiningMessage(n)) }
        }
        await sendAll()
    }

    private func fetch() async {
        do {
            try await transport.fetchChanges()
        } catch {
            log.error("Fetch failed: \(String(describing: error), privacy: .public)")
            noteProblem("Couldn't check iCloud for changes: \(error.localizedDescription)")
        }
    }

    /// A full scan; queues its result. False when the breaker tripped (sync is then paused).
    private func scanAndEnqueue() async -> Bool {
        do {
            let outcome = try await detector.fullScan()
            if let held = outcome.massDelete {
                heldDeletes = held
                heldDeleteCount = held.count
                pause(.massDelete)
                return false
            }
            await enqueue(outcome.saves, outcome.deletes)
            return true
        } catch {
            log.error("Full scan failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func sendAll() async {
        var previous = Int.max
        for _ in 0..<8 {
            guard running, !crashed, !status.isPaused else { break }
            await flushAndEnqueue()
            let pending = pendingCount()
            guard pending > 0 else { break }
            if case .joining = status {} else { status = .syncing(pending: pending) }
            do {
                try await transport.sendChanges()
            } catch is CancellationError {
                // The engine started its own send of the same changes first; it reports that one itself.
                log.notice("Send overtaken by the engine's own send")
                break
            } catch {
                log.error("Send failed with \(pending, privacy: .public) pending: \(String(describing: error), privacy: .public)")
                noteProblem("Couldn't upload to iCloud: \(error.localizedDescription)")
                scheduleFollowUp()
                break
            }
            let after = pendingCount()
            if after >= pending && after >= previous { break }   // only failures the engine retries later
            previous = after
        }
        guard running, !crashed, !status.isPaused else { return }
        let left = pendingCount()
        guard left == 0 else {
            // Not drained (offline, or only retries left): "joining" stays until the first send drains.
            if case .joining = status {} else { status = .syncing(pending: left) }
            return
        }
        account.lastSendAt = clock.now
        try? context.save()
        status = .idle(lastSync: clock.now)
    }

    /// Rows waiting for a save or a delete that can go now (frozen rows and held speaker deletes do not count).
    func pendingCount() -> Int {
        let save = SyncPending.save.rawValue, delete = SyncPending.delete.rawValue
        let rows = (try? context.fetch(FetchDescriptor<SyncRecordState>(predicate: #Predicate {
            $0.pendingRaw == save || $0.pendingRaw == delete
        }))) ?? []
        let projector = RecordProjector(context: context)
        var holdSpeakers: Bool?
        return rows.filter { row in
            guard let id = row.recordID else { return false }
            if row.pending == .save {
                guard let e = projector.entity(id) else { return false }
                return e.isSyncable
            }
            if id.type == .speaker {
                if holdSpeakers == nil { holdSpeakers = (try? detector.syncedRecordingIsProcessing()) ?? false }
                return holdSpeakers == false
            }
            return true
        }.count
    }

    private func stopRunning() {
        running = false
        flushTask?.cancel()
        flushTask = nil
        followUpTask?.cancel()
        followUpTask = nil
        followUpAttempt = 0
        detector.stopObserving()
        inFlight = [:]
    }

    private func pause(_ reason: SyncPauseReason) {
        status = .paused(reason)
        account.pausedReason = reason
        try? context.save()
    }

    /// Deletes every state row and forgets the engine state and account (local data is untouched).
    private func clearSyncState() {
        for row in (try? context.fetch(FetchDescriptor<SyncRecordState>())) ?? [] { context.delete(row) }
        let a = account
        a.engineState = nil
        a.accountHash = nil
        a.zoneReady = false
        a.lastFetchAt = nil
        a.lastSendAt = nil
        inFlight = [:]
        try? context.save()
    }

    // MARK: Local changes

    private func scheduleFlush() {
        guard running, flushTask == nil else { return }
        let delay = debounce
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushAndEnqueue()
            await self?.sendLocalChanges()
        }
    }

    /// Sends what a local change just queued, now. `CKSyncEngine` schedules its own send, but on the iPhone that can
    /// wait minutes (2026-11-24: a new recording reached iCloud only after Sync Now), so the app does not wait for it.
    private func sendLocalChanges() async {
        guard running, !crashed, !status.isPaused, pendingCount() > 0 else { return }
        log.notice("Sending local changes")
        let mark = problemCount
        await sendAll()
        roundWentThrough(since: mark)
    }

    /// The fast path now: what `didSave` collected becomes pending state and goes to the transport.
    func flushAndEnqueue() async {
        flushTask?.cancel()
        flushTask = nil
        guard running, !crashed else { return }
        do {
            let outcome = try detector.flush()
            await enqueue(outcome.saves, outcome.deletes)
        } catch {
            log.error("Change detection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueue(_ saves: [SyncRecordID], _ deletes: [SyncRecordID]) async {
        guard !saves.isEmpty || !deletes.isEmpty else { return }
        await transport.enqueue(saves: saves, deletes: deletes)
    }

    // MARK: Provider

    private var provider: @MainActor @Sendable (SyncRecordID) -> SyncRecord? {
        { [weak self] id in self?.provide(id) }
    }

    /// The record for a pending save, built when the transport makes a batch. Nil skips it (gone, frozen, or no
    /// longer pending).
    func provide(_ id: SyncRecordID) -> SyncRecord? {
        guard running, !crashed, let row = try? detector.stateRow(named: id.recordName), row.pending == .save,
              let e = RecordProjector(context: context).entity(id), e.isSyncable else { return nil }
        let record = RecordProjector.record(e, unresolved: row.unresolvedLinks, systemFields: row.systemFields)
        inFlight[id.recordName] = SyncSchema.hashes(record)
        return record
    }

    // MARK: Events

    private func ensureEventLoop() {
        guard loopTask == nil else { return }
        let events = transport.events
        let transport = self.transport
        loopTask = Task { [weak self] in
            for await event in events {
                if let self { await self.handle(event) }
                await transport.eventHandled()
            }
        }
    }

    func handle(_ event: SyncEvent) async {
        guard !crashed else { return }
        switch event {
        case .stateUpdate(let data):
            guard running, !ignoreStateUpdates else { return }
            account.engineState = data
            try? context.save()
        case .accountChange(let change):
            await handleAccountChange(change)
        case .fetched(let modifications, let deletions):
            guard running else { return }
            await handleFetched(modifications, deletions)
        case .fetchFinished:
            guard running else { return }
            await handleFetchFinished()
        case .sent(let saved, let deleted, let failures):
            guard running else { return }
            await handleSent(saved, deleted, failures)
        case .zoneDeleted(let reason):
            guard running else { return }
            stopRunning()
            clearSyncState()
            switch reason {
            case .deleted, .purged:
                pause(.zoneRemoved)
                Task { await self.transport.stop() }
            case .encryptedDataReset:
                Task {
                    await self.transport.stop()
                    await self.enable()
                }
            }
        }
    }

    private func handleFetched(_ modifications: [SyncRecord], _ deletions: [SyncRecordID]) async {
        log.notice("Fetched \(modifications.count, privacy: .public) changed and \(deletions.count, privacy: .public) deleted records: \(Self.names(modifications.map(\.id) + deletions), privacy: .public)")
        await flushAndEnqueue()
        if modifications.contains(where: { SyncSchema.recordVersion($0) > SyncSchema.version }) {
            otherDeviceNeedsUpdate = true
            ignoreStateUpdates = true
            stopRunning()
            pause(.needsUpdate)
            Task { await self.transport.stop() }
            return
        }
        var effects = RemoteApplier.Effects()
        do {
            try await applier.applyFetched(modifications: modifications, deletions: deletions, effects: &effects)
        } catch is SyncCrash {
            crash()
            return
        } catch {
            log.error("Applying fetched records failed: \(error.localizedDescription, privacy: .public)")
        }
        if effects.otherModelKey { otherDeviceNeedsUpdate = true }
        fetchTouchedProfiles.formUnion(effects.touchedProfiles)
        await enqueue(effects.saves, effects.deletes)
    }

    private func handleFetchFinished() async {
        do {
            let linked = try applier.finishFetch(touchedProfiles: fetchTouchedProfiles)
            // Chunks already rebuilt the search text of what they touched; links resolved now name new speakers.
            let repair = try InvariantRepair.run(store, touchedRecordings: linked)
            duplicateNames = repair.duplicateNames
            account.lastFetchAt = clock.now
            try context.save()
            log.notice("Fetch finished")
        } catch {
            log.error("Finishing a fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        fetchTouchedProfiles = []
        await flushAndEnqueue()
    }

    private func handleSent(_ saved: [SyncRecord], _ deleted: [SyncRecordID], _ failures: [SendFailure]) async {
        log.notice("Sent \(saved.count, privacy: .public) saves and \(deleted.count, privacy: .public) deletes, \(failures.count, privacy: .public) failed. Saved: \(Self.names(saved.map(\.id) + deleted), privacy: .public)")
        await flushAndEnqueue()
        var effects = RemoteApplier.Effects()
        let projector = RecordProjector(context: context)
        let names = saved.map(\.id.recordName) + deleted.map(\.recordName) + failures.map(\.recordID.recordName)
        let rows = (try? detector.stateRows(named: names)) ?? [:]
        var zoneGone = false, quotaFull = false
        var merged = 0, retry = 0, refused: [String] = []

        for record in saved {
            let name = record.id.recordName
            let sent = inFlight.removeValue(forKey: name) ?? SyncSchema.hashes(record)
            guard let row = rows[name] else { continue }
            row.systemFields = record.systemFields
            row.baseHashes = sent
            row.updatedAt = clock.now
            switch row.pending {
            case .delete:
                effects.deletes.append(record.id)
            case .parkedDelete:
                break
            case .none, .save:
                guard let e = projector.entity(record.id) else { continue }   // deleted meanwhile: the detector sends it
                guard e.isSyncable else { continue }                              // frozen: re-checked when ready
                if RecordProjector.hashes(e, unresolved: row.unresolvedLinks) != sent {
                    row.pending = .save
                    effects.saves.append(record.id)
                } else {
                    row.pending = .none
                }
            }
        }
        for id in deleted {
            inFlight.removeValue(forKey: id.recordName)
            guard let row = rows[id.recordName] else { continue }
            if projector.entity(id) == nil {
                context.delete(row)
            } else {
                // The entity exists again here: the server no longer has it, so it is new to the server.
                row.systemFields = nil
                row.baseHashes = [:]
                row.pending = .save
                effects.saves.append(id)
            }
        }
        for failure in failures {
            let id = failure.recordID
            switch failure {
            case .serverRecordChanged(let server):
                inFlight.removeValue(forKey: id.recordName)
                applier.merge(server: server, state: rows[id.recordName], effects: &effects)
                let again = rows[id.recordName]?.pending == .save
                if again { merged += 1 }
                log.notice("\(id.type.rawValue, privacy: .public) \(id.recordName, privacy: .public) changed on the server: merged\(again ? ", sending again" : "", privacy: .public)")
            case .unknownItem:
                // The server no longer has it: delete wins.
                inFlight.removeValue(forKey: id.recordName)
                applier.applyDeletion(id, state: rows[id.recordName], effects: &effects)
                log.notice("\(id.type.rawValue, privacy: .public) \(id.recordName, privacy: .public) is gone from the server: deleted here")
            case .zoneNotFound:
                log.error("\(id.type.rawValue, privacy: .public) \(id.recordName, privacy: .public): zone not found\(self.deletedZoneItself ? " (deleted here)" : "", privacy: .public)")
                if !deletedZoneItself { zoneGone = true }
            case .quotaExceeded:
                log.error("\(id.type.rawValue, privacy: .public) \(id.recordName, privacy: .public): iCloud quota exceeded")
                quotaFull = true
            case .retryable:
                // Queued again here: the engine is not relied on to keep it, and the follow-up sends it.
                inFlight.removeValue(forKey: id.recordName)
                retry += 1
                if let row = rows[id.recordName] {
                    switch row.pending {
                    case .save: effects.saves.append(id)
                    case .delete: effects.deletes.append(id)
                    case .none, .parkedDelete: break
                    }
                }
                log.error("\(id.type.rawValue, privacy: .public) \(id.recordName, privacy: .public): not saved, will retry")
            case .permanent(_, let message):
                inFlight.removeValue(forKey: id.recordName)
                refused.append(message)
                log.error("\(id.type.rawValue, privacy: .public) \(id.recordName, privacy: .public) was refused: \(message, privacy: .public)")
                if let row = rows[id.recordName], row.pending == .save { row.pending = .none }
            }
        }
        if !saved.isEmpty || !deleted.isEmpty { account.lastSendAt = clock.now }
        applier.refreshSearchText(effects.touchedRecordings)
        do {
            try fault?(.beforeSendResultSave)
        } catch {
            crash()
            return
        }
        try? context.save()
        if zoneGone {
            stopRunning()
            clearSyncState()
            pause(.zoneRemoved)
            Task { await self.transport.stop() }
            return
        }
        await enqueue(effects.saves, effects.deletes)
        if quotaFull { pause(.quotaFull); return }
        if let message = Self.sendProblem(merged: merged, retry: retry, refused: refused) { noteProblem(message) }
        if merged > 0 || retry > 0 {
            scheduleFollowUp()
        } else if failures.isEmpty, pendingCount() == 0 {
            // An automatic send by the engine drained everything: the status line says so.
            switch status {
            case .syncing, .joining: status = .idle(lastSync: account.lastSendAt)
            default: break
            }
        }
    }

    /// The status line's wording for records a send did not save. Counts and error codes only.
    static func sendProblem(merged: Int, retry: Int, refused: [String]) -> String? {
        func items(_ n: Int) -> String { "\(n) \(n == 1 ? "item" : "items")" }
        var parts: [String] = []
        if merged > 0 { parts.append("\(items(merged)) changed on another device (merged, sending again)") }
        if retry > 0 { parts.append("\(items(retry)) not saved (retrying)") }
        if let first = refused.first { parts.append("\(items(refused.count)) refused (\(first))") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Record names for the log, capped so a large batch stays one readable line. Record names hold only a type and
    /// a UUID, never a name or text.
    static func names(_ ids: [SyncRecordID], limit: Int = 40) -> String {
        let shown = ids.prefix(limit).map(\.recordName).joined(separator: " ")
        return ids.count > limit ? shown + " … (+\(ids.count - limit))" : shown
    }

    /// A pause that only the user can end (`resolveAccountChange`, `resolveMassDelete`, or turning the switch on again).
    /// Signing out and in never clears it: otherwise a sign-in would resume and upload without consent.
    private static func needsTheUser(_ reason: SyncPauseReason?) -> Bool {
        reason == .zoneRemoved || reason == .accountChanged || reason == .massDelete
    }

    private func handleAccountChange(_ change: AccountChange) async {
        switch change {
        case .signOut:
            guard settings.syncEnabled else { return }
            stopRunning()
            if let reason = account.pausedReason, Self.needsTheUser(reason) {
                status = .paused(reason)
            } else {
                pause(.noAccount)
            }
            Task { await self.transport.stop() }
        case .signIn(let hash), .switchAccounts(let hash):
            guard settings.syncEnabled else { return }
            let reason = account.pausedReason
            // Back on the account this library syncs with: an account-change pause ends; any other such pause stays.
            if Self.needsTheUser(reason), !(reason == .accountChanged && account.accountHash == hash) { return }
            if let stored = account.accountHash, stored != hash {
                stopRunning()
                pause(.accountChanged)
                Task { await self.transport.stop() }
            } else if !running {
                account.pausedReason = nil
                status = .idle(lastSync: account.lastSendAt)
                Task { await self.start() }
            }
        }
    }

    /// A simulated crash: everything unsaved is lost, and this coordinator does nothing more (tests relaunch).
    private func crash() {
        crashed = true
        stopRunning()
        context.rollback()
        Task { await self.transport.stop() }
    }

    // MARK: Account row

    var account: SyncAccountState { Self.accountRow(context, create: true)! }

    static func accountRow(_ context: ModelContext, create: Bool) -> SyncAccountState? {
        var d = FetchDescriptor<SyncAccountState>(predicate: #Predicate { $0.key == "default" })
        d.fetchLimit = 1
        if let row = try? context.fetch(d).first { return row }
        guard create else { return nil }
        let row = SyncAccountState()
        context.insert(row)
        return row
    }
}
