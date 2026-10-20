import Foundation
import Testing
import Synchronization
@testable import PilotCore

private actor CoordinatorPauseGate {
    private var entered = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        if released { return }
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { released = true; pending?.resume(); pending = nil }
}
private actor CoordinatorLifecycleJournal: PurchaseJournalStore {
    private var value: PurchaseJournal
    let loadGate: CoordinatorPauseGate?
    let saveGate: CoordinatorPauseGate?
    var failSave = false
    init(_ phase: PurchaseJournal.Phase = .idle, loadGate: CoordinatorPauseGate? = nil, saveGate: CoordinatorPauseGate? = nil) {
        value = PurchaseJournal(phase: phase, attemptID: UUID(), variantID: coordinatorVariant.id, storeID: coordinatorStore.id, updatedAt: coordinatorTestDate)
        self.loadGate = loadGate; self.saveGate = saveGate
    }
    func load() async throws -> PurchaseJournal { if let loadGate { await loadGate.pause() }; return value }
    func save(_ journal: PurchaseJournal) async throws {
        if let saveGate { await saveGate.pause() }
        if failSave { throw TestFailure.storage }
        value = journal
    }
    func setFailSave() { failSave = true }
    func durableValue() -> PurchaseJournal { value }
}
private actor CoordinatorSleepGate {
    private(set) var intervals: [TimeInterval] = []
    private var arrived: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Error>?
    func sleep(_ interval: TimeInterval) async throws {
        intervals.append(interval); arrived?.resume(); arrived = nil
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForSleep() async {
        if !intervals.isEmpty { return }
        await withCheckedContinuation { arrived = $0 }
    }
    func cancelSleep() { pending?.resume(throwing: CancellationError()); pending = nil }
}
private struct CoordinatorFailureInventory: InventoryFetching {
    let cancellation: Bool
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        if cancellation { throw CancellationError() }
        throw URLError(.notConnectedToInternet)
    }
}
@MainActor private final class CoordinatorCancellationDriver: CheckoutDriver {
    var cancellations = 0
    func prepare(request: CheckoutRequest, profile: SecureProfile) async throws -> CheckoutReview { throw CancellationError() }
    func submit(review: CheckoutReview) async throws -> CheckoutOutcome { Issue.record("Cancelled prepare submitted"); return .unavailable }
    func cancel() { cancellations += 1 }
}
@MainActor private func coordinatorEventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Expected coordinator transition did not complete")
}

