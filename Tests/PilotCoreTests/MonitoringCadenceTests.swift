import Foundation
import Synchronization
import Testing
@testable import PilotCore

private final class CadenceTime: Sendable {
    private struct State { var wall = coordinatorTestDate; var elapsed: TimeInterval = 0 }
    private let value = Mutex(State())
    private let origin = ContinuousClock.now
    func now() -> Date { value.withLock { $0.wall } }
    func elapsedSeconds() -> TimeInterval { value.withLock { $0.elapsed } }
    func monotonicNow() -> ContinuousClock.Instant { origin.advanced(by: .seconds(elapsedSeconds())) }
    func advance(_ seconds: TimeInterval) {
        value.withLock { $0.wall = $0.wall.addingTimeInterval(seconds); $0.elapsed += seconds }
    }
    func jumpWallClock(_ seconds: TimeInterval) { value.withLock { $0.wall = $0.wall.addingTimeInterval(seconds) } }
}
private actor CadenceInventory: InventoryFetching {
    let clock: CadenceTime
    let duration: TimeInterval
    let failure: AppleServiceError?
    let wallClockJump: TimeInterval
    var starts: [Date] = []
    var elapsedStarts: [TimeInterval] = []
    var maximumConcurrent = 0
    private var active = 0
    var suspend = false
    var pending: CheckedContinuation<Void, Never>?
    init(clock: CadenceTime, duration: TimeInterval, failure: AppleServiceError? = nil, wallClockJump: TimeInterval = 0) {
        self.clock = clock; self.duration = duration; self.failure = failure; self.wallClockJump = wallClockJump
    }
    func setSuspended() { suspend = true }
    func release() { let continuation = pending; pending = nil; continuation?.resume() }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        starts.append(clock.now()); elapsedStarts.append(clock.elapsedSeconds())
        active += 1; maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        if suspend { await withCheckedContinuation { pending = $0 } }
        clock.advance(duration)
        clock.jumpWallClock(wallClockJump)
        if let failure { throw failure }
        return InventorySnapshot(stores: [coordinatorStore], availability: [])
    }
}
private actor CadenceSleeper {
    let clock: CadenceTime
    let limit: Int
    var waits: [TimeInterval] = []
    var requestedAt: [Date] = []
    init(clock: CadenceTime, limit: Int = 3) { self.clock = clock; self.limit = limit }
    func sleep(_ seconds: TimeInterval) throws {
        waits.append(seconds); requestedAt.append(clock.now())
        if waits.count >= limit { throw CancellationError() }
        clock.advance(seconds)
    }
}
@MainActor private final class CadenceDriver: CheckoutDriver {
    var pause: CheckoutError? = .manualInputRequired
    var requests: [CheckoutRequest] = []
    var profiles: [SecureProfile] = []
    var submitted = 0
    var cancelled = 0
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        requests.append(request); profiles.append(profile)
        if let pause { throw pause }
        return CheckoutReview(variantID: request.variant.id, storeID: request.store.id, quantity: 1, total: 2500,
                              currencyCode: "CAD", pickupDate: coordinatorTestDate.addingTimeInterval(3600),
                              pickupEndDate: coordinatorTestDate.addingTimeInterval(7200), pickupSlot: "Synthetic slot",
                              expiresAt: coordinatorTestDate.addingTimeInterval(600))
    }
    func submit(review: CheckoutReview) -> CheckoutOutcome { submitted += 1; return .confirmed(orderID: "SYNTHETIC") }
    func cancel() { cancelled += 1 }
}
@MainActor private func cadenceEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        await Task.yield()
    }
    throw TestFailure.storage
}

