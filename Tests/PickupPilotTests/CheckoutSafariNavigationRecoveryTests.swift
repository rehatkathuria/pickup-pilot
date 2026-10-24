import Foundation
import PilotCore
import Testing
@testable import PickupPilot

private actor NavigationRecoveryVault: SecureVault {
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) { Issue.record("Safari must retain its own cookies.") }
    func loadSession() -> Data? { Issue.record("Safari must not import a Keychain session."); return nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() {}
}

/// Scripted browser responses only. This fixture cannot launch Safari, use Keychain or submit an order.
@MainActor private final class NavigationRecoveryPage: AppleCheckoutPage {
    let browserKind: CheckoutBrowserKind = .safari
    let usesBrowserManagedSession = true
    var snapshots: [Result<CheckoutSnapshot, CheckoutError>]
    var loadFailure = false
    var waitFailureAt: Int?
    var advanceResults: [Result<Bool, CheckoutError>] = []
    var guestResult: Result<Bool, CheckoutError> = .success(true)
    var manualInputFailure = false
    var placeResult: Result<Bool, CheckoutError> = .success(true)
    var onAdvance: (() -> Void)?
    private(set) var loads: [URL] = []
    private(set) var recoveryRequests: [CheckoutRequest] = []
    private(set) var advancedPhases: [CheckoutSnapshot.Phase] = []
    private(set) var advanceDispatches: [String] = []
    private(set) var guestCalls = 0
    private(set) var waitCalls = 0
    private(set) var manualInputCalls = 0
    private(set) var placeCalls = 0
    private var consumedDocuments: Set<String> = []
    private var current: CheckoutSnapshot?

    init(_ evidence: [CheckoutSnapshot]) { snapshots = evidence.map { .success($0) } }
    func load(_ url: URL) throws {
        loads.append(url)
        if loadFailure { loadFailure = false; throw CheckoutError.safariWindowUnavailable }
    }
    func snapshot() throws -> CheckoutSnapshot {
        let result = snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
        let evidence = try result.get()
        current = evidence
        return evidence
    }
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) throws -> Bool {
        waitCalls += 1
        if waitFailureAt == waitCalls { throw CheckoutError.safariWindowUnavailable }
        return false
    }
    func advance(request: CheckoutRequest, profile: SecureProfile) throws -> Bool {
        let evidence = try #require(current)
        advancedPhases.append(evidence.phase)
        let documentID = try #require(evidence.documentID)
        // Match the transport's per-document action latch: an uncertain delivered click remains consumed.
        guard consumedDocuments.insert(documentID).inserted else { return false }
        advanceDispatches.append(documentID)
        onAdvance?()
        return try (advanceResults.isEmpty ? .success(true) : advanceResults.removeFirst()).get()
    }
    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) throws -> Bool {
        guestCalls += 1
        return try guestResult.get()
    }
    func acknowledgeManualInput(market: Market) throws {
        manualInputCalls += 1
        if manualInputFailure { manualInputFailure = false; throw CheckoutError.safariWindowUnavailable }
    }
    func recoverCheckoutNavigation(request: CheckoutRequest) -> Bool {
        recoveryRequests.append(request)
        return true
    }
    func placeOrder(expected: CheckoutSnapshot) throws -> Bool {
        placeCalls += 1
        return try placeResult.get()
    }
    func restoreSession(_ data: Data?) { Issue.record("Safari must not import cookies.") }
    func sessionData() -> Data { Issue.record("Safari must not export cookies."); return Data() }
    func cancel() {}
}

private enum NavigationLossOrigin: String, CaseIterable, Sendable {
    case initialLoad, initialWait, snapshot, advance, wait, manualInputResume
}
private enum FinalNavigationLossOrigin: String, CaseIterable, Sendable {
    case reviewVerification, finalDispatch, confirmationWait
}

