import Foundation
import SwiftData
import TranscribeCore

/// The single writer of the library (§5.5). Every public method is one transaction that ends in exactly
/// one `context.save()` (or none when nothing changed). All access is on the main actor through the
/// container's main context, so `@Query` views refresh immediately.
@MainActor
public final class LibraryStore: LibraryStoring {
    public let context: ModelContext
    let paths: AppPaths
    let deviceIdentity: any DeviceIdentity
    let clock: AppClock
    let policy: MatchPolicy
    let alignment: AlignmentConfig
    /// This device's capture channel (`CaptureChannel.current`, or `LaunchConfig.channel` in the fake engine and UI
    /// tests). New recordings get it, and `stampCaptureChannels()` gives it to rows that have none.
    public let localChannel: String

    /// Key of the install id first recorded with this store. It lives in a small plist next to the store file, so it
    /// travels with the store (backup/restore) but never with the Keychain item. Informational only: nothing is
    /// ever deleted because it differs from the current install id.
    public static let storeDeviceIDKey = "transcribe.storeDeviceID"

    /// A `ModelContext` does not keep its container alive, and SwiftData traps on any fetch once the container
    /// is gone. The store outlives its creator whenever a job is still running (the coordinator holds it), so
    /// it keeps the container alive itself.
    private let container: ModelContainer

    public init(context: ModelContext, paths: AppPaths, deviceIdentity: any DeviceIdentity, clock: AppClock,
                localChannel: String) {
        self.context = context; self.container = context.container
        self.paths = paths; self.deviceIdentity = deviceIdentity; self.clock = clock
        self.policy = .default; self.alignment = .default
        self.localChannel = localChannel
    }

    // MARK: Lookup helpers

    func recording(_ id: UUID) throws -> Recording {
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let recording = try context.fetch(descriptor).first else { throw StoreError.notFound("recording \(id)") }
        return recording
    }

    func profile(_ id: UUID) throws -> VoiceProfile {
        var descriptor = FetchDescriptor<VoiceProfile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let profile = try context.fetch(descriptor).first else { throw StoreError.notFound("profile \(id)") }
        return profile
    }

    func speaker(id: UUID) throws -> RecordingSpeaker {
        var descriptor = FetchDescriptor<RecordingSpeaker>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let speaker = try context.fetch(descriptor).first else { throw StoreError.notFound("speaker \(id)") }
        return speaker
    }

    func speaker(_ key: SpeakerKey, in recording: Recording) throws -> RecordingSpeaker {
        guard let s = recording.speaker(key) else { throw StoreError.notFound("speaker \(key) in \(recording.id)") }
        return s
    }

    func folder(_ id: UUID) throws -> Folder {
        var descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let folder = try context.fetch(descriptor).first else { throw StoreError.notFound("folder \(id)") }
        return folder
    }

    func allProfiles() throws -> [VoiceProfile] {
        try context.fetch(FetchDescriptor<VoiceProfile>()).sorted(by: Self.profileOrder)
    }

    func allSpeakers() throws -> [RecordingSpeaker] {
        try context.fetch(FetchDescriptor<RecordingSpeaker>())
    }

