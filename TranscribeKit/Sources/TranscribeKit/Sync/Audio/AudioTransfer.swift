import Foundation

/// Moves `af.<id>` records outside the sync engine. Implemented by `CloudKitAudioTransfer` (TranscribeCloudKit) and
/// `FakeAudioTransfer` (TranscribeFakes). Every method throws `AudioTransferError` only and honours task cancellation.
///
/// The blobs live in the private database's default zone, which no sync engine and no database subscription sees, so
/// only this protocol ever moves them (decision 1).
public protocol AudioTransfer: AnyObject, Sendable {
    /// Metadata only, never the asset. Any count (the implementation batches ≤ 200 ids per request).
    func probe(_ ids: [UUID]) async throws -> [UUID: AudioPresence]
    /// One record with every key (the asset is fetched and its staged file discarded). Used only to confirm a
    /// metadata probe's `.unreadable` before anything is deleted.
    func probeFully(_ id: UUID) async throws -> AudioPresence
    /// Which of `ids` have a `rec.<id>` record in the `Library` zone (metadata only, `desiredKeys = []`, ≤ 200 per
    /// request; per-record `unknownItem` = absent). Throws `.zoneMissing` when the zone is gone. Used only by the sweep.
    func recordingRecordsExist(_ ids: [UUID]) async throws -> Set<UUID>
    /// Create-only save of `af.<id>` from `file` (a staged copy the caller owns).
    func upload(_ file: URL, descriptor: AudioDescriptor, options: AudioTransferOptions,
                progress: @escaping @Sendable (Double) -> Void) async throws -> AudioUploadOutcome
    /// Downloads `af.<id>` and moves the asset to `destination` before returning; returns the record's descriptor.
    func download(_ id: UUID, to destination: URL, options: AudioTransferOptions,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> AudioDescriptor
    /// Deletes by id; a missing record counts as deleted (≤ 200 per request, non-atomic).
    func delete(_ ids: [UUID]) async throws
    /// Every `AudioFile` with its creation date; eventually consistent; `.indexMissing` without the index.
    func listAll() async throws -> [AudioListing]
}
