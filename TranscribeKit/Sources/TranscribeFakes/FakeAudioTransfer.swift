import Foundation
import TranscribeKit

/// One device's audio transfer over a `FakeCloud`, behaving like `CloudKitAudioTransfer` as `AudioSync` uses it: the
/// account is the one its `FakeTransport` is signed in to at each call (nil → `.noAccount`), every request fails
/// `.networkUnavailable` while the cloud's network is down, ids go in requests of at most 200, and task cancellation
/// is honoured before a request (nothing happens) and after it (the effect stays, the call throws `.cancelled`).
///
/// The counters count requests that reached the cloud (an account signed in and the network up), whatever the cloud
/// answered, so a test can check that nothing was asked at all.
public actor FakeAudioTransfer: AudioTransfer {
    /// One upload or download that reached the cloud, with the options it ran with.
    public struct Call: Sendable, Equatable {
        public var op: FakeCloud.AudioOp
        public var id: UUID
        public var options: AudioTransferOptions
    }

    public let cloud: FakeCloud
    public let transport: FakeTransport

    /// Upload requests (a refusal for quota or an existing blob included).
    public private(set) var uploads = 0
    /// Download requests.
    public private(set) var downloads = 0
    /// Probe requests (≤ 200 ids each), `probeFully` included.
    public private(set) var probes = 0
    /// Delete requests (≤ 200 ids each).
    public private(set) var deletes = 0
    /// `listAll` requests.
    public private(set) var listings = 0
    /// `recordingRecordsExist` requests (≤ 200 ids each).
    public private(set) var recordingChecks = 0
    /// Bytes of blobs the cloud stored from this device.
    public private(set) var bytesUp: Int64 = 0
    /// Bytes this device wrote to download destinations.
    public private(set) var bytesDown: Int64 = 0
    /// Every upload and download that reached the cloud, in order.
    public private(set) var calls: [Call] = []

    public init(cloud: FakeCloud, transport: FakeTransport) {
        self.cloud = cloud
        self.transport = transport
    }

    /// The options of each `op` on `id`, in order (`options.userInitiated` tells Download Now from automatic work).
    public func options(_ op: FakeCloud.AudioOp, _ id: UUID) -> [AudioTransferOptions] {
        calls.filter { $0.op == op && $0.id == id }.map(\.options)
    }

    // MARK: AudioTransfer

    public func probe(_ ids: [UUID]) async throws -> [UUID: AudioPresence] {
        guard !ids.isEmpty else { return [:] }
        let account = try await reach()
        probes += Self.requests(ids.count)
        let answer = await outcome { try await cloud.audioProbe(account: account, ids: ids) }
        try await finish(.probe, ids)
        return try answer.get()
    }

    public func probeFully(_ id: UUID) async throws -> AudioPresence {
        let account = try await reach()
        probes += 1
        let answer = await outcome { try await cloud.audioProbeFully(account: account, id: id) }
        try await finish(.probeFully, [id])
        return try answer.get()
    }

    public func recordingRecordsExist(_ ids: [UUID]) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let account = try await reach()
        recordingChecks += Self.requests(ids.count)
        let answer = await outcome { try await cloud.audioRecordingRecordsExist(account: account, ids: ids) }
        try await finish(.checkRecordings, ids)
        return try answer.get()
    }

    public func upload(_ file: URL, descriptor: AudioDescriptor, options: AudioTransferOptions,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> AudioUploadOutcome {
        let id = descriptor.recordingID
        let account = try await reach()
        guard let data = try? Data(contentsOf: file) else { throw AudioTransferError.sourceChanged }
        uploads += 1
        calls.append(Call(op: .upload, id: id, options: options))
        progress(0)
        let answer = await outcome { try await cloud.audioUpload(account: account, data: data, descriptor: descriptor) }
        if case .success(let reply) = answer {
            switch reply {
            case .uploaded, .lostReply: bytesUp += Int64(data.count)
            case .alreadyThere, .refused: break
            }
        }
        try await finish(.upload, [id])
        switch try answer.get() {
        case .uploaded:
            progress(1)
            return .uploaded
        case .alreadyThere(let server):
            progress(1)
            return .alreadyThere(server)
        case .lostReply:
            throw AudioTransferError.retryable(retryAfter: nil)
        case .refused(let error):
            throw error
        }
    }

    public func download(_ id: UUID, to destination: URL, options: AudioTransferOptions,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> AudioDescriptor {
        let account = try await reach()
        downloads += 1
        calls.append(Call(op: .download, id: id, options: options))
        progress(0)
        let reply = await cloud.audioDownload(account: account, id: id)
        try await finish(.download, [id])
        switch reply {
        case .delivered(let data, let descriptor):
            try write(data, to: destination)
            bytesDown += Int64(data.count)
            progress(1)
            return descriptor
        case .failed(let error, let partial):
            if let partial { try? write(partial, to: destination) }
            throw error
        }
    }

    public func delete(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let account = try await reach()
        deletes += Self.requests(ids.count)
        let answer = await outcome { try await cloud.audioDelete(account: account, ids: ids) }
        try await finish(.delete, ids)
        try answer.get()
    }

    public func listAll() async throws -> [AudioListing] {
        let account = try await reach()
        listings += 1
        let answer = await outcome { try await cloud.audioList(account: account) }
        try await finish(.list, [FakeCloud.audioListID])
        return try answer.get()
    }

    // MARK: Helpers

    /// Before a request: not cancelled, an account, the network up. Returns the account.
    private func reach() async throws -> String {
        if Task.isCancelled { throw AudioTransferError.cancelled }
        guard let account = await transport.signedInAccount else { throw AudioTransferError.noAccount }
        if await cloud.networkDown { throw AudioTransferError.networkUnavailable }
        return account
    }

    /// After the cloud answered: the hook once per id, then the cancellation check.
    private func finish(_ op: FakeCloud.AudioOp, _ ids: [UUID]) async throws {
        if let hook = await cloud.currentAudioHook {
            for id in ids { await hook(op, id) }
        }
        if Task.isCancelled { throw AudioTransferError.cancelled }
    }

    private func outcome<T: Sendable>(_ body: () async throws -> T) async -> Result<T, AudioTransferError> {
        do {
            return .success(try await body())
        } catch let error as AudioTransferError {
            return .failure(error)
        } catch {
            return .failure(.other(code: -1))
        }
    }

    private func write(_ data: Data, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw AudioTransferError.other(code: -1)
        }
    }

    static func requests(_ ids: Int) -> Int { (ids + AudioPolicy.batch - 1) / AudioPolicy.batch }
}
