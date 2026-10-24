import Foundation

public protocol PreferencesStore: Sendable {
    func load() throws -> PilotPreferences
    func save(_ preferences: PilotPreferences) throws
}

/// Only this non-secret settings type may be serialized to an ordinary file.
public struct FilePreferencesStore: PreferencesStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> PilotPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return PilotPreferences() }
        return try JSONDecoder().decode(PilotPreferences.self, from: Data(contentsOf: url))
    }
    public func save(_ preferences: PilotPreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
