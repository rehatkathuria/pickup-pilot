import Foundation
import Testing
@testable import PickupPilot

@Suite(.serialized) @MainActor struct CheckoutTimingTests {
    @Test func invalidFallbackBoundsReportNoPageEvidence() async throws {
        for timeout: TimeInterval in [0, -1, .nan, .infinity, -.infinity] {
            #expect(try await AppleCheckoutTiming.waitForFallback(timeout: timeout) == false)
        }
    }

    @Test func shortFallbackRespectsItsRequestedBoundAndReportsNoPageEvidence() async throws {
        let started = ContinuousClock.now
        #expect(try await AppleCheckoutTiming.waitForFallback(timeout: 0.025) == false)
        #expect(started.duration(to: .now) >= .milliseconds(20))
    }

    @Test func longFallbackRequestIsCappedToTheConservativeInterval() async throws {
        let started = ContinuousClock.now
        let bounded = try await Self.fallbackFinishesBeforeWatchdog()
        #expect(bounded, "A fallback must not consume the caller's entire long checkout timeout.")
        #expect(started.duration(to: .now) >= .milliseconds(500))
    }

    // No actor state crosses into the task group. Only the fallback operation hops
    // to its main-actor API; both children return Sendable Bool values.
    private nonisolated static func fallbackFinishesBeforeWatchdog() async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask(operation: longFallback)
            group.addTask(operation: watchdog)
            defer { group.cancelAll() }
            let completed = try await group.next() ?? false
            return completed
        }
    }
    private nonisolated static func longFallback() async throws -> Bool {
        _ = try await AppleCheckoutTiming.waitForFallback(timeout: 60)
        return true
    }
    private nonisolated static func watchdog() async throws -> Bool {
        try await Task.sleep(for: .seconds(5))
        return false
    }

    @Test(arguments: [false, true]) func cancellationInterruptsBothNamedConservativeWaits(legacyPause: Bool) async throws {
        var entered = false
        var completed = false
        let waiting = Task {
            entered = true
            if legacyPause { try await AppleCheckoutTiming.pause() }
            else { _ = try await AppleCheckoutTiming.waitForFallback(timeout: 60) }
            completed = true
        }
        for _ in 0..<1_000 { if entered { break }; await Task.yield() }
        try #require(entered)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!completed)
    }
}
