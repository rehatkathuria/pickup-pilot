import Foundation
import PilotCore
import Testing
@testable import PickupPilot

private actor EmptyBagRecoveryVault: SecureVault {
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) {}
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() {}
}

/// Entirely scripted browser evidence: no Safari, WebKit, network or Keychain access.
@MainActor private final class EmptyBagRecoveryPage: AppleCheckoutPage {
    let browserKind: CheckoutBrowserKind = .safari
    let usesBrowserManagedSession = true
    var snapshots: [CheckoutSnapshot]
    private(set) var loads: [URL] = []
    private(set) var advancedSnapshots: [CheckoutSnapshot] = []
    private(set) var manualInputAcknowledgements: [Market] = []
    private(set) var guestSnapshots: [CheckoutSnapshot] = []
    private(set) var snapshotCalls = 0
    private(set) var placeCalls = 0
    private var current: CheckoutSnapshot?

    init(_ snapshots: [CheckoutSnapshot]) { self.snapshots = snapshots }
    func load(_ url: URL) { loads.append(url) }
    func snapshot() throws -> CheckoutSnapshot {
        snapshotCalls += 1
        let evidence = snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
        current = evidence
        return evidence
    }
    func advance(request: CheckoutRequest, profile: SecureProfile) throws -> Bool {
        advancedSnapshots.append(try #require(current))
        return true
    }
    func acknowledgeManualInput(market: Market) { manualInputAcknowledgements.append(market) }
    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) -> Bool {
        guestSnapshots.append(snapshot)
        return true
    }
    func placeOrder(expected: CheckoutSnapshot) -> Bool { placeCalls += 1; return false }
    func restoreSession(_ data: Data?) { Issue.record("Safari recovery must use its existing browser session.") }
    func sessionData() -> Data { Issue.record("Safari recovery must not export cookies."); return Data() }
    func cancel() {}
}