@Suite(.serialized) @MainActor struct CheckoutSafariNavigationRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_792_166_400)
    private let bagURL = URL(string: "https://www.apple.com/ca/shop/bag")!
    private var request: CheckoutRequest {
        CheckoutRequest(
            variant: ProductVariant(id: "NAVIGATION-CA/A", name: "Synthetic selected item", storage: "256GB", color: "Blue",
                                    productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/navigation-synthetic")!),
            store: RetailStore(id: "R121", name: "Synthetic store"), market: .ca, maximumTotal: 4000)
    }
    private func document(_ number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", number)
    }
    private func bag(_ number: Int = 10, empty: Bool = false) -> CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: bagURL.absoluteString, phase: .bag,
                         productIDs: empty ? [] : [request.variant.id], quantities: empty ? [] : [1],
                         bagIsEmpty: empty, documentID: document(number))
    }
    private func form(_ phase: CheckoutSnapshot.Phase, _ number: Int, errors: Bool = false) -> CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: phase,
                         hasErrors: errors, documentID: document(number))
    }
    private func auth(_ number: Int) -> CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/signIn", phase: .authentication,
                         documentID: document(number))
    }
    private func product(_ number: Int) -> CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: request.variant.productURL.absoluteString, phase: .product,
                         productIDs: [request.variant.id], documentID: document(number))
    }
    private var review: CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .review,
                         productIDs: [request.variant.id], storeIDs: [request.store.id], quantities: [1],
                         totalText: "$3,388.87", currencyCode: "CAD", pickupStartISO: "2026-10-24T14:00:00Z",
                         pickupEndISO: "2026-10-24T14:15:00Z", pickupSlot: "10:00–10:15", finalActionCount: 1,
                         pickupOnly: true, documentID: document(1), reviewStateID: document(2))
    }
    private func driver(_ page: NavigationRecoveryPage) -> AppleCheckoutDriver {
        AppleCheckoutDriver(vault: NavigationRecoveryVault(), page: page, now: { self.now })
    }
    private func pauseAtReview(_ driver: AppleCheckoutDriver) async {
        await #expect(throws: CheckoutError.manualInputRequired) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(driver.requiresPaymentConfirmation)
    }

    @Test(arguments: NavigationLossOrigin.allCases)
    private func confirmedWindowLossReconnectsFromEveryNonfinalBoundary(_ origin: NavigationLossOrigin) async {
        let page = NavigationRecoveryPage([bag(), review])
        let driver = driver(page)
        switch origin {
        case .initialLoad: page.loadFailure = true
        case .initialWait: page.waitFailureAt = 1
        case .snapshot: page.snapshots.insert(.failure(.safariWindowUnavailable), at: 0)
        case .advance: page.advanceResults = [.failure(.safariWindowUnavailable)]
        case .wait: page.waitFailureAt = 2
        case .manualInputResume:
            page.snapshots = [.success(form(.contact, 20, errors: true))]
            await #expect(throws: CheckoutError.manualInputRequired) {
                try await driver.prepare(request: request, profile: SecureProfile())
            }
            #expect(!driver.requiresPaymentConfirmation)
            page.manualInputFailure = true
        }
        // A reconnect navigates back to the bag; the recovered document is independently observed.
        if [.advance, .wait].contains(origin) { page.snapshots = [.success(bag()), .success(bag(11)), .success(review)] }
        if origin == .manualInputResume { page.snapshots = [.success(bag(11)), .success(review)] }
        await pauseAtReview(driver)
        #expect(page.recoveryRequests == [request])
        #expect(page.placeCalls == 0 && !driver.hasEmbeddedBrowser)
        #expect(page.manualInputCalls == (origin == .manualInputResume ? 1 : 0))
    }

    @Test func reconnectCanRefillAnEmptyBagAndStartAFreshGuestFlowBeforeReview() async {
        let page = NavigationRecoveryPage([bag(), auth(20), form(.fulfillment, 21)])
        page.snapshots += [.failure(.safariWindowUnavailable), .success(bag(30, empty: true)), .success(product(31)),
                           .success(bag(32)), .success(auth(33)), .success(review)]
        let driver = driver(page)
        await pauseAtReview(driver)
        #expect(page.recoveryRequests == [request])
        #expect(page.loads == [bagURL, request.variant.productURL])
        #expect(page.advancedPhases == [.bag, .fulfillment, .product, .bag])
        #expect(page.guestCalls == 2 && page.placeCalls == 0)
    }

    @Test func reconnectDoesNotRearmGuestUntilTheRecoveredBagIsVerified() async {
        let page = NavigationRecoveryPage([bag(), auth(20), form(.fulfillment, 21)])
        page.snapshots += [.failure(.safariWindowUnavailable), .success(auth(22))]
        let driver = driver(page)
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.recoveryRequests == [request] && page.guestCalls == 1)
        #expect(page.placeCalls == 0 && !driver.requiresPaymentConfirmation)
    }

    @Test func uncertainNonfinalAndGuestClicksAreObservedWithoutDuplicateDispatch() async {
        let page = NavigationRecoveryPage([bag(), bag(), auth(20), auth(20), form(.fulfillment, 21), review])
        page.advanceResults = [.failure(.safariNavigationChanged), .success(true)]
        page.guestResult = .failure(.safariNavigationChanged)
        let driver = driver(page)
        await pauseAtReview(driver)
        #expect(page.advancedPhases == [.bag, .bag, .fulfillment])
        #expect(page.advanceDispatches == [document(10), document(21)])
        #expect(page.guestCalls == 1 && page.recoveryRequests.isEmpty)
        #expect(page.loads == [bagURL] && page.placeCalls == 0)
    }

    @Test func reconnectBudgetSurvivesManualInputAndReviewPauses() async {
        let page = NavigationRecoveryPage([bag(), form(.contact, 20, errors: true)])
        page.snapshots.insert(.failure(.safariWindowUnavailable), at: 0)
        let driver = driver(page)
        await #expect(throws: CheckoutError.manualInputRequired) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.recoveryRequests.count == 1)
        page.manualInputFailure = true
        page.snapshots = [.success(bag(30)), .success(review)]
        await pauseAtReview(driver)
        #expect(page.recoveryRequests.count == 2)
        page.snapshots = [.failure(.safariWindowUnavailable)]
        await #expect(throws: CheckoutError.safariWindowUnavailable) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.recoveryRequests.count == 2 && page.placeCalls == 0)
        driver.cancel()
        page.snapshots = [.failure(.safariWindowUnavailable), .success(bag(40)), .success(review)]
        await pauseAtReview(driver)
        #expect(page.recoveryRequests.count == 3 && page.loads == [bagURL, bagURL])
    }

    @Test func reconnectDoesNotResetTheExistingThreeRefillBudget() async {
        let page = NavigationRecoveryPage([bag(10, empty: true), product(11), bag(12),
                                           bag(20, empty: true), product(21), bag(22),
                                           bag(30, empty: true), product(31), bag(32)])
        page.snapshots += [.failure(.safariWindowUnavailable), .success(bag(40, empty: true))]
        let driver = driver(page)
        await #expect(throws: CheckoutError.unsupportedPage) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.recoveryRequests == [request])
        #expect(page.loads == [bagURL] + Array(repeating: request.variant.productURL, count: 3))
        #expect(page.placeCalls == 0 && !driver.requiresPaymentConfirmation)
    }

    @Test func cancellationDuringAChangedWindowResponseNeverReconnects() async {
        let page = NavigationRecoveryPage([bag(), review])
        let driver = driver(page)
        page.advanceResults = [.failure(.safariWindowUnavailable)]
        page.onAdvance = { driver.cancel() }
        await #expect(throws: CheckoutError.cancelled) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.recoveryRequests.isEmpty && page.loads == [bagURL])
        #expect(page.placeCalls == 0 && !driver.requiresPaymentConfirmation)
    }

    @Test func anUnprovenPopupLeavingTheBagBehindResumesFromANewOwnedBag() async {
        let oldBag = bag(10), freshBag = bag(11)
        let page = NavigationRecoveryPage([oldBag] + Array(repeating: oldBag, count: 5) + [freshBag, review])
        let driver = driver(page)
        await pauseAtReview(driver)
        #expect(page.recoveryRequests == [request])
        #expect(page.advanceDispatches == [document(10), document(11)])
        #expect(page.placeCalls == 0)
    }

    @Test(arguments: FinalNavigationLossOrigin.allCases)
    private func finalSubmissionNeverReconnectsOrRedispatches(_ origin: FinalNavigationLossOrigin) async throws {
        let page = NavigationRecoveryPage([review])
        let driver = driver(page)
        await pauseAtReview(driver)
        let confirmedReview = try await driver.prepare(request: request, profile: SecureProfile())
        switch origin {
        case .reviewVerification:
            page.snapshots = [.failure(.safariWindowUnavailable)]
            await #expect(throws: CheckoutError.safariWindowUnavailable) { try await driver.submit(review: confirmedReview) }
            #expect(page.placeCalls == 0)
        case .finalDispatch, .confirmationWait:
            if origin == .finalDispatch { page.placeResult = .failure(.safariWindowUnavailable) }
            else { page.waitFailureAt = page.waitCalls + 1 }
            let outcome = try await driver.submit(review: confirmedReview)
            guard case .indeterminate = outcome else { Issue.record("An uncertain final action must remain locked."); return }
            await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: confirmedReview) }
            #expect(page.placeCalls == 1)
        }
        #expect(page.recoveryRequests.isEmpty && page.loads == [bagURL])
    }
}
