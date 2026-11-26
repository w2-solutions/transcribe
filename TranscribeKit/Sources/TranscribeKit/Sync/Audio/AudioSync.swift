import Foundation
import Observation
import os
import SwiftData
import TranscribeCore

/// What audio sync needs from outside `TranscribeKit`: the blob transport, the encoder, the device's network, power
/// and storage, and the platform (which decides the automatic download window).
public struct AudioSyncDependencies: Sendable {
    public var transfer: any AudioTransfer
    public var encoder: any AudioEncoding
    public var conditions: any DeviceConditions
    public var platform: DevicePlatform

    public init(transfer: any AudioTransfer, encoder: any AudioEncoding, conditions: any DeviceConditions,
                platform: DevicePlatform = .current) {
        self.transfer = transfer; self.encoder = encoder; self.conditions = conditions; self.platform = platform
    }
}

/// Tests: where `AudioSync.fault` may throw to simulate a crash.
public enum AudioFaultPoint: Sendable, Equatable {
    /// The blob is stored; the marker row is not saved yet.
    case afterUploadBeforeRowSave
    /// The download is moved into Audio/; the row is not repointed yet.
    case afterMoveBeforeRename
}

/// Moves recordings' audio beside the record sync (§3.5). Owned by `SyncCoordinator`; runs only while sync runs.
///
/// One job loop at a time, one job at a time (decision 5). Each pass of the loop derives the work from the store (the
/// backlog is never stored), runs the first job that applies (`nextJob`) in a task of its own, and goes again until
/// nothing applies. Work starts only from existing triggers (`pump()`): the end of every sync round, send results,
/// the switch, opening a transcript, Download Now, and network or power changes. There is no timer.
///
/// A job captures `epoch` when it starts, and after every `await` it touches the store only while `epoch` is unchanged
/// and `coordinator.audioMayRun` holds (decision 6). The one exception is an upload whose `transfer.upload` returned:
/// it finishes its marker even if the switch went off meanwhile; only an epoch change abandons it.
///
/// What it knows lives in the store as one audio row per marker (`AudioRows`); everything else is in memory and is
/// forgotten at launch and by `reset()`.
@MainActor @Observable
public final class AudioSync {
    /// Bumps when a file lands, a marker row changes, or a transfer starts/ends. Views that check audio read it.
    public internal(set) var revision = 0
    public internal(set) var progress: [UUID: Double] = [:]
    public internal(set) var summary = AudioSyncSummary()
    /// The one-time notice should show (decision 24).
    public internal(set) var introPending = false

    /// Ready recordings here with a known marker (row `.onServer`) and no local file: what Remove iCloud Copy would lose.
    public var cloudOnlyCount: Int {
        _ = revision
        return cloudOnlyIDs().count
    }

    /// Whether Download Audio First would download now: Sync audio on and audio sync allowed to run (sync on,
    /// running, not paused).
    public var downloadAvailability: AudioDownloadAvailability {
        _ = revision
        guard settings.syncAudio else { return .syncAudioOff }
        return coordinator?.audioMayRun == true ? .available : .syncPaused
    }

    /// Sum of `bytes` over known markers (`.sending`/`.onServer` rows), for the quota pause line.
    public var bytesInICloud: Int64 {
        _ = revision
        return allAudioRows().reduce(Int64(0)) { sum, row in
            guard let f = row.audioFacts, f.marker != .deleting else { return sum }
            return sum + max(0, f.descriptor.bytes)
        }
    }

    /// Set by `AppEnvironment` (defaults suit tests).
    @ObservationIgnored public var isBusy: @MainActor () -> Bool = { false }      // recording or processing
    @ObservationIgnored public var isInFront: @MainActor () -> Bool = { true }
    @ObservationIgnored public var background: (any BackgroundTaskBridge)?

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let clock: AppClock
    @ObservationIgnored let dependencies: AudioSyncDependencies
    @ObservationIgnored weak var coordinator: SyncCoordinator?
    @ObservationIgnored let log = Logger(subsystem: "ai.w2solutions.transcribe", category: "audio")

    // Tests
    @ObservationIgnored var fault: ((AudioFaultPoint) throws -> Void)?
    @ObservationIgnored var epoch = 0

