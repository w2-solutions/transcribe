import Foundation

/// The helper's identity for one Claude app: a random client id, its own key pair, and, once the app answered its
/// pairing request, the app's public key (pinned: a reply that does not verify against it is not Transcribe's) and the
/// two pairing nonces; and whether a call under this pairing ever got a verified 200 or 202 (`verified`).
public struct HelperIdentity: Sendable, Equatable {
    public let clientID: String
    public let name: String
    /// Stored form (raw 32 bytes, base64url). Never sent anywhere.
    let privateKey: String
    public let publicKey: String
    public private(set) var appPublicKey: String?
    /// The app's nonce and this helper's, from the pairing exchange (set together with `appPublicKey`).
    public private(set) var appNonce: String?
    public private(set) var clientNonce: String?
    /// A call under this pairing got a reply that verified against the pinned key with 200 or 202: the app this helper
    /// pinned allowed it. Such a pairing is never replaced automatically; one that never verified may be (`StdioBridge`).
    public private(set) var verified: Bool

    init?(clientID: String, name: String, privateKey: String, appPublicKey: String?, appNonce: String?,
          clientNonce: String?, verified: Bool = false) {
        guard PairingCrypto.isClientID(clientID), ClientName.sanitized(name) == name,
              let publicKey = PairingCrypto.publicKey(ofPrivate: privateKey),
              appPublicKey.map(PairingCrypto.isPublicKey) ?? true, appNonce.map(PairingCrypto.isNonce) ?? true,
              clientNonce.map(PairingCrypto.isNonce) ?? true,
              (appPublicKey == nil) == (appNonce == nil), (appNonce == nil) == (clientNonce == nil),
              !verified || appPublicKey != nil else { return nil }
        self.clientID = clientID; self.name = name; self.privateKey = privateKey; self.publicKey = publicKey
        self.appPublicKey = appPublicKey; self.appNonce = appNonce; self.clientNonce = clientNonce
        self.verified = verified
    }

    static func new(name: String) -> HelperIdentity {
        HelperIdentity(clientID: PairingCrypto.newClientID(), name: name, privateKey: PairingCrypto.newPrivateKey(),
                       appPublicKey: nil, appNonce: nil, clientNonce: nil)!
    }

    /// This identity with the app's answer to its pairing request; nil for malformed values.
    func pinned(appPublicKey: String, appNonce: String, clientNonce: String) -> HelperIdentity? {
        HelperIdentity(clientID: clientID, name: name, privateKey: privateKey, appPublicKey: appPublicKey,
                       appNonce: appNonce, clientNonce: clientNonce)
    }

    /// This pairing, marked as having had a verified answer.
    func markedVerified() -> HelperIdentity? {
        HelperIdentity(clientID: clientID, name: name, privateKey: privateKey, appPublicKey: appPublicKey,
                       appNonce: appNonce, clientNonce: clientNonce, verified: true)
    }

    /// The pairing transcript, once the app answered.
    public var pairing: String? {
        guard let appPublicKey, let appNonce, let clientNonce else { return nil }
        return PairingCrypto.transcript(clientID: clientID, clientPublicKey: publicKey, appPublicKey: appPublicKey,
                                        appNonce: appNonce, clientNonce: clientNonce)
    }

    /// The signing credentials, once the app answered.
    public var credentials: ClientCredentials? {
        guard let appPublicKey, let pairing,
              let key = PairingCrypto.sharedKey(privateKey: privateKey, peerPublicKey: appPublicKey, clientID: clientID,
                                                clientPublicKey: publicKey, appPublicKey: appPublicKey, pairing: pairing)
        else { return nil }
        return ClientCredentials(clientID: clientID, publicKey: publicKey, pairing: pairing, key: key)
    }

    /// The code for this pairing ("482 913"), once the app answered.
    public var code: String? { pairing.map(PairingCrypto.code(pairing:)) }
}

