import Foundation
import Synchronization

/// The Mac app's install id: a random UUID string kept in `root/InstallID` (inside the app's sandbox container).
///
/// The Mac uses a file rather than the Keychain, so a Developer ID build needs no keychain prompt and no
/// keychain-access-group profile. The id is never used to delete anything.
///
/// Returns an empty string when the file can be neither read nor written ("unknown").
public struct FileDeviceIdentity: DeviceIdentity {
    public static let fileName = "InstallID"
    private static let lock = Mutex<Void>(())

    let root: URL

    public init(root: URL) { self.root = root }

    var fileURL: URL { root.appending(path: Self.fileName, directoryHint: .notDirectory) }

    public func installID() -> String {
        Self.lock.withLock { _ in
            if let existing = read() { return existing }
            let fresh = UUID().uuidString
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(fresh.utf8).write(to: fileURL, options: [.atomic])
            } catch {
                return ""
            }
            return fresh
        }
    }

    private func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
