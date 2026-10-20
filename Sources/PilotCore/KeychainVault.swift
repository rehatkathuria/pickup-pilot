import Foundation
import LocalAuthentication
import Security

public enum KeychainStorageMode: Sendable, Equatable {
    /// Requires a developer-signed app with its provisioned application identifier.
    case dataProtection
    /// Explicit local-build option: macOS login Keychain, calling-app-only ACL, no iCloud sync.
    /// Follows login Keychain locking; it cannot enforce WhenUnlockedThisDeviceOnly.
    case localLoginKeychain
}

/// Owns exactly three generic-password accounts within an app-specific service.
/// Never silently changes storage modes or falls back to ordinary files.
public actor KeychainVault: SecureVault {
    public static let defaultService = "local.pickuppilot.secrets.v1"
    private let service: String
    private let backend: any KeychainBackend

    public init(service: String = KeychainVault.defaultService, mode: KeychainStorageMode = .dataProtection) {
        self.service = service
        self.backend = SystemKeychainBackend(mode: mode)
    }

    init(service: String, backend: any KeychainBackend) {
        self.service = service
        self.backend = backend
    }

    public func saveProfile(_ profile: SecureProfile) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: profile.fields, format: .binary, options: 0)
        try save(data, account: .profile)
    }

    public func loadProfile() throws -> SecureProfile? {
        guard let data = try load(account: .profile) else { return nil }
        do {
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let fields = object as? [String: String] else { throw SecureVaultError.malformedProfile }
            return try SecureProfile(fields: fields)
        } catch {
            throw SecureVaultError.malformedProfile
        }
    }

    public func deleteProfile() throws { try delete(account: .profile) }
    public func saveSession(_ data: Data) throws { try save(data, account: .session) }
    public func loadSession() throws -> Data? { try load(account: .session) }
    public func deleteSession() throws { try delete(account: .session) }
    public func saveOrderState(_ data: Data) throws { try save(data, account: .orderState) }
    public func loadOrderState() throws -> Data? { try load(account: .orderState) }
    public func deleteOrderState() throws { try delete(account: .orderState) }

    public func clear() throws {
        // Attempt all exact accounts, even when one item is inaccessible.
        var firstError: (any Error)?
        do { try deleteProfile() } catch { firstError = error }
        do { try deleteSession() } catch { if firstError == nil { firstError = error } }
        do { try deleteOrderState() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    private func save(_ data: Data, account: KeychainAccount) throws {
        let item = KeychainItem(service: service, account: account)
        let status = backend.add(item, data: data)
        if status == errSecDuplicateItem {
            try check(backend.update(item, data: data), operation: "update")
        } else {
            try check(status, operation: "save")
        }
    }

    private func load(account: KeychainAccount) throws -> Data? {
        let result = backend.copy(KeychainItem(service: service, account: account))
        if result.status == errSecItemNotFound { return nil }
        try check(result.status, operation: "read")
        guard let data = result.data else { throw SecureVaultError.unexpectedKeychainResult }
        return data
    }

    private func delete(account: KeychainAccount) throws {
        let status = backend.delete(KeychainItem(service: service, account: account))
        if status != errSecItemNotFound { try check(status, operation: "delete") }
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else { throw SecureVaultError.keychain(operation: operation, status: status) }
    }
}

enum KeychainAccount: String, Sendable {
    case profile = "checkout-profile-v1", session = "apple-session-v1", orderState = "order-state-v1"
}
struct KeychainItem: Sendable, Equatable { let service: String; let account: KeychainAccount }
struct KeychainReadResult: Sendable { let status: OSStatus; let data: Data? }

protocol KeychainBackend: Sendable {
    func add(_ item: KeychainItem, data: Data) -> OSStatus
    func update(_ item: KeychainItem, data: Data) -> OSStatus
    func copy(_ item: KeychainItem) -> KeychainReadResult
    func delete(_ item: KeychainItem) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    var mode: KeychainStorageMode = .dataProtection
    var accessCreator: @Sendable () -> (OSStatus, SecAccess?) = {
        var access: SecAccess?
        // Apple's file-based Keychain API is deprecated but is the supported local-build
        // option without a provisioned developer identity. nil trusts only this app.
        let status = SecAccessCreate("Pickup Pilot private checkout data" as CFString, nil, &access)
        return (status, access)
    }

    static func query(_ item: KeychainItem, mode: KeychainStorageMode = .dataProtection) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: item.service,
         kSecAttrAccount as String: item.account.rawValue,
         kSecAttrSynchronizable as String: false,
         // Required for the accessibility class to have meaning on macOS.
         kSecUseDataProtectionKeychain as String: mode == .dataProtection,
         // Never block the monitor or tests on a modal authentication prompt.
         kSecUseAuthenticationContext as String: context]
    }

    static func attributes(data: Data, mode: KeychainStorageMode = .dataProtection) -> [String: Any] {
        var attributes: [String: Any] = [kSecValueData as String: data]
        if mode == .dataProtection { attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        return attributes
    }

    func add(_ item: KeychainItem, data: Data) -> OSStatus {
        var query = Self.query(item, mode: mode)
        for (key, value) in Self.attributes(data: data, mode: mode) { query[key] = value }
        if mode == .localLoginKeychain {
            let (status, access) = accessCreator()
            guard status == errSecSuccess else { return status }
            guard let access else { return errSecInternalComponent }
            query[kSecAttrAccess as String] = access
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(_ item: KeychainItem, data: Data) -> OSStatus {
        SecItemUpdate(Self.query(item, mode: mode) as CFDictionary, Self.attributes(data: data, mode: mode) as CFDictionary)
    }

    func copy(_ item: KeychainItem) -> KeychainReadResult {
        var query = Self.query(item, mode: mode)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return KeychainReadResult(status: status, data: result as? Data)
    }

    func delete(_ item: KeychainItem) -> OSStatus { SecItemDelete(Self.query(item, mode: mode) as CFDictionary) }
}
