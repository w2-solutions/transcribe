import Foundation
import TranscribeCore

public struct AppPaths: Sendable {
    public let root: URL               // Application Support/Transcribe (real) | Application Support/Transcribe-Fake (fake engine)
                                       // | NSTemporaryDirectory()/transcribe-uitest-<pid> (-uiTesting)
    public var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    /// Where builds before bundling downloaded the models (~704 MB). Deleted at launch; never used.
    public var legacyModelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var storeURL: URL { root.appendingPathComponent("Library.store") }
    /// One JSON line per speech-model prepare (timings only, the last 200; `PrepareLog` in TranscribeFluid). Written
    /// by the real engine only, never in UI tests.
    public var prepareLogURL: URL { root.appendingPathComponent("prepare-log.jsonl") }

    public init(config: LaunchConfig) {
        if config.uiTesting {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("transcribe-uitest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            root = support.appendingPathComponent(config.useFakeEngine ? "Transcribe-Fake" : "Transcribe", isDirectory: true)
        }
    }

    /// Tests.
    public init(root: URL) { self.root = root }

    public func audioURL(fileName: String) -> URL { audioDirectory.appendingPathComponent(fileName, isDirectory: false) }

    /// `Audio/Stems/`: the temporary per-stream files of recordings that captured the microphone and Mac audio.
    /// `prepare()` does not create it; the capture that writes a stem does.
    public var stemsDirectory: URL { audioDirectory.appendingPathComponent(CaptureStems.directoryName, isDirectory: true) }

    /// `Audio/Stems/<id>.mic.wav` or `<id>.system.wav`, beside the recording's `<id>.wav` (`CaptureStems.beside`).
    public func stemURL(recordingID: UUID, stream: CaptureStream) -> URL {
        stems(recordingID: recordingID).url(stream)
    }

    /// Both stems of a recording.
    public func stems(recordingID: UUID) -> CaptureStems {
        CaptureStems.beside(audioURL: audioURL(fileName: newAudioFileName(for: recordingID)))
    }

    /// "<uuid>.wav"
    public func newAudioFileName(for id: UUID) -> String { "\(id.uuidString).wav" }

    /// Creates the root and Audio/; sets file protection .completeUntilFirstUserAuthentication (iOS) on Audio/.
    /// The speech models are read-only resources in the app bundle, so there is no models folder here.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, audioDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                             ofItemAtPath: audioDirectory.path)
        #endif
    }

    /// Deletes the models an older build downloaded into `Models/` (best effort). True when something was removed.
    @discardableResult public func removeLegacyModels() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyModelsDirectory.path) else { return false }
        return (try? fm.removeItem(at: legacyModelsDirectory)) != nil
    }
}