    /// "Me" first, then oldest first, then by name: a stable order for candidates and "Compared with …".
    nonisolated static func profileOrder(_ a: VoiceProfile, _ b: VoiceProfile) -> Bool {
        if a.isMe != b.isMe { return a.isMe }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Deletes the recording's audio file and any stems left beside it.
    func removeAudio(of recording: Recording) {
        try? FileManager.default.removeItem(at: paths.audioURL(fileName: recording.audioFileName))
        removeStems(of: recording)
    }

    /// Deletes the temporary per-stream files of a recording that captured the microphone and Mac audio
    /// (`Audio/Stems/<base>.mic.wav` and `.system.wav`). Nothing happens when there are none.
    func removeStems(of recording: Recording) {
        let stems = CaptureStems.beside(audioURL: paths.audioURL(fileName: recording.audioFileName))
        for stream in CaptureStream.allCases { try? FileManager.default.removeItem(at: stems.url(stream)) }
    }

    static func trimmed(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// lowercased title + transcript + speaker names
    func rebuildSearchText(_ recording: Recording) {
        var parts: [String] = []
        if let title = recording.title { parts.append(title) }
        if let doc = recording.transcript { parts.append(doc.plainText) }
        parts.append(contentsOf: recording.sortedSpeakers.filter(\.hasName).map(\.displayName))
        recording.searchText = parts.joined(separator: "\n").lowercased()
    }

    func setTranscript(_ document: TranscriptDocument, on recording: Recording) throws {
        recording.transcriptData = try document.encoded()
        recording.asrModelID = document.asrModelID
        let flat = document.turns.isEmpty
            ? document.words.map(\.text).joined(separator: " ")
            : document.turns.map(\.text).joined(separator: " ")
        recording.previewText = String(flat.prefix(200))
    }

    func deleteSpeakers(of recording: Recording) {
        let old = recording.speakers
        recording.speakers.removeAll()
        for s in old { context.delete(s) }
    }

    /// Re-colours every speaker from its linked profile slot (§5.4 `assign`).
    func recolour(_ recording: Recording) {
        let requests = recording.sortedSpeakers.map {
            ColourRequest(key: $0.key, ordinal: $0.ordinal, profileSlot: $0.profile?.colourSlot)
        }
        let slots = ColourAssigner.assign(requests)
        for s in recording.speakers { if let slot = slots[s.key] { s.colourSlot = slot } }
    }

    /// Speaker `s` takes the profile's slot; any other holder moves (§5.4 `reassign`).
    func adoptSlot(of profile: VoiceProfile, for s: RecordingSpeaker, in recording: Recording) {
        let current = Dictionary(recording.speakers.map { ($0.key, $0.colourSlot) }, uniquingKeysWith: { a, _ in a })
        let slots = ColourAssigner.reassign(key: s.key, toProfileSlot: profile.colourSlot, current: current)
        for sp in recording.speakers { if let slot = slots[sp.key] { sp.colourSlot = slot } }
    }

    /// The first "Listen" clip of a speaker, used as a sample's clip and quote.
    func firstClip(for key: SpeakerKey, in recording: Recording) -> (range: TimeRange, quote: String)? {
        guard let doc = recording.transcript else { return nil }
        return CleanSpeech.listenClips(for: key, turns: doc.turns, max: 1, config: alignment).first
    }

    /// Curated insert of one embedding into a profile (§5.3). Returns false when skipped as a near-duplicate.
    ///
    /// `channel` is the capture channel of the sample's source recording (D10), never this device's; `input` is that
    /// recording's input route, for the log only. The 12-sample cap, the duplicate check and the protection of the
    /// earliest `.named` sample apply per channel (D12), so a sample never evicts one heard on another channel.
    @discardableResult
    func insertSample(into profile: VoiceProfile, vector: VoiceVector, modelKey: String, origin: SampleOrigin,
                      speechSeconds: Double, sourceRecordingID: UUID?, sourceSpeakerID: UUID?,
                      clip: TimeRange?, quote: String?, channel: String?, input: String?) -> Bool {
        let live = profile.samples.filter { $0.embeddingModelKey == profile.embeddingModelKey }
        if live.isEmpty && profile.embeddingModelKey != modelKey {
            // A profile with no usable samples (all removed, or a model change) re-enrols on the new model.
            // Its negatives and group labels were measured on the old model too, so they go with the samples.
            for stale in profile.samples { context.delete(stale) }
            profile.samples.removeAll()
            for stale in profile.negatives { context.delete(stale) }
            profile.negatives.removeAll()
            deleteGroupLabels(of: profile)
            profile.embeddingModelKey = modelKey
        }
        guard profile.embeddingModelKey == modelKey else { return false }
        let existing: [CuratedSample] = profile.samples.compactMap { s in
            guard s.embeddingModelKey == modelKey, s.captureChannel == channel,
                  let v = s.vector, v.dimension == vector.dimension else { return nil }
            return CuratedSample(id: s.id, vector: v, origin: s.origin, addedAt: s.addedAt, speechSeconds: s.speechSeconds)
        }
        let new = CuratedSample(id: UUID(), vector: vector, origin: origin, addedAt: clock.now, speechSeconds: speechSeconds)
        let result = SampleCurator.insert(new, into: existing, policy: policy)
        guard result.added else { return false }
        let sample = VoiceSample(id: new.id, vector: vector, embeddingModelKey: modelKey, origin: origin,
                                 addedAt: new.addedAt, speechSeconds: speechSeconds)
        context.insert(sample)
        sample.sourceRecordingID = sourceRecordingID
        sample.sourceSpeakerID = sourceSpeakerID
        sample.clipStart = clip?.start
        sample.clipEnd = clip?.end
        sample.quote = quote
        sample.captureChannel = channel
        sample.captureInput = input
        sample.profile = profile
        let evicted = Set(result.evicted)
        for s in profile.samples where evicted.contains(s.id) && s.id != sample.id { context.delete(s) }
        profile.samples.removeAll { evicted.contains($0.id) && $0.id != sample.id }
        profile.needsResample = false
        return true
    }

    /// Adds a sample taken from a recording speaker (clip and quote from its first listen clip).
    func addSpeakerSample(_ s: RecordingSpeaker, to profile: VoiceProfile, origin: SampleOrigin) -> (stored: Bool, skip: SampleSkipReason?) {
        guard s.source != .mixed else { return (false, .mixedSource) }
        guard let vector = s.vector, let key = s.embeddingModelKey else { return (false, .noVector) }
        guard SampleCurator.shouldAddSample(origin: origin, decision: nil, cleanSeconds: s.cleanSeconds, policy: policy) else {
            return (false, .tooLittleSpeech(seconds: s.cleanSeconds))
        }
        let usable = profile.samples.contains { $0.embeddingModelKey == profile.embeddingModelKey }
        if usable && profile.embeddingModelKey != key { return (false, .noVector) }
        let clip = s.recording.flatMap { firstClip(for: s.key, in: $0) }
        let added = insertSample(into: profile, vector: vector, modelKey: key, origin: origin,
                                 speechSeconds: s.cleanSeconds, sourceRecordingID: s.recording?.id,
                                 sourceSpeakerID: s.id, clip: clip?.range, quote: clip?.quote,
                                 channel: s.recording?.captureChannel, input: Self.captureInput(of: s))
        return added ? (true, nil) : (false, .duplicate)
    }

    /// A correction away from profile `p`: roll back what this speaker fed into `p` and never suggest `p` again.
    /// With `addNegative`, the voice is also kept as a negative for `p` (§1.4), after the fed samples are gone.
    func rollBack(_ p: VoiceProfile, from s: RecordingSpeaker, addNegative: Bool) {
        let fed = p.samples.filter { $0.sourceSpeakerID == s.id }
        for sample in fed { context.delete(sample) }
        p.samples.removeAll { $0.sourceSpeakerID == s.id }
        if !s.rejectedProfileIDs.contains(p.id) { s.rejectedProfileIDs.append(p.id) }
        if addNegative { self.addNegative(to: p, from: s) }
    }

    /// After a rollback (and after the corrected speaker has been unlinked from `p`): a profile left with
    /// no samples and no speakers is deleted, since it could never match or be shown usefully; one that
    /// still labels speakers but has no samples is marked as needing a new sample.
    func pruneAfterRollBack(_ p: VoiceProfile, movedAway: RecordingSpeaker) {
        guard p.samples.isEmpty else { return }
        // The inverse of `RecordingSpeaker.profile` may not have caught up yet: leave out the moved speaker.
        if !p.speakers.contains(where: { $0.id != movedAway.id && $0.profile?.id == p.id }) {
            for s in (try? allSpeakers()) ?? [] {
                s.rejectedProfileIDs.removeAll { $0 == p.id }
                if s.suggestedProfileID == p.id {
                    s.suggestedProfileID = nil
                    s.matchScore = nil
                    s.matchMargin = nil
                    if s.label == .suggested { s.label = .unnamed }
                }
            }
            context.delete(p)
        } else {
            p.needsResample = true
        }
    }

    // MARK: Device

    var deviceFileURL: URL { paths.root.appendingPathComponent("StoreDevice.plist", isDirectory: false) }

    func storedDeviceID() -> String? {
        guard let data = try? Data(contentsOf: deviceFileURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return nil }
        return dict[Self.storeDeviceIDKey]
    }

    func writeDeviceID(_ id: String) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: [Self.storeDeviceIDKey: id], format: .xml, options: 0)
        try data.write(to: deviceFileURL, options: .atomic)
    }

