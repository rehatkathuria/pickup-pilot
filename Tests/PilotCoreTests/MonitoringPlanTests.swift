import Foundation
import Synchronization
import Testing
@testable import PilotCore

private final class PlanClock: Sendable {
    private let value = Mutex(coordinatorTestDate)
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
private actor PlanGate {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
private enum PlanReply: Sendable {
    case result(InventorySnapshot), failure(AppleServiceError), cancelled
}
private struct PlanFetch: Equatable, Sendable {
    let market: Market
    let location: String
    let variants: [ProductVariant]
}
private actor PlanInventory: InventoryFetching {
    private var replies: [PlanReply]
    private var gate: PlanGate?
    private let clock: PlanClock
    private(set) var requests: [PlanFetch] = []
    init(clock: PlanClock, replies: [PlanReply]) { self.clock = clock; self.replies = replies }
    func setGate(_ gate: PlanGate?) { self.gate = gate }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        requests.append(PlanFetch(market: market, location: location, variants: variants))
        let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
        if let gate { await gate.pause() }
        // Deliberately ignores caller cancellation, exercising the coordinator's stale-result guard.
        clock.advance(2)
        switch reply {
        case .result(let result): return result
        case .failure(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }
}
@MainActor private final class PlanDriver: CheckoutDriver {
    var pause: CheckoutError = .manualInputRequired
    private(set) var requests: [CheckoutRequest] = []
    private(set) var submits = 0
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        requests.append(request); throw pause
    }
    func submit(review: CheckoutReview) -> CheckoutOutcome { submits += 1; return .unavailable }
    func cancel() {}
}
private actor PlanVault: SecureVault {
    let gate: PlanGate?
    init(gate: PlanGate? = nil) { self.gate = gate }
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() async -> SecureProfile? { if let gate { await gate.pause() }; return coordinatorTestProfile() }
    func deleteProfile() {}
    func saveSession(_ data: Data) {}
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() {}
}
private actor PlanJournal: PurchaseJournalStore {
    let gate: PlanGate?
    init(gate: PlanGate? = nil) { self.gate = gate }
    func load() async -> PurchaseJournal { if let gate { await gate.pause() }; return PurchaseJournal() }
    func save(_ journal: PurchaseJournal) {}
}

@Suite @MainActor struct MonitoringPlanTests {
    private var noStock: InventorySnapshot { InventorySnapshot(stores: [coordinatorStore], availability: []) }
    private var stock: InventorySnapshot {
        InventorySnapshot(stores: [coordinatorStore], availability: [StoreAvailability(storeID: coordinatorStore.id, variantID: coordinatorVariant.id,
                                                                                     state: .available, message: "Synthetic pickup quote")])
    }
    private func makeCoordinator(_ inventory: PlanInventory, clock: PlanClock, fixture: CoordinatorFixture,
                                 driver: (any CheckoutDriver)? = nil) -> MonitoringCoordinator {
        MonitoringCoordinator(inventory: inventory, driver: driver ?? fixture.driver, vault: fixture.vault, journalStore: fixture.journalStore,
                              now: { clock.now() }, sleep: { _ in throw CancellationError() })
    }
    private func arm(_ coordinator: MonitoringCoordinator, fixture: CoordinatorFixture, location: String = "Synthetic city") async throws {
        try await coordinator.arm(configuration: fixture.preferences, variants: [coordinatorVariant], stores: [coordinatorStore],
                                  location: location, runContinuously: false)
    }
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 { if condition() { return }; await Task.yield() }
        throw TestFailure.storage
    }

    @Test func selectedPlanFreezesOrderedScopeAndPriorityControlsTheChoice() async throws {
        let f = CoordinatorFixture(), clock = PlanClock(), driver = PlanDriver()
        let second = ProductVariant(id: "SECOND/CA", name: "Synthetic second configuration", storage: "512GB", color: "Synthetic",
                                    productURL: Market.ca.productBaseURL.appendingPathComponent("second"))
        let secondStore = RetailStore(id: "SECONDSTORE", name: "Synthetic second store")
        let all = InventorySnapshot(stores: [coordinatorStore, secondStore], availability:
            [coordinatorVariant, second].flatMap { variant in [coordinatorStore, secondStore].map {
                StoreAvailability(storeID: $0.id, variantID: variant.id, state: .available, message: "Synthetic quote")
            } })
        let inventory = PlanInventory(clock: clock, replies: [.result(all)])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f, driver: driver)
        var preferences = f.preferences
        preferences.selectedVariantIDs = [second.id, coordinatorVariant.id]
        preferences.selectedStoreIDs = [secondStore.id, coordinatorStore.id]
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant, second], stores: [coordinatorStore, secondStore],
                                  location: "Synthetic priority city", runContinuously: false)
        let expected = MonitoringPlan(configuration: preferences, variants: [second, coordinatorVariant], stores: [secondStore, coordinatorStore], location: "Synthetic priority city")
        #expect(coordinator.monitoringPlan == expected)
        preferences.selectedVariantIDs.reverse(); preferences.maximumTotal = 1
        #expect(coordinator.monitoringPlan == expected) // Caller edits cannot mutate the armed value copy.
        await coordinator.performCycle()
        #expect(await inventory.requests == [PlanFetch(market: .ca, location: expected.location, variants: expected.variants)])
        #expect(driver.requests.first?.variant == second && driver.requests.first?.store == secondStore)
        #expect(coordinator.events.contains { $0.message.contains(second.name) && $0.message.contains(second.id) && $0.message.contains(secondStore.name) })
        #expect(driver.submits == 0 && coordinator.checkCount == 1)
        coordinator.stop()
        #expect(coordinator.monitoringPlan == expected)
    }

    @Test func onlySuccessfulRearmResetsPlanSnapshotAndTelemetry() async throws {
        let f = CoordinatorFixture(), clock = PlanClock()
        let inventory = PlanInventory(clock: clock, replies: [.result(noStock), .failure(.blocked(541))])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f)
        try await arm(coordinator, fixture: f)
        await coordinator.performCycle(); await coordinator.performCycle(); coordinator.stop()
        let originalPlan = coordinator.monitoringPlan, originalSnapshot = coordinator.snapshot
        let originalStarted = coordinator.lastCheckStarted, originalFinished = coordinator.lastCheckFinished
        #expect(coordinator.checkCount == 2 && coordinator.lastCheckError != nil)
        var invalid = f.preferences; invalid.maximumTotal = 0
        await #expect(throws: CoordinatorError.self) {
            try await coordinator.arm(configuration: invalid, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Different", runContinuously: false)
        }
        #expect(coordinator.monitoringPlan == originalPlan && coordinator.snapshot == originalSnapshot && coordinator.checkCount == 2)
        #expect(coordinator.lastCheckStarted == originalStarted && coordinator.lastCheckFinished == originalFinished)
        try await arm(coordinator, fixture: f, location: "Synthetic next city")
        #expect(coordinator.monitoringPlan?.location == "Synthetic next city")
        #expect(coordinator.snapshot == nil && coordinator.lastCheck == nil && coordinator.nextCheck == nil)
        #expect(coordinator.checkCount == 0 && coordinator.lastCheckStarted == nil && coordinator.lastCheckFinished == nil)
        #expect(coordinator.lastCheckError == nil && !coordinator.isCheckingInventory)
        #expect(coordinator.detail == "Armed for 1 selected configuration at 1 pickup store. Waiting for the first availability check.")
        coordinator.stop()
    }

    @Test func failedCheckRetainsLastSuccessButMarksItStaleUntilANewSuccess() async throws {
        let f = CoordinatorFixture(), clock = PlanClock()
        let inventory = PlanInventory(clock: clock, replies: [.result(noStock), .failure(.invalidResponse("synthetic-secret-token")), .result(noStock)])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f)
        try await arm(coordinator, fixture: f)
        await coordinator.performCycle()
        let successful = coordinator.lastCheck
        #expect(successful == coordinatorTestDate.addingTimeInterval(2))
        #expect(coordinator.lastCheckStarted == coordinatorTestDate && coordinator.lastCheckFinished == successful)
        await coordinator.performCycle()
        #expect(coordinator.snapshot == noStock && coordinator.lastCheck == successful && coordinator.checkCount == 2)
        #expect(coordinator.lastCheckStarted == coordinatorTestDate.addingTimeInterval(2))
        #expect(coordinator.lastCheckFinished == coordinatorTestDate.addingTimeInterval(4))
        #expect(coordinator.lastCheckError == "Apple's availability response could not be safely verified")
        #expect(!coordinator.detail.contains("synthetic-secret-token") && !coordinator.events.contains { $0.message.contains("synthetic-secret-token") })
        let gate = PlanGate(); await inventory.setGate(gate)
        let retry = Task { await coordinator.performCycle() }; await gate.waitForEntry()
        #expect(coordinator.isCheckingInventory && coordinator.lastCheckFinished == nil && coordinator.lastCheckError != nil)
        #expect(coordinator.snapshot == noStock && coordinator.lastCheck == successful && coordinator.checkCount == 3)
        await gate.release(); await retry.value
        #expect(!coordinator.isCheckingInventory && coordinator.lastCheckError == nil)
        #expect(coordinator.lastCheck == coordinatorTestDate.addingTimeInterval(6) && coordinator.lastCheckFinished == coordinator.lastCheck)
        coordinator.stop()
    }

    @Test(arguments: [false, true])
    func stopClearsInFlightStateAndIgnoresLateSuccessOrFailure(failure: Bool) async throws {
        let f = CoordinatorFixture(), clock = PlanClock(), gate = PlanGate()
        let inventory = PlanInventory(clock: clock, replies: [failure ? .failure(.blocked(541)) : .result(stock)])
        await inventory.setGate(gate)
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f)
        try await arm(coordinator, fixture: f)
        let pending = Task { await coordinator.performCycle() }; await gate.waitForEntry()
        await coordinator.performCycle()
        #expect(coordinator.checkCount == 1)
        #expect(await inventory.requests.count == 1)
        #expect(coordinator.isCheckingInventory && coordinator.snapshot == nil && coordinator.lastCheckFinished == nil)
        coordinator.stop()
        let finished = coordinator.lastCheckFinished, error = coordinator.lastCheckError
        #expect(!coordinator.isCheckingInventory && error == "Availability check was cancelled.")
        await gate.release(); await pending.value
        #expect(coordinator.status == .stopped && coordinator.snapshot == nil && coordinator.lastCheck == nil)
        #expect(coordinator.lastCheckFinished == finished && coordinator.lastCheckError == error && coordinator.checkCount == 1)
        #expect(f.driver.prepared == 0 && f.driver.submitted == 0)
    }

    @Test func waitingForScheduleDoesNotInventAnInventoryCheck() async throws {
        let f = CoordinatorFixture(), clock = PlanClock()
        let inventory = PlanInventory(clock: clock, replies: [.result(noStock)])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f)
        var preferences = f.preferences
        preferences.attemptWindow.start = coordinatorTestDate.addingTimeInterval(100)
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic", runContinuously: false)
        await coordinator.performCycle()
        #expect(coordinator.status == .waiting && coordinator.monitoringPlan != nil)
        #expect(coordinator.checkCount == 0 && coordinator.lastCheckStarted == nil && coordinator.lastCheckFinished == nil)
        #expect(coordinator.lastCheck == nil && coordinator.lastCheckError == nil && !coordinator.isCheckingInventory)
        #expect(await inventory.requests.isEmpty)
        coordinator.stop()
    }

    @Test(arguments: [CheckoutError.manualInputRequired])
    func checkoutHandoffAndResumeDoNotFabricateAnotherInventorySuccess(pause: CheckoutError) async throws {
        let f = CoordinatorFixture(), clock = PlanClock(), driver = PlanDriver(); driver.pause = pause
        let inventory = PlanInventory(clock: clock, replies: [.result(stock)])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f, driver: driver)
        try await arm(coordinator, fixture: f); await coordinator.performCycle()
        let started = coordinator.lastCheckStarted, finished = coordinator.lastCheckFinished
        #expect(coordinator.checkCount == 1 && !coordinator.isCheckingInventory && coordinator.lastCheckError == nil)
        await coordinator.performCycle()
        #expect(coordinator.checkCount == 1)
        clock.advance(10); coordinator.resumeAuthentication()
        try await eventually { driver.requests.count == 2 }
        #expect(coordinator.checkCount == 1)
        #expect(await inventory.requests.count == 1)
        #expect(coordinator.lastCheckStarted == started && coordinator.lastCheckFinished == finished && coordinator.lastCheck == finished)
        #expect(!coordinator.isCheckingInventory && coordinator.lastCheckError == nil && driver.submits == 0)
        coordinator.stop()
    }

    @Test func postInventoryProfileFailureDoesNotMislabelTheSuccessfulNetworkRequest() async throws {
        let f = CoordinatorFixture(), clock = PlanClock()
        let inventory = PlanInventory(clock: clock, replies: [.result(stock)])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f)
        try await arm(coordinator, fixture: f); await f.vault.deleteProfile(); await coordinator.performCycle()
        #expect(coordinator.checkCount == 1 && coordinator.snapshot == stock && coordinator.lastCheck != nil)
        #expect(coordinator.lastCheckError == nil && coordinator.lastCheckFinished == coordinator.lastCheck && !coordinator.isCheckingInventory)
        #expect(f.driver.prepared == 0 && f.driver.submitted == 0)
        coordinator.stop()
    }

    @Test func canceledTransportNeverCountsAsSuccessfulInventory() async throws {
        let f = CoordinatorFixture(), clock = PlanClock()
        let inventory = PlanInventory(clock: clock, replies: [.cancelled])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f)
        try await arm(coordinator, fixture: f); await coordinator.performCycle()
        #expect(coordinator.checkCount == 1 && coordinator.snapshot == nil && coordinator.lastCheck == nil)
        #expect(!coordinator.isCheckingInventory && coordinator.lastCheckFinished != nil && coordinator.lastCheckError == "Availability check was cancelled.")
        #expect(coordinator.status == .monitoring && f.driver.prepared == 0)
        coordinator.stop()
    }

    @Test(arguments: ["journal", "profile"])
    func approvalRevokedDuringStorageAwaitNeverActivatesMonitoring(stage: String) async throws {
        let f = CoordinatorFixture(), clock = PlanClock(), gate = PlanGate()
        let inventory = PlanInventory(clock: clock, replies: [.result(stock)])
        let vault = PlanVault(gate: stage == "profile" ? gate : nil), journal = PlanJournal(gate: stage == "journal" ? gate : nil)
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: f.driver, vault: vault, journalStore: journal, now: { clock.now() })
        var approved = true
        let pending = Task {
            try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic",
                                      authorizationCheck: { approved })
        }
        await gate.waitForEntry(); approved = false; await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!coordinator.isArmed && coordinator.monitoringPlan == nil && coordinator.checkCount == 0)
        #expect(coordinator.snapshot == nil && !coordinator.isCheckingInventory)
        #expect(await inventory.requests.isEmpty)
    }

    @Test func approvalIsCheckedAgainImmediatelyBeforeActivation() async throws {
        let f = CoordinatorFixture(), clock = PlanClock()
        let inventory = PlanInventory(clock: clock, replies: [.result(stock)])
        let coordinator = makeCoordinator(inventory, clock: clock, fixture: f)
        var validations = 0
        await #expect(throws: CancellationError.self) {
            try await coordinator.arm(configuration: f.preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic",
                                      authorizationCheck: { validations += 1; return validations < 3 })
        }
        #expect(validations == 3 && !coordinator.isArmed && coordinator.monitoringPlan == nil)
        #expect(coordinator.checkCount == 0)
        #expect(await inventory.requests.isEmpty)
    }
}