@MainActor @Suite struct CoordinatorLifecycleTests {
    @Test func continuousMonitorPublishesNextCheckAndDisarmCancelsPendingSleep() async throws {
        let f = CoordinatorFixture(); let sleep = CoordinatorSleepGate()
        let monotonic = ContinuousClock.now
        await f.inventory.setResponse(InventorySnapshot(stores: [coordinatorStore], availability: []))
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore,
                                                now: { coordinatorTestDate }, monotonicNow: { monotonic }, sleep: { try await sleep.sleep($0) })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: true)
        await sleep.waitForSleep()
        #expect(coordinator.nextCheck == coordinatorTestDate.addingTimeInterval(f.preferences.pollInterval))
        #expect(await sleep.intervals == [f.preferences.pollInterval])
        #expect(await f.inventory.calls == 1)
        let shutdown = Task { await coordinator.stopAndWait() }
        await sleep.cancelSleep(); await shutdown.value
        #expect(coordinator.nextCheck == nil)
        #expect(!coordinator.isArmed)
        #expect(f.driver.prepared == 0)
    }
    @Test func defaultClockAndRealCancelableSleepWorkWithoutWaitingForPollInterval() async throws {
        let f = CoordinatorFixture()
        await f.inventory.setResponse(InventorySnapshot(stores: [coordinatorStore], availability: []))
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore)
        var preferences = f.preferences
        preferences.attemptWindow = DateWindow(start: .distantPast, end: Date().addingTimeInterval(3600))
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic")
        await coordinatorEventually { coordinator.nextCheck != nil }
        #expect(coordinator.lastCheck != nil)
        await coordinator.stopAndWait()
        #expect(coordinator.nextCheck == nil)
        #expect(coordinator.status == .stopped)
    }
    @Test func ordinaryFieldResumeContinuesSameArmedRequestAndCanConfirm() async throws {
        let f = CoordinatorFixture(); f.driver.prepareError = .manualInputRequired
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .manualInputRequired)
        f.driver.prepareError = nil
        f.coordinator.resumeAuthentication()
        await coordinatorEventually { f.coordinator.status == .confirmed }
        #expect(f.driver.submitted == 1)
        #expect(f.coordinator.events.contains { $0.message.contains("Continuing") })
        #expect(f.coordinator.nextCheck == nil)
        f.coordinator.stop()
        #expect(f.coordinator.status == .confirmed)
    }
    @Test func waitingSchedulePerformsNoInventoryAndEventuallyExpires() async throws {
        let f = CoordinatorFixture(); let clock = Mutex(coordinatorTestDate)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore, now: { clock.withLock { $0 } })
        var p = f.preferences
        p.attemptWindow = DateWindow(start: coordinatorTestDate.addingTimeInterval(100), end: coordinatorTestDate.addingTimeInterval(200))
        try await coordinator.arm(configuration: p, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        await coordinator.performCycle()
        #expect(coordinator.status == .waiting)
        #expect(await f.inventory.calls == 0)
        clock.withLock { $0 = coordinatorTestDate.addingTimeInterval(201) }
        await coordinator.performCycle()
        #expect(!coordinator.isArmed)
        #expect(coordinator.status == .stopped)
        #expect(coordinator.detail.contains("ended"))
    }
    @Test func boundedActivityAndPublicStatusMessagesRemainUseful() {
        let f = CoordinatorFixture()
        for _ in 0..<105 { f.coordinator.stop() }
        #expect(f.coordinator.events.count == 100)
        #expect(f.coordinator.events.allSatisfy { $0.date == coordinatorTestDate && !$0.message.isEmpty })
        for status in [PilotStatus.stopped, .checking, .monitoring, .waiting, .preparing, .authenticationRequired, .submitting, .confirmed, .uncertain, .failed] {
            #expect(!status.title.isEmpty)
        }
        for error in [CoordinatorError.alreadyRunning, .invalidConfiguration("Synthetic"), .profileIncomplete, .purchaseLocked, .invalidConfirmation] {
            #expect(error.errorDescription?.isEmpty == false)
        }
        f.coordinator.resumeAuthentication()
        #expect(!f.coordinator.isArmed)
    }
    @Test func reentrantArmResetAndReconcileAreRejectedAndDisarmInvalidatesPendingArm() async throws {
        let f = CoordinatorFixture(); let gate = CoordinatorPauseGate()
        let journal = CoordinatorLifecycleJournal(loadGate: gate)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: journal, now: { coordinatorTestDate })
        let first = Task { try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false) }
        await gate.waitForEntry()
        await #expect(throws: CoordinatorError.self) {
            try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        }
        await #expect(throws: CoordinatorError.self) { try await coordinator.resetPurchaseLock() }
        await #expect(throws: CoordinatorError.self) { try await coordinator.reconcileConfirmation(orderID: "SYNTHETIC") }
        coordinator.stop(); await gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!coordinator.isArmed)
    }
    @Test func armRejectsKnownForeignStoresEmptyLocationExpiredWindowAndInvalidPreferences() async throws {
        let f = CoordinatorFixture()
        var foreign = coordinatorStore; foreign.countryCode = "GB"
        await #expect(throws: CoordinatorError.self) {
            try await f.coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [foreign], location: "Synthetic", runContinuously: false)
        }
        for (preferences, location) in [(f.preferences, " "), ({ var p = f.preferences; p.attemptWindow.end = coordinatorTestDate; return p }(), "Synthetic"),
                                        ({ var p = f.preferences; p.maximumTotal = 0; return p }(), "Synthetic")] {
            await #expect(throws: CoordinatorError.self) {
                try await f.coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: location, runContinuously: false)
            }
        }
    }
    @Test func profileRemovedAfterArmingStopsPreparationWithoutExposingSecrets() async throws {
        let f = CoordinatorFixture(); try await f.arm(); await f.vault.deleteProfile()
        await f.coordinator.performCycle()
        #expect(f.driver.prepared == 0)
        #expect(f.coordinator.detail.contains("secure profile or order storage is unavailable"))
        f.coordinator.stop()
    }
    @Test(arguments: [false, true]) func networkAndCancellationStayDistinctBeforePreparation(cancellation: Bool) async throws {
        let f = CoordinatorFixture()
        let coordinator = MonitoringCoordinator(inventory: CoordinatorFailureInventory(cancellation: cancellation), driver: f.driver, vault: f.vault, journalStore: f.journalStore, now: { coordinatorTestDate })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        await coordinator.performCycle()
        #expect(f.driver.prepared == 0)
        if cancellation { #expect(f.driver.cancelled > 0) }
        else { #expect(coordinator.detail.contains("network or response error")) }
        coordinator.stop()
    }
    @Test func cancellationDuringPreparationCancelsBrowserWithoutSubmission() async throws {
        let f = CoordinatorFixture(); let driver = CoordinatorCancellationDriver()
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: driver, vault: f.vault, journalStore: f.journalStore, now: { coordinatorTestDate })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        await coordinator.performCycle()
        #expect(driver.cancellations == 1)
        #expect(!coordinator.journal.blocksPurchase)
        coordinator.stop()
    }
    @Test func disarmingDuringIntentPersistenceNeverSubmitsAndKeepsConservativeLock() async throws {
        let f = CoordinatorFixture(); let gate = CoordinatorPauseGate()
        let journal = CoordinatorLifecycleJournal(saveGate: gate)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: journal, now: { coordinatorTestDate })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        let cycle = Task { await coordinator.performCycle() }
        await gate.waitForEntry(); coordinator.stop(); await gate.release()
        // markUncertain performs a second save. Release that independently if it reaches the storage gate.
        await gate.release()
        await cycle.value
        #expect(f.driver.submitted == 0)
        #expect(coordinator.journal.blocksPurchase)
        #expect(coordinator.status == .uncertain)
    }
    @Test(arguments: [PurchaseJournal.Phase.uncertain, .submitting])
    func verifiedConfirmationIsPersistedWithoutAnotherSubmission(phase: PurchaseJournal.Phase) async throws {
        let f = CoordinatorFixture(); let journal = CoordinatorLifecycleJournal(phase)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: journal, now: { coordinatorTestDate })
        await coordinator.restoreJournal()
        let before = try await journal.load()
        try await coordinator.reconcileConfirmation(orderID: " SYNTHETIC-AFTER-AUTH ")
        let after = try await journal.load()
        #expect(after.phase == .confirmed)
        #expect(after.orderID == "SYNTHETIC-AFTER-AUTH")
        #expect(after.attemptID == before.attemptID)
        #expect(coordinator.status == .confirmed)
        #expect(f.driver.submitted == 0)
        await #expect(throws: CoordinatorError.self) { try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false) }
    }
    @Test func confirmationStorageFailurePreservesDurablePendingLock() async throws {
        let f = CoordinatorFixture(); let journal = CoordinatorLifecycleJournal(.uncertain)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: journal, now: { coordinatorTestDate })
        await coordinator.restoreJournal(); await journal.setFailSave()
        await #expect(throws: TestFailure.self) { try await coordinator.reconcileConfirmation(orderID: "SYNTHETIC") }
        #expect(coordinator.status == .uncertain)
        #expect(coordinator.journal.phase == .uncertain)
        #expect(await journal.durableValue().blocksPurchase)
        #expect(f.driver.submitted == 0)
    }
    @Test func confirmationRequiresPendingSubmissionNonemptyNumberAndDisarmedState() async throws {
        let f = CoordinatorFixture()
        await #expect(throws: CoordinatorError.self) { try await f.coordinator.reconcileConfirmation(orderID: "SYNTHETIC") }
        await #expect(throws: CoordinatorError.self) { try await f.coordinator.reconcileConfirmation(orderID: " \n ") }
        try await f.arm()
        await #expect(throws: CoordinatorError.self) { try await f.coordinator.reconcileConfirmation(orderID: "SYNTHETIC") }
        f.coordinator.stop()
    }
    @Test func continuousPickupWindowsAllowOneOvernightIntervalAndRejectClosedGaps() {
        let formatter = ISO8601DateFormatter()
        let night = DailyWindow(startMinute: 22 * 60, endMinute: 2 * 60)
        let late = formatter.date(from: "2026-10-17T23:00:00Z")!
        let early = formatter.date(from: "2026-10-18T01:00:00Z")!
        #expect(night.contains(start: late, end: early, timeZone: "UTC"))
        #expect(!night.contains(start: early, end: late, timeZone: "UTC"))
        #expect(!night.contains(start: late, end: early.addingTimeInterval(86400), timeZone: "UTC"))
        let daytime = DailyWindow(startMinute: 9 * 60, endMinute: 17 * 60)
        let dayStart = formatter.date(from: "2026-10-17T09:00:00Z")!
        let dayEnd = formatter.date(from: "2026-10-17T17:00:00Z")!
        #expect(daytime.contains(start: dayStart, end: dayEnd, timeZone: "UTC"))
        #expect(!daytime.contains(start: dayStart, end: dayEnd.addingTimeInterval(86400), timeZone: "UTC"))
        var preferences = PilotPreferences()
        preferences.pickupWindow = DateWindow(start: dayStart, end: dayEnd.addingTimeInterval(86400))
        preferences.pickupHours = daytime; preferences.timeZoneIdentifier = "UTC"
        #expect(preferences.permitsPickup(at: dayStart))
        #expect(!preferences.permitsPickup(at: dayEnd.addingTimeInterval(3600)))
        #expect(!preferences.permitsPickup(at: dayEnd.addingTimeInterval(2 * 86400)))
    }
}

