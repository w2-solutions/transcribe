import FluidAudio
import Foundation
import os
import TranscribeCore

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
        if error is CancellationError || error is PrepareInterruption { return .cancelled }
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
            case .modelsMissing: return ModelStatus.missingFromAppMessage
            case .noSpeech: return "No speech found"
            case .tooShort: return "The recording is too short"
            case .microphoneDenied: return "Microphone access is off"
            case .sourceUnavailable: return "Mac audio can't be recorded here"
            case .cancelled: return "Cancelled"
            }
        }
        if let pause = error as? PrepareInterruption { return "Paused (\(pause.reason.rawValue))" }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
        return (error as NSError).localizedDescription
    }
}

/// A prepare stopped because the app went to the background (`PreparePauseReason`). Not a failure: it maps to
/// `EngineError.cancelled`, sets no load failure, and the next prepare (on return to the front) carries on.
struct PrepareInterruption: Error, Sendable, Equatable {
    let reason: PreparePauseReason
}
