import Foundation
import Testing
@testable import PilotCore

let coordinatorTestDate = Date(timeIntervalSince1970: 1_800_000_000)
func coordinatorTestProfile() -> SecureProfile {
    SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "test@example.invalid", phone: "+14165550100", cardholder: "Synthetic Tester", cardNumber: "4111111111111111", expiryMonth: "12", expiryYear: "2099", cvv: "123", billingLine1: "1 Test Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
}
let coordinatorVariant = ProductVariant(id: "TEST/CA", name: "Synthetic iPhone", storage: "256GB", color: "Night Sky", productURL: Market.ca.productBaseURL.appendingPathComponent("test"))
let coordinatorStore = RetailStore(id: "TESTSTORE", name: "Synthetic Store")

actor CoordinatorTestVault: SecureVault {
    var profile: SecureProfile? = coordinatorTestProfile()
    var session: Data?
    var order: Data?
    func saveProfile(_ profile: SecureProfile) { self.profile = profile }
    func loadProfile() -> SecureProfile? { profile }
    func deleteProfile() { profile = nil }
    func saveSession(_ data: Data) { session = data }
    func loadSession() -> Data? { session }
    func deleteSession() { session = nil }
    func saveOrderState(_ data: Data) { order = data }
    func loadOrderState() -> Data? { order }
    func deleteOrderState() { order = nil }
    func clear() { profile = nil; session = nil; order = nil }
}
actor CoordinatorTestInventory: InventoryProviding {
    var response = InventorySnapshot(stores: [coordinatorStore], availability: [StoreAvailability(storeID: coordinatorStore.id, variantID: coordinatorVariant.id, state: .available, message: "Synthetic stock")])
    var failure: AppleServiceError?
    var calls = 0
    func setResponse(_ value: InventorySnapshot) { response = value }
    func setFailure(_ value: AppleServiceError?) { failure = value }
    func fetch(market: Market, location: String, variants: [ProductVariant]) throws -> InventorySnapshot {
        calls += 1
        if let failure { throw failure }
        return response
    }
}
actor CoordinatorTestJournalStore: PurchaseJournalStore {
    var value = PurchaseJournal()
    var saves = 0
    var failSave = false
    var failLoad = false
    func set(_ value: PurchaseJournal) { self.value = value }
    func setFailSave(_ value: Bool) { failSave = value }
    func setFailLoad(_ value: Bool) { failLoad = value }
    func load() throws -> PurchaseJournal { if failLoad { throw TestFailure.storage }; return value }
    func save(_ journal: PurchaseJournal) throws { if failSave { throw TestFailure.storage }; value = journal; saves += 1 }
}
enum TestFailure: Error { case storage, submit }
@MainActor final class CoordinatorTestDriver: CheckoutDriver {
    var prepared = 0
    var submitted = 0
    var cancelled = 0
    var prepareError: CheckoutError?
    var preparedProfiles: [SecureProfile] = []
    var submitError = false
    var submitCheckoutError: CheckoutError?
    var outcome: CheckoutOutcome = .confirmed(orderID: "SYNTHETIC-ORDER")
    var unsafeReview = false
    var beforeSubmit: (() async -> Void)?
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        prepared += 1
        preparedProfiles.append(profile)
        if let prepareError { throw prepareError }
        return CheckoutReview(variantID: request.variant.id, storeID: request.store.id, quantity: unsafeReview ? 2 : 1, total: 2500, currencyCode: "CAD", pickupDate: coordinatorTestDate.addingTimeInterval(3600), pickupEndDate: coordinatorTestDate.addingTimeInterval(7200), pickupSlot: "Synthetic slot", expiresAt: coordinatorTestDate.addingTimeInterval(600))
    }
    func submit(review: CheckoutReview) async throws -> CheckoutOutcome {
        submitted += 1
        await beforeSubmit?()
        if let submitCheckoutError { throw submitCheckoutError }
        if submitError { throw TestFailure.submit }
        return outcome
    }
    func cancel() { cancelled += 1 }
}
@MainActor struct CoordinatorFixture {
    let vault = CoordinatorTestVault()
    let inventory = CoordinatorTestInventory()
    let driver = CoordinatorTestDriver()
    let journalStore = CoordinatorTestJournalStore()
    let coordinator: MonitoringCoordinator
    var preferences: PilotPreferences
    init() {
        coordinator = MonitoringCoordinator(inventory: inventory, driver: driver, vault: vault, journalStore: journalStore, now: { coordinatorTestDate }, sleep: { _ in throw CancellationError() })
        var p = PilotPreferences()
        p.selectedStoreIDs = [coordinatorStore.id]; p.selectedVariantIDs = [coordinatorVariant.id]
        p.attemptWindow = DateWindow(start: coordinatorTestDate.addingTimeInterval(-60), end: coordinatorTestDate.addingTimeInterval(86400))
        p.pickupWindow = DateWindow(start: coordinatorTestDate, end: coordinatorTestDate.addingTimeInterval(86400))
        p.timeZoneIdentifier = "UTC"
        preferences = p
    }
    func arm() async throws {
        try await coordinator.arm(configuration: preferences, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Synthetic location", runContinuously: false)
    }
}

@MainActor @Suite struct MonitoringCoordinatorTests {
    @Test func writesIntentBeforeOneSubmissionAndLocksRestart() async throws {
        let f = CoordinatorFixture()
        f.driver.beforeSubmit = {
            let journal = try? await f.journalStore.load()
            #expect(journal?.phase == .submitting)
        }
        try await f.arm()
        await f.coordinator.performCycle()
        #expect(f.coordinator.status == .confirmed)
        #expect(!f.coordinator.isArmed)
        #expect(f.driver.submitted == 1)
        #expect(f.coordinator.journal.orderID == "SYNTHETIC-ORDER")
        await f.coordinator.performCycle()
        #expect(f.driver.submitted == 1)
        await #expect(throws: CoordinatorError.self) { try await f.arm() }
        let restart = MonitoringCoordinator(inventory: f.inventory, driver: f.driver, vault: f.vault, journalStore: f.journalStore)
        await restart.restoreJournal()
        #expect(restart.status == .confirmed)
        #expect(restart.journal.blocksPurchase)
    }
    @Test(arguments: [CheckoutOutcome.requiresAuthentication, .unavailable, .indeterminate(reason: "Synthetic timeout"), .confirmed(orderID: "")])
    func uncertainSubmissionNeverRetries(_ outcome: CheckoutOutcome) async throws {
        let f = CoordinatorFixture(); f.driver.outcome = outcome
        try await f.arm(); await f.coordinator.performCycle(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .uncertain)
        #expect(f.coordinator.journal.blocksPurchase)
        #expect(f.driver.submitted == 1)
        #expect(!f.coordinator.isArmed)
    }
    @Test func submitThrowLocksThenExplicitResetAllowsNewArm() async throws {
        let f = CoordinatorFixture(); f.driver.submitError = true
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .uncertain)
        try await f.coordinator.resetPurchaseLock()
        #expect(!f.coordinator.journal.blocksPurchase)
        try await f.arm()
        f.coordinator.stop()
        #expect(f.coordinator.status == .stopped)
    }
    @Test func noStockDoesNotOpenCheckout() async throws {
        let f = CoordinatorFixture()
        await f.inventory.setResponse(InventorySnapshot(stores: [coordinatorStore], availability: [StoreAvailability(storeID: coordinatorStore.id, variantID: coordinatorVariant.id, state: .disabled, message: "Check back")]))
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .monitoring)
        #expect(f.driver.prepared == 0)
        #expect(f.coordinator.lastCheck == coordinatorTestDate)
        #expect(f.coordinator.snapshot?.availability.first?.state == .disabled)
        f.coordinator.stop()
    }
    @Test(arguments: [CheckoutError.authenticationRequired, .guestCheckoutUnavailable])
    func guestOnlyAuthenticationRequirementStopsWithoutSubmissionIntent(error: CheckoutError) async throws {
        let f = CoordinatorFixture(); f.driver.prepareError = error
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .failed)
        #expect(!f.coordinator.isArmed)
        #expect(!f.coordinator.journal.blocksPurchase)
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && f.driver.cancelled == 1)
        #expect(await f.journalStore.saves == 0)
        #expect(f.coordinator.detail.contains("guest checkout only") && f.coordinator.detail.contains("will not request"))
        #expect(!f.coordinator.detail.contains("Complete Apple") && !f.coordinator.detail.contains("then resume"))
        f.driver.prepareError = nil
        f.coordinator.resumeAuthentication(); await f.coordinator.performCycle()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && !f.coordinator.isArmed)
        #expect(await f.inventory.calls == 1)
        #expect(PilotStatus.authenticationRequired.title == "Guest checkout unavailable")
        f.coordinator.stop()
    }
    @Test(arguments: [CheckoutError.safariUnavailable, .safariPermissionRequired, .safariJavaScriptDisabled, .safariWindowUnavailable, .safariAutomationFailed])
    func safariSetupFailureDisarmsWithoutRetryAndCannotResumeRetainedProfile(error: CheckoutError) async throws {
        let f = CoordinatorFixture(); f.driver.prepareError = error
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .failed && !f.coordinator.isArmed)
        #expect(f.coordinator.detail == error.localizedDescription)
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && f.driver.cancelled == 1)
        #expect(!f.coordinator.journal.blocksPurchase)
        #expect(await f.journalStore.saves == 0)
        #expect(!f.coordinator.detail.contains(coordinatorTestProfile().cardNumber))
        #expect(!f.coordinator.detail.contains(coordinatorTestProfile().email))

        // Ordinary Continue cannot resurrect the failed preparation or its profile.
        await f.vault.deleteProfile()
        f.driver.prepareError = nil
        f.coordinator.resumeAuthentication(); await f.coordinator.performCycle()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0)
        #expect(await f.inventory.calls == 1)
        await #expect(throws: CoordinatorError.self) { try await f.arm() }

        // A fresh explicit arm must read fresh local profile values, never the paused copy.
        var fresh = coordinatorTestProfile(); fresh.givenName = "Fresh Synthetic"
        await f.vault.saveProfile(fresh)
        f.driver.prepareError = .manualInputRequired
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .manualInputRequired && f.coordinator.isArmed)
        #expect(f.driver.preparedProfiles.count == 2 && f.driver.submitted == 0)
        #expect(f.driver.preparedProfiles.last?.givenName == fresh.givenName)
        #expect(f.driver.preparedProfiles.first?.givenName != f.driver.preparedProfiles.last?.givenName)
        f.coordinator.stop()
    }

    @Test(arguments: [CheckoutError.safariUnavailable, .safariPermissionRequired, .safariJavaScriptDisabled, .safariWindowUnavailable, .safariAutomationFailed])
    func safariFailureAfterSubmissionIntentLocksUncertainAcrossRestart(error: CheckoutError) async throws {
        let f = CoordinatorFixture(); f.driver.submitCheckoutError = error
        f.driver.beforeSubmit = {
            let persisted = try? await f.journalStore.load()
            #expect(persisted?.phase == .submitting && persisted?.blocksPurchase == true)
        }
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .uncertain && !f.coordinator.isArmed)
        #expect(f.coordinator.journal.blocksPurchase && f.driver.submitted == 1)
        await f.coordinator.performCycle(); f.coordinator.resumeAuthentication()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.driver.prepared == 1 && f.driver.submitted == 1)
        #expect(await f.inventory.calls == 1)
        await #expect(throws: CoordinatorError.self) { try await f.arm() }
        let restart = MonitoringCoordinator(inventory: f.inventory, driver: f.driver,
                                             vault: f.vault, journalStore: f.journalStore)
        await restart.restoreJournal()
        #expect(restart.status == .uncertain && restart.journal.blocksPurchase)
        #expect(f.driver.submitted == 1)
    }

    @Test func manualInputPausesWithoutCancellingTheLiveCheckoutOrCreatingSubmissionIntent() async throws {
        let f = CoordinatorFixture(); f.driver.prepareError = .manualInputRequired
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .manualInputRequired)
        #expect(f.coordinator.status.title == "Checkout input needed")
        #expect(f.coordinator.isArmed && !f.coordinator.journal.blocksPurchase)
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && f.driver.cancelled == 0)
        #expect(await f.journalStore.saves == 0)
        #expect(f.coordinator.detail.contains("confirm the payment method"))
        await f.coordinator.performCycle()
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0)
        f.coordinator.resumeAuthentication()
        for _ in 0..<100 {
            if f.driver.prepared > 1 { break }
            await Task.yield()
        }
        #expect(f.driver.prepared == 2 && f.driver.submitted == 0 && f.driver.cancelled == 0)
        #expect(f.coordinator.status == .manualInputRequired)
        f.coordinator.stop()
        f.coordinator.resumeAuthentication()
        #expect(!f.coordinator.isArmed && f.coordinator.status == .stopped)
    }
    @Test func unsafeReviewAndPreparationRetryLimit() async throws {
        let f = CoordinatorFixture(); f.driver.unsafeReview = true
        try await f.arm()
        for _ in 0..<3 { await f.coordinator.performCycle() }
        #expect(f.coordinator.status == .failed)
        #expect(!f.coordinator.isArmed)
        #expect(f.driver.submitted == 0)
    }
    @Test func blockedCheckoutStopsImmediatelyWithoutSubmittingOrRetrying() async throws {
        let f = CoordinatorFixture(); f.driver.prepareError = .storefrontBlocked
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .failed && !f.coordinator.isArmed)
        #expect(f.coordinator.detail.contains("access or rate-limit response"))
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && f.driver.cancelled == 1)
        let saves = await f.journalStore.saves
        #expect(!f.coordinator.journal.blocksPurchase && saves == 0)
        await f.coordinator.performCycle()
        #expect(f.driver.prepared == 1)
    }
    @Test func missingCheckoutPageStopsWithoutCallingItABlockedSession() async throws {
        let f = CoordinatorFixture(); f.driver.prepareError = .pageNotFound
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .failed && !f.coordinator.isArmed)
        #expect(f.coordinator.detail.contains("Page Not Found") && !f.coordinator.detail.contains("blocked"))
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && f.driver.cancelled == 1)
        #expect(!f.coordinator.journal.blocksPurchase)
        #expect(await f.journalStore.saves == 0)
        await f.coordinator.performCycle(); f.coordinator.resumeAuthentication()
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && !f.coordinator.isArmed)
    }
    @Test func refusedGuestCheckoutStopsWithoutRetrySignInOrJournal() async throws {
        let f = CoordinatorFixture(); f.driver.prepareError = .guestCheckoutRefused
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .failed && !f.coordinator.isArmed)
        #expect(f.coordinator.detail.contains("refused the guest checkout") && f.coordinator.detail.contains("will not retry, sign in"))
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && f.driver.cancelled == 1)
        #expect(!f.coordinator.journal.blocksPurchase)
        #expect(await f.journalStore.saves == 0)
        await f.coordinator.performCycle(); f.coordinator.resumeAuthentication()
        #expect(f.driver.prepared == 1 && f.driver.submitted == 0 && !f.coordinator.isArmed)
    }
    @Test func storageMustSucceedBeforeSubmit() async throws {
        let f = CoordinatorFixture()
        try await f.arm(); await f.journalStore.setFailSave(true)
        await f.coordinator.performCycle()
        #expect(f.driver.submitted == 0)
        #expect(!f.coordinator.journal.blocksPurchase)
        f.coordinator.stop()
    }
    @Test func confirmedReceiptWriteFailureStillLocks() async throws {
        let f = CoordinatorFixture()
        f.driver.beforeSubmit = { await f.journalStore.setFailSave(true) }
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.status == .uncertain)
        let durable = try await f.journalStore.load()
        #expect(durable.phase == .submitting)
    }
    @Test func restorationReadFailureDoesNotEraseLock() async {
        let f = CoordinatorFixture()
        await f.journalStore.setFailLoad(true)
        await f.coordinator.restoreJournal()
        #expect(f.coordinator.status == .failed)
        await #expect(throws: TestFailure.self) { try await f.arm() }
    }
    @Test func rateLimitDoesNotAttemptPurchase() async throws {
        let f = CoordinatorFixture(); await f.inventory.setFailure(.rateLimited(retryAfter: 600))
        try await f.arm(); await f.coordinator.performCycle()
        #expect(f.coordinator.detail.contains("600"))
        #expect(f.driver.submitted == 0)
        f.coordinator.stop()
    }
    @Test func armRejectsMissingProfileAndStaleChoices() async throws {
        let f = CoordinatorFixture(); await f.vault.deleteProfile()
        await #expect(throws: CoordinatorError.self) { try await f.arm() }
        var p = f.preferences; p.selectedVariantIDs = ["OTHER"]
        await #expect(throws: CoordinatorError.self) {
            try await f.coordinator.arm(configuration: p, variants: [coordinatorVariant], stores: [coordinatorStore], location: "Test", runContinuously: false)
        }
    }
    @Test func resetWhileArmedAndDoubleArmAreRejected() async throws {
        let f = CoordinatorFixture(); try await f.arm()
        await #expect(throws: CoordinatorError.self) { try await f.coordinator.resetPurchaseLock() }
        await #expect(throws: CoordinatorError.self) { try await f.arm() }
        f.coordinator.stop()
    }
    @Test func journalKeychainCodec() async throws {
        let vault = CoordinatorTestVault(); let store = KeychainJournalStore(vault: vault)
        let empty = try await store.load(); #expect(empty.phase == .idle)
        let record = PurchaseJournal(phase: .uncertain, attemptID: UUID(), orderID: "Synthetic", variantID: "TEST", storeID: "TESTSTORE", updatedAt: coordinatorTestDate)
        try await store.save(record)
        let loaded = try await store.load(); #expect(loaded == record)
        await vault.saveOrderState(Data("broken".utf8))
        await #expect(throws: (any Error).self) { try await store.load() }
    }
}