@Suite(.serialized) @MainActor struct CheckoutEmptyBagRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_792_166_400)
    private let bagURL = URL(string: "https://www.apple.com/ca/shop/bag")!

    private var request: CheckoutRequest {
        CheckoutRequest(
            variant: ProductVariant(id: "EMPTY-BAG-CA/A", name: "Synthetic selected product", storage: "256GB", color: "Blue",
                                    productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/empty-bag-synthetic")!),
            store: RetailStore(id: "R121", name: "Synthetic store"), market: .ca, maximumTotal: 4000)
    }
    private func bag(empty: Bool = false, documentID: String = "00000000-0000-4000-8000-000000000010") -> CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: bagURL.absoluteString, phase: .bag,
                         productIDs: empty ? [] : [request.variant.id], quantities: empty ? [] : [1], bagIsEmpty: empty,
                         documentID: documentID)
    }
    private var product: CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: request.variant.productURL.absoluteString, phase: .product, productIDs: [request.variant.id])
    }
    private var review: CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .review,
                         productIDs: [request.variant.id], storeIDs: [request.store.id], quantities: [1],
                         totalText: "$3,388.87", currencyCode: "CAD", pickupStartISO: "2026-10-24T14:00:00Z",
                         pickupEndISO: "2026-10-24T14:15:00Z", pickupSlot: "10:00–10:15", finalActionCount: 1,
                         pickupOnly: true, documentID: "00000000-0000-4000-8000-000000000001",
                         reviewStateID: "00000000-0000-4000-8000-000000000002")
    }
    private func driver(_ page: EmptyBagRecoveryPage) -> AppleCheckoutDriver {
        AppleCheckoutDriver(vault: EmptyBagRecoveryVault(), page: page, now: { self.now }, sleep: {})
    }
    private func pauseAtReview(_ driver: AppleCheckoutDriver) async {
        await #expect(throws: CheckoutError.manualInputRequired) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(driver.requiresPaymentConfirmation)
    }

    @Test func initiallyEmptyBagAddsExactSelectedProductBeforeCheckout() async {
        let page = EmptyBagRecoveryPage([bag(empty: true), product, bag(), review])
        let driver = driver(page)
        await pauseAtReview(driver)
        #expect(page.loads == [bagURL, request.variant.productURL])
        #expect(page.advancedSnapshots.map(\.phase) == [.product, .bag])
        #expect(page.advancedSnapshots.last?.productIDs == [request.variant.id])
        #expect(page.advancedSnapshots.last?.quantities == [1])
        #expect(page.placeCalls == 0 && !driver.hasEmbeddedBrowser)
    }

    @Test func bagThatEmptiesAfterCheckoutIsRefilledAndCheckedOutAgain() async {
        let page = EmptyBagRecoveryPage([bag(empty: true), product, bag(), bag(empty: true), product, bag(), review])
        let driver = driver(page)
        await pauseAtReview(driver)
        #expect(page.loads == [bagURL, request.variant.productURL, request.variant.productURL])
        #expect(page.advancedSnapshots.map(\.phase) == [.product, .bag, .product, .bag])
        #expect(page.advancedSnapshots.filter { $0.phase == .bag }.allSatisfy {
            !$0.bagIsEmpty && $0.productIDs == [request.variant.id] && $0.quantities == [1]
        })
        #expect(page.placeCalls == 0)
    }

    @Test func staleEmptySnapshotsDuringPendingProductNavigationDoNotRequestAnotherLoad() async {
        var loading = bag(empty: true); loading.phase = .loading
        let page = EmptyBagRecoveryPage([bag(empty: true), bag(empty: true), loading, product, bag(empty: true), bag(), review])
        let driver = driver(page)
        await pauseAtReview(driver)
        #expect(page.loads == [bagURL, request.variant.productURL])
        #expect(page.advancedSnapshots.map(\.phase) == [.product, .bag])
        #expect(page.snapshotCalls == 7 && page.placeCalls == 0)
    }

    @Test func distinctVerifiedEmptyBagAfterProductNavigationCanRetryAnAddThatDidNotStick() async {
        let replacement = bag(empty: true, documentID: "00000000-0000-4000-8000-000000000011")
        let page = EmptyBagRecoveryPage([bag(empty: true), product, replacement, replacement, product, bag(), review])
        let driver = driver(page)
        await pauseAtReview(driver)
        #expect(page.loads == [bagURL, request.variant.productURL, request.variant.productURL])
        #expect(page.advancedSnapshots.map(\.phase) == [.product, .product, .bag])
        #expect(page.placeCalls == 0)
    }

    @Test func pendingRefillSurvivesAnInputHandoffWithoutLoadingTheProductTwice() async {
        var contact = review; contact.phase = .contact; contact.hasErrors = true
        let page = EmptyBagRecoveryPage([bag(empty: true), product, contact])
        let driver = driver(page)
        await #expect(throws: CheckoutError.manualInputRequired) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(!driver.requiresPaymentConfirmation)
        page.snapshots = [bag(empty: true), product, bag(), review]
        await pauseAtReview(driver)
        #expect(page.loads == [bagURL, request.variant.productURL])
        #expect(page.manualInputAcknowledgements == [.ca])
        #expect(page.advancedSnapshots.map(\.phase) == [.product, .product, .bag])
        #expect(page.placeCalls == 0)
    }

    @Test func repeatedBagLossStopsAfterThreeProductLoadsWithinOnePreparation() async {
        let refill = [bag(empty: true), product, bag()]
        let page = EmptyBagRecoveryPage(refill + refill + refill + [bag(empty: true)])
        let driver = driver(page)
        await #expect(throws: CheckoutError.unsupportedPage) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.loads == [bagURL] + Array(repeating: request.variant.productURL, count: 3))
        #expect(page.advancedSnapshots.map(\.phase) == [.product, .bag, .product, .bag, .product, .bag])
        #expect(!driver.requiresPaymentConfirmation && page.placeCalls == 0)
    }

    @Test func refillBudgetSurvivesInputAndReviewResumesAndResetsForFreshAttempt() async {
        var contact = review; contact.phase = .contact; contact.hasErrors = true
        let page = EmptyBagRecoveryPage([bag(empty: true), product, bag(), contact])
        let driver = driver(page)
        await #expect(throws: CheckoutError.manualInputRequired) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        for _ in 0..<2 {
            page.snapshots = [bag(empty: true), product, bag(), review]
            await pauseAtReview(driver)
        }
        page.snapshots = [bag(empty: true)]
        await #expect(throws: CheckoutError.unsupportedPage) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.loads == [bagURL] + Array(repeating: request.variant.productURL, count: 3))
        #expect(page.manualInputAcknowledgements == [.ca] && page.placeCalls == 0)
        driver.cancel()
        page.snapshots = [bag(empty: true), product, bag(), review]
        await pauseAtReview(driver)
        #expect(page.loads == [bagURL] + Array(repeating: request.variant.productURL, count: 3) + [bagURL, request.variant.productURL])
        #expect(page.advancedSnapshots.map(\.phase) == [.product, .bag, .product, .bag, .product, .bag, .product, .bag])
        #expect(page.placeCalls == 0)
    }

    @Test func unsafeBagEvidenceNeverAddsOrChecksOutAnItem() async {
        var wrongProduct = bag(); wrongProduct.productIDs = ["DIFFERENT-SYNTHETIC-CA/A"]
        var extraQuantity = bag(); extraQuantity.quantities = [2]
        var contradictoryEmpty = bag(empty: true); contradictoryEmpty.productIDs = [request.variant.id]
        var contradictoryQuantity = bag(empty: true); contradictoryQuantity.quantities = [1]
        var unverifiedContents = bag(); unverifiedContents.productIDs = []; unverifiedContents.quantities = []
        var emptyWithErrors = bag(empty: true); emptyWithErrors.hasErrors = true
        var matchingWithErrors = bag(); matchingWithErrors.hasErrors = true
        var emptyWithoutDocument = bag(empty: true); emptyWithoutDocument.documentID = nil
        var emptyWithMalformedDocument = bag(empty: true); emptyWithMalformedDocument.documentID = "invalid"
        var emptyWithFinalAction = bag(empty: true); emptyWithFinalAction.finalActionCount = 1
        for unsafe in [wrongProduct, extraQuantity, contradictoryEmpty, contradictoryQuantity, unverifiedContents, emptyWithErrors,
                       matchingWithErrors, emptyWithoutDocument, emptyWithMalformedDocument, emptyWithFinalAction] {
            let page = EmptyBagRecoveryPage([unsafe, product, bag(), review])
            let driver = driver(page)
            await #expect(throws: CheckoutError.unsafeReview) {
                try await driver.prepare(request: request, profile: SecureProfile())
            }
            #expect(page.loads == [bagURL])
            #expect(page.advancedSnapshots.isEmpty && page.snapshotCalls == 1 && page.placeCalls == 0)
        }
    }

    @Test func restoredVerifiedBagAllowsOneFreshGuestDispatchForTheNewCheckout() async {
        let firstAuthentication = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/signIn", phase: .authentication,
                                                   documentID: "00000000-0000-4000-8000-000000000020")
        var secondAuthentication = firstAuthentication
        secondAuthentication.documentID = "00000000-0000-4000-8000-000000000021"
        var fulfillment = review; fulfillment.phase = .fulfillment
        var contact = review; contact.phase = .contact; contact.hasErrors = true
        let page = EmptyBagRecoveryPage([bag(), firstAuthentication, fulfillment, bag(empty: true), product, bag(), secondAuthentication, contact])
        let driver = driver(page)
        await #expect(throws: CheckoutError.manualInputRequired) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.loads == [bagURL, request.variant.productURL])
        #expect(page.advancedSnapshots.map(\.phase) == [.bag, .fulfillment, .product, .bag])
        #expect(page.guestSnapshots.map(\.documentID) == [firstAuthentication.documentID, secondAuthentication.documentID])
        #expect(!driver.requiresPaymentConfirmation && page.placeCalls == 0)
    }

    @Test func authenticationBeforeReplenishedBagVerificationCannotRedispatchGuestCheckout() async {
        let authentication = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/signIn", phase: .authentication,
                                              documentID: "00000000-0000-4000-8000-000000000020")
        var fulfillment = review; fulfillment.phase = .fulfillment
        let page = EmptyBagRecoveryPage([bag(), authentication, fulfillment, bag(empty: true), product, authentication])
        let driver = driver(page)
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.loads == [bagURL, request.variant.productURL])
        #expect(page.advancedSnapshots.map(\.phase) == [.bag, .fulfillment, .product])
        #expect(page.guestSnapshots.count == 1 && page.placeCalls == 0)
    }

    @Test func emptyBagAtFinalSubmitCheckCannotTriggerRefillOrPlaceOrder() async throws {
        let page = EmptyBagRecoveryPage([review])
        let driver = driver(page)
        await pauseAtReview(driver)
        let approved = try await driver.prepare(request: request, profile: SecureProfile())
        page.snapshots = [bag(empty: true), product, bag(), review]
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: approved) }
        #expect(page.loads == [bagURL] && page.advancedSnapshots.isEmpty && page.placeCalls == 0)
    }

    @Test func indeterminateSubmissionLocksEmptyBagRecoveryIncludingAfterCancellation() async throws {
        let page = EmptyBagRecoveryPage([review])
        let driver = driver(page)
        await pauseAtReview(driver)
        let approved = try await driver.prepare(request: request, profile: SecureProfile())
        let outcome = try await driver.submit(review: approved)
        guard case .indeterminate = outcome else { Issue.record("Synthetic failed submit must be indeterminate."); return }
        page.snapshots = [bag(empty: true), product, bag(), review]
        let recovered = try await driver.recoverOutcome()
        if case .indeterminate = recovered {} else { Issue.record("An empty bag cannot confirm the earlier order.") }
        await #expect(throws: CheckoutError.unsafeReview) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        driver.cancel()
        await #expect(throws: CheckoutError.unsafeReview) {
            try await driver.prepare(request: request, profile: SecureProfile())
        }
        #expect(page.loads == [bagURL] && page.advancedSnapshots.isEmpty && page.placeCalls == 1)
    }
}