    // MARK: Recording lifecycle

    public func createRecording(id: UUID, createdAt: Date, audioFileName: String, source: RecordingSource) throws {
        let recording = Recording(id: id, createdAt: createdAt, audioFileName: audioFileName, source: source)
        context.insert(recording)
        recording.captureChannel = localChannel   // imports too: imported audio counts as heard on this device (D9)
        try context.save()
    }

    public func finishCapture(id: UUID, audio: CapturedAudio, language: LanguageHint) throws {
        let r = try recording(id)
        r.duration = audio.duration
        r.marks = audio.marks
        r.peaks = audio.peaks
        if let detail = audio.detail { r.captureDetailJSON = detail.json() }
        if case .language(let code) = language { r.languageRaw = code } else { r.languageRaw = nil }
        r.stage = .queued
        r.queueReasonRaw = nil
        try context.save()
    }

    public func hasLocalAudio(_ recording: Recording) -> Bool {
        FileManager.default.fileExists(atPath: paths.audioURL(fileName: recording.audioFileName).path)
    }

    @discardableResult
    public func sweepOrphanAudio(minimumAge: TimeInterval = 3_600, now: Date = Date()) throws -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fm.contentsOfDirectory(at: paths.audioDirectory, includingPropertiesForKeys: keys) else { return 0 }
        // Every stage is at or above .capturing, so every row protects its file.
        let named = Set(try context.fetch(FetchDescriptor<Recording>()).filter { $0.stage >= .capturing }.map(\.audioFileName))
        var removed = 0
        for url in files where url.pathExtension.lowercased() == "wav" && !named.contains(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                  now.timeIntervalSince(modified) >= minimumAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed + ((try? sweepOrphanStems(minimumAge: minimumAge, now: now)) ?? 0)
    }

