import Foundation

@MainActor enum AppleCheckoutTiming {
    static let fallbackInterval: TimeInterval = 0.6
    static let stalledInterval: TimeInterval = 3
    nonisolated static func monotonicNow() -> ContinuousClock.Instant { .now }
    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
    static func pause() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }
    static func waitForFallback(timeout: TimeInterval) async throws -> Bool {
        guard timeout.isFinite, timeout > 0 else { return false }
        try await Task.sleep(for: .seconds(min(timeout, fallbackInterval)))
        return false
    }
}
