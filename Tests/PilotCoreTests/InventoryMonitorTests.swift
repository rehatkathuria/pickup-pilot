import Foundation
import Synchronization
import Testing
@testable import PilotCore

private let inventoryMonitorDate = Date(timeIntervalSince1970: 1_800_000_000)
private let inventoryMonitorProduct = ProductVariant(id: "SYNTHETIC/A", name: "Synthetic product", storage: "", color: "",
    productURL: URL(string: "https://www.apple.com/ca/shop/product/synthetic/a")!)
private let inventoryMonitorStore = RetailStore(id: "R001", name: "Synthetic Store", latitude: 43.6, longitude: -79.4, countryCode: "CA")

private func monitorSnapshot(_ state: AvailabilityState, quote: String = "Today", store: RetailStore = inventoryMonitorStore) -> InventorySnapshot {
    InventorySnapshot(stores: [store], availability: [StoreAvailability(storeID: store.id, variantID: inventoryMonitorProduct.id, state: state, message: quote)])
}

private final class InventoryMonitorTime: Sendable {
    private struct State { var elapsed: TimeInterval = 0; var wallOffset: TimeInterval = 0 }
    private let state = Mutex(State())
    private let origin = ContinuousClock.now
    func now() -> Date { state.withLock { inventoryMonitorDate.addingTimeInterval($0.elapsed + $0.wallOffset) } }
    func elapsed() -> TimeInterval { state.withLock { $0.elapsed } }
    func monotonicNow() -> ContinuousClock.Instant { origin.advanced(by: .seconds(elapsed())) }
    func advance(_ seconds: TimeInterval) { state.withLock { $0.elapsed += seconds } }
    func jumpWallClock(_ seconds: TimeInterval) { state.withLock { $0.wallOffset += seconds } }
}

private actor InventoryMonitorFeed: InventoryFetching {
    var result: Result<InventorySnapshot, AppleServiceError>
    let clock: InventoryMonitorTime
    let duration: TimeInterval
    let wallJump: TimeInterval
    var starts: [TimeInterval] = []
    var maximumConcurrent = 0
    private var active = 0
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    init(clock: InventoryMonitorTime, result: Result<InventorySnapshot, AppleServiceError> = .success(monitorSnapshot(.unavailable)),
         duration: TimeInterval = 0, wallJump: TimeInterval = 0) {
        self.clock = clock; self.result = result; self.duration = duration; self.wallJump = wallJump
    }
    func set(_ result: Result<InventorySnapshot, AppleServiceError>) { self.result = result }
    func suspend() { suspended = true }
    func release() { suspended = false; let pending = continuation; continuation = nil; pending?.resume() }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        starts.append(clock.elapsed()); active += 1; maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        if suspended { await withCheckedContinuation { continuation = $0 } }
        clock.advance(duration); clock.jumpWallClock(wallJump)
        return try result.get()
    }
}

private actor InventoryMonitorSleeper {
    let clock: InventoryMonitorTime
    let limit: Int
    var waits: [TimeInterval] = []
    init(clock: InventoryMonitorTime, limit: Int = 3) { self.clock = clock; self.limit = limit }
    func sleep(_ seconds: TimeInterval) throws {
        waits.append(seconds)
        if waits.count >= limit { throw CancellationError() }
        clock.advance(seconds)
    }
}

private actor InventoryMonitorControlledSleeper {
    var waits: [TimeInterval] = []
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    var pendingCount: Int { pending.count }
    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waits.append(seconds); pending[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func finishOne() {
        guard let first = pending.first else { return }
        pending.removeValue(forKey: first.key)?.resume()
    }
}

@MainActor private func monitorEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<4000 {
        if await condition() { return }
        await Task.yield()
    }
    throw InventoryMonitorError.invalidConfiguration
}

@MainActor private func makeInventoryMonitor(_ feed: InventoryMonitorFeed, clock: InventoryMonitorTime) -> InventoryMonitor {
    InventoryMonitor(inventory: feed, now: { clock.now() }, monotonicNow: { clock.monotonicNow() })
}

