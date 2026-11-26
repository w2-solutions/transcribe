import Foundation
import TranscribeCore

public struct AppPaths: Sendable {
    public let root: URL               // Application Support/Transcribe (real) | Application Support/Transcribe-Fake (fake engine)
                                       // | NSTemporaryDirectory()/transcribe-uitest-<pid> (-uiTesting)
    public var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    /// Audio sync's downloads in progress (`<id>.<ext>.part`); emptied at launch, never backed up.
    public var audioIncomingDirectory: URL { root.appendingPathComponent("AudioIncoming", isDirectory: true) }
    /// Audio sync's encoded copies waiting to upload (`<id>.m4a`); never backed up.
    public var audioOutgoingDirectory: URL { root.appendingPathComponent("AudioOutgoing", isDirectory: true) }
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

    /// "<uuid>.wav"
    public func newAudioFileName(for id: UUID) -> String { "\(id.uuidString).wav" }

    /// Creates the root, Audio/, AudioIncoming/ and AudioOutgoing/; sets file protection
    /// .completeUntilFirstUserAuthentication (iOS) on the three audio folders, and excludes the two scratch folders
    /// from backups (Audio/, downloaded copies included, stays in backups: decision 22).
    /// The speech models are read-only resources in the app bundle, so there is no models folder here.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, audioDirectory, audioIncomingDirectory, audioOutgoingDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        #if os(iOS)
        for dir in [audioDirectory, audioIncomingDirectory, audioOutgoingDirectory] {
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                 ofItemAtPath: dir.path)
        }
        #endif
        for dir in [audioIncomingDirectory, audioOutgoingDirectory] {
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        }
    }

    /// Deletes the models an older build downloaded into `Models/` (best effort). True when something was removed.
    @discardableResult public func removeLegacyModels() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyModelsDirectory.path) else { return false }
        return (try? fm.removeItem(at: legacyModelsDirectory)) != nil
    }
}
