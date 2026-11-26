import Foundation
import os
import SwiftData
import TranscribeCore

/// The job loop (§3.5): job choice, the launch probe, uploads, downloads, deletes and the server-truth sweep.
extension AudioSync {
    enum Job: Equatable {
        /// Hand waiting marker saves and deletes to the transport again (once per launch or reset).
        case requeueMarkers
        /// Blobs (then markers) of recordings whose delete is settled.
        case delete([UUID])
        /// This launch's probe: ready recordings with no file and no row (decision 23).
        case launchProbe([UUID])
        /// Upload candidates' presence, asked once per loop run.
        case probeUploads([UUID])
        case download(UUID, userInitiated: Bool)
        case upload(UUID, userInitiated: Bool)
        case sweep

        var isTransfer: Bool {
            switch self {
            case .upload, .download: true
            default: false
            }
        }

        /// What the switch cancels: transfers and probes, never a delete or a sweep.
        var isTransferOrProbe: Bool {
            switch self {
            case .upload, .download, .launchProbe, .probeUploads: true
            case .requeueMarkers, .delete, .sweep: false
            }
        }

        /// An automatic upload or download, or a probe: user-initiated work pre-empts it (a cancelled probe is not
        /// read as an answer and runs again). Never a delete, a sweep or the marker requeue.
        var isPreemptible: Bool {
            switch self {
            case .upload(_, let user), .download(_, let user): !user
            case .launchProbe, .probeUploads: true
            case .requeueMarkers, .delete, .sweep: false
            }
        }
    }

    enum JobOutcome { case next, endLoop }

    enum CancelReason { case preempted, switchOff, background, stopped }

    /// The job in flight.
    struct Running {
        let token: Int
        let job: Job
        let task: Task<JobOutcome, Never>
        /// An upload whose `transfer.upload` returned: only an epoch change stops it now.
        var committed = false
        var reason: CancelReason?
    }

    // MARK: Loop

    func loop(epoch e: Int, id: Int) async {
        uploadPresence = [:]
        uploadsLowStorage = false
        while !Task.isCancelled, e == epoch, !crashed, !removing {
            guard let coordinator, coordinator.audioMayRun else { break }
            guard await coordinator.currentAccountMatches() else {
                log.notice("audio: the signed-in account is not this library's; waiting")
                break
            }
            guard !Task.isCancelled, e == epoch, !removing, coordinator.audioMayRun else { break }
            let s = snapshot(housekeeping: true)
            if forceAnyNetwork { forceSeenByLoop = id }
            guard let job = nextJob(s) else { break }
            let outcome = await perform(job, epoch: e)
            recomputeSummary()
            if outcome == .endLoop { break }
        }
    }

    func loopEnded(_ id: Int) {
        guard loopID == id else { return }
        loopTask = nil
        if forceSeenByLoop == id {
            forceAnyNetwork = false
            forceSeenByLoop = nil
        }
        recomputeSummary()
        if rerun {
            rerun = false
            pump()
        }
    }

    /// Runs a job in a task of its own, so it can be cancelled (switch, pre-emption, background expiry) while the
    /// loop goes on.
    func perform(_ job: Job, epoch e: Int) async -> JobOutcome {
        jobToken += 1
        let token = jobToken
        let task = Task { [weak self] () -> JobOutcome in
            guard let self else { return .endLoop }
            return await self.execute(job, epoch: e, token: token)
        }
        current = Running(token: token, job: job, task: task)
        if job.isTransfer { revision += 1 }
        let outcome = await task.value
        if current?.token == token { current = nil }
        if job.isTransfer { revision += 1 }
        if let granted = backgroundToken, let background {
            backgroundToken = nil
            Task { await background.end(granted, success: true) }
        }
        return outcome
    }

    func execute(_ job: Job, epoch e: Int, token: Int) async -> JobOutcome {
        switch job {
        case .requeueMarkers:
            requeued = true
            await coordinator?.sendAudioMarkers()
            return .next
        case .delete(let ids): return await deleteJob(ids, epoch: e)
        case .launchProbe(let ids): return await launchProbe(ids, epoch: e)
        case .probeUploads(let ids): return await probeUploads(ids, epoch: e)
        case .download(let id, let user): return await downloadJob(id, userInitiated: user, epoch: e, token: token)
        case .upload(let id, let user): return await uploadJob(id, userInitiated: user, epoch: e, token: token)
        case .sweep: return await sweepJob(epoch: e)
        }
    }