    // MARK: Memory (§3.2: forgotten at launch; `reset()` forgets it too)

    /// A fault point threw: this instance does nothing more (tests relaunch).
    @ObservationIgnored var crashed = false
    /// Remove iCloud Copy is under way: no job starts.
    @ObservationIgnored var removing = false
    /// The last removal failed: this device uploads no audio until one succeeds or the app relaunches.
    @ObservationIgnored var removalFailed = false
    /// Recordings this launch's probe has answered for (or whose marker this device saw go): no longer `.checking`.
    @ObservationIgnored var probed: Set<UUID> = []
    /// Upload candidates' presence in iCloud, asked once per loop run (a blob may vanish between runs).
    @ObservationIgnored var uploadPresence: [UUID: AudioPresence] = [:]
    /// Download Now / Try Again / Download Audio First: any network, user-initiated, first in line.
    @ObservationIgnored var forced: Set<UUID> = []
    /// Transcripts opened: their audio downloads next, under the automatic network rule.
    @ObservationIgnored var opened: Set<UUID> = []
    /// Sync Audio Now: the backlog goes once over any network, until a loop that saw this goes idle.
    @ObservationIgnored var forceAnyNetwork = false
    @ObservationIgnored var forceSeenByLoop: Int?
    /// Failures in a row and when the next try may run, per recording.
    @ObservationIgnored var failures: [UUID: Int] = [:]
    @ObservationIgnored var retryAt: [UUID: Date] = [:]
    /// Downloads whose last try failed (the banner's "Couldn't download the audio").
    @ObservationIgnored var failedDownloads: Set<UUID> = []
    /// Downloads whose last free-space check failed.
    @ObservationIgnored var lowStorage: Set<UUID> = []
    /// This loop run found too little room to stage an upload.
    @ObservationIgnored var uploadsLowStorage = false
    /// An audio upload was refused for a full iCloud: audio uploads wait until then (decision 7).
    @ObservationIgnored var uploadsBlockedUntil: Date?
    @ObservationIgnored var tooLong: Set<UUID> = []
    @ObservationIgnored var uploadsThisLaunch: [UUID: Int] = [:]
    @ObservationIgnored var notFoundMarkerDeletes = 0
    /// Markers the server refused for good this session (`permanent`): not offered again.
    @ObservationIgnored var refused: Set<UUID> = []
    /// Waiting marker saves and deletes were handed to the transport again since launch or `reset()`.
    @ObservationIgnored var requeued = false
    /// The sweep failed: not tried again before this.
    @ObservationIgnored var sweepRetryAt: Date?
    /// `introPending` was decided for this launch.
    @ObservationIgnored var introDecided = false

    // MARK: The loop

    @ObservationIgnored var loopTask: Task<Void, Never>?
    @ObservationIgnored var loopID = 0
    /// Something asked for work while the loop ran: run it again when it ends.
    @ObservationIgnored var rerun = false
    @ObservationIgnored var current: Running?
    @ObservationIgnored var jobToken = 0
    @ObservationIgnored var backgroundToken: BackgroundToken?

    init(store: LibraryStore, settings: AppSettings, clock: AppClock, dependencies: AudioSyncDependencies,
         coordinator: SyncCoordinator) {
        self.store = store
        self.settings = settings
        self.clock = clock
        self.dependencies = dependencies
        self.coordinator = coordinator
        dependencies.conditions.setOnChange { [weak self] in
            Task { @MainActor in self?.conditionsChanged() }
        }
    }

    // MARK: Views

    /// Where this recording's audio is, for the transcript banner and the voice sample clips (§3.5 "State for views").
    public func state(of recording: Recording) -> RecordingAudioState {
        // A local file is final for the screen: read nothing audio sync changes while other recordings transfer, so
        // their progress ticks and revisions do not redraw this transcript.
        if store.hasLocalAudio(recording) { return .local }
        _ = revision
        let id = recording.id
        let fraction = progress[id]
        var marker: (descriptor: AudioDescriptor, version: Int64, deleting: Bool)?
        switch audioRow(id)?.audioRead {
        case .facts(let f)?: marker = (f.descriptor, f.markerVersion, f.marker == .deleting)
        case .newer?: marker = (Self.placeholder(id), SyncSchema.version + 1, false)
        case .malformed?, nil: marker = nil
        }
        return RecordingAudioState.resolve(
            hasLocalFile: false, syncOn: settings.syncEnabled,
            syncRunning: coordinator?.audioMayRun ?? false, audioOn: settings.syncAudio, marker: marker,
            probed: probed.contains(id), downloading: fraction != nil, fraction: fraction.flatMap { $0 > 0 ? $0 : nil },
            failed: failedDownloads.contains(id), wait: downloadWait(id), channel: recording.captureChannel)
    }

