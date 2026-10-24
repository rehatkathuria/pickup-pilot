import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

private actor GuestDriverVault: SecureVault {
    private var writes = 0
    var failSave = false
    func failNextSave() { failSave = true }
    func sessionWrites() -> Int { writes }
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) throws {
        if failSave { throw CheckoutError.sessionStorage }
        writes += 1
    }
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() {}
}

@MainActor private final class GuestDriverPage: AppleCheckoutPage {
    let diagnostics: CheckoutPageDiagnostics? = CheckoutPageDiagnostics()
    var snapshots: [CheckoutSnapshot]
    var guestResult = true
    var guestResults: [Bool] = []
    var onGuestResult: ((Bool) -> Void)?
    var suspendGuest = false
    var guestContinuation: CheckedContinuation<Void, Never>?
    private(set) var guestCalls = 0
    private(set) var guestDispatches = 0
    private(set) var snapshotCalls = 0
    private(set) var loads = 0
    private(set) var advances = 0
    private(set) var finalCalls = 0
    init(_ snapshots: [CheckoutSnapshot]) { self.snapshots = snapshots }
    func resetDiagnostics() { diagnostics?.reset() }
    func load(_ url: URL) { loads += 1 }
    var latchBlockAfterGuest = false
    func snapshot() throws -> CheckoutSnapshot {
        snapshotCalls += 1
        if latchBlockAfterGuest, guestDispatches > 0 { throw CheckoutError.storefrontBlocked }
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0] }
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) -> Bool { false }
    func advance(request: CheckoutRequest, profile: SecureProfile) -> Bool { advances += 1; return false }
    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) async -> Bool {
        guestCalls += 1
        let result = guestResults.isEmpty ? guestResult : guestResults.removeFirst()
        if result { guestDispatches += 1 }
        if suspendGuest { await withCheckedContinuation { guestContinuation = $0 } }
        onGuestResult?(result)
        return result
    }
    func resumeGuest() { guestContinuation?.resume(); guestContinuation = nil }
    func placeOrder(expected: CheckoutSnapshot) -> Bool { finalCalls += 1; return false }
    func restoreSession(_ data: Data?) {}
    func sessionData() -> Data { Data("synthetic-session".utf8) }
    func cancel() {}
}