private actor CoordinatorPausedInventory: InventoryFetching {
    let gate: CoordinatorPauseGate
    init(gate: CoordinatorPauseGate) { self.gate = gate }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        await gate.pause()
        return InventorySnapshot(stores: [coordinatorStore], availability: [StoreAvailability(storeID: coordinatorStore.id, variantID: coordinatorVariant.id, state: .available, message: "Synthetic")])
    }
}
@MainActor private final class CoordinatorPausedFailureDriver: CheckoutDriver {
    let gate: CoordinatorPauseGate
    var cancellations = 0
    init(gate: CoordinatorPauseGate) { self.gate = gate }
    func prepare(request: CheckoutRequest, profile: SecureProfile) async throws -> CheckoutReview {
        await gate.pause(); throw CheckoutError.unsupportedPage
    }
    func submit(review: CheckoutReview) async throws -> CheckoutOutcome { Issue.record("Stopped prepare submitted"); return .unavailable }
    func cancel() { cancellations += 1 }
}
@MainActor @Suite struct CoordinatorLateCompletionTests {
    @Test func successfulInventoryReturningAfterDisarmCannotPrepareCheckout() async throws {
        let f = CoordinatorFixture(); let gate = CoordinatorPauseGate()
        let coordinator = MonitoringCoordinator(inventory: CoordinatorPausedInventory(gate: gate), driver: f.driver, vault: f.vault, journalStore: f.journalStore, now: { coordinatorTestDate })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        let cycle = Task { await coordinator.performCycle() }
        await gate.waitForEntry(); coordinator.stop(); await gate.release(); await cycle.value
        #expect(f.driver.prepared == 0)
        #expect(coordinator.status == .stopped)
    }
    @Test func genericPreparationFailureReturningAfterDisarmDoesNotRestartMonitor() async throws {
        let f = CoordinatorFixture(); let gate = CoordinatorPauseGate(); let driver = CoordinatorPausedFailureDriver(gate: gate)
        let coordinator = MonitoringCoordinator(inventory: f.inventory, driver: driver, vault: f.vault, journalStore: f.journalStore, now: { coordinatorTestDate })
        try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        let cycle = Task { await coordinator.performCycle() }
        await gate.waitForEntry(); coordinator.stop(); await gate.release(); await cycle.value
        #expect(!coordinator.isArmed)
        #expect(coordinator.status == .stopped)
        #expect(!coordinator.journal.blocksPurchase)
    }
    @Test func namedProductionClockCompletesAnUncancelledZeroDelay() async throws {
        try await MonitoringClock.sleep(0)
    }
    @Test func reconciledConfirmationRetainsReceiptFromTheSingleSubmittedAttempt() async throws {
        let f = CoordinatorFixture(); f.driver.outcome = .requiresAuthentication
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .uncertain && !f.coordinator.isArmed && f.coordinator.journal.blocksPurchase)
        #expect(!f.coordinator.detail.lowercased().contains("authentication") && !f.coordinator.detail.lowercased().contains("sign-in"))
        f.coordinator.resumeAuthentication(); await f.coordinator.performCycle()
        #expect(f.driver.submitted == 1 && f.coordinator.journal.blocksPurchase)
        let pending = f.coordinator.journal
        #expect(pending.receipt != nil)
        try await f.coordinator.reconcileConfirmation(orderID: "SYNTHETIC-AFTER-BANK-AUTH")
        #expect(f.coordinator.journal.phase == .confirmed)
        #expect(f.coordinator.journal.receipt == pending.receipt)
        #expect(f.coordinator.journal.attemptID == pending.attemptID)
        #expect(f.driver.submitted == 1)
    }
}