    func cancelCurrent(_ reason: CancelReason) {
        guard var c = current else { return }
        c.reason = reason
        current = c
        c.task.cancel()
    }

    /// User-initiated work cancels an automatic transfer or a probe in flight (no failure, no backoff); it runs again
    /// later.
    func preemptAutomatic() {
        guard let c = current, c.job.isPreemptible, !c.committed else { return }
        log.notice("audio: automatic work gives way to work the user asked for")
        cancelCurrent(.preempted)
    }

    func markCommitted(_ token: Int) {
        guard var c = current, c.token == token else { return }
        c.committed = true
        current = c
    }

    func cancelReason(_ token: Int) -> CancelReason? {
        guard let c = current, c.token == token else { return nil }
        return c.reason
    }

    /// The job may touch the store: same epoch, audio may run, nothing crashed.
    func alive(_ e: Int) -> Bool {
        e == epoch && !crashed && (coordinator?.audioMayRun ?? false)
    }

    // MARK: Job choice

    /// The first job that applies (§3.5 "Job choice"); nil ends the loop.
    func nextJob(_ s: Snapshot) -> Job? {
        guard !removing, !crashed, coordinator?.audioMayRun == true, isInFront() else { return nil }
        let now = clock.now

        // 1. Deletes, whatever Sync audio says: the recording's delete is settled here.
        let gone = s.rows.filter { id, f in
            f.marker != .deleting && f.recordingSeen && s.recordings[id] == nil && s.recRows[id] == nil
                && !inBackoff(id, now)
        }.keys.sorted { $0.uuidString < $1.uuidString }
        if !gone.isEmpty { return .delete(Array(gone.prefix(AudioPolicy.batch))) }
        if !requeued, s.rows.values.contains(where: { $0.marker != .onServer }) { return .requeueMarkers }

        // 2. Everything else needs the switch.
        guard settings.syncAudio else { return nil }

        // 3. Download Now / Try Again / Download Audio First: any network.
        for id in forced.sorted(by: { (s.recordings[$0]?.createdAt ?? .distantPast) > (s.recordings[$1]?.createdAt ?? .distantPast) }) {
            guard downloadable(id, s) else { forced.remove(id); continue }
            guard roomToDownload(id, s, userInitiated: true) else { forced.remove(id); continue }
            return .download(id, userInitiated: true)
        }

        // The launch probe (decision 23), opened transcripts first, ≤ 200 ids a request. Ids whose probe met a
        // transient error wait out their backoff; the rest of the work goes on meanwhile.
        let unprobed = s.recordings.values.filter { $0.ready && !$0.hasFile && !s.hasRow($0.id) && !probed.contains($0.id) }
        let probeNow = unprobed.filter { !inBackoff($0.id, now) }
        if !probeNow.isEmpty {
            let ordered = probeNow.sorted { a, b in
                let ao = opened.contains(a.id), bo = opened.contains(b.id)
                return ao != bo ? ao : Self.newestFirst(a, b)
            }
            return .launchProbe(Array(ordered.prefix(AudioPolicy.batch).map(\.id)))
        }
        // The launch probe has answered for everything: the one-time notice is decided for this launch.
        if unprobed.isEmpty { introDecided = true }

        let wait = automaticWait
        // 3. Opened transcripts: the automatic network rule.
        if wait == nil {
            for r in s.recordings.values.filter({ opened.contains($0.id) }).sorted(by: Self.newestFirst) {
                guard downloadable(r.id, s), !inBackoff(r.id, now) else { continue }
                guard roomToDownload(r.id, s, userInitiated: false) else { continue }
                return .download(r.id, userInitiated: forceAnyNetwork)
            }
        }

        // 4. Uploads.
        let blocked = uploadsBlockedUntil.map { now < $0 } ?? false
        if !removalFailed, !blocked, !uploadsLowStorage, wait == nil, !isBusy() {
            let candidates = uploadCandidates(s).filter { r in
                guard AudioPolicy.estimatedBytes(duration: r.duration) <= AudioPolicy.maxUploadBytes else {
                    tooLong.insert(r.id)
                    return false
                }
                return !inBackoff(r.id, now)
            }
            if let first = candidates.first {
                if uploadPresence[first.id] == nil {
                    let ask = candidates.filter { uploadPresence[$0.id] == nil }.prefix(AudioPolicy.batch).map(\.id)
                    return .probeUploads(Array(ask))
                }
                return .upload(first.id, userInitiated: forceAnyNetwork)
            }
        }

        // 5. Automatic downloads.
        if wait == nil {
            for r in downloadCandidates(s) {
                guard !inBackoff(r.id, now), roomToDownload(r.id, s, userInitiated: false) else { continue }
                return .download(r.id, userInitiated: forceAnyNetwork)
            }
        }

        // 6. The server-truth sweep, at most weekly, after a fetch that worked.
        if let last = settings.syncAudioLastSweep, now.timeIntervalSince(last) >= AudioPolicy.sweepInterval,
           coordinator?.fetchSucceededSinceReset == true, sweepRetryAt.map({ now >= $0 }) ?? true {
            return .sweep
        }
        return nil
    }