/// The helper's own state folder, in the user's real home: `~/Library/Application Support/Transcribe MCP/` (0700),
/// one file per Claude app (0600), named from its client name. The app never reads it. `TRANSCRIBE_MCP_STATE_DIR`
/// moves it (tests and the smoke script). Files are written to a 0600 temporary file opened with O_EXCL, then linked
/// (a new identity: the first of two helpers starting at once wins) or renamed (pinning the app's key) into place.
public struct HelperIdentityStore: Sendable {
    public static let folderName = "Transcribe MCP"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `TRANSCRIBE_MCP_STATE_DIR`, else `<real home>/Library/Application Support/Transcribe MCP`.
    public static func directory(environment: HelperEnvironment) -> URL {
        if let dir = environment.stateDirectory { return URL(fileURLWithPath: dir, isDirectory: true) }
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    /// The user's home from the user database (inside a sandbox `NSHomeDirectory()` would be a container).
    static var realHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    public func url(forName name: String) -> URL {
        directory.appending(path: ClientName.fileStem(name) + ".json", directoryHint: .notDirectory)
    }

    /// The saved identity for this client name; nil when there is none or it is malformed (or of an older version).
    public func load(name: String) -> HelperIdentity? {
        guard let data = try? Data(contentsOf: url(forName: name)), data.count <= 4_096,
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == File.currentVersion,
              file.clientName == name else {
            return nil
        }
        return HelperIdentity(clientID: file.clientID, name: name, privateKey: file.privateKey, appPublicKey: file.appKey,
                              appNonce: file.appNonce, clientNonce: file.clientNonce, verified: file.verified ?? false)
    }

    /// The saved identity, or a new one (saved, unpaired). If another helper saved one meanwhile, that one is used.
    public func loadOrCreate(name: String) throws -> HelperIdentity {
        if let existing = load(name: name) { return existing }
        try prepareDirectory()
        let identity = HelperIdentity.new(name: name)
        let target = url(forName: name)
        let temp = try writeTemp(identity)
        defer { unlink(temp.path) }
        if link(temp.path, target.path) == 0 { return identity }
        guard errno == EEXIST else { throw Self.posix() }
        if let winner = load(name: name) { return winner }
        // A malformed (or older) file: replace it.
        guard rename(temp.path, target.path) == 0 else { throw Self.posix() }
        return identity
    }

    /// Saves the app's public key and the two pairing nonces for this identity, before the helper reveals its nonce.
    /// If the file now holds another identity (another helper paired again meanwhile), it is left alone; the pinned
    /// identity is still returned for this call.
    @discardableResult
    public func pin(_ identity: HelperIdentity, appPublicKey: String, appNonce: String,
                    clientNonce: String) throws -> HelperIdentity {
        guard let pinned = identity.pinned(appPublicKey: appPublicKey, appNonce: appNonce, clientNonce: clientNonce) else {
            throw POSIXError(.EINVAL)
        }
        guard load(name: identity.name)?.clientID == identity.clientID else { return pinned }
        let temp = try writeTemp(pinned)
        guard rename(temp.path, url(forName: identity.name).path) == 0 else {
            let error = Self.posix()
            unlink(temp.path)
            throw error
        }
        return pinned
    }

    /// Records that this pairing got a verified 200 or 202, if the file still holds this very pairing (same client id
    /// and transcript) and it is not marked yet. Returns the identity as marked.
    @discardableResult
    public func markVerified(_ identity: HelperIdentity) throws -> HelperIdentity {
        guard let marked = identity.markedVerified() else { throw POSIXError(.EINVAL) }
        guard !identity.verified, let current = load(name: identity.name), current.clientID == identity.clientID,
              current.pairing == identity.pairing, !current.verified else { return marked }
        let temp = try writeTemp(marked)
        guard rename(temp.path, url(forName: identity.name).path) == 0 else {
            let error = Self.posix()
            unlink(temp.path)
            throw error
        }
        return marked
    }

    /// Forgets this pairing (the next call makes a new identity), unless the file already holds another identity.
    public func forget(_ identity: HelperIdentity) {
        guard load(name: identity.name)?.clientID == identity.clientID else { return }
        unlink(url(forName: identity.name).path)
    }

    // MARK: - Files

    /// Version 2 adds the pairing nonces (and, optionally, `verified`; absent reads as false); a version 1 file (before
    /// commit and reveal) reads as malformed and is replaced by a new identity.
    private struct File: Codable {
        static let currentVersion = 2
        var version = currentVersion
        var clientID: String
        var clientName: String
        var privateKey: String
        var appKey: String?
        var appNonce: String?
        var clientNonce: String?
        var verified: Bool?

        enum CodingKeys: String, CodingKey {
            case version, clientID = "client_id", clientName = "client_name", privateKey = "private_key", appKey = "app_key"
            case appNonce = "app_nonce", clientNonce = "client_nonce", verified
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw Self.posix() }
    }

    private func writeTemp(_ identity: HelperIdentity) throws -> URL {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(clientID: identity.clientID, clientName: identity.name,
                                           privateKey: identity.privateKey, appKey: identity.appPublicKey,
                                           appNonce: identity.appNonce, clientNonce: identity.clientNonce,
                                           verified: identity.verified ? true : nil))
        let temp = directory.appending(path: ".\(ClientName.fileStem(identity.name)).\(UUID().uuidString).tmp",
                                       directoryHint: .notDirectory)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Self.posix() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(temp.path)
            throw error
        }
        return temp
    }

    private static func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
