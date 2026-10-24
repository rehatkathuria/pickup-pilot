import Foundation

public struct RetryPolicy: Sendable {
    public let base: TimeInterval
    public let maximum: TimeInterval
    public init(base: TimeInterval = 60, maximum: TimeInterval = 900) {
        let safeBase = base.isFinite ? max(30, base) : 60
        self.base = safeBase
        self.maximum = maximum.isFinite ? max(maximum, safeBase) : max(900, safeBase)
    }
    public func delay(failures: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let exponential = min(3600, min(maximum, base * pow(2, Double(min(20, max(0, failures - 1))))))
        let serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        return max(exponential, serverDelay)
    }
}
