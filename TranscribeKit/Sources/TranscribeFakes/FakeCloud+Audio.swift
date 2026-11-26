import Foundation
import TranscribeKit

/// The fake cloud's audio blobs (`af.<id>` in each account's default zone) and the controls tests use on them.
/// `FakeAudioTransfer` is the only client. The blobs are outside the `Library` zone, so no change feed, no zone delete
/// and no `FakeTransport` sees them.
///
/// Every request first fails `.networkUnavailable` while `setNetworkDown(true)` is on (checked by the transfer), then
/// takes an injected failure (`failNextAudio`) if one is waiting for its op and id.
extension FakeCloud {
    public struct StoredAudio: Sendable, Equatable {
        public var descriptor: AudioDescriptor
        public var data: Data
        public var created: Date
        /// Its encrypted fields cannot be read (after an encrypted-data reset).
        public var unreadable: Bool

        public init(descriptor: AudioDescriptor, data: Data, created: Date, unreadable: Bool = false) {
            self.descriptor = descriptor; self.data = data; self.created = created; self.unreadable = unreadable
        }
    }

    /// The operations `failNextAudio` and the audio hook name.
    public enum AudioOp: Sendable { case probe, probeFully, upload, download, delete, list, checkRecordings }

    /// The id the audio hook gets for a `.list` (a listing names no recording).
    public static let audioListID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: Test controls

    /// The next metadata probe of `id` says `.unreadable` (the blob stays intact; `probeFully` still reads it).
    public func failProbeAsUnreadable(_ id: UUID) { unreadableProbes.insert(id) }

    /// An account's blobs, by recording id.
    public func audio(account: String) -> [UUID: StoredAudio] { audioStore[account] ?? [:] }

    /// Stores a blob as another device would (replacing one with the same id).
    public func injectAudio(account: String, _ descriptor: AudioDescriptor, data: Data, created: Date) {
        audioStore[account, default: [:]][descriptor.recordingID] = StoredAudio(descriptor: descriptor, data: data,
                                                                                created: created)
    }

    /// Uploads that would take an account's blobs past `bytes` fail `.quotaExceeded`; records are unaffected. nil = no
    /// limit. (`setQuotaFull(true)` also refuses every audio upload.)
    public func setAudioQuota(bytes: Int64?) { audioQuota = bytes }

    /// The next `op` on `id` throws `error` (for `.list`, the id is ignored: the next listing fails). An injected
    /// download failure first writes the first half of the blob (or nothing, when there is none) to the destination,
    /// as an interrupted transfer would. An injected upload failure stores nothing.
    public func failNextAudio(_ op: AudioOp, _ id: UUID, with error: AudioTransferError) {
        audioFailures[op, default: [:]][id] = error
    }

    /// The next download of `id` delivers the blob with one byte flipped; its descriptor is unchanged.
    public func corruptNextDownload(_ id: UUID) { corruptDownloads.insert(id) }

    /// The next upload of `id` is stored, then the call throws `.retryable` (the reply was lost).
    public func commitThenLoseReply(_ id: UUID) { lostReplies.insert(id) }

    /// Without the `recordName` index, `listAll` throws `.indexMissing`. On by default.
    public func setAudioIndexExists(_ on: Bool) { audioIndexExists = on }

    /// Awaited once per id of every audio request that reached the cloud, after the cloud handled it (a blob stored,
    /// read or deleted, or a failure decided) and before the call returns. A task cancelled by then throws
    /// `.cancelled` and the effect stays, as with a reply lost to a cancelled operation. A `.list` passes
    /// `audioListID`. nil removes it.
    public func setAudioHook(_ hook: (@Sendable (AudioOp, UUID) async -> Void)?) { audioHook = hook }

    /// The clock for blobs' creation dates (tests pass their `TestClock`).
    public func setNow(_ now: @escaping @Sendable () -> Date) { audioNow = now }

    /// How many `failNextAudio` failures a request has taken (thrown) so far.
    public var audioFailuresTaken: Int { injectedAudioFailuresTaken }

    /// How many blobs a delete has removed so far (a missing blob counts as deleted but is not counted here).
    public var audioDeletesDone: Int { audioBlobsDeleted }

    // MARK: Transfer API (FakeAudioTransfer)

    enum UploadReply: Sendable {
        case uploaded
        case alreadyThere(AudioDescriptor)
        /// Stored, but the reply is lost: the call throws `.retryable`.
        case lostReply
        case refused(AudioTransferError)
    }

    enum DownloadReply: Sendable {
        case delivered(Data, AudioDescriptor)
        case failed(AudioTransferError, partial: Data?)
    }

    var currentAudioHook: (@Sendable (AudioOp, UUID) async -> Void)? { audioHook }