    func roomToDownload(_ id: UUID, _ s: Snapshot, userInitiated: Bool) -> Bool {
        let bytes = s.rows[id]?.descriptor.bytes ?? 0
        let free = dependencies.conditions.freeBytes(at: paths.audioDirectory, opportunistic: !userInitiated)
        guard AudioPolicy.hasRoom(free: free, bytes: bytes, userInitiated: userInitiated) else {
            if !lowStorage.contains(id) {
                log.notice("audio download skipped: storage low for au.\(id.uuidString, privacy: .public)")
                lowStorage.insert(id)
                revision += 1
            }
            return false
        }
        if lowStorage.remove(id) != nil { revision += 1 }
        return true
    }

    func inBackoff(_ id: UUID, _ now: Date) -> Bool {
        retryAt[id].map { now < $0 } ?? false
    }

    func backoff(_ id: UUID) {
        let n = failures[id, default: 0] + 1
        failures[id] = n
        retryAt[id] = clock.now.addingTimeInterval(AudioPolicy.backoffDelay(failures: n))
    }

    func clearFailure(_ id: UUID) {
        failures[id] = nil
        retryAt[id] = nil
        failedDownloads.remove(id)
    }

    /// A download failed (not for the network or a cancellation): the banner says so and offers Try Again, and it
    /// backs off. Download Now's request is used up: a forced download skips backoff, so keeping it would retry at once,
    /// over and over, while the failure lasts.
    func downloadFailedHere(_ id: UUID) {
        failedDownloads.insert(id)
        forced.remove(id)
        backoff(id)
        revision += 1
    }

    static func transferError(_ error: any Error) -> AudioTransferError {
        if let e = error as? AudioTransferError { return e }
        if error is CancellationError { return .cancelled }
        return .other(code: -1)
    }

    // MARK: Probes

