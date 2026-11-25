import Foundation
import TranscribeMCP

/// `<AppPaths.root>/ClaudeAccess.json` (D8): the switch, the app's own pairing key pair and the Claude apps the user
/// allowed. Owner-only (0600), written atomically. No Keychain (no prompt on Developer ID builds) and no UserDefaults.
/// Version 3 (allowed apps carry the pairing transcript they were allowed with); a file of any other version (the
/// access-key design and pairing before commit and reveal, never shipped) reads as none, so the switch is off.
struct ClaudeAccessFile: Codable, Equatable {
    static let currentVersion = 3

    var version = currentVersion
    var enabled: Bool
    /// The app's private key (raw 32 bytes, base64url).
    var appKey: String
    var allowed: [AllowedClient]

    enum CodingKeys: String, CodingKey { case version, enabled, appKey = "app_key", allowed }

    static let name = "ClaudeAccess.json"

    static func url(root: URL) -> URL { root.appendingPathComponent(name, isDirectory: false) }

    /// The saved state; nil when there is none or it is malformed (another version, or a bad key). An allowed app that
    /// is malformed, or repeats an earlier one's client id, is left out rather than losing the key and every other app.
    static func load(root: URL) -> ClaudeAccessFile? {
        guard let data = try? Data(contentsOf: url(root: root)),
              var file = try? decoder.decode(ClaudeAccessFile.self, from: data),
              file.version == currentVersion, PairingCrypto.publicKey(ofPrivate: file.appKey) != nil else { return nil }
        var seen = Set<String>()
        file.allowed = file.allowed.filter { $0.isValid && seen.insert($0.id).inserted }
        return file
    }

    /// Creates `root` if needed (the app saves before `AppPaths.prepare` runs), then writes a 0600 temporary file and
    /// renames it over the old one, so the private key is never readable by others, even for a moment.
    func save(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let target = Self.url(root: root)
        let temp = root.appendingPathComponent(".\(Self.name).\(UUID().uuidString)", isDirectory: false)
        // Created 0600 by open(2) itself (FileManager.createFile writes first and applies its attributes afterwards).
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
