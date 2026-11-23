import Foundation
import Security
import Synchronization

/// Random UUID kept in the Keychain with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
///
/// "ThisDeviceOnly" items are never restored onto another device, so a store restored from a backup
/// sees a different id and `LibraryStore.reconcileDevice()` wipes the voice samples (voices are per device).
///
/// Returns an empty string when the Keychain cannot be read (for example before first unlock), which
/// `reconcileDevice` treats as "unknown": it never wipes on an unknown id.
public struct KeychainDeviceIdentity: DeviceIdentity {
    static let service = "ai.w2solutions.transcribe.device"
    static let account = "install-id"
    private static let cache = Mutex<String?>(nil)

    let service: String
    let account: String

    public init() { self.init(service: Self.service, account: Self.account) }

    /// Tests: a separate item.
    init(service: String, account: String) { self.service = service; self.account = account }

    public func installID() -> String {
        let isDefault = service == Self.service && account == Self.account
        if isDefault, let cached = Self.cache.withLock({ $0 }) { return cached }
        let id: String
        switch read() {
        case .found(let value):
            id = value
        case .missing:
            let fresh = UUID().uuidString
            switch add(fresh) {
            case errSecSuccess: id = fresh
            case errSecDuplicateItem:
                // Another caller won the race: use theirs.
                guard case .found(let value) = read() else { return "" }
                id = value
            default: return ""
            }
        case .unavailable:
            return ""
        }
        if isDefault { Self.cache.withLock { $0 = id } }
        return id
    }

    /// Removes the item (tests only).
    func reset() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private enum ReadResult { case found(String), missing, unavailable }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read() -> ReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return .unavailable }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    private func add(_ value: String) -> OSStatus {
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }
}
