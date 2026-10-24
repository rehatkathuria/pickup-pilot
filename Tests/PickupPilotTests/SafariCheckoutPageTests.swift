import Foundation
import JavaScriptCore
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
    var evaluationEnvelope: String?
    var navigationIntents = 0
    var documentConfirmations = 0

    func expectNavigation(in handle: SafariWindowHandle) { navigationIntents += 1 }
    func confirmDocument(in handle: SafariWindowHandle) { documentConfirmations += 1 }

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
        if let evaluationEnvelope { return evaluationEnvelope }
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

    /// Exercise the generated early URL guards without a browser or profile.
    /// Every supplied document must return before the adapter touches its DOM.
    private func guardResult(_ script: String, documentAddress: String) throws -> [String: Any] {
        let context = try #require(JSContext())
        let components = try #require(URLComponents(string: documentAddress))
        let scheme = try #require(components.scheme)
        let host = components.host ?? ""
        let port = components.port.map(String.init) ?? ""
        context.setObject([
            "href": documentAddress, "protocol": scheme + ":", "hostname": host,
            "username": components.user ?? "", "password": components.password ?? "", "port": port,
            "origin": scheme + "://" + host + (port.isEmpty ? "" : ":" + port), "pathname": components.path
        ], forKeyedSubscript: "location" as NSString)
        let result = try #require(context.evaluateScript(script)?.toString())
        #expect(context.exception == nil)
        return try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
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
        #expect(script.range(of: #"location\.href\s*=(?!=)"#, options: .regularExpression) == nil && !script.contains("navigator.webdriver"))
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

    @Test func navigationBeforeSnapshotJavaScriptPollsTheNewPageWithoutAdvancingTheOldDocument() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        _ = try await page.snapshot()
        browser.postEvaluationURL = URL(string: "https://www.apple.com/ca/shop/signIn?SYNTHETIC_SECRET#fragment")!
        browser.evaluationEnvelope = "{\"ok\":false,\"navigationChanged\":true}"
        let value = try await page.snapshot()
        #expect(value.phase == .loading && value.sourceURL == Self.signInURL.absoluteString)
        #expect(browser.scripts.last?.contains("navigationChanged:true") == true)
        let count = browser.calls.count
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        #expect(browser.calls.count == count)
        browser.postEvaluationURL = nil
        browser.evaluationEnvelope = nil
        browser.snapshots = [Self.evidence(phase: .authentication)]
        #expect(try await page.snapshot().phase == .authentication)
    }

    @Test(arguments: ["https://www.apple.com/ca/shop/product/synthetic", "about:blank"])
    func destinationMetadataCanLeadTheOldAppleOrInitialBlankDocument(_ documentAddress: String) async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        let bagURL = URL(string: "https://www.apple.com/ca/shop/bag")!
        try await page.load(bagURL)
        _ = try await page.snapshot()
        browser.evaluationEnvelope = "{\"ok\":false,\"navigationChanged\":true}"
        let pending = try await page.snapshot()
        #expect(pending.phase == .loading && pending.sourceURL == bagURL.absoluteString)
        let script = try #require(browser.scripts.last)
        let result = try guardResult(script, documentAddress: documentAddress)
        #expect(result["ok"] as? Bool == false && result["navigationChanged"] as? Bool == true)
        let count = browser.calls.count
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        #expect(browser.calls.count == count)
        browser.evaluationEnvelope = nil
        browser.snapshots = [Self.evidence(phase: .bag)]
        #expect(try await page.snapshot().phase == .bag)
    }

    @Test(arguments: ["https://apple.com.example.invalid/ca/shop/product/synthetic", "http://www.apple.com/ca/shop/product/synthetic", "https://www.apple.com:444/ca/shop/product/synthetic", "about:blank#foreign"])
    func foreignJavaScriptDocumentsRemainRejectedDuringNativeAppleNavigation(_ documentAddress: String) async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        browser.evaluationEnvelope = "{\"ok\":false}"
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.snapshot() }
        let result = try guardResult(try #require(browser.scripts.last), documentAddress: documentAddress)
        #expect(result["ok"] as? Bool == false && result["navigationChanged"] == nil)
    }

    @Test(arguments: ["https://apple.com.example.invalid/ca/shop/bag", "http://www.apple.com/ca/shop/bag", "https://www.apple.com:444/ca/shop/bag", "about:blank#foreign"])
    func navigationMarkersRequireTheOwnedWindowToStillHaveAnAllowedNativeDestination(_ destination: String) async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        _ = try await page.snapshot()
        browser.postEvaluationURL = URL(string: destination)!
        browser.evaluationEnvelope = "{\"ok\":false,\"navigationChanged\":true}"
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.snapshot() }
        let count = browser.calls.count
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        #expect(browser.calls.count == count)
    }

    @Test func navigationMayReturnToTheExactInitialBlankDocument() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        browser.postEvaluationURL = URL(string: "about:blank")!
        browser.evaluationEnvelope = "{\"ok\":false,\"navigationChanged\":true}"
        let value = try await page.snapshot()
        #expect(value.phase == .loading && value.sourceURL == "about:blank")
    }

    @Test func ordinaryRejectedReadsFailButProvenUndispatchedWritesReobserveNavigation() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        _ = try await page.snapshot()
        browser.postEvaluationURL = Self.signInURL
        browser.evaluationEnvelope = "{\"ok\":false}"
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.snapshot() }
        browser.urls[101] = Self.checkoutURL
        browser.postEvaluationURL = nil
        browser.evaluationEnvelope = "{\"ok\":false,\"navigationChanged\":true}"
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        let script = try #require(browser.scripts.last)
        let rejected = try guardResult(script, documentAddress: Self.signInURL.absoluteString)
        #expect(rejected["ok"] as? Bool == false && rejected["navigationChanged"] as? Bool == true)
        #expect(script.contains("location.href === 'about:blank'"))
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

    @Test func transientSafariObjectLookupWaitsForTheNewDocument() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        _ = try await page.snapshot()
        browser.error = .navigationChanged
        #expect(try await page.snapshot().phase == .loading)
        browser.error = nil
        #expect(try await page.snapshot().phase == .review)
        #expect(browser.calls.filter { $0 == "create" }.count == 1)
    }

    @Test func unchangedPostClickBagCannotRevokePendingCrossOriginNavigation() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        let bag = Self.evidence(phase: .bag)
        browser.snapshots = [bag]
        _ = try await page.snapshot()
        let confirmations = browser.documentConfirmations
        #expect(try await page.advance(request: request(), profile: SecureProfile()))
        browser.snapshots = [bag]
        _ = try await page.snapshot()
        browser.actionResult = false
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        #expect(browser.documentConfirmations == confirmations)
        browser.snapshots = [Self.evidence(phase: .fulfillment)]
        _ = try await page.snapshot()
        #expect(browser.documentConfirmations == confirmations + 1)
    }

    @Test func transientGuestMetadataReadDoesNotConsumeAnUnsentGuestAction() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.signInURL)
        browser.snapshots = [Self.evidence(phase: .authentication)]
        let auth = try await page.snapshot()
        let priorEvaluations = browser.scripts.count
        browser.error = .navigationChanged
        #expect(try await page.continueAsGuest(request: request(), snapshot: auth) == false)
        #expect(browser.scripts.count == priorEvaluations)
        browser.error = nil
        #expect(try await page.continueAsGuest(request: request(), snapshot: auth))
        #expect(browser.scripts.count == priorEvaluations + 1)
    }

    @Test func blankDocumentBetweenSnapshotAndActionIsAReadinessTransition() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        _ = try await page.snapshot()
        let evaluations = browser.scripts.count
        browser.urls[101] = URL(string: "about:blank")!
        await #expect(throws: CheckoutError.safariNavigationChanged) {
            _ = try await page.advance(request: request(), profile: SecureProfile())
        }
        #expect(browser.scripts.count == evaluations)
    }

    @Test func lostWindowRecoveryCreatesANewOwnedBagWithoutClosingUnprovenTabs() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        #expect(try await page.recoverCheckoutNavigation(request: request()))
        #expect(browser.urls[102]?.absoluteString == "https://www.apple.com/ca/shop/bag")
        #expect(browser.closeIDs.isEmpty)
        #expect(page.diagnostics?.action == .reconnectingBrowser)
        page.cancel()
        #expect(try await page.recoverCheckoutNavigation(request: request()) == false)
        #expect(browser.calls.filter { $0 == "create" }.count == 2)
    }

    @Test func accessResponseCannotBecomeAnAutomaticWindowRecovery() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        var blocked = Self.evidence(phase: .blocked)
        blocked.blockingStatus = 541; blocked.blockingSource = "fetch"
        browser.snapshots = [blocked]
        await #expect(throws: CheckoutError.storefrontBlocked) { _ = try await page.snapshot() }
        #expect(try await page.recoverCheckoutNavigation(request: request()) == false)
        #expect(browser.calls.filter { $0 == "create" }.count == 1)
    }

    @Test func uncertainFinalActionCannotReconnectOrReplayInANewWindow() async throws {
        let browser = SyntheticSafariController()
        let page = SafariAppleCheckoutPage(transport: browser)
        try await page.load(Self.checkoutURL)
        let expected = try await page.snapshot()
        browser.error = .navigationChanged
        await #expect(throws: CheckoutError.safariNavigationChanged) {
            _ = try await page.placeOrder(expected: expected, request: request(), review: review())
        }
        browser.error = nil
        #expect(try await page.recoverCheckoutNavigation(request: request()) == false)
        #expect(browser.calls.filter { $0 == "create" }.count == 1)
    }

    @Test(arguments: [SafariAutomationError.permissionDenied, .javascriptDisabled, .windowLost, .ambiguousWindow, .unavailable, .timeout, .cancelled, .navigationChanged])
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
        case .navigationChanged: expected = .safariNavigationChanged
        default: expected = .safariAutomationFailed
        }
        await #expect(throws: expected) { try await page.load(Self.checkoutURL) }
    }
}