@Suite(.serialized) @MainActor struct CheckoutGuestDriverTests {
    private var request: CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "SYNTHETIC-CA/A", name: "Synthetic Duo", storage: "256GB", color: "Synthetic",
                                               productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                        store: RetailStore(id: "R121", name: "Synthetic Store"), market: .ca, maximumTotal: 4_000)
    }
    private var auth: CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/signIn", phase: .authentication,
                         documentID: "00000000-0000-4000-8000-000000000001")
    }
    private func makeDriver(_ page: GuestDriverPage, vault: GuestDriverVault = GuestDriverVault()) -> AppleCheckoutDriver {
        AppleCheckoutDriver(vault: vault, page: page, sleep: {})
    }

    @Test func oneGuestActionCanReachRequiredContactInputWithoutAnyFinalCall() async throws {
        let contact = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .contact)
        let page = GuestDriverPage([auth, contact]), vault = GuestDriverVault()
        let driver = makeDriver(page, vault: vault)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.loads == 1 && page.advances > 0 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 1)
        // User Continue uses the existing request/session and cannot resubmit Guest.
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.loads == 1 && page.finalCalls == 0)
    }

    @Test func unchangedGuestResponseStopsWithoutAccountFallbackAndNeverClicksAgain() async throws {
        let page = GuestDriverPage([auth]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.guestDispatches == 1 && page.finalCalls == 0)
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.guestDispatches == 1 && page.loads == 1 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }

    @Test func hydrationFalseDoesNotConsumeTheOneActualGuestDispatch() async throws {
        let contact = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .contact, hasErrors: true)
        let page = GuestDriverPage([auth, auth, auth, contact]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        page.guestResults = [false, false, true]
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 3 && page.guestDispatches == 1 && page.loads == 1 && page.finalCalls == 0)
        #expect(page.advances == 0 && driver.diagnostics?.action == .enteringContact)
        #expect(await vault.sessionWrites() == 1)
    }

    @Test func aConfirmedGuestDispatchRemainsConsumedWhenItsResultArrivesAfterTheDeadline() async throws {
        var clock = Date()
        let started = clock
        let page = GuestDriverPage([auth]), vault = GuestDriverVault()
        page.onGuestResult = { dispatched in if dispatched { clock = started.addingTimeInterval(31) } }
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { clock }, sleep: {})
        await #expect(throws: CheckoutError.unsupportedPage) { try await driver.prepare(request: request, profile: SecureProfile()) }
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.guestDispatches == 1 && page.loads == 1)
        #expect(page.advances == 0 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }

    @Test func guestReadinessIsBoundedWithoutDispatchingOrRequestingSignIn() async throws {
        let page = GuestDriverPage([auth]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        page.guestResult = false
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls > 1 && page.guestCalls <= 17 && page.guestDispatches == 0)
        #expect(page.loads == 1 && page.advances == 0 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }

    @Test func aPendingGuestRequestUsesThePreparationBoundWithoutDispatchingTwice() async throws {
        var loading = auth; loading.phase = .loading
        let contact = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .contact, hasErrors: true)
        let page = GuestDriverPage([auth] + Array(repeating: loading, count: 8) + [contact])
        let driver = makeDriver(page)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.guestDispatches == 1 && page.snapshotCalls == 10)
        #expect(page.loads == 1 && page.finalCalls == 0)
    }

    @Test func blockedGuestResponseStopsWithoutRetryOrSessionWrite() async throws {
        let blocked = CheckoutSnapshot(sourceURL: auth.sourceURL, phase: .blocked)
        let page = GuestDriverPage([auth, blocked]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        await #expect(throws: CheckoutError.storefrontBlocked) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.advances == 0 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }

    @Test(arguments: [403, 429, 541], [CheckoutSnapshot.Phase.pageNotFound, .blocked])
    func appleAccessResponseToTheGuestDispatchIsReportedAsARefusalWithoutRetry(_ status: Int, _ phase: CheckoutSnapshot.Phase) async throws {
        var destination = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/404", phase: phase)
        destination.blockingStatus = status; destination.blockingSource = "fetch"
        let page = GuestDriverPage([auth, destination]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        await #expect(throws: CheckoutError.guestCheckoutRefused) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.guestDispatches == 1 && page.advances == 0 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }

    @Test func aLatchedAccessResponseAfterTheGuestDispatchIsARefusalWithoutRetry() async throws {
        let page = GuestDriverPage([auth]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        page.latchBlockAfterGuest = true
        await #expect(throws: CheckoutError.guestCheckoutRefused) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.advances == 0 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }

    @Test func aPageNotFoundWithoutAccessEvidenceIsNotCalledARefusal() async throws {
        let destination = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/404", phase: .pageNotFound)
        let page = GuestDriverPage([auth, destination]), driver = makeDriver(page)
        await #expect(throws: CheckoutError.pageNotFound) { try await driver.prepare(request: request, profile: SecureProfile()) }
    }

    @Test(arguments: [CheckoutSnapshot.Phase.pageNotFound, .unknown])
    func guestErrorDestinationsStopAfterOneClickAndKeepTheFailingAction(_ phase: CheckoutSnapshot.Phase) async throws {
        let destination = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/404", phase: phase)
        let page = GuestDriverPage([auth, destination]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        let expected: CheckoutError = phase == .pageNotFound ? .pageNotFound : .unsupportedPage
        await #expect(throws: expected) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.loads == 1 && page.advances == 0 && page.finalCalls == 0)
        #expect(page.snapshotCalls == (phase == .pageNotFound ? 2 : 6))
        #expect(await vault.sessionWrites() == 0)
        #expect(driver.diagnostics === page.diagnostics && driver.diagnostics?.action == .continuingAsGuest)
        driver.cancel()
        #expect(driver.diagnostics?.action == .continuingAsGuest)
    }

    @Test func transientUnknownCheckoutHydrationSettlesBeforeAdvancingWithoutAnotherGuestClick() async throws {
        let unknown = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .unknown)
        var fulfillment = unknown; fulfillment.phase = .fulfillment
        var contact = unknown; contact.phase = .contact; contact.hasErrors = true
        let page = GuestDriverPage([auth, unknown, fulfillment, contact]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 1 && page.loads == 1 && page.advances == 1 && page.finalCalls == 0)
        #expect(page.snapshotCalls == 4 && driver.diagnostics?.action == .enteringContact)
        #expect(await vault.sessionWrites() == 1)
    }

    @Test(arguments: ["other-market", "other-host", "other-path", "errors", "final-control", "missing-document"])
    func ineligibleAuthenticationStopsGuestOnlyCheckoutWithoutClicking(_ kind: String) async throws {
        var evidence = auth
        switch kind {
        case "other-market": evidence.sourceURL = "https://secure6.store.apple.com/uk/shop/signIn"
        case "other-host": evidence.sourceURL = "https://apple.com.example.invalid/ca/shop/signIn"
        case "other-path": evidence.sourceURL = "https://secure6.store.apple.com/ca/shop/verify"
        case "errors": evidence.hasErrors = true
        case "missing-document": evidence.documentID = nil
        default: evidence.finalActionCount = 1
        }
        let page = GuestDriverPage([evidence]), driver = makeDriver(page)
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestCalls == 0 && page.advances == 0 && page.finalCalls == 0)
    }

    @Test func unscheduledAdapterStillPausesForExplicitPaymentConfirmation() async throws {
        let adapter = CheckoutRequest(variant: ProductVariant(id: CatalogProduct.adapterSKU, name: "Synthetic Adapter", storage: "", color: "",
                                                             productURL: CatalogProduct.adapterURL),
                                      store: request.store, market: .ca, maximumTotal: 25)
        let evidence = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .review,
                                        productIDs: [CatalogProduct.adapterSKU], storeIDs: ["R121"], quantities: [1],
                                        totalText: "CA$11.30", currencyCode: "CAD", pickupSlot: "Pickup after Apple confirms it is ready",
                                        finalActionCount: 1, pickupOnly: true, documentID: auth.documentID,
                                        reviewStateID: "00000000-0000-4000-8000-000000000002", pickupIsUnscheduled: true)
        let page = GuestDriverPage([evidence]), driver = makeDriver(page)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: adapter, profile: SecureProfile()) }
        #expect(driver.requiresPaymentConfirmation && page.finalCalls == 0)
        let approved = try await driver.prepare(request: adapter, profile: SecureProfile())
        #expect(approved.pickupIsUnscheduled && approved.pickupDate == nil && approved.pickupEndDate == nil)
        #expect(!driver.requiresPaymentConfirmation && page.finalCalls == 0 && page.guestCalls == 0)
    }

    @Test func unavailableGuestDoesNotSaveASessionOrMaskTheFailureWithAStorageError() async throws {
        let page = GuestDriverPage([auth]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        page.guestResult = false
        await vault.failNextSave()
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.guestDispatches == 0 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }

    @Test func cancellationWhileGuestActionIsSuspendedRejectsTheLateResult() async throws {
        let page = GuestDriverPage([auth]), vault = GuestDriverVault(), driver = makeDriver(page, vault: vault)
        page.suspendGuest = true
        let pending = Task { try await driver.prepare(request: request, profile: SecureProfile()) }
        for _ in 0..<1_000 { if page.guestContinuation != nil { break }; await Task.yield() }
        try #require(page.guestContinuation != nil)
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.prepare(request: request, profile: SecureProfile()) }
        driver.cancel()
        page.resumeGuest()
        await #expect(throws: CheckoutError.cancelled) { try await pending.value }
        #expect(page.guestCalls == 1 && page.finalCalls == 0)
        #expect(await vault.sessionWrites() == 0)
    }
}