@Suite @MainActor struct InventoryMonitorTests {
    @Test(arguments: [AppleServiceError.invalidResponse("Synthetic"), .httpStatus(503), .blocked(541), .rateLimited(retryAfter: 600)])
    func seededFailureWaitsForBackoffWithoutDuplicatingDiscoveryThenRecovers(error: AppleServiceError) async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock, result: .success(monitorSnapshot(.available)))
        let sleeper = InventoryMonitorControlledSleeper()
        let monitor = InventoryMonitor(inventory: feed, now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var batches: [[InventoryChange]] = []
        monitor.onChanges = { batches.append($0) }
        let delay = error.retryDelay ?? 30
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], initialFailure: error)
        #expect(monitor.snapshot == nil && monitor.lastCheck == nil && monitor.lastError != nil && monitor.checkCount == 1)
        #expect(monitor.nextCheck == inventoryMonitorDate.addingTimeInterval(delay))
        try await monitorEventually { await sleeper.waits.count == 1 }
        #expect(await sleeper.waits == [delay])
        #expect(await feed.starts.isEmpty)
        await monitor.performRefresh()
        #expect(await feed.starts.isEmpty)
        #expect(batches.isEmpty && monitor.changes.isEmpty)
        clock.advance(delay); await sleeper.finishOne()
        try await monitorEventually { monitor.lastCheck != nil && !monitor.isRefreshing }
        #expect(await feed.starts == [delay])
        #expect(monitor.checkCount == 2 && monitor.lastError == nil)
        #expect(batches.count == 1 && batches.first?.first?.newState == .available)
        #expect(batches.first?.first?.oldState == nil)
        await monitor.stopAndWait()
    }

    @Test func seededSuccessAndFailureAreMutuallyExclusive() {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let monitor = makeInventoryMonitor(feed, clock: clock)
        #expect(throws: InventoryMonitorError.self) {
            try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct],
                              initialSnapshot: monitorSnapshot(.available), initialFailure: .httpStatus(503))
        }
        #expect(!monitor.isRunning && monitor.checkCount == 0 && monitor.snapshot == nil)
    }

    @Test func seededStartupPublishesAndAlertsWithoutASecondRequestBeforeTheNextInterval() async throws {
        let clock = InventoryMonitorTime()
        let response = monitorSnapshot(.available)
        let feed = InventoryMonitorFeed(clock: clock, result: .success(response))
        let sleeper = InventoryMonitorControlledSleeper()
        let monitor = InventoryMonitor(inventory: feed, now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var batches: [[InventoryChange]] = []
        monitor.onChanges = { batches.append($0) }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], initialSnapshot: response)
        #expect(monitor.snapshot == response && monitor.checkCount == 1 && monitor.lastCheck == inventoryMonitorDate)
        #expect(monitor.nextCheck == inventoryMonitorDate.addingTimeInterval(1))
        try await monitorEventually { await sleeper.waits.count == 1 && batches.count == 1 }
        #expect(await feed.starts.isEmpty)
        #expect(await sleeper.waits == [1])
        #expect(batches.first?.first?.oldState == nil)
        clock.advance(1); await sleeper.finishOne()
        try await monitorEventually { await feed.starts.count == 1 && monitor.checkCount == 2 && !monitor.isRefreshing }
        #expect(await feed.starts == [1])
        #expect(batches.count == 1 && monitor.changes.count == 1)
        await monitor.stopAndWait()
    }

    @Test(arguments: [AvailabilityState.unavailable, .disabled])
    func seededUnavailableBaselinesAreQuietAndDetectTheNextVerifiedChange(state: AvailabilityState) async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock, result: .success(monitorSnapshot(.available)))
        let monitor = makeInventoryMonitor(feed, clock: clock)
        var batches: [[InventoryChange]] = []
        monitor.onChanges = { batches.append($0) }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false,
                          initialSnapshot: monitorSnapshot(state))
        #expect(monitor.changes.isEmpty && monitor.snapshot == monitorSnapshot(state))
        await monitor.performRefresh()
        #expect(batches.count == 1 && batches.first?.first?.oldState == state)
        #expect(batches.first?.first?.newState == .available)
        await monitor.stopAndWait()
    }

    @Test func seededSnapshotUsesTheSameMissingAndDuplicateRowVerification() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let monitor = makeInventoryMonitor(feed, clock: clock)
        let duplicate = monitorSnapshot(.available).availability[0]
        var deliveries = 0
        monitor.onChanges = { deliveries += $0.count }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false,
                          initialSnapshot: InventorySnapshot(stores: [inventoryMonitorStore], availability: [duplicate, duplicate]))
        #expect(monitor.snapshot?.availability.isEmpty == true && monitor.unverifiedPairCount == 1)
        #expect(monitor.changes.isEmpty && deliveries == 0)
        await monitor.stopAndWait()
    }

    @Test func cancelingImmediatelyAfterSeededStartPreventsDeferredNotificationAndNetworkWork() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let monitor = makeInventoryMonitor(feed, clock: clock)
        var deliveries = 0
        monitor.onChanges = { deliveries += $0.count }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], initialSnapshot: monitorSnapshot(.available))
        await monitor.stopAndWait()
        #expect(deliveries == 0 && !monitor.isRunning && monitor.nextCheck == nil)
        #expect(await feed.starts.isEmpty)
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false,
                          initialSnapshot: monitorSnapshot(.unavailable))
        #expect(monitor.changes.isEmpty)
        await monitor.stopAndWait()
    }

    @Test func usesOneSecondDefaultAndBoundsInterval() {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let monitor = makeInventoryMonitor(feed, clock: clock)
        #expect(monitor.refreshInterval == 1)
        monitor.setRefreshInterval(0); #expect(monitor.refreshInterval == 1)
        monitor.setRefreshInterval(15); #expect(monitor.refreshInterval == 15)
        monitor.setRefreshInterval(.infinity); #expect(monitor.refreshInterval == 1)
        monitor.setRefreshInterval(.nan); #expect(monitor.refreshInterval == 1)
        monitor.setRefreshInterval(4000); #expect(monitor.refreshInterval == 3600)
    }

    @Test func validatesLocationProductScopeAndRunningAdmission() throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let monitor = makeInventoryMonitor(feed, clock: clock)
        #expect(throws: InventoryMonitorError.self) { try monitor.start(market: .ca, location: " ", variants: [inventoryMonitorProduct]) }
        #expect(throws: InventoryMonitorError.self) { try monitor.start(market: .ca, location: "Synthetic", variants: []) }
        #expect(throws: InventoryMonitorError.self) { try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct, inventoryMonitorProduct]) }
        #expect(throws: InventoryMonitorError.self) { try monitor.start(market: .us, location: "Synthetic", variants: [inventoryMonitorProduct]) }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        #expect(throws: InventoryMonitorError.self) { try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct]) }
        monitor.stop()
    }

    @Test(arguments: [AvailabilityState.unavailable, .disabled, .available])
    func onlyInitialAvailableResultAlerts(state: AvailabilityState) async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock, result: .success(monitorSnapshot(state)))
        let monitor = makeInventoryMonitor(feed, clock: clock)
        var batches: [[InventoryChange]] = []
        monitor.onChanges = { batches.append($0) }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        await monitor.performRefresh(); await monitor.performRefresh()
        #expect(monitor.checkCount == 2 && monitor.lastCheck == inventoryMonitorDate)
        #expect(batches.count == (state == .available ? 1 : 0))
        if state == .available {
            let change = try #require(batches.first?.first)
            #expect(change.oldState == nil && change.oldMessage == nil && change.newState == .available)
            #expect(change.storeName == inventoryMonitorStore.name && change.productName == inventoryMonitorProduct.name)
        }
        await monitor.stopAndWait()
    }

    @Test func changeNamesIncludeVariantDetailsWithoutRepeatingExistingDetails() async throws {
        for (name, expected) in [("Synthetic product", "Synthetic product · 256 GB · Blue"),
                                 ("Synthetic product 256GB Blue", "Synthetic product 256GB Blue")] {
            let clock = InventoryMonitorTime()
            let feed = InventoryMonitorFeed(clock: clock, result: .success(monitorSnapshot(.available)))
            let monitor = makeInventoryMonitor(feed, clock: clock)
            var product = inventoryMonitorProduct
            product.name = name; product.storage = "256 GB"; product.color = "Blue"
            try monitor.start(market: .ca, location: "Synthetic", variants: [product], runContinuously: false)
            await monitor.performRefresh()
            #expect(monitor.changes.first?.productName == expected)
            await monitor.stopAndWait()
        }
    }

    @Test func tracksStateAndNormalizedQuotesWithoutRepeatedAlerts() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let monitor = makeInventoryMonitor(feed, clock: clock)
        var batches: [[InventoryChange]] = []
        monitor.onChanges = { batches.append($0) }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        await monitor.performRefresh()
        await feed.set(.success(monitorSnapshot(.unavailable, quote: "  TODAY\n ")))
        await monitor.performRefresh()
        #expect(batches.isEmpty)
        await feed.set(.success(monitorSnapshot(.available, quote: "Tomorrow")))
        await monitor.performRefresh()
        await feed.set(.success(monitorSnapshot(.available, quote: "Friday")))
        await monitor.performRefresh()
        await feed.set(.success(monitorSnapshot(.disabled, quote: "Unavailable")))
        await monitor.performRefresh()
        #expect(batches.count == 3 && batches.allSatisfy { $0.count == 1 })
        #expect(monitor.changes.map(\.newState) == [.disabled, .available, .available])
        #expect(monitor.changes[1].oldMessage == "Tomorrow" && monitor.changes[1].newMessage == "Friday")
        await monitor.stopAndWait()
    }

    @Test func includesAllResponseStoresAndBatchesChangesImmediately() async throws {
        let clock = InventoryMonitorTime()
        let other = RetailStore(id: "R002", name: "Other Store")
        let response = InventorySnapshot(stores: [inventoryMonitorStore, other], availability: [
            StoreAvailability(storeID: inventoryMonitorStore.id, variantID: inventoryMonitorProduct.id, state: .available, message: "Today"),
            StoreAvailability(storeID: other.id, variantID: inventoryMonitorProduct.id, state: .available, message: "Tomorrow")])
        let feed = InventoryMonitorFeed(clock: clock, result: .success(response)), sleeper = InventoryMonitorSleeper(clock: clock, limit: 1)
        let monitor = InventoryMonitor(inventory: feed, now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var deliveries: [(Int, Int)] = []
        monitor.onChanges = { deliveries.append(($0.count, await sleeper.waits.count)) }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct])
        try await monitorEventually { await sleeper.waits.count == 1 }
        #expect(deliveries.count == 1 && deliveries[0].0 == 2 && deliveries[0].1 == 0)
        #expect(monitor.snapshot == response)
        await monitor.stopAndWait()
    }

    @Test func missingAndDuplicateRowsAreUnknownAndPreserveLastVerifiedBaseline() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock, result: .success(monitorSnapshot(.available)))
        let monitor = makeInventoryMonitor(feed, clock: clock)
        var batches: [[InventoryChange]] = []
        monitor.onChanges = { batches.append($0) }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        await monitor.performRefresh()
        await feed.set(.success(InventorySnapshot(stores: [inventoryMonitorStore], availability: [])))
        await monitor.performRefresh()
        #expect(monitor.unverifiedPairCount == 1 && monitor.snapshot?.availability.isEmpty == true)
        let row = StoreAvailability(storeID: inventoryMonitorStore.id, variantID: inventoryMonitorProduct.id, state: .unavailable, message: "Unknown duplicate")
        await feed.set(.success(InventorySnapshot(stores: [inventoryMonitorStore], availability: [row, row])))
        await monitor.performRefresh()
        #expect(monitor.unverifiedPairCount == 1 && monitor.snapshot?.availability.isEmpty == true)
        await feed.set(.success(monitorSnapshot(.available)))
        await monitor.performRefresh()
        #expect(batches.count == 1)
        await monitor.stopAndWait()
    }

    @Test func duplicateStoresAndUnrequestedProductsCannotCreateAlerts() async throws {
        let clock = InventoryMonitorTime()
        let valid = monitorSnapshot(.available)
        let feed = InventoryMonitorFeed(clock: clock, result: .success(InventorySnapshot(stores: [inventoryMonitorStore, inventoryMonitorStore], availability: valid.availability)))
        let monitor = makeInventoryMonitor(feed, clock: clock)
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        await monitor.performRefresh()
        #expect(monitor.snapshot?.stores.isEmpty == true && monitor.changes.isEmpty)
        await feed.set(.success(InventorySnapshot(stores: [inventoryMonitorStore], availability: [StoreAvailability(storeID: inventoryMonitorStore.id, variantID: "UNREQUESTED", state: .available, message: "Today")])))
        await monitor.performRefresh()
        #expect(monitor.unverifiedPairCount == 1 && monitor.changes.isEmpty)
        await monitor.stopAndWait()
    }

    @Test(arguments: [0.2, 2.0])
    func healthyCadenceIsMonotonicStartToStartAndNeverOverlaps(duration: TimeInterval) async throws {
        let clock = InventoryMonitorTime()
        let actualFeed = InventoryMonitorFeed(clock: clock, duration: duration, wallJump: 3600)
        let sleeper = InventoryMonitorSleeper(clock: clock)
        let monitor = InventoryMonitor(inventory: actualFeed, now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct])
        try await monitorEventually { await sleeper.waits.count == 3 }
        let starts = await actualFeed.starts, waits = await sleeper.waits
        let expected = duration < 1 ? [0.0, 1, 2] : [0.0, 2, 4]
        #expect(starts.count == 3 && zip(starts, expected).allSatisfy { abs($0 - $1) < 0.000_001 })
        #expect(waits.allSatisfy { abs($0 - max(0, 1 - duration)) < 0.000_001 })
        #expect(await actualFeed.maximumConcurrent == 1)
        await monitor.stopAndWait()
    }

    @Test(arguments: [AppleServiceError.invalidResponse("Synthetic"), .httpStatus(503), .blocked(541), .rateLimited(retryAfter: 600)])
    func errorsBackOffAfterResponseAndCannotBeBypassedByManualRefresh(error: AppleServiceError) async throws {
        let clock = InventoryMonitorTime()
        let actualFeed = InventoryMonitorFeed(clock: clock, result: .failure(error), duration: 2)
        let sleeper = InventoryMonitorSleeper(clock: clock, limit: 1)
        let monitor = InventoryMonitor(inventory: actualFeed, now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct])
        try await monitorEventually { await sleeper.waits.count == 1 }
        #expect(await sleeper.waits == [error.retryDelay ?? 30])
        #expect(monitor.lastError != nil && monitor.lastCheck == nil)
        await monitor.performRefresh()
        #expect(await actualFeed.starts.count == 1)
        await monitor.stopAndWait()
    }

    @Test func transientFailureKeepsSnapshotAndBaselineUntilSuccessfulRetry() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let monitor = makeInventoryMonitor(feed, clock: clock)
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        await monitor.performRefresh()
        await feed.set(.failure(.rateLimited(retryAfter: 70)))
        await monitor.performRefresh()
        #expect(monitor.snapshot == monitorSnapshot(.unavailable))
        #expect(monitor.lastError != nil && monitor.changes.isEmpty)
        await feed.set(.success(monitorSnapshot(.available)))
        clock.advance(70)
        await monitor.performRefresh()
        #expect(monitor.lastError == nil && monitor.changes.first?.oldState == .unavailable)
        #expect(monitor.changes.first?.newState == .available)
        await monitor.stopAndWait()
    }

    @Test func concurrentRefreshesShareOneRequestAndIntervalEditDoesNotCancelIt() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        await feed.suspend()
        let monitor = makeInventoryMonitor(feed, clock: clock)
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        let first = Task { await monitor.performRefresh() }
        try await monitorEventually { await feed.isWaiting }
        let second = Task { await monitor.performRefresh() }
        monitor.setRefreshInterval(10)
        await Task.yield()
        #expect(await feed.starts.count == 1 && monitor.isRefreshing)
        await feed.release(); await first.value; await second.value
        #expect(await feed.maximumConcurrent == 1 && monitor.lastCheck != nil)
        await monitor.stopAndWait()
    }

    @Test func editingIntervalReschedulesSleepingLoopWithoutEarlyRequest() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock)
        let sleeper = InventoryMonitorControlledSleeper()
        let monitor = InventoryMonitor(inventory: feed, now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        monitor.setRefreshInterval(10)
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct])
        try await monitorEventually { await sleeper.waits.count == 1 }
        clock.advance(2); monitor.setRefreshInterval(5)
        try await monitorEventually { await sleeper.waits.count == 2 }
        #expect(await sleeper.waits == [10, 3])
        #expect(await feed.starts.count == 1)
        #expect(monitor.nextCheck == inventoryMonitorDate.addingTimeInterval(5))
        await monitor.stopAndWait()
        #expect(await sleeper.pendingCount == 0)
    }

    @Test func stopDropsLateNetworkResultAndPreventsOverlappingNewSession() async throws {
        let clock = InventoryMonitorTime()
        let feed = InventoryMonitorFeed(clock: clock, result: .success(monitorSnapshot(.available)))
        await feed.suspend()
        let monitor = makeInventoryMonitor(feed, clock: clock)
        var deliveries = 0
        monitor.onChanges = { deliveries += $0.count }
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        let pending = Task { await monitor.performRefresh() }
        try await monitorEventually { await feed.isWaiting }
        monitor.stop()
        #expect(!monitor.isRunning && !monitor.isRefreshing && monitor.nextCheck == nil)
        #expect(throws: InventoryMonitorError.self) { try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct]) }
        let shutdown = Task { await monitor.stopAndWait() }
        await feed.release(); await pending.value; await shutdown.value
        #expect(monitor.snapshot == nil && monitor.lastCheck == nil && monitor.lastError == nil && monitor.changes.isEmpty)
        #expect(deliveries == 0)
        try monitor.start(market: .ca, location: "Synthetic", variants: [inventoryMonitorProduct], runContinuously: false)
        await monitor.performRefresh()
        #expect(deliveries == 1 && monitor.changes.first?.oldState == nil)
        await monitor.stopAndWait()
    }
}