    func audioProbe(account: String, ids: [UUID]) throws -> [UUID: AudioPresence] {
        for id in ids { if let error = takeAudioFailure(.probe, id) { throw error } }
        let blobs = audioStore[account] ?? [:]
        var out: [UUID: AudioPresence] = [:]
        for id in ids {
            guard let stored = blobs[id] else { out[id] = .absent; continue }
            let forced = unreadableProbes.remove(id) != nil
            out[id] = stored.unreadable || forced ? .unreadable : .present(stored.descriptor)
        }
        return out
    }

    func audioProbeFully(account: String, id: UUID) throws -> AudioPresence {
        if let error = takeAudioFailure(.probeFully, id) { throw error }
        guard let stored = audioStore[account]?[id] else { return .absent }
        return stored.unreadable ? .unreadable : .present(stored.descriptor)
    }

    func audioRecordingRecordsExist(account: String, ids: [UUID]) throws -> Set<UUID> {
        for id in ids { if let error = takeAudioFailure(.checkRecordings, id) { throw error } }
        guard let found = recordingRecords(account: account, ids: ids) else { throw AudioTransferError.zoneMissing }
        return found
    }

    /// Create-only. A blob already there answers `.alreadyThere` with its descriptor (an unreadable one cannot be
    /// read back: `.refused(.other(code: 14))`, CloudKit's serverRecordChanged).
    func audioUpload(account: String, data: Data, descriptor: AudioDescriptor) throws -> UploadReply {
        let id = descriptor.recordingID
        if let error = takeAudioFailure(.upload, id) { throw error }
        var blobs = audioStore[account] ?? [:]
        if let existing = blobs[id] {
            return existing.unreadable ? .refused(.other(code: 14)) : .alreadyThere(existing.descriptor)
        }
        if quotaFull { return .refused(.quotaExceeded) }
        if let audioQuota {
            let used = blobs.values.reduce(Int64(0)) { $0 + Int64($1.data.count) }
            if used + Int64(data.count) > audioQuota { return .refused(.quotaExceeded) }
        }
        blobs[id] = StoredAudio(descriptor: descriptor, data: data, created: audioNow())
        audioStore[account] = blobs
        return lostReplies.remove(id) != nil ? .lostReply : .uploaded
    }

    /// A missing blob is `.notFound`; an unreadable one cannot be delivered (`.other(code: 0)`).
    func audioDownload(account: String, id: UUID) -> DownloadReply {
        let stored = audioStore[account]?[id]
        if let error = takeAudioFailure(.download, id) {
            return .failed(error, partial: stored.map { $0.data.prefix($0.data.count / 2) })
        }
        guard let stored else { return .failed(.notFound, partial: nil) }
        guard !stored.unreadable else { return .failed(.other(code: 0), partial: nil) }
        var data = stored.data
        if corruptDownloads.remove(id) != nil, !data.isEmpty {
            let i = data.startIndex + data.count / 2
            data[i] ^= 0xFF
        }
        return .delivered(data, stored.descriptor)
    }

    /// Missing blobs count as deleted. An injected failure on any id deletes nothing.
    func audioDelete(account: String, ids: [UUID]) throws {
        for id in ids { if let error = takeAudioFailure(.delete, id) { throw error } }
        guard var blobs = audioStore[account] else { return }
        for id in ids where blobs.removeValue(forKey: id) != nil { audioBlobsDeleted += 1 }
        audioStore[account] = blobs
    }

    func audioList(account: String) throws -> [AudioListing] {
        if let error = audioFailures[.list]?.first?.value {
            audioFailures[.list] = nil
            injectedAudioFailuresTaken += 1
            throw error
        }
        guard audioIndexExists else { throw AudioTransferError.indexMissing }
        return (audioStore[account] ?? [:]).values
            .map { AudioListing(recordingID: $0.descriptor.recordingID, created: $0.created) }
            .sorted { $0.recordingID.uuidString < $1.recordingID.uuidString }
    }

    private func takeAudioFailure(_ op: AudioOp, _ id: UUID) -> AudioTransferError? {
        let error = audioFailures[op]?.removeValue(forKey: id)
        if error != nil { injectedAudioFailuresTaken += 1 }
        return error
    }

    /// What a `Library` zone removal does to the blobs in the default zone.
    static func audio(_ blobs: [UUID: StoredAudio], afterZoneRemoval reason: ZoneDeletionReason) -> [UUID: StoredAudio] {
        switch reason {
        case .deleted: blobs
        case .purged: [:]
        case .encryptedDataReset: blobs.mapValues { var b = $0; b.unreadable = true; return b }
        }
    }
}