    /// Deletes stems (`Audio/Stems/*.wav`) older than `minimumAge` whose recording is gone or already ready: stems are
    /// deleted when a recording becomes ready, so these are left over from a crash or a failed delete. Stems of a
    /// recording still processing (or failed, which can be retried) are kept. `sweepOrphanAudio` calls this too (the
    /// stems live in a subfolder it does not list). Returns the number of files deleted.
    @discardableResult
    public func sweepOrphanStems(minimumAge: TimeInterval = 3_600, now: Date = Date()) throws -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fm.contentsOfDirectory(at: paths.stemsDirectory, includingPropertiesForKeys: keys) else { return 0 }
        let stageByFile = Dictionary(try context.fetch(FetchDescriptor<Recording>()).map { ($0.audioFileName, $0.stage) },
                                     uniquingKeysWith: { a, _ in a })
        var removed = 0
        for url in files where url.pathExtension.lowercased() == "wav" {
            let name = url.lastPathComponent
            guard let stream = CaptureStream.allCases.first(where: { name.hasSuffix(".\($0.rawValue).wav") }) else { continue }
            let base = String(name.dropLast(".\(stream.rawValue).wav".count))
            if let stage = stageByFile[base + ".wav"], stage != .ready { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                  now.timeIntervalSince(modified) >= minimumAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    public func discardRecording(id: UUID) throws {
        let r = try recording(id)
        removeAudio(of: r)
        context.delete(r)
        try context.save()
    }

    public func snapshot(of id: UUID) throws -> RecordingSnapshot {
        let r = try recording(id)
        return RecordingSnapshot(id: r.id, audioFileName: r.audioFileName, duration: r.duration, stage: r.stage,
                                 language: r.language, transcript: r.transcript, attemptCount: r.attemptCount,
                                 captureSources: Self.captureSources(of: r))
    }

    public func setStage(_ stage: RecordingStage, queueReason: QueueReason?, for id: UUID) throws {
        let r = try recording(id)
        guard r.stage != stage || r.queueReasonRaw != queueReason?.rawValue else { return }
        r.stage = stage
        r.queueReasonRaw = queueReason?.rawValue
        try context.save()
    }

    public func checkpointTranscript(id: UUID, document: TranscriptDocument) throws {
        let r = try recording(id)
        try setTranscript(document, on: r)
        r.stage = .transcribed
        r.queueReasonRaw = nil
        rebuildSearchText(r)
        try context.save()
    }

    public func checkpointSeparation(id: UUID, document: TranscriptDocument, speakers drafts: [SpeakerDraft]) throws {
        let r = try recording(id)
        deleteSpeakers(of: r)
        let slots = ColourAssigner.assign(drafts.map { ColourRequest(key: $0.key, ordinal: $0.ordinal, profileSlot: nil) })
        for d in drafts.sorted(by: { $0.ordinal < $1.ordinal }) {
            let s = RecordingSpeaker(key: d.key, ordinal: d.ordinal, colourSlot: slots[d.key] ?? (d.ordinal - 1) % SpeakerSlots.count)
            context.insert(s)
            s.cleanSeconds = d.cleanSeconds
            s.totalSeconds = d.totalSeconds
            s.turnCount = d.turnCount
            s.vectorData = d.vector?.packed
            s.vectorCoherence = d.coherence.map(Double.init)
            s.embeddingModelKey = d.embeddingModel.key
            s.captureSource = d.source?.rawValue   // in the same save as the speaker, so its first sync carries it
            s.recording = r
        }
        r.embeddingModelKey = drafts.first?.embeddingModel.key
        try setTranscript(document, on: r)
        r.stage = .separated
        r.queueReasonRaw = nil
        rebuildSearchText(r)
        try context.save()
    }

    public func probes(for id: UUID) throws -> [SpeakerProbe] {
        try recording(id).sortedSpeakers.map(Self.probe)
    }

    /// A speaker heard on both streams (`SpeakerSource.mixed`) is only ever asked about.
    static func probe(_ s: RecordingSpeaker) -> SpeakerProbe {
        SpeakerProbe(key: s.key, vector: s.vector, cleanSeconds: s.cleanSeconds, rejectedProfileIDs: Set(s.rejectedProfileIDs),
                     channel: s.recording?.captureChannel, askOnly: s.source == .mixed)
    }

    public func matchCandidates(modelKey: String) throws -> [ProfileCandidate] {
        try allProfiles().filter { $0.embeddingModelKey == modelKey }.map { Self.candidate($0, policy: policy) }
    }

    public func applyMatches(id: UUID, decisions: [SpeakerKey: MatchDecision], traces: [SpeakerKey: MatchTrace],
                             policy: MatchPolicy) throws -> ProcessingOutcome {
        let r = try recording(id)
        let sources = Self.captureSources(of: r)
        // The trace is written once, here, and never cleared by later edits.
        for s in r.sortedSpeakers {
            guard var trace = traces[s.key] else { continue }
            if sources != .microphone {
                if trace.speakerSource == nil { trace.speakerSource = s.source.rawValue }
                trace.version = Swift.max(trace.version, MatchTrace.groupsVersion)
            }
            if s.source == .mixed, trace.kind == .auto {
                // Never an automatic label for a voice heard on both streams (the matcher's askOnly; kept here too).
                trace.kind = .ask
                trace.reason = Self.mixedSourceReason
            }
            s.matchTraceData = try? JSONEncoder().encode(trace)
        }
        for s in r.sortedSpeakers where s.label != .named {
            var decision = decisions[s.key]
            if s.source == .mixed, case .autoLabel(let id, let score, _)? = decision { decision = .ask(profileID: id, score: score) }
            if case .autoLabel(let id, _, _)? = decision, (try? profile(id)) == nil { decision = nil }
            if case .ask(let id, _)? = decision, (try? profile(id)) == nil { decision = nil }
            switch decision {
            case .autoLabel(let profileID, let score, let margin)?:
                let p = try profile(profileID)
                s.label = .autoLabelled
                s.profile = p
                s.suggestedProfileID = nil
                s.nameSnapshot = nil
                s.matchScore = Double(score)
                s.matchMargin = Double(margin)
                // An automatic sample needs the profile's trusted samples alone to match strongly (§1.7), measured
                // before the insert, so an automatic sample never vouches for the next one. Only trusted samples
                // heard on this recording's channel count (§7).
                if s.source != .mixed, let vector = s.vector, let key = s.embeddingModelKey, key == p.embeddingModelKey,
                   SampleCurator.shouldAddAutomaticSample(
                       decision: decision,
                       trustedScore: VoiceMatcher.evidence(vector, against: Self.candidate(p, policy: policy),
                                                           probeChannel: r.captureChannel, policy: policy)?.trustedScore,
                       coherence: s.coherence, cleanSeconds: s.cleanSeconds, policy: policy) {
                    let clip = firstClip(for: s.key, in: r)
                    insertSample(into: p, vector: vector, modelKey: key, origin: .strongMatch, speechSeconds: s.cleanSeconds,
                                 sourceRecordingID: r.id, sourceSpeakerID: s.id, clip: clip?.range, quote: clip?.quote,
                                 channel: r.captureChannel, input: Self.captureInput(of: s))
                }
            case .ask(let profileID, let score)?:
                s.label = .suggested
                s.profile = nil
                s.suggestedProfileID = profileID
                s.matchScore = Double(score)
                s.matchMargin = nil
            case .unknown?, nil:
                s.label = .unnamed
                s.profile = nil
                s.suggestedProfileID = nil
                s.matchScore = nil
                s.matchMargin = nil
            }
        }
        recolour(r)
        r.hasUnseenResult = r.speakers.contains { $0.label == .autoLabelled }
        r.stage = .ready
        r.queueReasonRaw = nil
        r.failureMessage = nil
        r.attemptCount = 0
        r.noSpeech = false
        rebuildSearchText(r)
        try context.save()
        removeStems(of: r)   // temporary: every speaker has been embedded from them
        return Self.outcome(of: r)
    }

    /// The trace reason of a speaker heard on both streams, never auto-labelled.
    static let mixedSourceReason = "mixedSource"

    /// What a recording captured (`CaptureDetail.sources`); the microphone when the detail is missing.
    static func captureSources(of r: Recording) -> CaptureSources {
        CaptureDetail.decode(r.captureDetailJSON)?.captureSources ?? .microphone
    }

    static func outcome(of r: Recording) -> ProcessingOutcome {
        ProcessingOutcome(autoLabelled: r.speakers.filter { $0.label == .autoLabelled }.count,
                          suggested: r.speakers.filter { $0.label == .suggested }.count,
                          unnamed: r.speakers.filter { $0.label == .unnamed }.count,
                          noSpeech: r.noSpeech)
    }

    public func finishWithoutMatching(id: UUID, document: TranscriptDocument?, noSpeech: Bool) throws -> ProcessingOutcome {
        let r = try recording(id)
        deleteSpeakers(of: r)
        if let document { try setTranscript(document, on: r) }
        r.noSpeech = noSpeech
        r.hasUnseenResult = false
        r.stage = .ready
        r.queueReasonRaw = nil
        r.failureMessage = nil
        r.attemptCount = 0
        rebuildSearchText(r)
        try context.save()
        removeStems(of: r)
        return ProcessingOutcome(noSpeech: noSpeech)
    }

    public func markFailed(id: UUID, message: String) throws {
        let r = try recording(id)
        r.stage = .failed
        r.failureMessage = message
        r.queueReasonRaw = nil
        try context.save()
    }

    public func incrementAttempt(id: UUID) throws -> Int {
        let r = try recording(id)
        r.attemptCount += 1
        try context.save()
        return r.attemptCount
    }

    public func releaseAttempt(id: UUID) throws {
        let r = try recording(id)
        guard r.attemptCount > 0 else { return }
        r.attemptCount -= 1
        try context.save()
    }

    public func resetForRetry(id: UUID) throws {
        let r = try recording(id)
        r.attemptCount = 0
        r.failureMessage = nil
        r.stage = .queued
        r.queueReasonRaw = nil
        try context.save()
    }

    public func recoveryCandidates() throws -> [RecoverySnapshot] {
        let ready = RecordingStage.ready.rawValue
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.stageRaw < ready },
                                                    sortBy: [SortDescriptor(\.createdAt)])
        return try context.fetch(descriptor).map { r in
            RecoverySnapshot(id: r.id, stage: r.stage, audioFileName: r.audioFileName, attemptCount: r.attemptCount,
                             hasTranscript: r.transcriptData != nil,
                             audioExists: FileManager.default.fileExists(atPath: paths.audioURL(fileName: r.audioFileName).path))
        }
    }

