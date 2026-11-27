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
    /// Dictation audio (Mac): one short WAV per dictation, deleted as soon as it is transcribed, and leftovers at
    /// launch (`clearDictationFiles`). Never in Audio/, never in the library, never synced, excluded from backups.
    public var dictationDirectory: URL { root.appendingPathComponent("Dictation", isDirectory: true) }

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

    /// Creates `Dictation/` and excludes it from backups.
    public func prepareDictation() throws {
        try FileManager.default.createDirectory(at: dictationDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dictationDirectory
        try url.setResourceValues(values)
    }

    /// "Dictation/dictation-<uuid>.wav": the prefix tells the fake engine it is dictation.
    public func newDictationURL() -> URL {
        dictationDirectory.appendingPathComponent("\(DictationFiles.prefix)\(UUID().uuidString).wav", isDirectory: false)
    }

    /// A dictation file not modified for this long belongs to no running dictation: the longest one records for
    /// `DictationLimits.handsFreeMax` (the file is written all that time) and then waits at most
    /// `DictationLimits.modelsWaitCap` for the models before it is transcribed and deleted.
    public static let dictationLeftoverAge: TimeInterval = 3_600

    /// Removes dictation audio left by a crash or a quit mid-dictation (best effort). Only at launch, before this
    /// process can start a dictation.
    ///
    /// With no other copy of Transcribe running, the whole `Dictation/` folder goes. While another copy runs it may be
    /// dictating into this same folder (a Debug build and `/Applications/Transcribe.app` share one container), so then
    /// only files untouched for `dictationLeftoverAge` go.
    public func clearDictationFiles(otherCopyRunning: Bool = false, now: Date = Date()) {
        let fm = FileManager.default
        guard otherCopyRunning else {
            try? fm.removeItem(at: dictationDirectory)
            return
        }
        let files = (try? fm.contentsOfDirectory(at: dictationDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) >= Self.dictationLeftoverAge else { continue }
            try? fm.removeItem(at: file)
        }
    }

    /// Deletes the models an older build downloaded into `Models/` (best effort). True when something was removed.
    @discardableResult public func removeLegacyModels() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyModelsDirectory.path) else { return false }
        return (try? fm.removeItem(at: legacyModelsDirectory)) != nil
    }
}
