import CloudKit
import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

/// Who is signed in to iCloud, as a hash (§8.3: `sha256(userRecordID.recordName)`), and a watch on changes.
///
/// While `CKSyncEngine` runs it reports account changes itself. When sync is stopped (after a sign-out, for example)
/// nothing would notice the user signing in again, so `CloudKitTransport` also listens for `CKAccountChanged` and
/// turns a real change of account into an `.accountChange` event.
final class AccountObserver: Sendable {
    /// Immutable once `addObserver` returns, and only passed back to `removeObserver`.
    nonisolated(unsafe) private let token: any NSObjectProtocol

    /// `onChange` runs on an arbitrary queue each time CloudKit posts `CKAccountChanged` (it posts for more than sign-in
    /// and sign-out; the transport compares hashes before it reports anything).
    init(onChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in onChange() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }

    /// The hash of the signed-in account's user record name; nil when there is no account, iCloud is restricted, or
    /// the account cannot be read.
    static func currentHash(_ container: CKContainer) async -> String? {
        guard (try? await container.accountStatus()) == .available,
              let id = try? await container.userRecordID() else { return nil }
        return hash(id)
    }

    static func hash(_ id: CKRecord.ID) -> String {
        SHA256.hash(data: Data(id.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this process is signed with the iCloud container entitlement. A Mac build signed to run locally (no
    /// team) has none, and CloudKit raises an exception when such a process opens a container, so sync then reads as
    /// "no account" instead. iOS builds are always provisioned on device; the simulator honours the entitlements file.
    static func hasContainerEntitlement(_ identifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(identifier) ?? false
        #else
        return true
        #endif
    }
}
