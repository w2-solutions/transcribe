import FluidAudio
import Foundation
import os
import TranscribeCore

// MARK: - Install progress

/// What FluidAudio's `DownloadProgress` says, without the FluidAudio types (so it can be unit tested).
enum RawInstallPhase: Sendable, Equatable {
    case listing
    case downloading(completedFiles: Int, totalFiles: Int)
    case compiling
}

/// Turns FluidAudio's per-call download/compile progress into the contract's overall install progress.
///
/// FluidAudio reports each `ModelHub.loadModels` call as its own 0...1 operation (download 0...0.5,
/// compile 0.5...1), and `AsrModels.download` makes four such calls (one per model; the first downloads
/// the whole repo). So the raw fraction restarts several times. Nemotron 3's subdirectory download reports
/// download only (0...1, no compile phase). This mapper:
/// - gives each model set a byte-weighted slice of the overall bar: speech, then community-1, then Nemotron 3
///   (483 / 22 / 199 MB → 0...0.686, 0.686...0.717, 0.717...1);
/// - spends 90% of a slice on the download and 10% on compile events, counted against an expected total;
/// - never lets the reported fraction go backwards.
struct InstallProgressMapper: Sendable {
    /// Byte-weighted slices of the overall bar.
    static let speechShare = Double(FluidModelPaths.speechDownloadBytes) / Double(FluidModelPaths.totalDownloadBytes)
    static let communityOneShare = Double(FluidModelPaths.communityOneDownloadBytes) / Double(FluidModelPaths.totalDownloadBytes)
    static let downloadPortion = 0.9
    /// FluidAudio's repo-load download phase weight (`ProgressReporter(downloadPhaseWeight: 0.5)`).
    static let rawDownloadWeight = 0.5

    let component: ModelComponent
    let base: Double
    let share: Double
    let expectedCompileEvents: Int
    /// The raw fraction at which FluidAudio's download phase ends (0.5 for repo loads, 1 for subdirectory downloads).
    let downloadWeight: Double
    /// A subdirectory download emits no compile events; the model load that follows it (the first Neural Engine
    /// compile for Nemotron 3) is reported as compiling once every byte has arrived.
    let compilesAfterDownload: Bool
    private var compileEvents = 0
    private var componentHighWater = 0.0

    init(component: ModelComponent, base: Double, share: Double, expectedCompileEvents: Int,
         downloadWeight: Double = InstallProgressMapper.rawDownloadWeight, compilesAfterDownload: Bool = false) {
        self.component = component
        self.base = base
        self.share = share
        self.expectedCompileEvents = Swift.max(1, expectedCompileEvents)
        self.downloadWeight = downloadWeight
        self.compilesAfterDownload = compilesAfterDownload
    }

    /// AsrModels.download: four single-model loads, each emitting `compiling(name)` then `finished`.
    static func speech() -> InstallProgressMapper {
        InstallProgressMapper(component: .speech, base: 0, share: speechShare, expectedCompileEvents: 8)
    }
    /// OfflineDiarizerModels.load: a three-model load and a one-model load, each followed by `finished`.
    static func speakers() -> InstallProgressMapper {
        InstallProgressMapper(component: .speakers, base: speechShare, share: communityOneShare, expectedCompileEvents: 6)
    }
    /// Nemotron3Models.loadFromHuggingFace: one subdirectory download (download weight 1, no compile events),
    /// then a model load with no callback. Fills the rest of the bar.
    static func nemotron() -> InstallProgressMapper {
        let base = speechShare + communityOneShare
        return InstallProgressMapper(component: .speakers, base: base, share: 1 - base, expectedCompileEvents: 1,
                                     downloadWeight: 1, compilesAfterDownload: true)
    }