    public func repairCaptured(id: UUID, duration: TimeInterval, peaks: [Float]) throws {
        let r = try recording(id)
        r.duration = duration
        r.peaks = peaks
        r.stage = .queued
        r.queueReasonRaw = nil
        try context.save()
    }

    // MARK: Library edits

    public func rename(id: UUID, title: String?) throws {
        let r = try recording(id)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        r.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
        rebuildSearchText(r)
        try context.save()
    }

    public func setFavourite(id: UUID, _ isFavourite: Bool) throws {
        try recording(id).isFavourite = isFavourite
        try context.save()
    }

    public func markSeen(id: UUID) throws {
        let r = try recording(id)
        guard r.hasUnseenResult else { return }
        r.hasUnseenResult = false
        try context.save()
    }

    /// Row, speakers (cascade) and audio file. Samples keep their vectors: they hold plain ids only.
    /// The caller cancels any processing job first (`ProcessingCoordinator.cancel`).
    public func delete(id: UUID) throws {
        removeRecordingRow(try recording(id))
        try context.save()
    }

    /// Deletes a recording's audio file (if present), its speakers and the row; samples keep their vectors.
    /// Shared by `delete(id:)` and a remote delete (§8.4), so both have the same side effects. Does not save.
    func removeRecordingRow(_ r: Recording) {
        removeAudio(of: r)
        deleteSpeakers(of: r)
        context.delete(r)
    }

    public func createFolder(name: String) throws -> UUID {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty else { throw StoreError.invalidName }
        let folder = Folder(name: trimmed, createdAt: clock.now)
        context.insert(folder)
        try context.save()
        return folder.id
    }

    public func renameFolder(id: UUID, name: String) throws {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty else { throw StoreError.invalidName }
        try folder(id).name = trimmed
        try context.save()
    }

    /// Recordings in the folder stay in the library (nullify).
    public func deleteFolder(id: UUID) throws {
        let f = try folder(id)
        for r in f.recordings { r.folder = nil }
        context.delete(f)
        try context.save()
    }

    public func move(recordingID: UUID, toFolder folderID: UUID?) throws {
        let r = try recording(recordingID)
        r.folder = try folderID.map { try folder($0) }
        try context.save()
    }

    // MARK: Speakers and voices