    func launchProbe(_ ids: [UUID], epoch e: Int) async -> JobOutcome {
        let answers: [UUID: AudioPresence]
        do {
            answers = try await dependencies.transfer.probe(ids)
        } catch {
            let err = Self.transferError(error)
            switch err {
            case .networkUnavailable, .noAccount:
                log.notice("audio probe: \(ids.count, privacy: .public) asked, \(Self.describe(err), privacy: .public)")
                return .endLoop
            case .cancelled:
                return .next
            case .retryable(let retryAfter):
                // Not an answer: ask again after a backoff (or CloudKit's wait), still "checking" meanwhile. Only
                // after `launchProbeTries` such failures in a row are they read as absent for this launch.
                guard alive(e) else { return .endLoop }
                var gaveUp = 0
                for id in ids {
                    backoff(id)
                    if let wait = retryAfter, let at = retryAt[id], at < clock.now.addingTimeInterval(wait) {
                        retryAt[id] = clock.now.addingTimeInterval(wait)
                    }
                    if failures[id, default: 0] >= AudioPolicy.launchProbeTries {
                        probed.insert(id)
                        clearFailure(id)
                        gaveUp += 1
                    }
                }
                revision += 1
                log.error("audio probe: \(ids.count, privacy: .public) asked, failed: \(Self.describe(err), privacy: .public); \(gaveUp, privacy: .public) read as absent this launch")
                return .next
            default:
                guard alive(e) else { return .endLoop }
                probed.formUnion(ids)   // read as absent this launch
                revision += 1
                log.error("audio probe: \(ids.count, privacy: .public) asked, failed: \(Self.describe(err), privacy: .public)")
                return .next
            }
        }
        guard alive(e) else { return .endLoop }
        let rows = audioRows(ids)
        let now = clock.now
        var present = 0, unreadable = 0
        for id in ids {
            probed.insert(id)
            clearFailure(id)
            switch answers[id] ?? .absent {
            case .present(let d):
                present += 1
                if rows[id] == nil {
                    insertRow(AudioRowFacts(descriptor: d, marker: .onServer, recordingSeen: true, firstSeenAt: now))
                }
            case .unreadable:
                unreadable += 1
            case .absent:
                break
            }
        }
        if present > 0 { save() }
        revision += 1
        log.notice("audio probe: \(ids.count, privacy: .public) asked, \(present, privacy: .public) present, \(unreadable, privacy: .public) unreadable")
        return .next
    }

    func probeUploads(_ ids: [UUID], epoch e: Int) async -> JobOutcome {
        do {
            let answers = try await dependencies.transfer.probe(ids)
            guard alive(e) else { return .endLoop }
            for id in ids { uploadPresence[id] = answers[id] ?? .absent }
            let present = answers.values.filter { if case .present = $0 { true } else { false } }.count
            log.notice("audio probe: \(ids.count, privacy: .public) asked, \(present, privacy: .public) present, before uploading")
            return .next
        } catch {
            let err = Self.transferError(error)
            switch err {
            case .networkUnavailable, .noAccount: return .endLoop
            case .cancelled: return .next
            default:
                guard alive(e) else { return .endLoop }
                for id in ids { backoff(id) }
                log.error("audio probe before uploading failed: \(Self.describe(err), privacy: .public)")
                return .next
            }
        }
    }

    // MARK: Upload