    /// Priority; automatic network rules.
    public func transcriptOpened(_ id: UUID) {
        opened.insert(id)
        pump()
    }

    /// Download Now / Try Again: any network, .userInitiated; clears its failure; pre-empts an automatic transfer.
    public func downloadNow(_ id: UUID) {
        force([id])
    }

    /// Settings: the current backlog once, any network, .userInitiated; pre-empts an automatic transfer.
    public func syncAudioNow() {
        log.notice("Sync Audio Now")
        forceAnyNetwork = true
        forceSeenByLoop = nil
        uploadsLowStorage = false
        preemptAutomatic()
        revision += 1
        pump()
    }

    /// Download Audio First: `downloadNow` for every cloud-only recording.
    public func downloadCloudOnlyAudio() {
        force(cloudOnlyIDs())
    }

    /// Sync audio flipped: cancel or resume.
    public func settingChanged() {
        log.notice("Sync audio \(self.settings.syncAudio ? "on" : "off", privacy: .public)")
        revision += 1
        if !settings.syncAudio, let c = current, c.job.isTransferOrProbe, !c.committed {
            cancelCurrent(.switchOff)
        }
        pump()
    }

    /// Sets `syncAudioIntroShown`; `turnOff` also sets `syncAudio = false`.
    public func dismissIntro(turnOff: Bool) {
        settings.syncAudioIntroShown = true
        introPending = false
        introDecided = true
        if turnOff {
            settings.syncAudio = false
            settingChanged()
        }
    }

