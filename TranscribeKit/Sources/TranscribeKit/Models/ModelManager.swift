import Foundation
import Network
import Observation
import TranscribeCore

/// Owns the speech-model lifecycle for the UI: status, download progress, the network-cost and free-space
/// checks shown before a download, install → prepare → ready, and removal.
@MainActor @Observable
public final class ModelManager {
    public private(set) var status: ModelStatus = .notInstalled
    public private(set) var isExpensiveNetwork = false        // NWPathMonitor
    public private(set) var freeBytes: Int64?                 // volumeAvailableCapacityForImportantUsage
    public static let requiredFreeBytes: Int64 = 1_500_000_000

    /// User-facing copy shared by the Library card and the Speech models screen.
    public enum Copy {
        public static let lowSpace = "Free up about 1.5 GB to download the models."
        public static let wifiRecommended = "Wi-Fi recommended"
        public static let preparing = "Preparing for this iPhone… (one time, about a minute)"
        public static let checking = "Checking what's already on this iPhone…"
        public static let downloadFailed = "The download didn't finish. Check your connection and try again."
    }

    @ObservationIgnored private let engine: any SpeechEngine
    @ObservationIgnored private let onReady: @MainActor () -> Void
    @ObservationIgnored private let freeSpaceProvider: @MainActor () -> Int64?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var isBusy = false
    /// Runs before the models are removed, so nothing is using them: `AppEnvironment` wires it to
    /// `ProcessingCoordinator.suspendForModelRemoval()` (the running job waits for the models again).
    @ObservationIgnored public var beforeRemove: @MainActor () async -> Void = {}

    public convenience init(engine: any SpeechEngine, onReady: @escaping @MainActor () -> Void) {
        self.init(engine: engine, monitorsNetwork: true, freeSpace: { ModelManager.systemFreeBytes() }, onReady: onReady)
    }

    /// Full initialiser. Tests pass `monitorsNetwork: false` and a fixed `freeSpace`.
    public init(engine: any SpeechEngine, monitorsNetwork: Bool,
                freeSpace: @escaping @MainActor () -> Int64?, onReady: @escaping @MainActor () -> Void) {
        self.engine = engine
        self.onReady = onReady
        self.freeSpaceProvider = freeSpace
        self.freeBytes = freeSpace()
        if monitorsNetwork { startNetworkMonitor() }
    }

    isolated deinit {
        pathMonitor?.cancel()
    }

    // MARK: Derived state

    /// "704 MB" (real engine)
    public var downloadSizeText: String { Self.megabytes(engine.info.totalDownloadBytes) }
    public var speechSizeText: String { Self.megabytes(engine.info.speechDownloadBytes) }
    public var speakersSizeText: String { Self.megabytes(engine.info.speakersDownloadBytes) }

    public var isReady: Bool { status == .ready }

    /// False when the volume reports less than 1.5 GB free. Unknown free space never blocks a download.
    public var hasEnoughSpace: Bool { freeBytes.map { $0 >= Self.requiredFreeBytes } ?? true }

    /// A download can start from this state (nothing running, not already installed).
    public var canInstall: Bool {
        switch status {
        case .notInstalled, .failed: !isBusy && hasEnoughSpace
        case .installing, .installed, .preparing, .ready: false
        }
    }

    public var canRemove: Bool {
        switch status {
        case .installed, .ready, .failed: !isBusy
        case .notInstalled, .installing, .preparing: false
        }
    }

    /// Overall install fraction while downloading; nil otherwise.
    public var installFraction: Double? {
        if case .installing(let p) = status { return p.fraction }
        return nil
    }

    /// Phase line under the progress bar ("Downloading speech model · 212 of 483 MB").
    public var phaseText: String? {
        switch status {
        case .installing(let p): Self.phaseText(p, info: engine.info)
        case .preparing, .installed: Copy.preparing
        default: nil
        }
    }

