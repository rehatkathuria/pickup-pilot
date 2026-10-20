import Foundation
import PilotCore
import Testing
@testable import PickupPilot

@MainActor private final class SyntheticSafariController: SafariControlling {
    var nextID = 101
    var urls: [Int: URL] = [:]
    var snapshots: [CheckoutSnapshot] = []
    var actionResult = true
    var error: SafariAutomationError?
    var calls: [String] = []
    var scripts: [String] = []
    var closeIDs: [Int] = []
    var suspendEvaluation = false
    var evaluation: CheckedContinuation<String, any Error>?
    var suspendCreation = false
    var creation: CheckedContinuation<SafariWindowHandle, any Error>?
    var postEvaluationURL: URL?

    func createWindow() async throws -> SafariWindowHandle {
        calls.append("create")
        if let error { throw error }
        let handle = SafariWindowHandle(id: nextID); nextID += 1
        urls[handle.id] = URL(string: "about:blank")!
        if suspendCreation { return try await withCheckedThrowingContinuation { creation = $0 } }
        return handle
    }
    func navigate(_ url: URL, in handle: SafariWindowHandle) async throws {
        calls.append("navigate:\(handle.id)")
        if let error { throw error }
        urls[handle.id] = url
    }
    func currentURL(in handle: SafariWindowHandle) async throws -> URL? {
        calls.append("url:\(handle.id)")
        if let error { throw error }
        return urls[handle.id]
    }
    func evaluate(script: String, in handle: SafariWindowHandle) async throws -> String {
        calls.append("evaluate:\(handle.id)"); scripts.append(script)
        if let error { throw error }
        if suspendEvaluation { return try await withCheckedThrowingContinuation { evaluation = $0 } }
        if let postEvaluationURL { urls[handle.id] = postEvaluationURL }
        if script.contains("const value=window.__pickupPilot.snapshot();") {
            let value = snapshots.isEmpty ? SafariCheckoutPageTests.evidence() : snapshots.removeFirst()
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "value": object]), as: UTF8.self)
        }
        return "{\"ok\":true,\"value\":\(actionResult)}"
    }
    func activate(_ handle: SafariWindowHandle) async throws { calls.append("activate:\(handle.id)"); if let error { throw error } }
    func close(_ handle: SafariWindowHandle) async throws {
        calls.append("close:\(handle.id)"); closeIDs.append(handle.id)
        if let error { throw error }
        urls.removeValue(forKey: handle.id)
    }
    func cancel() { calls.append("cancel") }
}

