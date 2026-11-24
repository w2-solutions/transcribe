import Foundation
import Observation
import TranscribeCore

/// Status and the on-device prepare of the bundled speech models.
///
/// The models ship read-only inside the app, so nothing is downloaded or removed. The prepare step (load, Neural
/// Engine compile, warm-up) runs on its own at launch and on foreground, but only from `.installed`. After a
/// failure it runs again only when the user taps "Try again" (`retry()`), so a load that fails every time does not
/// repeat the costly compile on every foreground.
@MainActor @Observable
public final class ModelManager {
    public private(set) var status: ModelStatus = .installed

    /// User-facing copy shared by the Library card and the Speech models screen.
    public enum Copy {
        public static func preparing(_ p: DevicePlatform) -> String { DeviceCopy(platform: p).preparingModels }
        /// The wording for the platform this build runs on.
        public static var preparing: String { preparing(.current) }
        public static let loadFailed = "The speech models couldn't load. Try again."
    }

    @ObservationIgnored private let engine: any SpeechEngine
    @ObservationIgnored private let platform: DevicePlatform
    @ObservationIgnored private let onReady: @MainActor () -> Void
    @ObservationIgnored private var isBusy = false

    public init(engine: any SpeechEngine, platform: DevicePlatform = .current, onReady: @escaping @MainActor () -> Void) {
        self.engine = engine
        self.platform = platform
        self.onReady = onReady
    }

    // MARK: Derived state

    public var isReady: Bool { status == .ready }

    /// Reason text for `.failed`.
    public var failureText: String? {
        if case .failed(let reason) = status { return reason }
        return nil
    }

    /// Line shown while the models are being prepared; nil otherwise.
    public var phaseText: String? {
        switch status {
        case .installed, .preparing: Copy.preparing(platform)
        case .ready, .failed: nil
        }
    }

    /// Settings → Model row value: "Parakeet", "Preparing…" or "Not ready".
    public var settingsValue: String { Self.settingsValue(status, info: engine.info) }

    // MARK: Actions

    /// Reads the engine's status (left alone while a prepare is running here).
    public func refresh() async {
        guard !isBusy else { return }
        status = await engine.modelStatus()
    }

    /// Prepares the models when the engine reports them shipped but not loaded. Does nothing after a failure:
    /// that waits for `retry()`.
    public func prepareIfInstalled() async {
        guard !isBusy else { return }
        let current = await engine.modelStatus()
        guard !isBusy else { return }
        status = current
        guard current == .installed else { return }
        await prepare()
    }

    /// "Try again" after a failed prepare.
    public func retry() async {
        guard !isBusy, case .failed = status else { return }
        await prepare()
    }

    private func prepare() async {
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

    // MARK: Pure helpers (tested)

    public static func settingsValue(_ status: ModelStatus, info: EngineInfo) -> String {
        switch status {
        case .ready: info.asrDisplayName
        case .installed, .preparing: "Preparing…"
        case .failed: "Not ready"
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case EngineError.modelsMissing: ModelStatus.missingFromAppMessage
        case EngineError.failed(let text) where !text.isEmpty: text
        default: Copy.loadFailed
        }
    }
}
