import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing
@testable import PilotCore

private final class SyntheticKeychainBackend: KeychainBackend {
    struct State {
        var values: [String: Data] = [:]
        var addStatus: OSStatus?
        var updateStatus: OSStatus?
        var copyStatus: OSStatus?
        var nilCopyData = false
        var deleteStatuses: [String: OSStatus] = [:]
        var deletes: [String] = []
        var copies: [(account: KeychainAccount, allowsAuthentication: Bool)] = []
    }
    let state = Mutex(State())
    private func key(_ item: KeychainItem) -> String { item.service + "/" + item.account.rawValue }
    func add(_ item: KeychainItem, data: Data) -> OSStatus {
        state.withLock {
            if let status = $0.addStatus { return status }
            if $0.values[key(item)] != nil { return errSecDuplicateItem }
            $0.values[key(item)] = data
            return errSecSuccess
        }
    }
    func update(_ item: KeychainItem, data: Data) -> OSStatus {
        state.withLock {
            if let status = $0.updateStatus { return status }
            $0.values[key(item)] = data
            return errSecSuccess
        }
    }
    func copy(_ item: KeychainItem) -> KeychainReadResult {
        copy(item, allowingAuthentication: false)
    }
    func copyAllowingAuthentication(_ item: KeychainItem) -> KeychainReadResult {
        copy(item, allowingAuthentication: true)
    }
    private func copy(_ item: KeychainItem, allowingAuthentication: Bool) -> KeychainReadResult {
        state.withLock {
            $0.copies.append((item.account, allowingAuthentication))
            if let status = $0.copyStatus { return KeychainReadResult(status: status, data: nil) }
            if $0.nilCopyData { return KeychainReadResult(status: errSecSuccess, data: nil) }
            guard let data = $0.values[key(item)] else { return KeychainReadResult(status: errSecItemNotFound, data: nil) }
            return KeychainReadResult(status: errSecSuccess, data: data)
        }
    }
    func delete(_ item: KeychainItem) -> OSStatus {
        state.withLock {
            $0.deletes.append(item.account.rawValue)
            if let status = $0.deleteStatuses[item.account.rawValue] { return status }
            return $0.values.removeValue(forKey: key(item)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

@Test func keychainSecurityQueryIsExactAndDeviceLocal() {
    #expect(SystemKeychainBackend().mode == .dataProtection)
    let item = KeychainItem(service: "local.pickuppilot.tests.synthetic", account: .profile)
    let query = SystemKeychainBackend.query(item)
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService as String] as? String == item.service)
    #expect(query[kSecAttrAccount as String] as? String == "checkout-profile-v1")
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    // Sandboxed CLI tests cannot connect to LocalAuthentication: its property
    // setter is ignored there. Check the actual flag in the real integration test.
    #expect(query[kSecUseAuthenticationContext as String] is LAContext)
    #expect(query[kSecAttrAccessGroup as String] == nil)
    #expect(query[kSecValueData as String] == nil)
    let attributes = SystemKeychainBackend.attributes(data: Data([1, 2, 3]))
    #expect(attributes[kSecValueData as String] as? Data == Data([1, 2, 3]))
    #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    #expect(attributes.count == 2)
    let legacyQuery = SystemKeychainBackend.query(item, mode: .localLoginKeychain)
    #expect(legacyQuery[kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(legacyQuery[kSecAttrSynchronizable as String] as? Bool == false)
    let legacyAttributes = SystemKeychainBackend.attributes(data: Data([1]), mode: .localLoginKeychain)
    #expect(legacyAttributes.count == 1)
    #expect(legacyAttributes[kSecAttrAccessible as String] == nil)
    let restoreQuery = SystemKeychainBackend.query(item, mode: .localLoginKeychain, allowingAuthentication: true)
    #expect((restoreQuery[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == false)
    #expect(restoreQuery[kSecAttrService as String] as? String == item.service)
    #expect(restoreQuery[kSecAttrAccount as String] as? String == "checkout-profile-v1")
    #expect(restoreQuery[kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(restoreQuery[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(restoreQuery[kSecAttrAccess as String] == nil)
    #expect(restoreQuery[kSecValueData as String] == nil)
}

@Test func explicitProfileRestoreUsesAnInteractiveReadWithoutRewritingAnyAccount() async throws {
    let backend = SyntheticKeychainBackend()
    let vault = KeychainVault(service: "local.pickuppilot.tests.restore", backend: backend)
    let profile = syntheticSecureProfile()
    try await vault.saveProfile(profile)
    try await vault.saveSession(Data([1]))
    try await vault.saveOrderState(Data([2]))
    let original = backend.state.withLock { $0.values }
    #expect(try await vault.loadProfileForUserInitiatedRestore() == profile)
    let secureVault: any SecureVault = vault
    #expect(try await secureVault.loadProfileForUserInitiatedRestore() == profile)
    #expect(try await vault.loadProfile() == profile)
    #expect(try await vault.loadSession() == Data([1]))
    #expect(try await vault.loadOrderState() == Data([2]))
    let requests = backend.state.withLock { $0.copies }
    #expect(requests.map(\.account) == [.profile, .profile, .profile, .session, .orderState])
    #expect(requests.map(\.allowsAuthentication) == [true, true, false, false, false])
    #expect(backend.state.withLock { $0.values } == original)
    #expect(backend.state.withLock { $0.deletes.isEmpty })
}

@Test func keychainACLFailureCannotCreateAnUnprotectedItem() {
    let item = KeychainItem(service: "local.pickuppilot.tests.never-created", account: .profile)
    let failing = SystemKeychainBackend(mode: .localLoginKeychain, accessCreator: { (errSecAuthFailed, nil) })
    #expect(failing.add(item, data: Data([1])) == errSecAuthFailed)
    let missing = SystemKeychainBackend(mode: .localLoginKeychain, accessCreator: { (errSecSuccess, nil) })
    #expect(missing.add(item, data: Data([1])) == errSecInternalComponent)
}

@Test func keychainProfileSessionAndOrderStateRoundTripUpdateAndClear() async throws {
    let backend = SyntheticKeychainBackend()
    let vault = KeychainVault(service: "local.pickuppilot.tests.synthetic", backend: backend)
    #expect(try await vault.loadProfile() == nil)
    #expect(try await vault.loadSession() == nil)
    #expect(try await vault.loadOrderState() == nil)
    let original = syntheticSecureProfile()
    try await vault.saveProfile(original)
    #expect(try await vault.loadProfile() == original)
    var changed = original
    changed.cvv = "456"
    changed.billingLine1 = "2 Test Street"
    try await vault.saveProfile(changed)
    #expect(try await vault.loadProfile() == changed)
    try await vault.saveSession(Data("synthetic-cookie".utf8))
    #expect(try await vault.loadSession() == Data("synthetic-cookie".utf8))
    try await vault.saveSession(Data("synthetic-cookie-2".utf8))
    #expect(try await vault.loadSession() == Data("synthetic-cookie-2".utf8))
    try await vault.saveOrderState(Data("synthetic-pending-order".utf8))
    #expect(try await vault.loadOrderState() == Data("synthetic-pending-order".utf8))
    try await vault.saveOrderState(Data("synthetic-order".utf8))
    #expect(try await vault.loadOrderState() == Data("synthetic-order".utf8))
    try await vault.clear()
    #expect(try await vault.loadProfile() == nil)
    #expect(try await vault.loadSession() == nil)
    #expect(try await vault.loadOrderState() == nil)
    try await vault.clear()
}

@Test func keychainServiceAndAccountIsolation() async throws {
    let backend = SyntheticKeychainBackend()
    let first = KeychainVault(service: "local.pickuppilot.tests.first", backend: backend)
    let second = KeychainVault(service: "local.pickuppilot.tests.second", backend: backend)
    try await first.saveProfile(syntheticSecureProfile())
    try await second.saveProfile(SecureProfile(cvv: "456"))
    try await first.saveSession(Data([7]))
    try await first.deleteProfile()
    #expect(try await first.loadProfile() == nil)
    #expect(try await first.loadSession() == Data([7]))
    try await first.clear()
    #expect(try await second.loadProfile() == SecureProfile(cvv: "456"))
}

@Test func keychainSaveReadAndUpdateErrorsAreSurfacedWithoutSecrets() async throws {
    let backend = SyntheticKeychainBackend()
    let vault = KeychainVault(service: "local.pickuppilot.tests.errors", backend: backend)
    backend.state.withLock { $0.addStatus = errSecInteractionNotAllowed }
    await #expect(throws: SecureVaultError.keychain(operation: "save", status: errSecInteractionNotAllowed)) {
        try await vault.saveProfile(syntheticSecureProfile())
    }
    backend.state.withLock { $0.addStatus = nil }
    try await vault.saveSession(Data([1]))
    backend.state.withLock { $0.updateStatus = errSecAuthFailed }
    await #expect(throws: SecureVaultError.keychain(operation: "update", status: errSecAuthFailed)) {
        try await vault.saveSession(Data([2]))
    }
    backend.state.withLock { $0.copyStatus = errSecInteractionNotAllowed }
    await #expect(throws: SecureVaultError.keychain(operation: "read", status: errSecInteractionNotAllowed)) {
        try await vault.loadProfile()
    }
    backend.state.withLock { $0.copyStatus = nil; $0.nilCopyData = true }
    await #expect(throws: SecureVaultError.unexpectedKeychainResult) { try await vault.loadProfile() }
}