    /// Settings → Model row value: "Parakeet", "Preparing…", "Not downloaded", "Downloading 42%".
    public var settingsValue: String { Self.settingsValue(status, info: engine.info) }

    /// Reason text for `.failed`.
    public var failureText: String? {
        if case .failed(let reason) = status { return reason }
        return nil
    }

    // MARK: Actions

    /// engine.modelStatus(), plus a fresh free-space reading.
    public func refresh() async {
        refreshFreeSpace()
        guard !isBusy else { return }
        status = await engine.modelStatus()
    }

    public func refreshFreeSpace() {
        freeBytes = freeSpaceProvider()
    }

    /// install → prepare → .ready → onReady(). Refuses (with a failed status) when space is short.
    public func install() async {
        guard !isBusy else { return }
        refreshFreeSpace()
        guard hasEnoughSpace else {
            status = .failed(Copy.lowSpace)
            return
        }
        isBusy = true
        defer { isBusy = false }
        status = .installing(ModelInstallProgress(fraction: 0, phase: .checking))
        do {
            try await engine.installModels { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .installing(let current) = self.status else { return }
                    // Progress callbacks can arrive out of order once they hop actors; never move backwards.
                    guard progress.fraction >= current.fraction else { return }
                    self.status = .installing(progress)
                }
            }
            status = .preparing
            try await engine.prepareModels()
            status = .ready
            refreshFreeSpace()
            onReady()
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    public func prepareIfInstalled() async {
        guard !isBusy else { return }
        let current = await engine.modelStatus()
        guard !isBusy else { return }
        status = current
        guard current == .installed else { return }
        isBusy = true
        defer { isBusy = false }
        status = .preparing
        do {
            try await engine.prepareModels()
            status = .ready
            onReady()
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    public func remove() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await beforeRemove()
        do {
            try await engine.removeModels()
        } catch {
            status = .failed(Self.message(for: error))
            // Nothing was removed: let the held processing queue carry on.
            if await engine.modelStatus() == .ready { onReady() }
            return
        }
        status = await engine.modelStatus()
        refreshFreeSpace()
    }

    // MARK: Pure helpers (tested)

    public static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    public static func phaseText(_ progress: ModelInstallProgress, info: EngineInfo) -> String {
        switch progress.phase {
        case .checking:
            return Copy.checking
        case .downloading(.speech, _, _):
            let speechShare = Double(info.speechDownloadBytes) / Double(max(1, info.totalDownloadBytes))
            let totalMB = Int((Double(info.speechDownloadBytes) / 1_000_000).rounded())
            let doneMB = Int((min(1, max(0, progress.fraction) / max(speechShare, 0.0001)) * Double(totalMB)).rounded())
            return "Downloading speech model · \(doneMB) of \(totalMB) MB"
        case .downloading(.speakers, _, _):
            return "Speaker models · \(megabytes(info.speakersDownloadBytes))"
        case .compiling:
            return Copy.preparing
        }
    }

    public static func settingsValue(_ status: ModelStatus, info: EngineInfo) -> String {
        switch status {
        case .ready: info.asrDisplayName
        case .installed, .preparing: "Preparing…"
        case .notInstalled: "Not downloaded"
        case .installing(let p): "Downloading \(Int((p.fraction * 100).rounded()))%"
        case .failed: "Download failed"
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case EngineError.failed(let text) where !text.isEmpty: text
        case EngineError.cancelled: "The download was cancelled."
        default: Copy.downloadFailed
        }
    }

    /// Free space on the volume that holds the app's data, as iOS reports it for user-requested downloads.
    nonisolated static func systemFreeBytes() -> Int64? {
        let url = URL.homeDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Network

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor in self?.isExpensiveNetwork = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "ai.w2solutions.transcribe.network", qos: .utility))
        pathMonitor = monitor
    }

    /// Tests: simulate a cellular / hotspot path.
    func setExpensiveNetworkForTesting(_ expensive: Bool) { isExpensiveNetwork = expensive }
}