    public func nameSpeaker(recordingID: UUID, key: SpeakerKey, as target: NameTarget, remember: Bool) throws -> NameResult {
        let r = try recording(recordingID)
        let s = try speaker(key, in: r)

        // Resolve the target: a new name that matches a saved voice names that voice.
        var resolved = target
        if case .newPerson(let name) = target {
            let trimmed = Self.trimmed(name)
            guard !trimmed.isEmpty else { throw StoreError.invalidName }
            if let existing = try allProfiles().first(where: { VoiceProfile.nameMatches($0.name, trimmed) }) {
                resolved = .existing(profileID: existing.id)
            } else {
                resolved = .newPerson(name: trimmed)
            }
        }

        // Captured before any change: the person this voice was labelled as, and the person it was suggested as.
        let previous = (s.label == .autoLabelled || s.label == .named) ? s.profile : nil
        let priorSuggestion = s.label == .suggested ? s.suggestedProfileID : nil
        let result: NameResult
        var changedProfile: VoiceProfile?

        switch resolved {
        case .newPerson(let name):
            if let previous { rollBack(previous, from: s, addNegative: remember) }
            if remember, let q = priorSuggestion, let suggested = try? profile(q) { addNegative(to: suggested, from: s) }
            if remember && s.canBeRemembered && s.source != .mixed, let vector = s.vector, let modelKey = s.embeddingModelKey {
                let owned = Set(try allProfiles().map(\.colourSlot))
                let slot = ColourAssigner.slotForNewProfile(speakerSlot: s.colourSlot, profileSlots: owned)
                let p = VoiceProfile(name: name, colourSlot: slot, embeddingModelKey: modelKey, now: clock.now)
                context.insert(p)
                let clip = firstClip(for: s.key, in: r)
                let stored = insertSample(into: p, vector: vector, modelKey: modelKey, origin: .named,
                                          speechSeconds: s.cleanSeconds, sourceRecordingID: r.id, sourceSpeakerID: s.id,
                                          clip: clip?.range, quote: clip?.quote,
                                          channel: r.captureChannel, input: Self.captureInput(of: s))
                s.profile = p
                s.nameSnapshot = nil
                adoptSlot(of: p, for: s, in: r)
                changedProfile = p
                result = NameResult(profileID: p.id, sampleStored: stored, skipReason: stored ? nil : .duplicate)
            } else {
                s.profile = nil
                s.nameSnapshot = name
                let skip: SampleSkipReason
                if !remember { skip = .rememberOff }
                else if s.source == .mixed { skip = .mixedSource }
                else if s.cleanSeconds < policy.minSampleSeconds { skip = .tooLittleSpeech(seconds: s.cleanSeconds) }
                else { skip = .noVector }
                result = NameResult(profileID: nil, sampleStored: false, skipReason: skip)
            }

        case .existing(let profileID):
            let p = try profile(profileID)
            if let previous, previous.id != p.id { rollBack(previous, from: s, addNegative: remember) }
            if remember, let q = priorSuggestion, q != p.id, let suggested = try? profile(q) { addNegative(to: suggested, from: s) }
            s.profile = p
            s.nameSnapshot = nil
            s.rejectedProfileIDs.removeAll { $0 == p.id }
            adoptSlot(of: p, for: s, in: r)
            // The user agreeing with what the app said is a confirmation; anything else corrects a miss.
            let origin: SampleOrigin = (previous?.id == p.id || priorSuggestion == p.id) ? .confirmed : .corrected
            let added = learnPositive(s, is: p, origin: origin, remember: remember)
            if added.stored { changedProfile = p }
            result = NameResult(profileID: p.id, sampleStored: added.stored, skipReason: added.skip)
        }

        s.label = .named
        s.suggestedProfileID = nil
        s.matchScore = nil
        s.matchMargin = nil
        // `namedAt` is when the person was first named (set when the profile is made). Naming or confirming a saved
        // voice leaves the profile record alone: it syncs, and rewriting it on every naming made two devices naming
        // the same person conflict on it.
        if let previous, previous.id != s.profile?.id { pruneAfterRollBack(previous, movedAway: s) }
        r.hasUnseenResult = r.speakers.contains { $0.label == .autoLabelled }
        rebuildSearchText(r)
        if let changedProfile {
            try Rematcher.run(changed: changedProfile, excludingRecording: r.id, context: context, policy: policy)
        }
        try context.save()
        return result
    }

    public func confirmSuggestion(recordingID: UUID, key: SpeakerKey) throws -> NameResult {
        let r = try recording(recordingID)
        let s = try speaker(key, in: r)
        guard let profileID = s.suggestedProfileID else { throw StoreError.invariant("speaker \(key) has no suggestion") }
        return try nameSpeaker(recordingID: recordingID, key: key, as: .existing(profileID: profileID), remember: true)
    }

    public func rejectSuggestion(recordingID: UUID, key: SpeakerKey) throws {
        let r = try recording(recordingID)
        let s = try speaker(key, in: r)
        if let profileID = s.suggestedProfileID, !s.rejectedProfileIDs.contains(profileID) {
            s.rejectedProfileIDs.append(profileID)
        }
        if let profileID = s.suggestedProfileID, let p = try? profile(profileID) { addNegative(to: p, from: s) }
        s.suggestedProfileID = nil
        s.matchScore = nil
        s.matchMargin = nil
        if s.label == .suggested { s.label = .unnamed }
        try context.save()
    }

    public func reassignTurn(recordingID: UUID, turnID: UUID, to target: TurnTarget) throws {
        let r = try recording(recordingID)
        guard var doc = r.transcript else { throw StoreError.invariant("recording \(recordingID) has no transcript") }
        guard let index = doc.turns.firstIndex(where: { $0.id == turnID }) else { throw StoreError.notFound("turn \(turnID)") }

        let newKey: SpeakerKey
        switch target {
        case .speaker(let key):
            _ = try speaker(key, in: r)
            newKey = key
        case .profile(let profileID):
            let p = try profile(profileID)
            if let linked = r.sortedSpeakers.first(where: { $0.profile?.id == p.id }) {
                newKey = linked.key
            } else {
                let s = makeUserSpeaker(in: r, preferredSlot: p.colourSlot)
                s.profile = p
                s.label = .named
                newKey = s.key
            }
        case .newName(let name):
            let trimmed = Self.trimmed(name)
            guard !trimmed.isEmpty else { throw StoreError.invalidName }
            if let same = r.sortedSpeakers.first(where: {
                $0.profile == nil && $0.nameSnapshot?.compare(trimmed, options: .caseInsensitive) == .orderedSame
            }) {
                newKey = same.key
            } else {
                let s = makeUserSpeaker(in: r, preferredSlot: nil)
                s.nameSnapshot = trimmed
                s.label = .named
                newKey = s.key
            }
        }

        let before = doc.turns
        doc.turns[index].speakerKeyOverride = (newKey == doc.turns[index].speakerKey) ? nil : newKey
        try setTranscript(doc, on: r)
        recount(r, before: before, after: doc.turns)
        rebuildSearchText(r)
        try context.save()
    }

