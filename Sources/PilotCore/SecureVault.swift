import Foundation

public protocol SecureVault: Sendable {
    func saveProfile(_ profile: SecureProfile) async throws
    func loadProfile() async throws -> SecureProfile?
    func deleteProfile() async throws
    func saveSession(_ data: Data) async throws
    func loadSession() async throws -> Data?
    func deleteSession() async throws
    func saveOrderState(_ data: Data) async throws
    func loadOrderState() async throws -> Data?
    func deleteOrderState() async throws
    func clear() async throws
}

public enum SecureVaultError: Error, LocalizedError, Sendable, Equatable {
    case keychain(operation: String, status: Int32)
    case malformedProfile
    case unexpectedKeychainResult

    public var errorDescription: String? {
        switch self {
        case let .keychain(operation, status):
            "Keychain \(operation) failed (status \(status)). Unlock this Mac and check the app's signing and Keychain permissions."
        case .malformedProfile:
            "The saved checkout profile is unreadable. Delete it and enter the details again."
        case .unexpectedKeychainResult:
            "Keychain returned an unexpected result."
        }
    }
}
