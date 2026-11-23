import Foundation
import TranscribeCore

public struct AppPaths: Sendable {
    public let root: URL               // Application Support/Transcribe (real) | Application Support/Transcribe-Fake (fake engine)
                                       // | NSTemporaryDirectory()/transcribe-uitest-<pid> (-uiTesting)
    public var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    public var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }  // isExcludedFromBackup = true
    public var storeURL: URL { root.appendingPathComponent("Library.store") }

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

    /// Creates directories; sets file protection .completeUntilFirstUserAuthentication (iOS) on Audio/,
    /// and isExcludedFromBackup on Models/.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, audioDirectory, modelsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                             ofItemAtPath: audioDirectory.path)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var models = modelsDirectory
        try models.setResourceValues(values)
    }
}
