import Foundation
import Testing
import Synchronization
@testable import PilotCore

private let edgeNow = Date(timeIntervalSince1970: 1_792_147_200)
private func edgeProfile() -> SecureProfile {
    SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid", phone: "+14165550100",
                  cardholder: "Synthetic Tester", cardNumber: "4111111111111111", expiryMonth: "12", expiryYear: "2099",
                  cvv: "123", billingLine1: "1 Synthetic Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
}
private func edgeVariant(market: Market = .ca) -> ProductVariant {
    ProductVariant(id: "SYNTHETIC/A", name: "Synthetic iPhone", storage: "256GB", color: "Night Sky", productURL: market.productBaseURL.appendingPathComponent("synthetic"))
}
private let edgeStore = RetailStore(id: "RTEST", name: "Synthetic store")
private func edgePreferences() -> PilotPreferences {
    var value = PilotPreferences()
    value.selectedVariantIDs = ["SYNTHETIC/A"]; value.selectedStoreIDs = ["RTEST"]
    value.attemptWindow = DateWindow(start: edgeNow.addingTimeInterval(-3600), end: edgeNow.addingTimeInterval(3600))
    value.pickupWindow = DateWindow(start: edgeNow, end: edgeNow.addingTimeInterval(3 * 86400))
    value.timeZoneIdentifier = "UTC"
    return value
}
private actor EdgeGate {
    private var didEnter = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        didEnter = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async {
        if didEnter { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor EdgeInventory: InventoryProviding {
    let gate: EdgeGate?
    let failure: AppleServiceError?
    init(gate: EdgeGate? = nil, failure: AppleServiceError? = nil) { self.gate = gate; self.failure = failure }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        if let gate { await gate.pause() }
        if let failure { throw failure }
        return InventorySnapshot(stores: [edgeStore], availability: [StoreAvailability(storeID: edgeStore.id, variantID: "SYNTHETIC/A", state: .available, message: "Synthetic only")])
    }
}
private actor EdgeVault: SecureVault {
    let gate: EdgeGate?
    private var loads = 0
    private var profile: SecureProfile? = edgeProfile()
    init(gate: EdgeGate? = nil) { self.gate = gate }
    func loadProfile() async throws -> SecureProfile? { loads += 1; if loads == 2, let gate { await gate.pause() }; return profile }
    func saveProfile(_ profile: SecureProfile) async throws { self.profile = profile }
    func deleteProfile() async throws { profile = nil }
    func saveSession(_ data: Data) async throws {}
    func loadSession() async throws -> Data? { nil }
    func deleteSession() async throws {}
    func saveOrderState(_ data: Data) async throws {}
    func loadOrderState() async throws -> Data? { nil }
    func deleteOrderState() async throws {}
    func clear() async throws { profile = nil }
}
private actor EdgeJournal: PurchaseJournalStore {
    private var journal = PurchaseJournal()
    func load() async throws -> PurchaseJournal { journal }
    func save(_ journal: PurchaseJournal) async throws { self.journal = journal }
}
@MainActor private final class EdgeDriver: CheckoutDriver {
    var prepareCalls = 0; var submitCalls = 0; var cancelCalls = 0
    let gate: EdgeGate?
    let authenticationFailure: Bool
    init(gate: EdgeGate? = nil, authenticationFailure: Bool = false) { self.gate = gate; self.authenticationFailure = authenticationFailure }
    func prepare(request: CheckoutRequest, profile: SecureProfile) async throws -> CheckoutReview {
        prepareCalls += 1
        if let gate { await gate.pause() }
        if authenticationFailure { throw CheckoutError.authenticationRequired }
        return CheckoutReview(variantID: request.variant.id, storeID: request.store.id, quantity: 1, total: 3000, currencyCode: request.market.currencyCode,
                              pickupDate: edgeNow.addingTimeInterval(86400), pickupEndDate: edgeNow.addingTimeInterval(86400 + 900), pickupSlot: "Synthetic slot", expiresAt: edgeNow.addingTimeInterval(300))
    }
    func submit(review: CheckoutReview) async throws -> CheckoutOutcome { submitCalls += 1; return .confirmed(orderID: "SYNTHETIC-ONLY") }
    func cancel() { cancelCalls += 1 }
}

@Test @MainActor func coordinatorRequiresVariantsFromTheExplicitSelectedCatalog() async throws {
    let adapter = ProductVariant(id: CatalogProduct.adapterSKU, name: "Synthetic adapter", storage: "", color: "", productURL: CatalogProduct.adapterURL)
    var preferences = edgePreferences()
    preferences.catalogProduct = .usbCHeadphoneAdapter
    preferences.selectedVariantIDs = [adapter.id]
    let accepted = MonitoringCoordinator(inventory: EdgeInventory(), driver: EdgeDriver(), vault: EdgeVault(), journalStore: EdgeJournal(), now: { edgeNow })
    try await accepted.arm(configuration: preferences, variants: [adapter], stores: [edgeStore], location: "Synthetic public location", runContinuously: false)
    #expect(accepted.isArmed && accepted.journal.phase == .idle)
    accepted.stop()
    var wrongIdentity = adapter; wrongIdentity.id = "OTHER/A"
    var wrongURL = adapter; wrongURL.productURL = edgeVariant().productURL
    let phone = edgeVariant()
    let cases: [(CatalogProduct, Market, [ProductVariant])] = [
        (.iPhoneDuo, .ca, [adapter]), (.usbCHeadphoneAdapter, .ca, [phone]),
        (.usbCHeadphoneAdapter, .ca, [wrongIdentity]), (.usbCHeadphoneAdapter, .ca, [wrongURL]),
        (.usbCHeadphoneAdapter, .ca, [adapter, phone]), (.iPhoneDuo, .ca, [phone, adapter]),
        (.usbCHeadphoneAdapter, .uk, [adapter])
    ]
    for (product, market, variants) in cases {
        var invalid = preferences; invalid.catalogProduct = product; invalid.market = market
        invalid.selectedVariantIDs = variants.map(\.id)
        let driver = EdgeDriver()
        let coordinator = MonitoringCoordinator(inventory: EdgeInventory(), driver: driver, vault: EdgeVault(), journalStore: EdgeJournal(), now: { edgeNow })
        do {
            try await coordinator.arm(configuration: invalid, variants: variants, stores: [edgeStore], location: "Synthetic public location", runContinuously: false)
            Issue.record("A mismatched catalog must not arm")
        } catch CoordinatorError.invalidConfiguration {}
        #expect(!coordinator.isArmed && driver.prepareCalls == 0 && driver.submitCalls == 0 && coordinator.journal.phase == .idle)
    }
}

@Test func dailyHoursSpanMidnightAndUsePhysicalStoreTimezoneCorrectly() {
    let window = DailyWindow(startMinute: 22 * 60, endMinute: 2 * 60)
    let parser = ISO8601DateFormatter()
    for instant in ["2026-10-17T02:00:00Z", "2026-10-17T05:30:00Z", "2026-10-17T06:00:59Z"] {
        #expect(window.contains(parser.date(from: instant)!, timeZone: "America/Toronto"))
    }
    #expect(!window.contains(parser.date(from: "2026-10-17T06:01:00Z")!, timeZone: "America/Toronto"))
    #expect(!window.contains(parser.date(from: "2026-10-16T22:00:00Z")!, timeZone: "America/Toronto"))
    #expect(!window.contains(edgeNow, timeZone: "Invalid/Timezone"))
    #expect(!DailyWindow(startMinute: -1).contains(edgeNow, timeZone: "UTC"))
    #expect(!DateWindow(start: edgeNow.addingTimeInterval(1), end: edgeNow).contains(edgeNow))
}
@Test func monetaryLimitMustRejectNaNAndConfigurationMustRejectDuplicateChoices() {
    var value = edgePreferences()
    value.maximumTotal = .nan
    #expect(!value.validationIssues.isEmpty)
    value = edgePreferences(); value.selectedVariantIDs += value.selectedVariantIDs
    #expect(!value.validationIssues.isEmpty)
    value = edgePreferences(); value.selectedStoreIDs += value.selectedStoreIDs
    #expect(!value.validationIssues.isEmpty)
}
@Test @MainActor func coordinatorRejectsCrossCountryCatalogAtArming() async throws {
    let coordinator = MonitoringCoordinator(inventory: EdgeInventory(), driver: EdgeDriver(), vault: EdgeVault(), journalStore: EdgeJournal(), now: { edgeNow })
    do {
        try await coordinator.arm(configuration: edgePreferences(), variants: [edgeVariant(market: .uk)], stores: [edgeStore], location: "M5V", runContinuously: false)
        Issue.record("A Canadian monitor accepted a UK selected-product URL")
        coordinator.stop()
    } catch CoordinatorError.invalidConfiguration { }
}
@Test @MainActor func disarmingDuringVaultReadPreventsSecretCheckoutPreparation() async throws {
    let gate = EdgeGate(); let driver = EdgeDriver()
    let coordinator = MonitoringCoordinator(inventory: EdgeInventory(), driver: driver, vault: EdgeVault(gate: gate), journalStore: EdgeJournal(), now: { edgeNow })
    try await coordinator.arm(configuration: edgePreferences(), variants: [edgeVariant()], stores: [edgeStore], location: "M5V", runContinuously: false)
    let cycle = Task { await coordinator.performCycle() }
    await gate.waitForEntry(); coordinator.stop(); await gate.release(); await cycle.value
    #expect(!coordinator.isArmed)
    #expect(coordinator.status == .stopped)
    #expect(driver.prepareCalls == 0)
    #expect(driver.submitCalls == 0)
}
@Test @MainActor func disarmingDuringInventoryFailurePreservesStoppedStatus() async throws {
    let gate = EdgeGate(); let driver = EdgeDriver()
    let coordinator = MonitoringCoordinator(inventory: EdgeInventory(gate: gate, failure: .blocked(541)), driver: driver, vault: EdgeVault(), journalStore: EdgeJournal(), now: { edgeNow })
    try await coordinator.arm(configuration: edgePreferences(), variants: [edgeVariant()], stores: [edgeStore], location: "M5V", runContinuously: false)
    let cycle = Task { await coordinator.performCycle() }
    await gate.waitForEntry(); coordinator.stop(); await gate.release(); await cycle.value
    #expect(coordinator.status == .stopped)
    #expect(driver.prepareCalls == 0)
}
@Test @MainActor func disarmingDuringAuthenticationFailurePreservesStoppedStatus() async throws {
    let gate = EdgeGate(); let driver = EdgeDriver(gate: gate, authenticationFailure: true)
    let coordinator = MonitoringCoordinator(inventory: EdgeInventory(), driver: driver, vault: EdgeVault(), journalStore: EdgeJournal(), now: { edgeNow })
    try await coordinator.arm(configuration: edgePreferences(), variants: [edgeVariant()], stores: [edgeStore], location: "M5V", runContinuously: false)
    let cycle = Task { await coordinator.performCycle() }
    await gate.waitForEntry(); coordinator.stop(); await gate.release(); await cycle.value
    #expect(coordinator.status == .stopped)
    #expect(driver.submitCalls == 0)
}
@Test @MainActor func closingAttemptWindowDuringPreparationPreventsSubmission() async throws {
    let gate = EdgeGate(); let driver = EdgeDriver(gate: gate)
    let clock = Mutex(edgeNow)
    let coordinator = MonitoringCoordinator(inventory: EdgeInventory(), driver: driver, vault: EdgeVault(), journalStore: EdgeJournal(), now: { clock.withLock { $0 } })
    try await coordinator.arm(configuration: edgePreferences(), variants: [edgeVariant()], stores: [edgeStore], location: "M5V", runContinuously: false)
    let cycle = Task { await coordinator.performCycle() }
    await gate.waitForEntry(); clock.withLock { $0 = edgeNow.addingTimeInterval(7200) }; await gate.release(); await cycle.value
    #expect(driver.submitCalls == 0)
    #expect(coordinator.journal.phase == .idle)
    await coordinator.performCycle()
    #expect(!coordinator.isArmed)
    #expect(coordinator.status == .stopped)
}
@Test func pickupSlotCannotCrossDisallowedDailyHoursEvenWhenBothEndpointsAreAllowed() {
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: "2026-10-17T23:00:00Z")!
    let end = formatter.date(from: "2026-10-18T23:00:00Z")!
    let request = CheckoutRequest(variant: edgeVariant(), store: edgeStore, market: .ca, maximumTotal: 4000,
                                  pickupWindow: DateWindow(start: edgeNow, end: end), pickupHours: DailyWindow(startMinute: 1320, endMinute: 120), timeZoneIdentifier: "UTC")
    let review = CheckoutReview(variantID: request.variant.id, storeID: request.store.id, quantity: 1, total: 3000, currencyCode: "CAD", pickupDate: start, pickupEndDate: end, pickupSlot: "Synthetic excessive slot", expiresAt: start)
    #expect(throws: CheckoutError.unsafeReview) { try review.validate(for: request, at: edgeNow) }
}