@Suite @MainActor struct MonitoringCadenceTests {
    @Test(arguments: [5.0, 30.0, 60.0])
    func healthyCadenceExcludesRequestDuration(interval: TimeInterval) async throws {
        let f = CoordinatorFixture(), clock = CadenceTime()
        let inventory = CadenceInventory(clock: clock, duration: 2)
        let sleeper = CadenceSleeper(clock: clock)
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var preferences = f.preferences; preferences.pollInterval = interval
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic")
        try await cadenceEventually { await sleeper.waits.count == 3 }
        let offsets = await inventory.starts.map { $0.timeIntervalSince(coordinatorTestDate) }
        let waits = await sleeper.waits
        print("Synthetic healthy cadence interval=\(interval), request=2s, starts=\(offsets), waits=\(waits)")
        #expect(offsets == [0, interval, 2 * interval])
        #expect(waits == Array(repeating: interval - 2, count: 3))
        #expect(await inventory.maximumConcurrent == 1)
        #expect(f.driver.prepared == 0)
        await coordinator.stopAndWait()
    }

    @Test(arguments: [0.2, 2.0])
    func oneSecondCadenceWaitsOnlyForRemainingTimeAndNeverOverlaps(requestDuration: TimeInterval) async throws {
        let f = CoordinatorFixture(), clock = CadenceTime()
        let inventory = CadenceInventory(clock: clock, duration: requestDuration)
        let sleeper = CadenceSleeper(clock: clock)
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var preferences = f.preferences; preferences.pollInterval = 1
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic")
        try await cadenceEventually { await sleeper.waits.count == 3 }
        let expectedStarts: [TimeInterval] = requestDuration < 1 ? [0, 1, 2] : [0, 2, 4]
        let expectedWait: TimeInterval = requestDuration < 1 ? 0.8 : 0
        let starts = await inventory.elapsedStarts, waits = await sleeper.waits
        #expect(starts.count == 3 && waits.count == 3)
        #expect(zip(starts, expectedStarts).allSatisfy { abs($0 - $1) < 0.000_001 })
        #expect(waits.allSatisfy { abs($0 - expectedWait) < 0.000_001 })
        #expect(await inventory.maximumConcurrent == 1)
        #expect(f.driver.prepared == 0 && f.driver.submitted == 0)
        await coordinator.stopAndWait()
    }

    @Test func slowRequestsNeverOverlapOrTriggerCatchUpBursts() async throws {
        let f = CoordinatorFixture(), clock = CadenceTime()
        let inventory = CadenceInventory(clock: clock, duration: 12)
        let sleeper = CadenceSleeper(clock: clock)
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic")
        try await cadenceEventually { await sleeper.waits.count == 3 }
        #expect(await inventory.starts.map { $0.timeIntervalSince(coordinatorTestDate) } == [0, 12, 24])
        #expect(await sleeper.waits == [0, 0, 0])
        #expect(await inventory.maximumConcurrent == 1)
        await coordinator.stopAndWait()
    }

    @Test(arguments: [-3600.0, 3600.0])
    func wallClockCorrectionsCannotShortenHealthyRequestSpacing(jump: TimeInterval) async throws {
        let f = CoordinatorFixture(), clock = CadenceTime()
        let inventory = CadenceInventory(clock: clock, duration: 2, wallClockJump: jump)
        let sleeper = CadenceSleeper(clock: clock)
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var preferences = f.preferences
        preferences.attemptWindow = DateWindow(start: .distantPast, end: .distantFuture)
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic")
        try await cadenceEventually { await sleeper.waits.count == 3 }
        #expect(await inventory.elapsedStarts == [0, 5, 10])
        #expect(await sleeper.waits == [3, 3, 3])
        #expect(await inventory.maximumConcurrent == 1)
        await coordinator.stopAndWait()
    }