@Test func keychainMalformedRecordsFailClosed() async throws {
    let backend = SyntheticKeychainBackend()
    let vault = KeychainVault(service: "local.pickuppilot.tests.invalid", backend: backend)
    for data in [Data([0, 1, 2]), try PropertyListSerialization.data(fromPropertyList: ["cvv": "123"], format: .binary, options: 0),
                 try PropertyListSerialization.data(fromPropertyList: ["synthetic"], format: .binary, options: 0)] {
        _ = backend.add(KeychainItem(service: "local.pickuppilot.tests.invalid", account: .profile), data: data)
        _ = backend.update(KeychainItem(service: "local.pickuppilot.tests.invalid", account: .profile), data: data)
        await #expect(throws: SecureVaultError.malformedProfile) { try await vault.loadProfile() }
    }
}

@Test func keychainClearAttemptsEveryAccountAndReportsFirstFailure() async throws {
    let backend = SyntheticKeychainBackend()
    let vault = KeychainVault(service: "local.pickuppilot.tests.clear", backend: backend)
    for failing in [KeychainAccount.profile, .session, .orderState] {
        backend.state.withLock { $0.deleteStatuses = [failing.rawValue: errSecAuthFailed]; $0.deletes = [] }
        await #expect(throws: SecureVaultError.keychain(operation: "delete", status: errSecAuthFailed)) {
            try await vault.clear()
        }
        #expect(backend.state.withLock { $0.deletes } == [KeychainAccount.profile.rawValue, KeychainAccount.session.rawValue, KeychainAccount.orderState.rawValue])
    }
    backend.state.withLock {
        $0.deleteStatuses = [KeychainAccount.profile.rawValue: errSecAuthFailed, KeychainAccount.session.rawValue: errSecInteractionNotAllowed,
                             KeychainAccount.orderState.rawValue: errSecParam]
    }
    await #expect(throws: SecureVaultError.keychain(operation: "delete", status: errSecAuthFailed)) { try await vault.clear() }
}