@Suite(.serialized) @MainActor struct SafariCheckoutPageTests {
    static let checkoutURL = URL(string: "https://secure6.store.apple.com/ca/shop/checkout")!
    static let signInURL = URL(string: "https://www.apple.com/ca/shop/signIn")!
    static func evidence(phase: CheckoutSnapshot.Phase = .review) -> CheckoutSnapshot {
        CheckoutSnapshot(sourceURL: checkoutURL.absoluteString, phase: phase, productIDs: ["SYNTHETIC/A"], storeIDs: ["R121"], quantities: [1],
                         totalText: "$10.00", currencyCode: "CAD", pickupStartISO: "2026-10-24T14:00:00Z", pickupEndISO: "2026-10-24T14:15:00Z",
                         pickupSlot: "Synthetic", finalActionCount: phase == .review ? 1 : 0, pickupOnly: true,
                         documentID: "00000000-0000-4000-8000-000000000001", reviewStateID: "00000000-0000-4000-8000-000000000002")
    }
    private func request(market: Market = .ca) -> CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "SYNTHETIC/A", name: "Synthetic", storage: "", color: "", productURL: URL(string: "https://www.apple.com\(market.storefrontPath)/shop/product/synthetic")!),
                        store: RetailStore(id: "R121", name: "Synthetic"), market: market, maximumTotal: 100)
    }
    private func review() -> CheckoutReview {
        let value = Self.evidence()
        return CheckoutReview(variantID: "SYNTHETIC/A", storeID: "R121", quantity: 1, total: 10, currencyCode: "CAD",
                              pickupDate: ISO8601DateFormatter().date(from: value.pickupStartISO!), pickupEndDate: ISO8601DateFormatter().date(from: value.pickupEndISO!),
                              pickupSlot: "Synthetic", expiresAt: Date().addingTimeInterval(60), sourceURL: value.sourceURL,
                              documentID: value.documentID, reviewStateID: value.reviewStateID)
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }

    @Test func initializationAndCookieCompatibilityNeverLaunchSafariOrExportWebsiteData() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(submissionAllowed: false, transport: browser)
        #expect(page.browserKind == .safari && page.usesBrowserManagedSession)
        try await page.restoreSession(Data("invalid legacy cookie bytes".utf8))
        await #expect(throws: CheckoutError.sessionStorage) { try await page.sessionData() }
        page.clearPage()
        await Task.yield()
        #expect(browser.calls == ["cancel"])
    }

    @Test func createsOneOwnedWindowReusesItAndShowsOnlyThatWindow() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        try await page.load(Self.signInURL)
        try await page.showBrowser()
        #expect(browser.calls == ["create", "navigate:101", "navigate:101", "activate:101"])
        #expect(browser.urls.count == 1)
    }

    @Test func metadataMustBeAppleHTTPSBeforeAnyScriptRuns() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        for text in ["https://apple.com.example.invalid/ca/shop/checkout", "https://www.apple.com:444/ca/shop/checkout", "http://www.apple.com/ca/shop/checkout"] {
            browser.urls[101] = URL(string: text)!
            await #expect(throws: CheckoutError.unsupportedPage) { try await page.snapshot() }
            await #expect(throws: CheckoutError.unsupportedPage) { try await page.acknowledgeManualInput(market: .ca) }
        }
        #expect(browser.scripts.isEmpty)
    }

    @Test func sanitizesNativeSourceAndBindsDocumentBeforeGuestOrFormActions() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(submissionAllowed: false, transport: browser)
        try await page.load(URL(string: "https://www.apple.com/ca/shop/signIn?token=SYNTHETIC_SECRET#fragment")!)
        var value = Self.evidence(phase: .authentication); value.sourceURL = "https://untrusted.invalid/?SYNTHETIC_SECRET"
        browser.snapshots = [value]
        let observed = try await page.snapshot()
        #expect(observed.sourceURL == Self.signInURL.absoluteString)
        #expect(try await page.continueAsGuest(request: request(), snapshot: observed))
        let script = try #require(browser.scripts.last)
        #expect(script.contains("location.origin + location.pathname !=="))
        #expect(script.contains("window.__pickupPilot.snapshot().documentID !=="))
        #expect(script.contains("__pickupPilotReviewOnly"))
        #expect(!script.contains("SYNTHETIC_SECRET"))
        #expect(!script.contains("location.href =") && !script.contains("navigator.webdriver"))
        browser.urls[101] = URL(string: "https://www.apple.com/uk/shop/signIn")!
        let count = browser.scripts.count
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.continueAsGuest(request: request(), snapshot: observed) }
        #expect(browser.scripts.count == count)
    }

    @Test func reviewOnlyFinalMethodsReturnBeforeEveryAppleEvent() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(submissionAllowed: false, transport: browser)
        #expect(try await page.placeOrder(expected: Self.evidence()) == false)
        #expect(try await page.placeOrder(expected: Self.evidence(), request: request(), review: review()) == false)
        #expect(browser.calls.isEmpty)
        try await page.load(Self.checkoutURL)
        let count = browser.calls.count
        #expect(try await page.placeOrder(expected: Self.evidence()) == false)
        #expect(try await page.placeOrder(expected: Self.evidence(), request: request(), review: review()) == false)
        #expect(browser.calls.count == count)
    }

    @Test func authorizedFinalCallUsesExistingAtomicReviewCapability() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        #expect(try await page.placeOrder(expected: Self.evidence(), request: request(), review: review()))
        let script = try #require(browser.scripts.last)
        #expect(script.contains("return window.__pickupPilot.submit("))
        #expect(script.contains("reviewExpiresAt") && script.contains("attemptStart"))
        #expect(script.contains("actual[key]") && script.contains("finalClickConsumed"))
        var stale = Self.evidence(); stale.documentID = UUID().uuidString
        let count = browser.scripts.count
        #expect(try await page.placeOrder(expected: stale, request: request(), review: review()) == false)
        #expect(browser.scripts.count == count)
    }

    @Test func changedNativePageDuringEvaluationReturnsLoading() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        browser.postEvaluationURL = Self.signInURL
        let value = try await page.snapshot()
        #expect(value.phase == .loading && value.sourceURL == Self.signInURL.absoluteString)
    }

    @Test func blankStartupPollsWithoutExecutingScript() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        browser.urls[101] = URL(string: "about:blank")!
        #expect(try await page.snapshot().phase == .loading)
        #expect(browser.scripts.isEmpty)
        #expect(try await page.waitForChange(after: CheckoutSnapshot(sourceURL: "about:blank", phase: .loading), timeout: 0.005) == false)
    }

    @Test func cancellationRejectsLateSnapshotAndKeepsWindowForInspection() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        browser.suspendEvaluation = true
        let task = Task { try await page.snapshot() }
        await waitUntil { browser.evaluation != nil }
        let continuation = try #require(browser.evaluation)
        page.cancel()
        continuation.resume(returning: "{\"ok\":true,\"value\":true}")
        await #expect(throws: CheckoutError.cancelled) { try await task.value }
        browser.suspendEvaluation = false
        var confirmation = Self.evidence(phase: .confirmation); confirmation.orderID = "W1234567890"
        browser.snapshots = [confirmation]
        #expect(try await page.snapshot().orderID == "W1234567890")
        let count = browser.calls.count
        await #expect(throws: CheckoutError.cancelled) { try await page.advance(request: request(), profile: SecureProfile()) }
        await #expect(throws: CheckoutError.cancelled) { try await page.placeOrder(expected: Self.evidence(), request: request(), review: review()) }
        #expect(browser.calls.count == count)
        #expect(browser.closeIDs.isEmpty)
        try await page.showBrowser()
        #expect(browser.calls.last == "activate:101")
    }

    @Test func cancellationDuringCreationClosesOnlyLateCreatedWindow() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        browser.suspendCreation = true
        let task = Task { try await page.load(Self.checkoutURL) }
        await waitUntil { browser.creation != nil }
        let continuation = try #require(browser.creation)
        page.cancel()
        continuation.resume(returning: SafariWindowHandle(id: 101))
        await #expect(throws: CheckoutError.cancelled) { try await task.value }
        #expect(browser.closeIDs == [101])
        #expect(!browser.calls.contains("navigate:101"))
    }

    @Test func clearAndResetNeverCloseANewerOrUnownedWindow() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        browser.urls[999] = URL(string: "https://example.invalid")!
        page.clearPage()
        try await page.load(Self.signInURL)
        #expect(browser.closeIDs == [101])
        #expect(browser.urls[102] == Self.signInURL && browser.urls[999] != nil)
        try await page.resetBrowserSession()
        #expect(browser.closeIDs == [101, 102])
        #expect(browser.urls[999] != nil)
        try await page.load(Self.checkoutURL)
        #expect(browser.urls[103] == Self.checkoutURL)
    }

    @Test func onlyObservedFetchOrXHRStatusBecomesBlockingEvidence() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        var blocked = Self.evidence(phase: .blocked); blocked.blockingStatus = 541; blocked.blockingSource = "fetch"
        browser.snapshots = [blocked]
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.snapshot() }
        browser.urls[101] = URL(string: "https://www.apple.com/ca/shop/go/404")!
        let missing = try await page.snapshot()
        #expect(missing.phase == .pageNotFound && missing.blockingStatus == 541 && missing.blockingSource == "fetch")
        #expect(page.diagnostics?.mainFrameStatus == nil)
        #expect(page.diagnostics?.currentRoute == .pageNotFound)
        page.resetDiagnostics()
        let plain = try await page.snapshot()
        #expect(plain.blockingStatus == nil && plain.phase == .pageNotFound)
    }

    @Test(arguments: [SafariAutomationError.permissionDenied, .javascriptDisabled, .windowLost, .ambiguousWindow, .unavailable, .timeout, .cancelled])
    func transportErrorsHaveFixedActionableMessages(_ failure: SafariAutomationError) async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        browser.error = failure
        let expected: CheckoutError
        switch failure {
        case .permissionDenied: expected = .safariPermissionRequired
        case .javascriptDisabled: expected = .safariJavaScriptDisabled
        case .windowLost, .ambiguousWindow: expected = .safariWindowUnavailable
        case .unavailable: expected = .safariUnavailable
        case .cancelled: expected = .cancelled
        default: expected = .safariAutomationFailed
        }
        await #expect(throws: expected) { try await page.load(Self.checkoutURL) }
    }
}