    func uploadJob(_ id: UUID, userInitiated: Bool, epoch e: Int, token: Int) async -> JobOutcome {
        let transfer = dependencies.transfer
        let name = "af.\(id.uuidString)"

        // 1. Is it there already (a crash after the upload, another device, a lost reply)?
        var presence = uploadPresence[id]
        if presence == nil {
            do {
                presence = try await transfer.probe([id])[id] ?? .absent
            } catch {
                return uploadFailed(id, Self.transferError(error), epoch: e, staged: nil)
            }
            guard alive(e) else { return .endLoop }
        }
        if case .unreadable? = presence {
            do {
                let full = try await transfer.probeFully(id)
                guard alive(e) else { return .endLoop }
                presence = full
                if case .unreadable = full {
                    try await transfer.delete([id])
                    guard alive(e) else { return .endLoop }
                    log.notice("audio delete \(name, privacy: .public): unreadable, uploading it again")
                    presence = .absent
                }
            } catch {
                return uploadFailed(id, Self.transferError(error), epoch: e, staged: nil)
            }
        }
        if case .present(let d)? = presence {
            log.notice("audio upload \(name, privacy: .public): already in iCloud, adopted")
            return await finishUpload(id, d, epoch: e, staged: nil, uploadedHere: false)
        }

        // 2. The source, its size and room to stage it.
        guard let r = recording(id), r.stage == .ready, store.hasLocalAudio(r) else { return .next }
        let estimate = AudioPolicy.estimatedBytes(duration: r.duration)
        if estimate > AudioPolicy.maxUploadBytes {
            tooLong.insert(id)
            return .next
        }
        let free = dependencies.conditions.freeBytes(at: paths.audioOutgoingDirectory, opportunistic: false)
        guard AudioPolicy.hasRoom(free: free, bytes: estimate, userInitiated: true) else {
            log.notice("audio upload skipped: storage low")
            uploadsLowStorage = true
            return .next
        }

        // 3. Stage the transfer copy (off the main actor).
        let source = paths.audioURL(fileName: r.audioFileName)
        let ext = source.pathExtension.lowercased()
        let stagedExt = ext == "wav" ? "m4a" : ext
        let staged = paths.audioOutgoingDirectory.appendingPathComponent("\(id.uuidString).\(stagedExt)", isDirectory: false)
        let fm = FileManager.default
        let descriptor: AudioDescriptor
        let started = ContinuousClock.now
        do {
            try fm.createDirectory(at: paths.audioOutgoingDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: staged.path) {
                descriptor = try await dependencies.encoder.describe(staged, recordingID: id)
            } else if ext == "wav" {
                descriptor = try await dependencies.encoder.encode(wav: source, to: staged, recordingID: id)
                log.notice("audio encoded \(id.uuidString, privacy: .public): \(Self.mb(descriptor.bytes), privacy: .public) in \(Self.seconds(since: started), privacy: .public)")
            } else if AudioFormat(fileExtension: ext) != nil {
                try fm.copyItem(at: source, to: staged)
                descriptor = try await dependencies.encoder.describe(staged, recordingID: id)
            } else {
                throw AudioEncodingError.unsupportedFormat
            }
        } catch {
            try? fm.removeItem(at: staged)
            guard alive(e) else { return .endLoop }
            if Task.isCancelled || error is CancellationError { return .next }
            log.error("audio encode \(id.uuidString, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            backoff(id)
            return .next
        }
        guard alive(e) else { return .endLoop }
        if Task.isCancelled { return .next }
        if descriptor.bytes > AudioPolicy.maxUploadBytes {
            try? fm.removeItem(at: staged)
            tooLong.insert(id)
            return .next
        }

        // 4. Create-only upload.
        let outcome: AudioUploadOutcome
        let sent = ContinuousClock.now
        do {
            outcome = try await transfer.upload(staged, descriptor: descriptor,
                                                options: AudioTransferOptions(userInitiated: userInitiated,
                                                                              allowsMetered: userInitiated,
                                                                              expectedBytes: descriptor.bytes),
                                                progress: { _ in })
        } catch {
            let err = Self.transferError(error)
            if err == .cancelled {
                uploadPresence[id] = nil   // the server may hold it now: ask again before the next try
                if cancelReason(token) == .switchOff, e == epoch {
                    return await afterSwitchOff(id, epoch: e, staged: staged)
                }
            }
            return uploadFailed(id, err, epoch: e, staged: staged)
        }
        markCommitted(token)
        uploadsThisLaunch[id, default: 0] += 1
        var final = descriptor
        switch outcome {
        case .uploaded:
            log.notice("audio upload \(name, privacy: .public): \(Self.mb(descriptor.bytes), privacy: .public) in \(Self.seconds(since: sent), privacy: .public)")
        case .alreadyThere(let server):
            final = server
            log.notice("audio upload \(name, privacy: .public): already in iCloud, adopted")
        }
        do {
            try fault?(.afterUploadBeforeRowSave)
        } catch {
            crash()
            return .endLoop
        }
        return await finishUpload(id, final, epoch: e, staged: staged, uploadedHere: outcome == .uploaded)
    }

    /// Step 5: the marker row, then the marker. Only an epoch change abandons it (the blob then stays, and the next
    /// probe adopts it).
    func finishUpload(_ id: UUID, _ d: AudioDescriptor, epoch e: Int, staged: URL?, uploadedHere: Bool) async -> JobOutcome {
        guard e == epoch, !crashed else { return .endLoop }
        guard let r = recording(id) else {
            // Deleted while it uploaded: its blob goes too.
            if uploadedHere {
                try? await dependencies.transfer.delete([id])
                log.notice("audio delete af.\(id.uuidString, privacy: .public): its recording was deleted during the upload")
            }
            removeStaged(id, staged)
            return .next
        }
        guard r.stage == .ready else {
            removeStaged(id, staged)
            return .next
        }
        if audioRow(id) == nil {
            insertRow(AudioRowFacts(descriptor: d, marker: .sending, recordingSeen: true, firstSeenAt: clock.now))
            save()
            revision += 1
        }
        // A blob adopted from iCloud (a crash after an earlier upload, a lost reply) can leave that try's staged copy.
        removeStaged(id, staged)
        clearFailure(id)
        uploadsBlockedUntil = nil
        uploadPresence[id] = nil
        await coordinator?.sendAudioMarkers()
        return .next
    }

    /// Deletes this upload's staged copy and any other `AudioOutgoing/<id>.*` an earlier try left.
    func removeStaged(_ id: UUID, _ staged: URL?) {
        let fm = FileManager.default
        if let staged { try? fm.removeItem(at: staged) }
        let prefix = id.uuidString + "."
        let dir = paths.audioOutgoingDirectory
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name, isDirectory: false))
        }
    }

    /// The switch went off while the upload's request was out: the server may have stored it. One metadata probe
    /// (not cancelled: it is finishing this upload) decides, so a stored blob never stays without its marker.
    func afterSwitchOff(_ id: UUID, epoch e: Int, staged: URL) async -> JobOutcome {
        let transfer = dependencies.transfer
        let answer = await Task { try? await transfer.probe([id]) }.value
        guard e == epoch, !crashed else { return .endLoop }
        if case .present(let d)? = answer?[id] {
            log.notice("audio upload af.\(id.uuidString, privacy: .public): stored before Sync audio went off; writing its marker")
            uploadsThisLaunch[id, default: 0] += 1
            return await finishUpload(id, d, epoch: e, staged: staged, uploadedHere: true)
        }
        return .next
    }

    func uploadFailed(_ id: UUID, _ error: AudioTransferError, epoch e: Int, staged: URL?) -> JobOutcome {
        switch error {
        case .networkUnavailable, .noAccount:
            log.notice("audio upload af.\(id.uuidString, privacy: .public): \(Self.describe(error), privacy: .public)")
            return .endLoop
        case .cancelled:
            return .next
        default:
            break
        }
        guard alive(e) else { return .endLoop }
        log.error("audio upload af.\(id.uuidString, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
        switch error {
        case .quotaExceeded:
            uploadsBlockedUntil = clock.now.addingTimeInterval(AudioPolicy.quotaRetry)
        case .sourceChanged:
            if let staged { try? FileManager.default.removeItem(at: staged) }
            backoff(id)
        case .tooLarge:
            tooLong.insert(id)
            if let staged { try? FileManager.default.removeItem(at: staged) }
        default:
            backoff(id)
        }
        revision += 1
        return .next
    }

    // MARK: Download

    func downloadJob(_ id: UUID, userInitiated: Bool, epoch e: Int, token: Int) async -> JobOutcome {
        guard let facts = audioRow(id)?.audioFacts, let ext = facts.descriptor.format.fileExtension else { return .next }
        let fm = FileManager.default
        let part = paths.audioIncomingDirectory.appendingPathComponent("\(id.uuidString).\(ext).part", isDirectory: false)
        try? fm.createDirectory(at: paths.audioIncomingDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: part)
        let name = "af.\(id.uuidString)"
        progress[id] = 0
        let options = AudioTransferOptions(userInitiated: userInitiated, allowsMetered: userInitiated,
                                           expectedBytes: facts.descriptor.bytes)
        let started = ContinuousClock.now
        let got: AudioDescriptor
        do {
            got = try await dependencies.transfer.download(id, to: part, options: options, progress: { [weak self] f in
                Task { @MainActor in self?.setProgress(id, f, token: token) }
            })
        } catch {
            progress[id] = nil
            return await downloadFailed(id, Self.transferError(error), epoch: e, part: part)
        }
        guard alive(e) else {
            try? fm.removeItem(at: part)
            progress[id] = nil
            return .endLoop
        }

        // 3. Verify against the descriptor that came with the blob.
        let size = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value
        let sha = try? await FileDigest.sha256(of: part)
        guard alive(e) else {
            try? fm.removeItem(at: part)
            progress[id] = nil
            return .endLoop
        }
        // Cancelled while the file was checked (pre-empted, the switch, the background time): no failure, no backoff.
        if Task.isCancelled {
            try? fm.removeItem(at: part)
            progress[id] = nil
            return .next
        }
        guard size == got.bytes, sha == got.sha256 else {
            try? fm.removeItem(at: part)
            progress[id] = nil
            downloadFailedHere(id)
            log.error("audio download \(name, privacy: .public): the file does not match its record; rejected")
            return .next
        }
        if got != facts.descriptor, let row = audioRow(id), var f = row.audioFacts {
            f.descriptor = got
            row.audioFacts = f
            save()
            log.notice("audio download \(name, privacy: .public): the marker disagreed with its blob; the row takes the blob's")
        }
        guard let gotExt = got.format.fileExtension else {
            try? fm.removeItem(at: part)
            progress[id] = nil
            return .next
        }

        // 4-5. Move into Audio/ and point the recording at it.
        var faulted = false
        let installed: Bool
        do {
            installed = try store.installDownloadedAudio(part, for: id, fileExtension: gotExt, afterMove: {
                do { try self.fault?(.afterMoveBeforeRename) } catch { faulted = true; throw error }
            })
        } catch {
            if faulted {
                crash()
                return .endLoop
            }
            try? fm.removeItem(at: part)
            progress[id] = nil
            downloadFailedHere(id)
            log.error("audio download \(name, privacy: .public): installing failed: \(String(describing: type(of: error)), privacy: .public)")
            return .next
        }
        progress[id] = nil
        guard installed else { return .next }
        clearFailure(id)
        forced.remove(id)
        opened.remove(id)
        lowStorage.remove(id)
        revision += 1
        log.notice("audio download \(name, privacy: .public): \(Self.mb(got.bytes), privacy: .public) in \(Self.seconds(since: started), privacy: .public) (\(String(describing: self.dependencies.conditions.network), privacy: .public))")
        return .next
    }

    func setProgress(_ id: UUID, _ fraction: Double, token: Int) {
        guard current?.token == token, progress[id] != nil else { return }
        progress[id] = min(1, max(0, fraction))
    }

    func downloadFailed(_ id: UUID, _ error: AudioTransferError, epoch e: Int, part: URL) async -> JobOutcome {
        let name = "af.\(id.uuidString)"
        switch error {
        case .networkUnavailable, .noAccount:
            // The part stays until the next download replaces it or the next launch empties AudioIncoming/.
            log.notice("audio download \(name, privacy: .public): \(Self.describe(error), privacy: .public)")
            return .endLoop
        case .cancelled:
            try? FileManager.default.removeItem(at: part)
            return .next
        default:
            break
        }
        try? FileManager.default.removeItem(at: part)
        guard alive(e) else { return .endLoop }
        guard error == .notFound else {
            downloadFailedHere(id)
            log.error("audio download \(name, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            return .next
        }

        // A missing blob: confirmed by a second probe before anything changes (decision 11).
        let presence: AudioPresence
        do {
            presence = try await dependencies.transfer.probe([id])[id] ?? .absent
        } catch {
            guard alive(e) else { return .endLoop }
            downloadFailedHere(id)
            return .next
        }
        guard alive(e) else { return .endLoop }
        guard presence == .absent else {
            downloadFailedHere(id)
            log.notice("audio download \(name, privacy: .public): notFound, but the probe finds it; retrying later")
            return .next
        }
        guard notFoundMarkerDeletes < AudioPolicy.maxNotFoundMarkerDeletesPerLaunch else {
            forced.remove(id)
            backoff(id)
            log.error("audio download \(name, privacy: .public): missing from iCloud; marker deletes for missing audio are at their limit this launch")
            coordinator?.noteAudioProblem("Some audio in iCloud couldn't be found.")
            return .next
        }
        notFoundMarkerDeletes += 1
        forced.remove(id)
        if let row = audioRow(id), var f = row.audioFacts {
            f.marker = .deleting
            row.audioFacts = f
            save()
        }
        revision += 1
        log.notice("audio download \(name, privacy: .public): missing from iCloud; deleting its marker so the holder uploads it again")
        await coordinator?.sendAudioMarkers()
        return .next
    }

    // MARK: Delete

    func deleteJob(_ ids: [UUID], epoch e: Int) async -> JobOutcome {
        do {
            try await dependencies.transfer.delete(ids)
        } catch {
            let err = Self.transferError(error)
            switch err {
            case .networkUnavailable, .noAccount:
                log.notice("audio delete \(ids.count, privacy: .public) af records: \(Self.describe(err), privacy: .public)")
                return .endLoop
            case .cancelled:
                return .next
            default:
                guard alive(e) else { return .endLoop }
                for id in ids { backoff(id) }
                log.error("audio delete \(ids.count, privacy: .public) af records failed: \(Self.describe(err), privacy: .public)")
                return .next
            }
        }
        guard alive(e) else { return .endLoop }
        let rows = audioRows(ids)
        for id in ids {
            probed.insert(id)
            guard let row = rows[id], var f = row.audioFacts else { continue }
            f.marker = .deleting
            row.audioFacts = f
        }
        save()
        revision += 1
        log.notice("audio delete \(ids.count, privacy: .public) af records: their recordings were deleted")
        await coordinator?.sendAudioMarkers()
        return .next
    }

    // MARK: Sweep

    /// Deletes blobs whose `rec.` record the server no longer has (decision 13). Local rows are never the criterion.
    func sweepJob(epoch e: Int) async -> JobOutcome {
        let transfer = dependencies.transfer
        let now = clock.now
        do {
            let listing = try await transfer.listAll()
            guard alive(e) else { return .endLoop }
            let local = Set(((try? context.fetch(FetchDescriptor<Recording>())) ?? []).map(\.id))
            let uploading = Set(unsentUploadIDs())
            let cutoff = now.addingTimeInterval(-AudioPolicy.orphanMinimumAge)
            let candidates = listing.filter { $0.created < cutoff && !local.contains($0.recordingID) && !uploading.contains($0.recordingID) }
                .map(\.recordingID).sorted { $0.uuidString < $1.uuidString }
            var existing = Set<UUID>()
            var start = 0
            while start < candidates.count {
                let chunk = Array(candidates[start..<min(start + AudioPolicy.batch, candidates.count)])
                existing.formUnion(try await transfer.recordingRecordsExist(chunk))
                guard alive(e) else { return .endLoop }
                start += AudioPolicy.batch
            }
            let orphans = candidates.filter { !existing.contains($0) }
            for id in orphans {
                try await transfer.delete([id])
                guard alive(e) else { return .endLoop }
                probed.insert(id)
                if let row = audioRow(id) {
                    if var f = row.audioFacts {
                        f.marker = .deleting
                        f.recordingSeen = true
                        row.audioFacts = f
                    }
                } else {
                    insertRow(AudioRowFacts(descriptor: Self.placeholder(id), marker: .deleting, recordingSeen: true,
                                            firstSeenAt: now))
                }
                save()
            }
            settings.syncAudioLastSweep = now
            sweepRetryAt = nil
            if !orphans.isEmpty { revision += 1 }
            log.notice("audio sweep: \(listing.count, privacy: .public) listed, \(orphans.count, privacy: .public) orphans deleted")
            if !orphans.isEmpty { await coordinator?.sendAudioMarkers() }
            return .next
        } catch {
            let err = Self.transferError(error)
            switch err {
            case .networkUnavailable, .noAccount:
                return .endLoop
            case .cancelled:
                return .next
            case .indexMissing:
                guard alive(e) else { return .endLoop }
                settings.syncAudioLastSweep = now
                log.error("audio sweep: indexMissing (the AudioFile recordName index); nothing deleted")
                return .next
            default:
                guard alive(e) else { return .endLoop }
                sweepRetryAt = now.addingTimeInterval(AudioPolicy.backoff[2])
                log.error("audio sweep aborted: \(Self.describe(err), privacy: .public)")
                return .next
            }
        }
    }
}