    @Test func concurrentCycleCallsShareOneBatchedInventoryRequest() async throws {
        let f = CoordinatorFixture(), clock = CadenceTime()
        let inventory = CadenceInventory(clock: clock, duration: 2)
        await inventory.setSuspended()
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore, now: { clock.now() }, monotonicNow: { clock.monotonicNow() })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        let first = Task { await coordinator.performCycle() }
        try await cadenceEventually { await inventory.pending != nil }
        await coordinator.performCycle()
        #expect(await inventory.starts.count == 1)
        await inventory.release(); await first.value
        #expect(await inventory.maximumConcurrent == 1)
        coordinator.stop()
    }

    @Test(arguments: [AppleServiceError.invalidResponse("Synthetic"), .httpStatus(503), .blocked(403), .blocked(541), .rateLimited(retryAfter: 600)])
    func errorBackoffStartsAfterResponseAndKeepsConservativeFloors(error: AppleServiceError) async throws {
        let f = CoordinatorFixture(), clock = CadenceTime()
        let inventory = CadenceInventory(clock: clock, duration: 2, failure: error)
        let sleeper = CadenceSleeper(clock: clock, limit: 1)
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var preferences = f.preferences; preferences.pollInterval = 1
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic")
        try await cadenceEventually { await sleeper.waits.count == 1 }
        #expect(await sleeper.waits == [error.retryDelay ?? 30])
        #expect(await sleeper.requestedAt == [coordinatorTestDate.addingTimeInterval(2)])
        #expect(await inventory.starts.count == 1)
        #expect(f.driver.prepared == 0 && f.driver.submitted == 0)
        await coordinator.stopAndWait()
    }

    @Test(arguments: [CheckoutError.manualInputRequired])
    func continuationUsesOriginalChoiceAndProfileWithoutRefetchingInventory(error: CheckoutError) async throws {
        let f = CoordinatorFixture(); let driver = CadenceDriver(); driver.pause = error
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { coordinatorTestDate }, sleep: { _ in throw CancellationError() })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        await coordinator.performCycle()
        let originalRequest = try #require(driver.requests.first), originalProfile = try #require(driver.profiles.first)
        await f.inventory.setFailure(.blocked(541))
        await f.vault.deleteProfile()
        coordinator.resumeAuthentication()
        try await cadenceEventually { driver.requests.count == 2 }
        #expect(driver.requests == [originalRequest, originalRequest] && driver.profiles == [originalProfile, originalProfile])
        #expect(await f.inventory.calls == 1)
        #expect(driver.submitted == 0 && driver.cancelled == 0 && !coordinator.journal.blocksPurchase)
        coordinator.stop()
    }

    @Test func continuationRefreshesDurablePurchaseLockBeforePreparing() async throws {
        let f = CoordinatorFixture(); let driver = CadenceDriver()
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { coordinatorTestDate }, sleep: { _ in throw CancellationError() })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        await coordinator.performCycle()
        await f.journalStore.set(PurchaseJournal(phase: .uncertain, attemptID: UUID()))
        driver.pause = nil
        coordinator.resumeAuthentication()
        try await cadenceEventually { !coordinator.isArmed }
        #expect(coordinator.status == .uncertain && coordinator.journal.blocksPurchase)
        #expect(driver.requests.count == 1 && driver.submitted == 0 && driver.cancelled == 1)
        #expect(await f.inventory.calls == 1)
    }

    @Test func continuationOutsideDailyHoursCannotCarryConfirmationIntoLaterWindow() async throws {
        let f = CoordinatorFixture(), clock = CadenceTime(); let driver = CadenceDriver()
        var preferences = f.preferences
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let minute = calendar.component(.hour, from: coordinatorTestDate) * 60 + calendar.component(.minute, from: coordinatorTestDate)
        preferences.attemptHours = DailyWindow(startMinute: minute, endMinute: minute)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { _ in throw CancellationError() })
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        await coordinator.performCycle()
        clock.advance(120)
        coordinator.resumeAuthentication()
        try await cadenceEventually { coordinator.status == .waiting }
        #expect(driver.requests.count == 1 && driver.submitted == 0 && driver.cancelled == 1)
        #expect(await f.inventory.calls == 1)
        coordinator.stop()
    }

    @Test func fastPollingDoesNotReducePreparationFailureBackoff() async throws {
        let f = CoordinatorFixture(), clock = CadenceTime()
        f.driver.prepareError = .unsupportedPage
        let sleeper = CadenceSleeper(clock: clock, limit: 1)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { clock.now() }, monotonicNow: { clock.monotonicNow() }, sleep: { try await sleeper.sleep($0) })
        var preferences = f.preferences; preferences.pollInterval = 1
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic")
        try await cadenceEventually { await sleeper.waits.count == 1 }
        #expect(await sleeper.waits == [30])
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0)
        await coordinator.stopAndWait()
    }
}