    private func force(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            forced.insert(id)
            failedDownloads.remove(id)
            lowStorage.remove(id)
            failures[id] = nil
            retryAt[id] = nil
        }
        preemptAutomatic()
        revision += 1
        pump()
    }

    // MARK: Coordinator

    /// Starts the job loop if work may run (and refreshes the summary). While a loop runs, it runs once more after.
    func pump() {
        recomputeSummary()
        guard loopTask == nil else { rerun = true; return }
        guard mayStartLoop else { return }
        loopID += 1
        let id = loopID, e = epoch
        rerun = false
        loopTask = Task { [weak self] in
            await self?.loop(epoch: e, id: id)
            self?.loopEnded(id)
        }
    }

    var mayStartLoop: Bool {
        !crashed && !removing && (coordinator?.audioMayRun ?? false) && isInFront()
    }

    /// No-op on the Mac (it always counts as in front), except that coming to the front pumps.
    func setForeground(_ inFront: Bool) {
        if inFront {
            pump()
            return
        }
        guard dependencies.platform != .mac, let c = current, c.job.isTransfer, let background,
              backgroundToken == nil else { return }
        let token = c.token
        Task { [weak self] in
            let granted = await background.beginShortTask(name: "Audio sync", onExpire: {
                Task { @MainActor in self?.backgroundExpired(token) }
            })
            guard let self else { return }
            if self.current?.token == token {
                self.backgroundToken = granted
            } else if let granted {
                await background.end(granted, success: true)
            }
        }
    }

    /// Sync Now.
    func clearBackoff() {
        failures = [:]
        retryAt = [:]
        failedDownloads = []
        lowStorage = []
        uploadsLowStorage = false
        uploadsBlockedUntil = nil
        sweepRetryAt = nil
        revision += 1
    }

    /// epoch += 1; cancels the loop and the transfer. The one-time notice shows only while sync runs (decision 24).
    func stop() {
        epoch += 1
        loopTask?.cancel()
        cancelCurrent(.stopped)
        if introPending { introPending = false }
    }

    /// `stop()`, then awaits the loop task's end.
    func stopAndWait() async {
        let running = loopTask
        stop()
        await running?.value
    }

    /// After clearSyncState: epoch += 1, forget memory (the launch probe runs again).
    func reset() {
        stop()
        probed = []
        uploadPresence = [:]
        forced = []
        opened = []
        forceAnyNetwork = false
        forceSeenByLoop = nil
        failures = [:]
        retryAt = [:]
        failedDownloads = []
        lowStorage = []
        uploadsLowStorage = false
        uploadsBlockedUntil = nil
        tooLong = []
        uploadsThisLaunch = [:]
        notFoundMarkerDeletes = 0
        refused = []
        requeued = false
        sweepRetryAt = nil
        progress = [:]
        revision += 1
        recomputeSummary()
    }

    /// epoch += 1, removing = true (nextJob → nil).
    func beginRemoval() {
        removing = true
        stop()
    }

    /// removing = false; failed → removalFailed = true.
    func endRemoval(failed: Bool) {
        removing = false
        removalFailed = failed
        revision += 1
        pump()
    }

    /// Zone gone: the uploads to abandon, captured before the rows go: `.sending` rows (blob up, marker not
    /// acknowledged) and the upload in flight, whose blob may already be stored although its row is not written.
    func uploadsToAbandon() -> [UUID] {
        var ids = unsentUploadIDs()
        if let c = current, case .upload(let id, _) = c.job, !ids.contains(id) { ids.append(id) }
        return ids
    }

    /// Zone gone: waits for the loop and the transfer in flight to end (a late commit cannot land after the delete),
    /// then `abandonUploads(ids)`.
    func abandonUploadsAfterStop(_ ids: [UUID]) async {
        await stopAndWait()
        await abandonUploads(ids)
    }

    /// Zone gone: best-effort `transfer.delete(ids)`, one attempt, errors logged and ignored; it runs after `stop()`,
    /// so it ignores `audioMayRun`.
    func abandonUploads(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await dependencies.transfer.delete(ids)
            log.notice("audio delete \(ids.count, privacy: .public) af records: uploads whose markers met a missing zone")
        } catch {
            log.error("audio delete of \(ids.count, privacy: .public) unsent uploads failed: \(Self.describe(error), privacy: .public)")
        }
    }

    // MARK: Tests

    /// Until no runnable job is left: starts the loop if it may run and waits until it (and any rerun) has ended.
    func drain() async {
        pump()
        while let task = loopTask { await task.value }
    }

    // MARK: Helpers

    func conditionsChanged() {
        revision += 1
        pump()
    }

    func backgroundExpired(_ token: Int) {
        backgroundToken = nil
        guard let c = current, c.token == token, !c.committed else { return }
        log.notice("audio transfer stopped: the background time ended")
        cancelCurrent(.background)
    }

    /// A fault point threw: everything unsaved is lost and this instance does nothing more.
    func crash() {
        log.error("audio sync stopped at a fault point (test)")
        crashed = true
        store.context.rollback()
        stop()
    }

    var paths: AppPaths { store.paths }
    var context: ModelContext { store.context }

    static func describe(_ error: any Error) -> String {
        if let e = error as? AudioTransferError { return String(describing: e) }
        if let e = error as? AudioEncodingError {
            if case .failed = e { return "encodingFailed" }
            return String(describing: e)
        }
        return String(describing: type(of: error))
    }

    /// Sizes for the log: rounded to 0.1 MB (decision 21).
    static func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

    /// Transfer and encode times for the log (never a recording's duration).
    static func seconds(since start: ContinuousClock.Instant) -> String {
        let d = ContinuousClock.now - start
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.1f s", s)
    }

    static func placeholder(_ id: UUID) -> AudioDescriptor {
        AudioDescriptor(recordingID: id, format: .aac16kMono, bytes: 0, sha256: "", duration: 0)
    }
}

/// What `AudioSync.handleSent` asks the coordinator to do with the marker part of a send result.
struct AudioSentEffects {
    var saves: [SyncRecordID] = []
    var deletes: [SyncRecordID] = []
    var zoneGone = false
    var quotaFull = false
    var retry = 0
    var refused: [String] = []
}