/// Opt in under a correctly signed test host. No UI is permitted by the query.
/// Always uses a fresh service and synthetic data, with cleanup attempted on every path.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PICKUP_PILOT_KEYCHAIN_INTEGRATION"] == "1"))
func keychainRealSyntheticRoundTripWithCleanup() async throws {
    let service = "local.pickuppilot.tests.integration." + UUID().uuidString
    let mode: KeychainStorageMode = ProcessInfo.processInfo.environment["PICKUP_PILOT_KEYCHAIN_MODE"] == "dataProtection" ? .dataProtection : .localLoginKeychain
    let vault = KeychainVault(service: service, mode: mode)
    let query = SystemKeychainBackend.query(KeychainItem(service: service, account: .profile), mode: mode)
    #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
    do {
        try await vault.saveProfile(syntheticSecureProfile())
        #expect(try await vault.loadProfile() == syntheticSecureProfile())
        var updated = syntheticSecureProfile()
        updated.cvv = "456"
        try await vault.saveProfile(updated)
        #expect(try await vault.loadProfile() == updated)
        try await vault.saveSession(Data("synthetic-cookie".utf8))
        #expect(try await vault.loadSession() == Data("synthetic-cookie".utf8))
        try await vault.saveOrderState(Data("synthetic-pending-order".utf8))
        #expect(try await vault.loadOrderState() == Data("synthetic-pending-order".utf8))
        try await vault.deleteProfile()
        try await vault.deleteSession()
        try await vault.deleteOrderState()
        #expect(try await vault.loadProfile() == nil)
        #expect(try await vault.loadSession() == nil)
        #expect(try await vault.loadOrderState() == nil)
        try await vault.clear()
    } catch {
        try? await vault.clear()
        throw error
    }
}