    /// "Same as Speaker N" for a whole speaker: every turn of `source` moves to `target` in one transaction.
    /// A correction away from a labelled person rolls back what this speaker fed that profile and rejects it
    /// (§6.5: a whole-speaker correction rolls back auto samples). The source speaker is removed once it has
    /// no turns left, so it never shows as a voice waiting for a name.
    public func moveAllTurns(recordingID: UUID, from source: SpeakerKey, to target: SpeakerKey) throws {
        guard source != target else { return }
        let r = try recording(recordingID)
        guard var doc = r.transcript else { throw StoreError.invariant("recording \(recordingID) has no transcript") }
        let s = try speaker(source, in: r)
        let t = try speaker(target, in: r)

        if s.label == .autoLabelled || s.label == .named, let p = s.profile {
            // The voice belongs to the target speaker, so it is not P unless the target is P too.
            rollBack(p, from: s, addNegative: t.profile?.id != p.id)
            s.profile = nil
            pruneAfterRollBack(p, movedAway: s)
        }
        s.label = .unnamed
        s.nameSnapshot = nil
        s.suggestedProfileID = nil
        s.matchScore = nil
        s.matchMargin = nil
        // The target now speaks with both voices' turns: heard on two different streams, it is mixed from now on.
        let joined = SpeakerSource.joined(s.source, t.source)
        if joined != t.source { t.captureSource = joined.rawValue }

        let before = doc.turns
        for i in doc.turns.indices where doc.turns[i].effectiveSpeakerKey == source {
            doc.turns[i].speakerKeyOverride = (target == doc.turns[i].speakerKey) ? nil : target
        }
        try setTranscript(doc, on: r)
        recount(r, before: before, after: doc.turns)
        if s.turnCount == 0, r.speakers.contains(where: { $0.id == s.id }) {
            keepTrace(of: s, movedTo: target, in: r)
            r.speakers.removeAll { $0.id == s.id }
            context.delete(s)
        }
        recolour(r)
        r.hasUnseenResult = r.speakers.contains { $0.label == .autoLabelled }
        rebuildSearchText(r)
        try context.save()
    }

    /// Turn counts and "spoke for" follow the effective speaker after turn overrides change; user ("U")
    /// speakers left with no turns are removed. Seconds move by the change in effective turn time, so a
    /// separated speaker keeps its diariser total and a user speaker starts from its turns.
    func recount(_ r: Recording, before: [Turn], after: [Turn]) {
        func tally(_ turns: [Turn]) -> (counts: [SpeakerKey: Int], seconds: [SpeakerKey: Double]) {
            var counts: [SpeakerKey: Int] = [:], seconds: [SpeakerKey: Double] = [:]
            for t in turns {
                guard let k = t.effectiveSpeakerKey else { continue }
                counts[k, default: 0] += 1
                seconds[k, default: 0] += t.range.duration
            }
            return (counts, seconds)
        }
        let old = tally(before), new = tally(after)
        for s in r.speakers {
            s.turnCount = new.counts[s.key] ?? 0
            let delta = (new.seconds[s.key] ?? 0) - (old.seconds[s.key] ?? 0)
            s.totalSeconds = s.turnCount == 0 ? 0 : Swift.max(0, s.totalSeconds + delta)
        }
        let orphans = r.speakers.filter { $0.key.hasPrefix("U") && (new.counts[$0.key] ?? 0) == 0 }
        for s in orphans {
            r.speakers.removeAll { $0.id == s.id }
            context.delete(s)
        }
    }

    /// New "U<n>" speaker numbered after every existing speaker. No vector: it never feeds matching.
    func makeUserSpeaker(in r: Recording, preferredSlot: Int?) -> RecordingSpeaker {
        let used = Set(r.speakers.map(\.colourSlot))
        let n = (r.speakers.compactMap { $0.key.hasPrefix("U") ? Int($0.key.dropFirst()) : nil }.max() ?? 0) + 1
        let ordinal = (r.speakers.map(\.ordinal).max() ?? 0) + 1
        let slot: Int
        if let preferredSlot, !used.contains(preferredSlot) { slot = preferredSlot }
        else { slot = (0..<SpeakerSlots.count).first { !used.contains($0) } ?? (ordinal - 1) % SpeakerSlots.count }
        let s = RecordingSpeaker(key: "U\(n)", ordinal: ordinal, colourSlot: slot)
        context.insert(s)
        // A speaker the user made has no attribution: in a recording of both streams it is mixed (it learns nothing
        // either way, having no vector), and in a Mac-audio-only recording it was heard through Mac audio.
        switch Self.captureSources(of: r) {
        case .microphone: break
        case .both: s.captureSource = SpeakerSource.mixed.rawValue
        case .macAudio: s.captureSource = SpeakerSource.system.rawValue
        }
        s.recording = r
        return s
    }

    public func setAutoLabel(profileID: UUID, _ on: Bool) throws {
        try profile(profileID).autoLabel = on
        try context.save()
    }

    public func setIsMe(profileID: UUID?) throws {
        let all = try context.fetch(FetchDescriptor<VoiceProfile>())
        if let profileID, !all.contains(where: { $0.id == profileID }) { throw StoreError.notFound("profile \(profileID)") }
        for p in all { p.isMe = (p.id == profileID) }
        try context.save()
    }

    public func renameProfile(profileID: UUID, name: String) throws {
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty else { throw StoreError.invalidName }
        let p = try profile(profileID)
        p.name = trimmed
        for speaker in p.speakers { if let r = speaker.recording { rebuildSearchText(r) } }
        try context.save()
    }