    mutating func map(fraction raw: Double, phase: RawInstallPhase) -> ModelInstallProgress {
        let r = raw.isFinite ? Swift.min(1, Swift.max(0, raw)) : 0
        let local: Double
        let outPhase: ModelInstallProgress.Phase
        switch phase {
        case .listing:
            local = 0
            outPhase = componentHighWater == 0 ? .checking : .downloading(component, completedFiles: 0, totalFiles: 0)
        case .downloading(let done, let total):
            local = Swift.min(1, r / Swift.max(downloadWeight, 0.0001)) * Self.downloadPortion
            outPhase = compilesAfterDownload && r >= downloadWeight
                ? .compiling(component) : .downloading(component, completedFiles: done, totalFiles: total)
        case .compiling:
            compileEvents += 1
            let c = Double(Swift.min(compileEvents, expectedCompileEvents)) / Double(expectedCompileEvents)
            local = Self.downloadPortion + (1 - Self.downloadPortion) * c * 0.999
            outPhase = .compiling(component)
        }
        componentHighWater = Swift.max(componentHighWater, local)
        return ModelInstallProgress(fraction: base + share * componentHighWater, phase: outPhase)
    }

    /// The component finished: its share is complete.
    mutating func finished() -> ModelInstallProgress {
        componentHighWater = 1
        return ModelInstallProgress(fraction: base + share, phase: .compiling(component))
    }
}

extension RawInstallPhase {
    init(_ phase: DownloadPhase) {
        switch phase {
        case .listing: self = .listing
        case .downloading(let done, let total): self = .downloading(completedFiles: done, totalFiles: total)
        case .compiling: self = .compiling
        }
    }
}

/// Serialises FluidAudio's progress callbacks (they arrive on unspecified queues) through one mapper.
final class LockedInstallProgress: Sendable {
    private let state: OSAllocatedUnfairLock<InstallProgressMapper>
    private let sink: @Sendable (ModelInstallProgress) -> Void

    init(_ mapper: InstallProgressMapper, sink: @escaping @Sendable (ModelInstallProgress) -> Void) {
        state = OSAllocatedUnfairLock(initialState: mapper)
        self.sink = sink
    }

    func report(_ progress: DownloadProgress) {
        let mapped = state.withLock { $0.map(fraction: progress.fractionCompleted, phase: RawInstallPhase(progress.phase)) }
        sink(mapped)
    }

    func finish() {
        sink(state.withLock { $0.finished() })
    }

    var handler: ProgressHandler { { [self] in report($0) } }
}

// MARK: - Transcription progress

/// Counts finished ASR windows (they may finish out of order) and reports done / total, never going backwards.
final class WindowProgressCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (done: Set<Int>(), last: 0.0))
    private let sink: @Sendable (Double) -> Void

    init(sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }

    func windowFinished(index: Int, of count: Int) {
        guard count > 0 else { return }
        let value: Double? = state.withLock { s in
            s.done.insert(index)
            // Keep the last few percent for the seam merge that follows the windows.
            let f = Swift.min(0.99, Double(s.done.count) / Double(count))
            guard f > s.last else { return nil }
            s.last = f
            return f
        }
        if let value { sink(value) }
    }
}

// MARK: - Errors

enum FluidErrorMapping {
    /// Maps FluidAudio / system errors onto the engine contract.
    static func engineError(_ error: any Error) -> EngineError {
        if let e = error as? EngineError { return e }
        if error is CancellationError { return .cancelled }
        if let e = error as? URLError, e.code == .cancelled { return .cancelled }
        if let e = error as? ASRError {
            switch e {
            case .invalidAudioData: return .tooShort
            case .notInitialized: return .modelsMissing
            default: return .failed(describe(e))
            }
        }
        if let e = error as? OfflineDiarizationError {
            switch e {
            case .noSpeechDetected: return .noSpeech
            case .modelNotLoaded: return .modelsMissing
            default: return .failed(describe(e))
            }
        }
        if error is Nemotron3Error { return .failed(describe(error)) }
        if let e = error as? DownloadError {
            if case .modelMissing = e { return .modelsMissing }
            return .failed(describe(e))
        }
        return .failed(describe(error))
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? EngineError {
            switch e {
            case .failed(let message): return message
            case .modelsMissing: return "Speech models are not installed"
            case .noSpeech: return "No speech found"
            case .tooShort: return "The recording is too short"
            case .microphoneDenied: return "Microphone access is off"
            case .cancelled: return "Cancelled"
            }
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
        return (error as NSError).localizedDescription
    }
}
