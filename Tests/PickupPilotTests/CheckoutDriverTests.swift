import Foundation
import Testing
import WebKit
@testable import PickupPilot
@testable import PilotCore

private enum CheckoutSyntheticFailure: Error { case expected }
private struct SafariDriverPreferences: PreferencesStore {
    func load() -> PilotPreferences { PilotPreferences() }
    func save(_ preferences: PilotPreferences) { Issue.record("Synthetic Safari driver tests must not persist preferences.") }
}
private actor CheckoutTestVault: SecureVault {
    var session: Data?
    var sessionWrites = 0
    var sessionReads = 0
    var profileReads = 0
    var sessionDeletes = 0
    var failSave = false
    var suspendLoad = false
    var loadingSession = false
    var loadContinuation: CheckedContinuation<Void,Never>?
    func setFailSave() { failSave = true }
    func pauseLoad() { suspendLoad = true }
    func isLoadingSession() -> Bool { loadingSession }
    func resumeLoad() { suspendLoad = false; loadContinuation?.resume(); loadContinuation = nil }
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { profileReads += 1; return nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) throws { if failSave { throw CheckoutSyntheticFailure.expected }; session = data; sessionWrites += 1 }
    func sessionWriteCount() -> Int { sessionWrites }
    func loadSession() async -> Data? {
        sessionReads += 1
        loadingSession = true
        if suspendLoad { await withCheckedContinuation { loadContinuation = $0 } }
        loadingSession = false
        return session
    }
    func deleteSession() { sessionDeletes += 1; session = nil }
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() { session = nil }
}
@MainActor private final class CheckoutTestPage: AppleCheckoutPage {
    let diagnostics: CheckoutPageDiagnostics? = CheckoutPageDiagnostics()
    var diagnosticResets = 0
    var browserKind: CheckoutBrowserKind = .embeddedFixture
    var usesBrowserManagedSession = false
    var sessionDataCalls = 0
    var browserResets = 0
    var clearCalls = 0
    var showCalls = 0
    var suspendNavigation = false
    var navigationContinuation: CheckedContinuation<Void,Never>?
    var snapshots: [CheckoutSnapshot]
    var loads: [URL] = []
    var advanceCalls = 0
    var snapshotCalls = 0
    var waitTimeouts: [TimeInterval] = []
    var waitHint: (() -> Bool)?
    var placeCalls = 0
    var cancelCalls = 0
    var restoreCalls = 0
    var recoveryCalls: [Market] = []
    var manualInputAcknowledgements: [Market] = []
    var manualInputError: CheckoutError?
    var recoveryError: CheckoutError?
    var suspendRecovery = false
    var recoveryContinuation: CheckedContinuation<Void,Never>?
    var suspendSession = false
    var sessionContinuation: CheckedContinuation<Void,Never>?
    var suspendSnapshot = false
    var snapshotContinuation: CheckedContinuation<Void,Never>?
    var suspendRestore = false
    var restoreContinuation: CheckedContinuation<Void,Never>?
    var lastSnapshot: CheckoutSnapshot?
    var advanceResult = true
    var placeResult = true
    var throwPlace = false
    var throwSnapshot = false
    var session = Data("synthetic-cookie".utf8)
    init(_ snapshots: [CheckoutSnapshot]) { self.snapshots = snapshots }
    func resetDiagnostics() { diagnosticResets += 1; diagnostics?.reset() }
    func load(_ url: URL) async {
        loads.append(url)
        if suspendNavigation { await withCheckedContinuation { navigationContinuation = $0 } }
    }
    func resumeNavigation() { suspendNavigation = false; navigationContinuation?.resume(); navigationContinuation = nil }
    func snapshot() async throws -> CheckoutSnapshot {
        snapshotCalls += 1
        if suspendSnapshot {
            suspendSnapshot = false
            await withCheckedContinuation { snapshotContinuation = $0 }
        }
        if throwSnapshot { throw CheckoutSyntheticFailure.expected }
        let result = snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
        lastSnapshot = result
        return result
    }
    func advance(request: CheckoutRequest, profile: SecureProfile) -> Bool { advanceCalls += 1; return advanceResult }
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) async throws -> Bool {
        waitTimeouts.append(timeout)
        if let waitHint { return waitHint() }
        return try await AppleCheckoutTiming.waitForFallback(timeout: timeout)
    }
    func placeOrder(expected: CheckoutSnapshot) throws -> Bool { placeCalls += 1; if throwPlace { throw CheckoutSyntheticFailure.expected }; return placeResult }
    func restoreSession(_ data: Data?) async {
        restoreCalls += 1
        if suspendRestore { await withCheckedContinuation { restoreContinuation = $0 } }
        session = data ?? Data()
    }
    func resumeSnapshot() { snapshotContinuation?.resume(); snapshotContinuation = nil }
    func resumeRestore() { suspendRestore = false; restoreContinuation?.resume(); restoreContinuation = nil }
    func acknowledgeManualRecovery(market: Market) async throws {
        recoveryCalls.append(market)
        if suspendRecovery { await withCheckedContinuation { recoveryContinuation = $0 } }
        if let recoveryError { throw recoveryError }
    }
    func acknowledgeManualInput(market: Market) throws {
        manualInputAcknowledgements.append(market)
        if let manualInputError { throw manualInputError }
    }
    func resumeRecovery() { suspendRecovery = false; recoveryContinuation?.resume(); recoveryContinuation = nil }
    func resumeSession() { suspendSession = false; sessionContinuation?.resume(); sessionContinuation = nil }
    func sessionData() async -> Data {
        sessionDataCalls += 1
        let captured = session
        if suspendSession { await withCheckedContinuation { sessionContinuation = $0 } }
        return captured
    }
    func showBrowser() async throws { showCalls += 1 }
    func resetBrowserSession() async throws {
        browserResets += 1
        if !usesBrowserManagedSession { await restoreSession(nil) }
        clearPage()
    }
    func clearPage() { clearCalls += 1; cancel() }
    func cancel() { cancelCalls += 1 }
}
private let driverNow = Date(timeIntervalSince1970: 1_792_166_400)
private func driverRequest() -> CheckoutRequest {
    CheckoutRequest(variant: ProductVariant(id: "TEST-CA/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky", productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                    store: RetailStore(id: "R121", name: "Synthetic store"), market: .ca, maximumTotal: 4000)
}
private func driverReviewEvidence() -> CheckoutSnapshot {
    CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .review,
                     productIDs: ["TEST-CA/A"], storeIDs: ["R121"], quantities: [1], totalText: "$3,388.87", currencyCode: "CAD",
                     pickupStartISO: "2026-10-24T14:00:00Z", pickupEndISO: "2026-10-24T14:15:00Z", pickupSlot: "10:00–10:15",
                     finalActionCount: 1, pickupOnly: true, documentID: "00000000-0000-4000-8000-000000000001", reviewStateID: "00000000-0000-4000-8000-000000000002")
}
@Suite(.serialized) @MainActor struct CheckoutDriverTests {
    /// Explicitly simulate the human confirming the unchanged final review in these unit tests.
    private func confirmReview(_ driver: AppleCheckoutDriver, page: CheckoutTestPage,
                               request: CheckoutRequest = driverRequest()) async throws -> CheckoutReview {
        do {
            let unexpected = try await driver.prepare(request:request,profile:SecureProfile())
            Issue.record("A final review must pause for human payment confirmation")
            return unexpected
        } catch CheckoutError.manualInputRequired {
            let evidence = try #require(page.lastSnapshot)
            guard evidence.phase == .review else { throw CheckoutError.manualInputRequired }
            // The review remains on screen during human inspection; do not consume the next
            // scripted post-confirmation event until the explicit second preparation finishes.
            page.snapshots.insert(evidence,at:0)
            return try await driver.prepare(request:request,profile:SecureProfile())
        }
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 { if condition() { return }; await Task.yield() }
        #expect(condition())
    }
    private func loadFixture(_ page: WKAppleCheckoutPage, origin: String) async throws {
        let marker = UUID().uuidString
        page.webView.loadHTMLString("<html><body data-fixture='\(marker)'>Synthetic browser boundary</body></html>",baseURL:URL(string:origin)!)
        for _ in 0..<100 {
            let value = try? await page.webView.callAsyncJavaScript("return document.body?.dataset.fixture || '';",in:nil,contentWorld:.page)
            if value as? String == marker, !page.webView.isLoading { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        Issue.record("Synthetic WebKit document did not become ready")
    }
    @Test func finalReviewRequiresItsOwnExplicitPaymentConfirmation() async throws {
        let evidence=driverReviewEvidence(),page=CheckoutTestPage([driverReviewEvidence()])
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{driverNow},sleep:{})
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        let unissued=try CheckoutPagePolicy.review(from:evidence,request:driverRequest(),now:driverNow)
        await #expect(throws:CheckoutError.unsafeReview) { try await driver.submit(review:unissued) }
        let confirmed=try await driver.prepare(request:driverRequest(),profile:SecureProfile())
        #expect(confirmed.expiresAt == driverNow.addingTimeInterval(60))
        #expect(page.loads.count == 1 && page.placeCalls == 0)
    }
    @Test func changedExpiredOrAccountGatedReviewRequiresNewConfirmation() async throws {
        for kind in 0..<4 {
            var clock=driverNow
            let original=driverReviewEvidence(),page=CheckoutTestPage([driverReviewEvidence()])
            let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{clock},sleep:{})
            await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
            var changed=original
            if kind == 0 { changed.totalText="$3,500.00" }
            if kind == 1 { clock=clock.addingTimeInterval(61) }
            if kind == 2 {
                var auth=original;auth.phase = .authentication;page.snapshots=[auth]
                await #expect(throws:CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
            }
            if kind == 3 { driver.cancel() }
            page.snapshots=[changed]
            await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
            let confirmed=try await driver.prepare(request:driverRequest(),profile:SecureProfile())
            #expect(confirmed.total == (kind == 0 ? Decimal(3_500) : Decimal(string:"3388.87")!))
            #expect(confirmed.expiresAt == clock.addingTimeInterval(60) && page.placeCalls == 0)
        }
    }
    @Test func preparesEverySupportedPageAndConfirmsOneOrder() async throws {
        let review = driverReviewEvidence()
        var bag = review; bag.phase = .bag; bag.finalActionCount = 0
        var empty = bag; empty.bagIsEmpty = true; empty.productIDs = []; empty.quantities = []
        var product = review; product.phase = .product
        var fulfill = review; fulfill.phase = .fulfillment
        var contact = review; contact.phase = .contact
        var payment = review; payment.phase = .payment
        var confirmed = review; confirmed.phase = .confirmation; confirmed.orderID = "W1234567890"
        let page = CheckoutTestPage([empty, product, bag, fulfill, contact, payment, review, review, confirmed])
        let vault = CheckoutTestVault()
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
        let prepared = try await confirmReview(driver,page:page)
        #expect(page.loads.count == 2 && page.advanceCalls == 5)
        #expect(await vault.loadSession() == page.session)
        #expect(try await driver.submit(review: prepared) == .confirmed(orderID: "W1234567890"))
        #expect(page.placeCalls == 1)
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: prepared) }
        #expect(try await driver.recoverOutcome() == .confirmed(orderID: "W1234567890"))
        driver.cancel()
        #expect(page.cancelCalls == 2)
        #expect(try await driver.recoverOutcome() == .confirmed(orderID: "W1234567890"))
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
    }
    @Test func accountGateStopsBeforeReviewWithoutAddingAnotherCartItem() async throws {
        var auth = driverReviewEvidence(); auth.phase = .authentication
        let page = CheckoutTestPage([auth, driverReviewEvidence()])
        let vault = CheckoutTestVault()
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(page.loads.count == 1 && page.snapshotCalls == 1 && page.advanceCalls == 0 && page.placeCalls == 0)
        #expect(await vault.sessionWriteCount() == 0)
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.recoverOutcome() }
    }
    @Test func rejectsUnavailableUnknownChangedCartAndExistingConfirmation() async {
        var snapshots: [CheckoutSnapshot] = []
        for phase in [CheckoutSnapshot.Phase.unavailable, .unknown, .confirmation, .bag, .product] {
            var s = driverReviewEvidence(); s.phase = phase
            if phase == .bag { s.quantities = [2] }
            if phase == .product { s.hasErrors = true }
            snapshots.append(s)
        }
        for snapshot in snapshots {
            let page = CheckoutTestPage([snapshot]); page.advanceResult = false
            let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: {})
            await #expect(throws: (any Error).self) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
            #expect(page.placeCalls == 0)
        }
        var product = driverReviewEvidence(); product.phase = .product
        let stalled = CheckoutTestPage([product]); stalled.advanceResult = false
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: stalled, now: { driverNow }, sleep: {})
        await #expect(throws: CheckoutError.unsupportedPage) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(stalled.advanceCalls == 5)
        let cycling = CheckoutTestPage([product])
        let bounded = AppleCheckoutDriver(vault: CheckoutTestVault(), page: cycling, now: { driverNow }, sleep: {})
        await #expect(throws: CheckoutError.unsupportedPage) { try await bounded.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(cycling.advanceCalls == 50)
        var bag = driverReviewEvidence(); bag.phase = .bag
        let blockedBag = CheckoutTestPage([bag]); blockedBag.advanceResult = false
        let bagDriver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: blockedBag, now: { driverNow }, sleep: {})
        await #expect(throws: CheckoutError.unsupportedPage) { try await bagDriver.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(blockedBag.advanceCalls == 5 && blockedBag.placeCalls == 0)
    }
    @Test func rejectsWrongRequestAndSecureSessionFailure() async {
        let original = driverRequest()
        let wrong = CheckoutRequest(variant: original.variant, store: original.store, market: .us, maximumTotal: 4000)
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: CheckoutTestPage([driverReviewEvidence()]), sleep: {})
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.prepare(request: wrong, profile: SecureProfile()) }
        for maximum in [Decimal.zero,Decimal.nan] {
            let page = CheckoutTestPage([driverReviewEvidence()])
            let invalid = CheckoutRequest(variant:original.variant,store:original.store,market:.ca,maximumTotal:maximum)
            let invalidDriver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,sleep:{})
            await #expect(throws:CheckoutError.unsafeReview) { try await invalidDriver.prepare(request:invalid,profile:SecureProfile()) }
            #expect(page.loads.isEmpty && page.restoreCalls == 0)
        }
        let vault = CheckoutTestVault(); await vault.setFailSave()
        let broken = AppleCheckoutDriver(vault: vault, page: CheckoutTestPage([driverReviewEvidence()]), now: { driverNow }, sleep: {})
        await #expect(throws: CheckoutError.sessionStorage) { try await broken.prepare(request: original, profile: SecureProfile()) }
    }
    @Test func consumesSubmitCapabilityOnAnyPostClickUncertainty() async throws {
        for disposition in 0..<7 {
            let review = driverReviewEvidence()
            var after = review
            if disposition == 1 { after.phase = .authentication }
            if disposition == 2 { after.phase = .unavailable }
            if disposition == 5 { after.phase = .pageNotFound; after.sourceURL = "https://www.apple.com/ca/shop/404" }
            if disposition == 6 { after.phase = .blocked }
            let page = CheckoutTestPage([review, review, after])
            page.placeResult = disposition != 3
            page.throwPlace = disposition == 4
            let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: {})
            let prepared = try await confirmReview(driver,page:page)
            let outcome = try await driver.submit(review: prepared)
            switch disposition {
            case 1: #expect(outcome == .requiresAuthentication)
            case 2: #expect(outcome == .unavailable)
            default: if case .indeterminate = outcome {} else { Issue.record("Expected an uncertain order outcome") }
            }
            await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: prepared) }
            #expect(page.placeCalls == 1)
            let recovery = try await driver.recoverOutcome()
            if disposition == 1 { #expect(recovery == .requiresAuthentication) }
        }
    }
    @Test func finalReviewChangesAndCancellationBlockClick() async throws {
        let first = driverReviewEvidence()
        var changed = first; changed.totalText = "$3,500.00"
        let page = CheckoutTestPage([first, changed])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: {})
        let prepared = try await confirmReview(driver,page:page)
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: prepared) }
        #expect(page.placeCalls == 0)
        driver.cancel()
        await #expect(throws: CheckoutError.cancelled) { try await driver.submit(review: prepared) }
        let p = CheckoutTestPage([first, first]); p.snapshots[1].phase = .authentication
        let d = AppleCheckoutDriver(vault: CheckoutTestVault(), page: p, now: { driverNow }, sleep: {})
        let r = try await confirmReview(d,page:p)
        #expect(try await d.submit(review: r) == .requiresAuthentication)
        #expect(p.placeCalls == 0)
    }
    @Test func clearSessionRemovesMemoryAndReconciliationResetsLatch() async throws {
        let first = driverReviewEvidence()
        var confirmation = first; confirmation.phase = .confirmation; confirmation.orderID = "W1234567890"
        let page = CheckoutTestPage([first,first,confirmation])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: {})
        let review = try await confirmReview(driver,page:page)
        _ = try await driver.submit(review: review)
        try await driver.clearSession()
        #expect(page.session.isEmpty && page.cancelCalls == 3)
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        try await driver.resetAfterReconciliation()
        page.snapshots = [first]
        _ = try await confirmReview(driver,page:page)
        #expect(page.loads.count == 2 && page.cancelCalls == 6)
    }
    @Test func explicitReturnToBagOnlyNavigatesAndDoesNotReadOrWriteSecrets() async throws {
        let page = CheckoutTestPage([driverReviewEvidence()]), vault = CheckoutTestVault()
        page.diagnostics?.recordAction(.continuingAsGuest)
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
        try await driver.returnToBag(market: .uk)
        #expect(page.loads.map(\.absoluteString) == ["https://www.apple.com/uk/shop/bag"])
        #expect(page.restoreCalls == 0 && page.snapshotCalls == 0 && page.advanceCalls == 0 && page.placeCalls == 0)
        #expect(await vault.sessionReads == 0)
        #expect(await vault.profileReads == 0)
        #expect(await vault.sessionWriteCount() == 0)
        #expect(page.diagnosticResets == 1 && driver.diagnostics?.action == .openingBag)
    }
    @Test func returningToBagRevokesPreparedReviewAndForcesAFreshNormalAttempt() async throws {
        let page = CheckoutTestPage([driverReviewEvidence()]), vault = CheckoutTestVault()
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
        let prepared = try await confirmReview(driver, page: page)
        let reads = await vault.sessionReads, writes = await vault.sessionWriteCount()
        try await driver.returnToBag(market: .ca)
        #expect(!driver.requiresPaymentConfirmation && page.loads.count == 2 && page.restoreCalls == 1)
        #expect(await vault.sessionReads == reads)
        #expect(await vault.sessionWriteCount() == writes)
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: prepared) }
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(page.loads.count == 3 && page.restoreCalls == 2 && page.placeCalls == 0)
    }
    @Test func returnToBagRejectsOverlapCancellationAndAnExistingSubmission() async throws {
        let page = CheckoutTestPage([driverReviewEvidence()]), vault = CheckoutTestVault()
        page.suspendNavigation = true
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
        let operation = Task { try await driver.returnToBag(market: .ca) }
        await waitUntil { page.navigationContinuation != nil }
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.returnToBag(market: .ca) }
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        driver.cancel(); page.resumeNavigation()
        await #expect(throws: CheckoutError.cancelled) { try await operation.value }
        #expect(page.loads.count == 1 && page.restoreCalls == 0 && page.placeCalls == 0)
        #expect(await vault.sessionReads == 0)
        let submittedPage = CheckoutTestPage([driverReviewEvidence()]); submittedPage.placeResult = false
        let submitted = AppleCheckoutDriver(vault: CheckoutTestVault(), page: submittedPage, now: { driverNow }, sleep: {})
        let review = try await confirmReview(submitted, page: submittedPage)
        _ = try await submitted.submit(review: review)
        await #expect(throws: CheckoutError.unsafeReview) { try await submitted.returnToBag(market: .ca) }
        #expect(submittedPage.loads.count == 1 && submittedPage.placeCalls == 1)
    }
    @Test func defaultClockAndWaitPrepareAReviewWithoutExternalNetwork() async throws {
        var evidence = driverReviewEvidence()
        let formatter = ISO8601DateFormatter()
        evidence.pickupStartISO = formatter.string(from: Date().addingTimeInterval(86_400))
        evidence.pickupEndISO = formatter.string(from: Date().addingTimeInterval(87_300))
        let page = CheckoutTestPage([evidence])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page)
        let before = Date()
        let review = try await confirmReview(driver,page:page)
        #expect(review.expiresAt >= before.addingTimeInterval(60))
        #expect(page.placeCalls == 0 && page.loads.count == 1)
        driver.cancel()
    }
    @Test func cancellingRealDefaultBrowserWaitNeverAdvancesOrSubmits() async throws {
        let page = CheckoutTestPage([driverReviewEvidence()])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page)
        let operation = Task { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        for _ in 0..<100 {
            if !page.loads.isEmpty { break }
            await Task.yield()
        }
        #expect(page.loads.count == 1)
        driver.cancel(); operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(page.advanceCalls == 0 && page.placeCalls == 0)
    }
    @Test func slowNavigationDoesNotConsumeUnknownPageStallsOrReloadProduct() async throws {
        let review = driverReviewEvidence()
        var unknown = review; unknown.phase = .unknown
        var loading = review; loading.phase = .loading
        var empty = review; empty.phase = .bag; empty.bagIsEmpty = true; empty.productIDs = []; empty.quantities = []; empty.finalActionCount = 0
        let states = [empty] + Array(repeating: loading, count: 12) + [empty,loading] + Array(repeating: unknown, count: 4) + [loading,review]
        let page = CheckoutTestPage(states)
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: {})
        _ = try await confirmReview(driver,page:page)
        #expect(page.snapshotCalls == states.count + 1)
        #expect(page.loads.map(\.path) == ["/ca/shop/bag", "/ca/shop/buy-iphone/iphone-duo/synthetic"])
        #expect(page.advanceCalls == 0 && page.placeCalls == 0)
    }
    @Test func loadingIsBoundedByDeadlineAndCannotReloadAStaleEmptyBag() async {
        var loading = driverReviewEvidence(); loading.phase = .loading
        let page = CheckoutTestPage([loading])
        var clock = driverNow
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { clock }, sleep: { clock = clock.addingTimeInterval(10) })
        await #expect(throws: CheckoutError.unsupportedPage) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(clock == driverNow.addingTimeInterval(30))
        #expect(page.snapshotCalls == 2 && page.loads.count == 1 && page.advanceCalls == 0)
        let boundedPage = CheckoutTestPage([loading])
        let bounded = AppleCheckoutDriver(vault: CheckoutTestVault(), page: boundedPage, now: { driverNow }, sleep: {})
        await #expect(throws: CheckoutError.unsupportedPage) { try await bounded.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(boundedPage.snapshotCalls == 50 && boundedPage.loads.count == 1)
        var empty = driverReviewEvidence(); empty.phase = .bag; empty.bagIsEmpty = true; empty.productIDs = []; empty.quantities = []; empty.finalActionCount = 0
        let stalePage = CheckoutTestPage([empty])
        let stale = AppleCheckoutDriver(vault: CheckoutTestVault(), page: stalePage, now: { driverNow }, sleep: {})
        await #expect(throws: CheckoutError.unsupportedPage) { try await stale.prepare(request: driverRequest(), profile: SecureProfile()) }
        #expect(stalePage.loads.count == 2 && stalePage.placeCalls == 0)
    }
    @Test func cancellationWhileLoadingStopsBeforeAnyFormAction() async throws {
        var loading = driverReviewEvidence(); loading.phase = .loading
        let page = CheckoutTestPage([loading])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: { await Task.yield() })
        let operation = Task { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        for _ in 0..<100 { if page.snapshotCalls > 0 { break }; await Task.yield() }
        #expect(page.snapshotCalls > 0)
        driver.cancel(); operation.cancel()
        await #expect(throws: CheckoutError.cancelled) { try await operation.value }
        #expect(page.loads.count == 1 && page.advanceCalls == 0 && page.placeCalls == 0)
    }
    @Test func cancelledPreparationRevalidatesBagBeforeSameRequestCanResume() async throws {
        let page = CheckoutTestPage([driverReviewEvidence()])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: {})
        _ = try await confirmReview(driver,page:page)
        driver.cancel()
        var empty = driverReviewEvidence(); empty.phase = .bag; empty.bagIsEmpty = true; empty.productIDs = []; empty.quantities = []; empty.finalActionCount = 0
        page.snapshots = [empty,driverReviewEvidence()]
        _ = try await confirmReview(driver,page:page)
        #expect(page.loads.map(\.path) == ["/ca/shop/bag", "/ca/shop/bag", "/ca/shop/buy-iphone/iphone-duo/synthetic"])
        #expect(page.placeCalls == 0)
    }
    @Test func cancellationDuringSessionLoadOrRestoreNeverNavigates() async throws {
        let vault = CheckoutTestVault()
        await vault.pauseLoad()
        let page = CheckoutTestPage([driverReviewEvidence()])
        let driver = AppleCheckoutDriver(vault:vault,page:page,sleep:{})
        let loading = Task { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        for _ in 0..<1_000 { if await vault.isLoadingSession() { break }; await Task.yield() }
        #expect(await vault.isLoadingSession())
        driver.cancel()
        await vault.resumeLoad()
        await #expect(throws:CheckoutError.cancelled) { try await loading.value }
        #expect(page.restoreCalls == 0 && page.loads.isEmpty && page.advanceCalls == 0)

        let restoringPage = CheckoutTestPage([driverReviewEvidence()]); restoringPage.suspendRestore = true
        let restoringDriver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:restoringPage,sleep:{})
        let restoring = Task { try await restoringDriver.prepare(request:driverRequest(),profile:SecureProfile()) }
        await waitUntil { restoringPage.restoreContinuation != nil }
        restoringDriver.cancel(); restoringPage.resumeRestore()
        await #expect(throws:CheckoutError.cancelled) { try await restoring.value }
        #expect(restoringPage.loads.isEmpty && restoringPage.advanceCalls == 0)
    }
    @Test func cancellationDuringPreparationSnapshotNeverAdvancesAForm() async throws {
        var product = driverReviewEvidence(); product.phase = .product
        let page = CheckoutTestPage([product]); page.suspendSnapshot = true
        let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,sleep:{})
        let operation = Task { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        await waitUntil { page.snapshotContinuation != nil }
        driver.cancel(); page.resumeSnapshot()
        await #expect(throws:CheckoutError.cancelled) { try await operation.value }
        #expect(page.advanceCalls == 0 && page.placeCalls == 0)
    }
    @Test func disarmOrTaskCancellationDuringFinalSnapshotCannotClick() async throws {
        for cancelTask in [false,true] {
            let page = CheckoutTestPage([driverReviewEvidence()])
            let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{ driverNow },sleep:{})
            let review = try await confirmReview(driver,page:page)
            page.suspendSnapshot = true
            let submission = Task { try await driver.submit(review:review) }
            await waitUntil { page.snapshotContinuation != nil }
            if cancelTask { submission.cancel() } else { driver.cancel() }
            page.resumeSnapshot()
            await #expect(throws:CheckoutError.cancelled) { try await submission.value }
            #expect(page.placeCalls == 0)
            driver.cancel()
        }
    }
    @Test func reviewExpiryDuringFinalSnapshotRequiresFreshPreparation() async throws {
        var clock = driverNow
        let page = CheckoutTestPage([driverReviewEvidence()])
        let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{ clock },sleep:{})
        let review = try await confirmReview(driver,page:page)
        page.suspendSnapshot = true
        let submission = Task { try await driver.submit(review:review) }
        await waitUntil { page.snapshotContinuation != nil }
        clock = clock.addingTimeInterval(61)
        page.resumeSnapshot()
        await #expect(throws:CheckoutError.expiredReview) { try await submission.value }
        #expect(page.placeCalls == 0)
    }
    @Test func finalSnapshotCannotOutliveAttemptDatesOrDailyHours() async throws {
        for closesDailyHours in [false,true] {
            var clock = closesDailyHours ? driverNow.addingTimeInterval(59) : driverNow
            var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
            let minute = calendar.component(.hour,from:clock) * 60 + calendar.component(.minute,from:clock)
            let base = driverRequest()
            let request = CheckoutRequest(variant:base.variant,store:base.store,market:base.market,maximumTotal:base.maximumTotal,
                                          timeZoneIdentifier:"UTC",
                                          attemptWindow:DateWindow(start:clock.addingTimeInterval(-60),end:clock.addingTimeInterval(closesDailyHours ? 3_600 : 5)),
                                          attemptHours:closesDailyHours ? DailyWindow(startMinute:minute,endMinute:minute) : DailyWindow())
            let page = CheckoutTestPage([driverReviewEvidence()])
            let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{ clock },sleep:{})
            let review = try await confirmReview(driver,page:page,request:request)
            page.suspendSnapshot = true
            let submission = Task { try await driver.submit(review:review) }
            await waitUntil { page.snapshotContinuation != nil }
            clock = clock.addingTimeInterval(closesDailyHours ? 2 : 6)
            page.resumeSnapshot()
            await #expect(throws:CheckoutError.expiredReview) { try await submission.value }
            #expect(page.placeCalls == 0)
        }
    }
    @Test func overlappingPreparationAndSubmissionDoNotShareAReviewCapability() async throws {
        let first = driverReviewEvidence()
        var confirmed = first; confirmed.phase = .confirmation; confirmed.orderID = "W1234567890"
        let page = CheckoutTestPage([first,first,confirmed]); page.suspendSnapshot = true
        let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{ driverNow },sleep:{})
        let preparation = Task { try await confirmReview(driver,page:page) }
        await waitUntil { page.snapshotContinuation != nil }
        await #expect(throws:CheckoutError.unsafeReview) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        page.resumeSnapshot()
        let review = try await preparation.value
        #expect(page.loads.count == 1 && page.restoreCalls == 1)
        page.suspendSnapshot = true
        let submission = Task { try await driver.submit(review:review) }
        await waitUntil { page.snapshotContinuation != nil }
        await #expect(throws:CheckoutError.unsafeReview) { try await driver.submit(review:review) }
        page.resumeSnapshot()
        #expect(try await submission.value == .confirmed(orderID:"W1234567890"))
        #expect(page.placeCalls == 1)
    }
    @Test func manualHandoffPreservesLiveSessionAndAllowsUnlimitedHumanTime() async throws {
        for phase in [CheckoutSnapshot.Phase.fulfillment,.contact,.payment] {
            for hasErrors in [false,true] {
                var clock = driverNow
                var evidence = driverReviewEvidence(); evidence.phase = phase; evidence.hasErrors = hasErrors
                let page = CheckoutTestPage([evidence]); page.advanceResult = false
                let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{ clock },sleep:{})
                await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
                #expect(page.advanceCalls == (hasErrors ? 0 : 5))
                clock = clock.addingTimeInterval(3_600)
                page.snapshots = [driverReviewEvidence()]
                _ = try await confirmReview(driver,page:page)
                #expect(page.loads.count == 1 && page.restoreCalls == 1 && page.placeCalls == 0)
            }
        }
    }
    @Test func contradictoryEmptyBagAndChangedReviewOriginNeverAdvance() async throws {
        var empty = driverReviewEvidence(); empty.phase = .bag; empty.bagIsEmpty = true
        let page = CheckoutTestPage([empty])
        let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{ driverNow },sleep:{})
        await #expect(throws:CheckoutError.unsafeReview) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.loads.count == 1 && page.advanceCalls == 0)
        for phase in [CheckoutSnapshot.Phase.bag,.product,.fulfillment,.contact,.payment] {
            var wrongCountry = driverReviewEvidence(); wrongCountry.phase = phase
            wrongCountry.sourceURL = "https://www.apple.com/us/shop/bag"
            wrongCountry.bagIsEmpty = true; wrongCountry.productIDs = []; wrongCountry.quantities = []
            let countryPage = CheckoutTestPage([wrongCountry])
            let countryDriver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:countryPage,sleep:{})
            await #expect(throws:CheckoutError.unsupportedPage) { try await countryDriver.prepare(request:driverRequest(),profile:SecureProfile()) }
            #expect(countryPage.loads.count == 1 && countryPage.advanceCalls == 0)
        }
        var changed = driverReviewEvidence(); changed.sourceURL = "https://secure7.store.apple.com/ca/shop/checkout"
        let reviewPage = CheckoutTestPage([driverReviewEvidence(),changed])
        let reviewDriver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:reviewPage,now:{ driverNow },sleep:{})
        let review = try await confirmReview(reviewDriver,page:reviewPage)
        await #expect(throws:CheckoutError.unsafeReview) { try await reviewDriver.submit(review:review) }
        #expect(reviewPage.placeCalls == 0)
    }
    @Test func reportedStorefrontBlockStopsBeforeAnyFurtherAction() async {
        var blocked = driverReviewEvidence(); blocked.phase = .blocked
        let page = CheckoutTestPage([blocked])
        let driver = AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{ driverNow },sleep:{})
        await #expect(throws:CheckoutError.storefrontBlocked) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.snapshotCalls == 1 && page.advanceCalls == 0 && page.placeCalls == 0)
    }
    @Test func nativeMainDocumentSecurityResponsesBlockWithoutABypass() async throws {
        func response(_ status:Int,url:String="https://www.apple.com/ca/shop/bag") -> HTTPURLResponse {
            HTTPURLResponse(url:URL(string:url)!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:nil)!
        }
        for status in [403,429,541] {
            let page = WKAppleCheckoutPage()
            page.observeNavigationResponse(response(status),isForMainFrame:true)
            await #expect(throws:CheckoutError.storefrontBlocked) { try await page.snapshot() }
            await #expect(throws:CheckoutError.storefrontBlocked) { try await page.advance(request:driverRequest(),profile:SecureProfile()) }
            await #expect(throws:CheckoutError.storefrontBlocked) { try await page.placeOrder(expected:driverReviewEvidence()) }
            // A subsequent success redirect must not erase the observed security failure.
            page.observeNavigationResponse(response(200),isForMainFrame:true)
            await #expect(throws:CheckoutError.storefrontBlocked) { try await page.snapshot() }
            page.clearPage()
            _ = try await page.snapshot()
        }
        for (response,mainFrame) in [(response(541),false),
                                    (response(403,url:"https://synthetic-bank.example.invalid/challenge"),true),
                                    (response(200),true)] {
            let page = WKAppleCheckoutPage()
            page.observeNavigationResponse(response,isForMainFrame:mainFrame)
            #expect(try await page.snapshot().phase == .unknown)
        }
    }
    @Test func nativeEvidenceNeverRetainsCheckoutOrChallengeURLTokens() async throws {
        let raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(driverReviewEvidence()))
        let page = WKAppleCheckoutPage(evaluator:{ _,_ in raw })
        try await loadFixture(page,origin:"https://www.apple.com/ca/shop/checkout?session=SYNTHETIC-SESSION-TOKEN#SYNTHETIC-FRAGMENT")
        #expect(page.webView.url?.query == "session=SYNTHETIC-SESSION-TOKEN")
        let snapshot = try await page.snapshot()
        #expect(snapshot.sourceURL == "https://www.apple.com/ca/shop/checkout")
        let encoded = String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self)
        #expect(!encoded.contains("SYNTHETIC-SESSION-TOKEN") && !encoded.contains("SYNTHETIC-FRAGMENT"))
        var reads = 0
        let challenge = WKAppleCheckoutPage(evaluator:{ _,_ in reads += 1; return raw })
        try await loadFixture(challenge,origin:"https://synthetic-bank.example.invalid/challenge?session=SYNTHETIC-SESSION-TOKEN#SYNTHETIC-FRAGMENT")
        let auth = try await challenge.snapshot()
        #expect(auth.phase == .authentication && auth.sourceURL == "https://synthetic-bank.example.invalid/challenge")
        #expect(reads == 0)
        page.clearPage(); challenge.clearPage()
    }
    @Test func navigationDuringJavaScriptSnapshotNeverUsesTheOldDocument() async throws {
        let raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(driverReviewEvidence()))
        for throwsBridgeError in [false,true] {
            weak var currentPage: WKAppleCheckoutPage?
            let page = WKAppleCheckoutPage(evaluator:{ _,_ in
                currentPage?.webView.loadHTMLString("<body>New synthetic document</body>",baseURL:URL(string:"https://www.apple.com/ca/shop/bag")!)
                if throwsBridgeError { throw CheckoutSyntheticFailure.expected }
                return raw
            })
            currentPage = page
            try await loadFixture(page,origin:"https://www.apple.com/ca/shop/checkout")
            #expect(try await page.snapshot().phase == .loading)
            page.clearPage()
        }
        let malformed = WKAppleCheckoutPage(evaluator:{ _,_ in ["phase":"schemaChanged"] })
        try await loadFixture(malformed,origin:"https://www.apple.com/ca/shop/checkout")
        await #expect(throws:CheckoutError.unsupportedPage) { try await malformed.snapshot() }
        malformed.clearPage()
    }
    @Test func nativeReviewOnlyModeIsImmutableAndNeverInvokesSubmissionBridge() async throws {
        var bridgeCalls = 0
        let page = WKAppleCheckoutPage(submissionAllowed:false,evaluator:{ _,_ in bridgeCalls += 1; return true })
        #expect(try await page.placeOrder(expected:driverReviewEvidence()) == false)
        try await loadFixture(page,origin:"https://secure6.store.apple.com/ca/shop/checkout")
        let immutable = try await page.webView.callAsyncJavaScript("""
        const descriptor=Object.getOwnPropertyDescriptor(window,'__pickupPilotReviewOnly');
        return descriptor?.value===true && descriptor.writable===false && descriptor.configurable===false;
        """,in:nil,contentWorld:.page)
        #expect(immutable as? Bool == true)
        #expect(try await page.placeOrder(expected:driverReviewEvidence()) == false)
        let evidence=driverReviewEvidence()
        let review=try CheckoutPagePolicy.review(from:evidence,request:driverRequest(),now:driverNow)
        #expect(try await page.placeOrder(expected:evidence,request:driverRequest(),review:review) == false)
        #expect(bridgeCalls == 0)
        page.clearPage()
    }
    @Test func nativeAuthorizedSubmissionPassesExactTimingLimitsToAtomicJavaScriptCheck() async throws {
        var captured:[String:Any] = [:]
        let page=WKAppleCheckoutPage(evaluator:{ _,arguments in
            captured=arguments["authorization"] as? [String:Any] ?? [:]
            return false
        })
        let base=driverRequest()
        let request=CheckoutRequest(variant:base.variant,store:base.store,market:base.market,maximumTotal:base.maximumTotal,
                                    timeZoneIdentifier:"America/Toronto",
                                    attemptWindow:DateWindow(start:driverNow,end:driverNow.addingTimeInterval(300)),
                                    attemptHours:DailyWindow(startMinute:510,endMinute:1_125))
        let evidence=driverReviewEvidence()
        let review=try CheckoutPagePolicy.review(from:evidence,request:request,now:driverNow)
        try await loadFixture(page,origin:evidence.sourceURL)
        #expect(try await page.placeOrder(expected:evidence,request:request,review:review) == false)
        #expect(captured["attemptStart"] as? Double == request.attemptWindow.start.timeIntervalSince1970 * 1_000)
        #expect(captured["attemptEnd"] as? Double == request.attemptWindow.end.timeIntervalSince1970 * 1_000)
        #expect(captured["reviewExpiresAt"] as? Double == review.expiresAt.timeIntervalSince1970 * 1_000)
        #expect(captured["startMinute"] as? Int == 510 && captured["endMinute"] as? Int == 1_125)
        #expect(captured["timeZone"] as? String == "America/Toronto")
        page.clearPage()
    }
    @Test func browserManagedPreparationAndSubmissionNeverReadOrSerializeCookieSessions() async throws {
        let vault = CheckoutTestVault()
        try await vault.saveSession(Data("synthetic legacy session".utf8))
        let writes = await vault.sessionWrites
        let first = driverReviewEvidence()
        let page = CheckoutTestPage([first])
        page.browserKind = .safari; page.usesBrowserManagedSession = true
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
        let review = try await confirmReview(driver, page: page)
        var confirmation = first; confirmation.phase = .confirmation; confirmation.orderID = "W1234567890"
        page.snapshots = [first, confirmation]
        #expect(try await driver.submit(review: review) == .confirmed(orderID: "W1234567890"))
        let reads = await vault.sessionReads, savedWrites = await vault.sessionWrites
        #expect(reads == 0 && savedWrites == writes)
        #expect(page.restoreCalls == 0 && page.sessionDataCalls == 0)
        #expect(page.loads.count == 1 && page.placeCalls == 1)
        #expect(!driver.hasEmbeddedBrowser && driver.browserKind == .safari)
    }

    @Test func browserManagedRecoveryVerifiesOnlyOwnedPageAndRevokesOldReview() async throws {
        for resumesCurrentPage in [false, true] {
            let vault = CheckoutTestVault()
            let page = CheckoutTestPage([driverReviewEvidence()])
            page.browserKind = .safari; page.usesBrowserManagedSession = true
            let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
            let review = try await confirmReview(driver, page: page)
            if resumesCurrentPage { try await driver.resumeAfterManualRecovery(request: driverRequest()) }
            else { try await driver.recoverSessionAfterManualInput(market: .ca) }
            #expect(page.recoveryCalls == [.ca] && page.sessionDataCalls == 0 && page.restoreCalls == 0)
            let reads = await vault.sessionReads, writes = await vault.sessionWrites
            #expect(reads == 0 && writes == 0)
            #expect(!driver.hasEmbeddedBrowser && !driver.requiresPaymentConfirmation)
            await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: review) }
            await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
            #expect(page.loads.count == (resumesCurrentPage ? 1 : 2) && page.placeCalls == 0)
        }
    }

    @Test func browserManagedResetDelegatesOnlyWindowCleanupAndModelDeletesLegacyAppSession() async throws {
        let vault = CheckoutTestVault()
        try await vault.saveSession(Data("synthetic legacy session".utf8))
        let page = CheckoutTestPage([driverReviewEvidence()])
        page.browserKind = .safari; page.usesBrowserManagedSession = true
        let driver = AppleCheckoutDriver(vault: vault, page: page, now: { driverNow }, sleep: {})
        let model = PilotModel(vault: vault, preferencesStore: SafariDriverPreferences(), smoke: true, checkout: driver)
        await model.clearSession()
        #expect(page.browserResets == 1 && page.clearCalls == 1)
        #expect(page.restoreCalls == 0 && page.sessionDataCalls == 0 && page.loads.isEmpty)
        let deletes = await vault.sessionDeletes, reads = await vault.sessionReads, writes = await vault.sessionWrites
        #expect(deletes == 1 && reads == 0 && writes == 1)
        #expect(!driver.hasEmbeddedBrowser && model.message.contains("Safari"))
    }

    @Test func productionFactoryAndDefaultModelSelectSafariWithoutConstructingWebKit() {
        let vault = CheckoutTestVault()
        let driver = AppleCheckoutDriver.safari(vault: vault)
        let model = PilotModel(vault: vault, preferencesStore: SafariDriverPreferences(), smoke: true)
        #expect(driver.browserKind == .safari && driver.usesBrowserManagedSession && !driver.hasEmbeddedBrowser)
        #expect(model.checkout.browserKind == .safari && model.checkout.usesBrowserManagedSession && !model.checkout.hasEmbeddedBrowser)
        driver.endReviewOnlySession()
        model.checkout.endReviewOnlySession()
        #expect(!driver.hasEmbeddedBrowser && !model.checkout.hasEmbeddedBrowser)
    }

    @Test func explicitRecoveryPreservesCurrentCookiesWithoutPreparingOrSubmitting() async throws {
        for resumesCurrentPage in [false,true] {
            let stale=Data("synthetic-old-session".utf8),current=Data("synthetic-repaired-session".utf8)
            let vault=CheckoutTestVault();try await vault.saveSession(stale)
            let page=CheckoutTestPage([driverReviewEvidence()]);page.session=current
            let driver=AppleCheckoutDriver(vault:vault,page:page,now:{driverNow},sleep:{})
            if resumesCurrentPage { try await driver.resumeAfterManualRecovery(request:driverRequest()) }
            else { try await driver.recoverSessionAfterManualInput(market:.ca) }
            #expect(await vault.loadSession() == current && page.session == current)
            #expect(page.recoveryCalls == [.ca] && page.restoreCalls == 0 && page.loads.isEmpty)
            #expect(page.snapshotCalls == 0 && page.advanceCalls == 0 && page.placeCalls == 0 && !driver.requiresPaymentConfirmation)
            await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
            #expect(page.session == current && page.restoreCalls == (resumesCurrentPage ? 0 : 1))
            #expect(page.loads.count == (resumesCurrentPage ? 0 : 1) && page.placeCalls == 0)
        }
    }
    @Test func cancelledOrOverlappingRecoveryNeverWritesCapturedCookies() async throws {
        for cancelAtCookieRead in [false,true] {
            let stale=Data("synthetic-saved-session".utf8),vault=CheckoutTestVault()
            try await vault.saveSession(stale)
            let page=CheckoutTestPage([driverReviewEvidence()]);page.session=Data("synthetic-current-session".utf8)
            page.suspendRecovery = !cancelAtCookieRead;page.suspendSession=cancelAtCookieRead
            let driver=AppleCheckoutDriver(vault:vault,page:page,now:{driverNow},sleep:{})
            let recovery=Task { try await driver.resumeAfterManualRecovery(request:driverRequest()) }
            await waitUntil { cancelAtCookieRead ? page.sessionContinuation != nil : page.recoveryContinuation != nil }
            await #expect(throws:CheckoutError.unsafeReview) { try await driver.recoverSessionAfterManualInput(market:.ca) }
            await #expect(throws:CheckoutError.unsafeReview) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
            driver.cancel()
            if cancelAtCookieRead { page.resumeSession() } else { page.resumeRecovery() }
            await #expect(throws:CheckoutError.cancelled) { try await recovery.value }
            let saved=await vault.loadSession(),writes=await vault.sessionWriteCount()
            #expect(saved == stale && writes == 1)
            #expect(page.loads.isEmpty && page.restoreCalls == 0 && page.advanceCalls == 0 && page.placeCalls == 0)
        }
        let vault=CheckoutTestVault(),page=CheckoutTestPage([driverReviewEvidence()])
        page.suspendRecovery=true
        let driver=AppleCheckoutDriver(vault:vault,page:page,sleep:{})
        let recovery=Task { try await driver.recoverSessionAfterManualInput(market:.ca) }
        await waitUntil { page.recoveryContinuation != nil }
        recovery.cancel();page.resumeRecovery()
        await #expect(throws:CheckoutError.cancelled) { try await recovery.value }
        #expect(await vault.sessionWriteCount() == 0)
    }
    @Test func recoveryRejectsUnsafePagesStorageFailureAndAnyExistingSubmission() async throws {
        let vault=CheckoutTestVault(),page=CheckoutTestPage([driverReviewEvidence()])
        let driver=AppleCheckoutDriver(vault:vault,page:page,now:{driverNow},sleep:{})
        page.recoveryError = .storefrontBlocked
        await #expect(throws:CheckoutError.storefrontBlocked) { try await driver.resumeAfterManualRecovery(request:driverRequest()) }
        #expect(await vault.sessionWriteCount() == 0 && page.loads.isEmpty)
        page.recoveryError=nil;await vault.setFailSave()
        await #expect(throws:CheckoutError.sessionStorage) { try await driver.recoverSessionAfterManualInput(market:.ca) }
        #expect(await vault.sessionWriteCount() == 0)
        let submittingPage=CheckoutTestPage([driverReviewEvidence()]);submittingPage.placeResult=false
        let submitting=AppleCheckoutDriver(vault:CheckoutTestVault(),page:submittingPage,now:{driverNow},sleep:{})
        let review=try await confirmReview(submitting,page:submittingPage)
        _ = try await submitting.submit(review:review)
        await #expect(throws:CheckoutError.unsafeReview) { try await submitting.recoverSessionAfterManualInput(market:.ca) }
        await #expect(throws:CheckoutError.unsafeReview) { try await submitting.resumeAfterManualRecovery(request:driverRequest()) }
        #expect(submittingPage.recoveryCalls.isEmpty && submittingPage.placeCalls == 1)
    }
    @Test func recoveringSessionRevokesAnEarlierFinalReviewConfirmation() async throws {
        let page=CheckoutTestPage([driverReviewEvidence()])
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{driverNow},sleep:{})
        let review=try await confirmReview(driver,page:page)
        try await driver.resumeAfterManualRecovery(request:driverRequest())
        await #expect(throws:CheckoutError.unsafeReview) { try await driver.submit(review:review) }
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.loads.count == 1 && page.placeCalls == 0 && driver.requiresPaymentConfirmation)
    }
    @Test func fastPageHintsDoNotExhaustThePreparationPollBudget() async throws {
        var loading=driverReviewEvidence();loading.phase = .loading
        let page=CheckoutTestPage(Array(repeating:loading,count:80)+[driverReviewEvidence()])
        page.waitHint={true}
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{driverNow})
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.snapshotCalls == 81 && page.waitTimeouts.count == 81)
        #expect(page.waitTimeouts.allSatisfy({$0>0 && $0<=0.6}) && page.advanceCalls == 0 && page.placeCalls == 0)
    }
    @Test func rapidUnchangedHintsUseElapsedStallTimeAndNeverFiveWakeups() async throws {
        for phase in [CheckoutSnapshot.Phase.contact,.unknown] {
            var clock=driverNow,evidence=driverReviewEvidence();evidence.phase=phase
            let page=CheckoutTestPage([evidence]);page.advanceResult=false
            page.waitHint={clock=clock.addingTimeInterval(0.1);return true}
            let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{clock})
            let expected=phase == .contact ? CheckoutError.manualInputRequired : .unsupportedPage
            await #expect(throws:expected) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
            #expect(page.snapshotCalls >= 29 && page.snapshotCalls <= 32 && page.waitTimeouts.count > 5)
            #expect(clock.timeIntervalSince(driverNow) >= 3 && page.placeCalls == 0)
        }
    }
    @Test func continuousProgressHintsCannotExtendTheThirtySecondDeadline() async throws {
        var clock=driverNow,evidence=driverReviewEvidence();evidence.phase = .product
        let page=CheckoutTestPage([evidence])
        page.waitHint={clock=clock.addingTimeInterval(0.25);return true}
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{clock})
        await #expect(throws:CheckoutError.unsupportedPage) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(clock == driverNow.addingTimeInterval(30) && page.snapshotCalls == 119)
        #expect(page.advanceCalls == 119 && page.placeCalls == 0)
    }
    @Test func onlyAnExplicitSupportedFieldHandoffResumeResetsNonfinalControls() async throws {
        var contact=driverReviewEvidence();contact.phase = .contact;contact.hasErrors=true
        let page=CheckoutTestPage([contact])
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{driverNow},sleep:{})
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.manualInputAcknowledgements.isEmpty && page.advanceCalls == 0)
        page.manualInputError = .manualInputRequired
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.manualInputAcknowledgements == [.ca] && page.advanceCalls == 0)
        page.manualInputError=nil;page.snapshots=[driverReviewEvidence()]
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.manualInputAcknowledgements == [.ca,.ca] && driver.requiresPaymentConfirmation)
        _ = try await driver.prepare(request:driverRequest(),profile:SecureProfile())
        #expect(page.manualInputAcknowledgements == [.ca,.ca] && page.placeCalls == 0)
    }
    @Test func cancellationClearsNonfinalHandoffResetAndRequiresFreshBagCheck() async throws {
        var contact=driverReviewEvidence();contact.phase = .contact;contact.hasErrors=true
        let page=CheckoutTestPage([contact])
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{driverNow},sleep:{})
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        driver.cancel();page.snapshots=[driverReviewEvidence()]
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(page.manualInputAcknowledgements.isEmpty && page.loads.count == 2 && page.placeCalls == 0)
    }
    @Test func clockRollbackAndContinuousHintsCannotExtendPreparationOrConfirmation() async throws {
        var date=driverNow,instant=ContinuousClock.now
        let began=instant
        var loading=driverReviewEvidence();loading.phase = .loading
        let page=CheckoutTestPage([loading])
        page.waitHint={date=date.addingTimeInterval(-1);instant=instant.advanced(by:.milliseconds(250));return true}
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{date},monotonicNow:{instant})
        await #expect(throws:CheckoutError.unsupportedPage) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(began.duration(to:instant) == .seconds(30) && date < driverNow && page.snapshotCalls == 119)
        #expect(page.advanceCalls == 0 && page.placeCalls == 0)

        date=driverNow;instant = .now
        let confirmationPage=CheckoutTestPage([driverReviewEvidence()]);confirmationPage.waitHint={true}
        let confirmationDriver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:confirmationPage,now:{date},monotonicNow:{instant})
        let review=try await confirmReview(confirmationDriver,page:confirmationPage)
        let submittingAt=instant
        confirmationPage.waitHint={date=date.addingTimeInterval(-10);instant=instant.advanced(by:.seconds(1));return true}
        let outcome=try await confirmationDriver.submit(review:review)
        if case .indeterminate = outcome {} else { Issue.record("Expected an uncertain order after bounded confirmation observation") }
        #expect(submittingAt.duration(to:instant) == .seconds(18) && confirmationPage.placeCalls == 1)
        await #expect(throws:CheckoutError.unsafeReview) { try await confirmationDriver.submit(review:review) }
    }
    @Test func replacementDocumentRequiresFreshPaymentConfirmationAndCannotUseEarlierApproval() async throws {
        let original=driverReviewEvidence()
        var replacement=original;replacement.documentID="00000000-0000-4000-8000-000000000002"
        let page=CheckoutTestPage([original])
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{driverNow},sleep:{})
        let approved=try await confirmReview(driver,page:page)
        #expect(approved.documentID == original.documentID)
        page.snapshots=[replacement]
        await #expect(throws:CheckoutError.unsafeReview) { try await driver.submit(review:approved) }
        #expect(page.placeCalls == 0)
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        #expect(driver.requiresPaymentConfirmation)
        let reapproved=try await driver.prepare(request:driverRequest(),profile:SecureProfile())
        #expect(reapproved.documentID == replacement.documentID && reapproved.token != approved.token)
        #expect(page.placeCalls == 0)
    }
    @Test func replacementDuringPaymentHandoffCannotInheritTheEarlierReviewToken() async throws {
        let original=driverReviewEvidence(),page=CheckoutTestPage([driverReviewEvidence()])
        let driver=AppleCheckoutDriver(vault:CheckoutTestVault(),page:page,now:{driverNow},sleep:{})
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        var replacement=original;replacement.documentID="00000000-0000-4000-8000-000000000002"
        page.snapshots=[replacement]
        await #expect(throws:CheckoutError.manualInputRequired) { try await driver.prepare(request:driverRequest(),profile:SecureProfile()) }
        let approved=try await driver.prepare(request:driverRequest(),profile:SecureProfile())
        #expect(approved.documentID == replacement.documentID && page.placeCalls == 0)
    }
    @Test func changedBillingStateCannotUseApprovalFromTheSameDocument() async throws {
        let original = driverReviewEvidence(), page = CheckoutTestPage([driverReviewEvidence()])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { driverNow }, sleep: {})
        let approved = try await confirmReview(driver, page: page)
        var replacement = original; replacement.reviewStateID = "00000000-0000-4000-8000-000000000003"
        page.snapshots = [replacement]
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: approved) }
        #expect(page.placeCalls == 0)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        let fresh = try await driver.prepare(request: driverRequest(), profile: SecureProfile())
        #expect(fresh.documentID == approved.documentID && fresh.reviewStateID == replacement.reviewStateID)
        #expect(fresh.token != approved.token && page.placeCalls == 0)
    }
    @Test func billingHandoffChangesRequireConfirmationAndNeverRefreshAnUnchangedExpiry() async throws {
        var clock = driverNow
        let page = CheckoutTestPage([driverReviewEvidence()])
        let driver = AppleCheckoutDriver(vault: CheckoutTestVault(), page: page, now: { clock }, sleep: {})
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        clock = clock.addingTimeInterval(7)
        let approved = try await driver.prepare(request: driverRequest(), profile: SecureProfile())
        #expect(approved.expiresAt == driverNow.addingTimeInterval(60))
        var replacement = driverReviewEvidence(); replacement.reviewStateID = "00000000-0000-4000-8000-000000000003"
        page.snapshots = [replacement]
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        clock = clock.addingTimeInterval(5)
        let fresh = try await driver.prepare(request: driverRequest(), profile: SecureProfile())
        #expect(fresh.expiresAt == driverNow.addingTimeInterval(67))
        #expect(fresh.reviewStateID == replacement.reviewStateID && fresh.token != approved.token && page.placeCalls == 0)
        // A change while the very first review is awaiting confirmation also cannot inherit it.
        driver.cancel(); page.snapshots = [driverReviewEvidence()]
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
        page.snapshots = [replacement]
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: driverRequest(), profile: SecureProfile()) }
    }
}