    public func mergeProfiles(source: UUID, into target: UUID) throws {
        guard source != target else { throw StoreError.invariant("cannot merge a voice into itself") }
        let src = try profile(source)
        let dst = try profile(target)
        var touched: [UUID: Recording] = [:]

        // Speakers keep each recording's frozen colour slot.
        for s in Array(src.speakers) {
            s.profile = dst
            if let r = s.recording { touched[r.id] = r }
        }
        for s in try allSpeakers() {
            if s.suggestedProfileID == src.id { s.suggestedProfileID = dst.id }
            if s.rejectedProfileIDs.contains(src.id) {
                s.rejectedProfileIDs.removeAll { $0 == src.id }
                if !s.rejectedProfileIDs.contains(dst.id) { s.rejectedProfileIDs.append(dst.id) }
            }
        }
        // TODO(integration, after T2): insert through `SampleCurator.insertMany` once per channel over the union, so
        // group-preserving curation protects both profiles' sound groups (plan §2.5 step 6). Today each sample goes
        // through the one-at-a-time insert.
        // Samples keep their origin and channel, so trust survives the merge on the channel it was earned on.
        // They also keep their stored bytes: `sample.vector` normalises again, and packing that would change the last
        // bits of some values, so copied group label anchors would no longer find their samples bit for bit.
        for sample in src.sortedSamples {
            guard let decoded = sample.vector else { continue }
            let v = VoiceVector.unpacked(sample.vectorData, dimension: decoded.dimension).first ?? decoded
            insertSample(into: dst, vector: v, modelKey: sample.embeddingModelKey, origin: sample.origin,
                         speechSeconds: sample.speechSeconds, sourceRecordingID: sample.sourceRecordingID,
                         sourceSpeakerID: sample.sourceSpeakerID, clip: sample.clipRange, quote: sample.quote,
                         channel: sample.captureChannel, input: sample.captureInput)
        }
        // After the samples: the loop can re-enrol dst on src's model, and labels follow dst's model as it is now.
        copyGroupLabels(from: src, into: dst)
        try mergeNegatives(from: src, into: dst)
        if src.isMe { dst.isMe = true }
        dst.namedAt = max(dst.namedAt, src.namedAt)
        context.delete(src)
        for r in touched.values { rebuildSearchText(r) }
        try context.save()
    }

    public func forgetProfile(_ profileID: UUID) throws {
        forgetCleanup(try profile(profileID))
        try context.save()
    }

    /// Forgets a profile: its speakers keep the name as a snapshot, suggestions of it are cleared, rejections of it
    /// are dropped, then the profile (with its samples and negatives) is deleted. Shared by `forgetProfile` and a
    /// remote profile delete (§8.4), so both have the same side effects. Does not save.
    func forgetCleanup(_ p: VoiceProfile) {
        let profileID = p.id
        var touched: [UUID: Recording] = [:]
        // Read the links from the speakers' side: after a remote apply the profile's inverse may not have caught up.
        let all = (try? allSpeakers()) ?? []
        let linked = all.filter { $0.profile?.id == profileID }
        for s in linked {
            s.nameSnapshot = p.name
            s.profile = nil
            s.label = .named
            if let r = s.recording { touched[r.id] = r }
        }
        for s in all {
            if s.suggestedProfileID == profileID {
                s.suggestedProfileID = nil
                s.matchScore = nil
                s.matchMargin = nil
                if s.label == .suggested { s.label = .unnamed }
            }
            if s.rejectedProfileIDs.contains(profileID) { s.rejectedProfileIDs.removeAll { $0 == profileID } }
        }
        context.delete(p)
        for r in touched.values {
            r.hasUnseenResult = r.speakers.contains { $0.label == .autoLabelled }
            rebuildSearchText(r)
        }
    }

    public func addSample(profileID: UUID, fromSpeaker recordingSpeakerID: UUID) throws -> NameResult {
        let p = try profile(profileID)
        let s = try speaker(id: recordingSpeakerID)
        if let other = s.profile, other.id != p.id {
            throw StoreError.invariant("speaker \(recordingSpeakerID) is \(other.name), not \(p.name)")
        }
        let priorSuggestion = s.label == .suggested ? s.suggestedProfileID : nil
        let negativesBefore = Set(p.negatives.map(\.id))
        let added = learnPositive(s, is: p, origin: .addedFromRecording, remember: true)
        // learnPositive drops negatives before the sample gate, so they can change even when no sample is stored.
        let negativesChanged = Set(p.negatives.map(\.id)) != negativesBefore
        if added.stored, s.profile == nil, let r = s.recording {
            // Adding this voice to a person says who the speaker is.
            s.profile = p
            s.nameSnapshot = nil
            s.label = .named
            s.suggestedProfileID = nil
            adoptSlot(of: p, for: s, in: r)
            rebuildSearchText(r)
            if let q = priorSuggestion, q != p.id, let suggested = try? profile(q) { addNegative(to: suggested, from: s) }
        }
        if added.stored || negativesChanged {
            // A removed negative can unblock suggestions too, so the rematch runs for either change.
            try Rematcher.run(changed: p, excludingRecording: s.recording?.id, context: context, policy: policy)
            try context.save()
        }
        return NameResult(profileID: p.id, sampleStored: added.stored, skipReason: added.skip)
    }

    /// Speakers with ≥ 10 s of clean speech on this profile's model that are this person or nobody yet,
    /// and that have not already given this profile a sample. Newest recording first.
    public func sampleCandidates(for profileID: UUID) throws -> [SampleCandidate] {
        let p = try profile(profileID)
        let fedSpeakers = Set(p.samples.compactMap(\.sourceSpeakerID))
        let hasUsable = p.samples.contains { $0.embeddingModelKey == p.embeddingModelKey }
        let rows: [(RecordingSpeaker, Recording)] = try allSpeakers().compactMap { s in
            guard let r = s.recording, r.stage == .ready, s.vectorData != nil, s.source != .mixed,
                  s.cleanSeconds >= policy.minSampleSeconds,
                  !fedSpeakers.contains(s.id),
                  s.profile == nil || s.profile?.id == p.id,
                  !s.rejectedProfileIDs.contains(p.id) else { return nil }
            if hasUsable, s.embeddingModelKey != p.embeddingModelKey { return nil }
            return (s, r)
        }
        return rows
            .sorted { a, b in a.1.createdAt != b.1.createdAt ? a.1.createdAt > b.1.createdAt : a.0.ordinal < b.0.ordinal }
            .map { s, r in
                SampleCandidate(id: s.id, recordingID: r.id, key: s.key, speakerName: s.displayName,
                                recordingTitle: r.displayTitle, cleanSeconds: s.cleanSeconds)
            }
    }
}
