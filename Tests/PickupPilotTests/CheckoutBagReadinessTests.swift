import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

private actor BagReadinessVault: SecureVault {
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

/// Only navigation is replaced. Snapshots, DOM changes, waits and nonfinal clicks
/// use the production native WebKit bridge. The document cannot access a network.
@MainActor private final class BagReadinessPage: AppleCheckoutPage {
    let native = WKAppleCheckoutPage(submissionAllowed: false)
    var revealAfterFirstSnapshot = false
    private(set) var phases: [CheckoutSnapshot.Phase] = []
    private(set) var loads = 0
    private(set) var advances = 0
    private(set) var finalCalls = 0
    func load(_ url: URL) { loads += 1 }
    func snapshot() async throws -> CheckoutSnapshot {
        let result = try await native.snapshot()
        phases.append(result.phase)
        if revealAfterFirstSnapshot, phases.count == 1 {
            _ = try await evaluate("setTimeout(()=>window.__syntheticBag.reveal(),30);return true;")
        }
        return result
    }
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) async throws -> Bool {
        if phases.isEmpty { return true } // The local load has already completed.
        return try await native.waitForChange(after: snapshot, timeout: timeout)
    }
    func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool {
        advances += 1
        return try await native.advance(request: request, profile: profile)
    }
    func placeOrder(expected: CheckoutSnapshot) -> Bool { finalCalls += 1; return false }
    func restoreSession(_ data: Data?) {}
    func sessionData() async throws -> Data { try await native.sessionData() }
    func cancel() { native.cancel() }
    func evaluate(_ script: String) async throws -> Any? {
        try await native.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }
}

@MainActor private final class BagReadinessClock {
    var value = Date()
}

@Suite(.serialized) @MainActor struct CheckoutBagReadinessTests {
    private var request: CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "BAG-SYNTHETIC-CA/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky",
                                               productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                        store: RetailStore(id: "R121", name: "Synthetic store"), market: .ca, maximumTotal: 4000)
    }
    private func cart(sku: String = "BAG-SYNTHETIC-CA/A", quantity: Int = 1, hasItems: Bool = true) -> [String: Any] {
        ["d": ["hasItems": hasItems], "items": ["phone": ["d": ["productId": sku, "quantity": quantity]]]]
    }
    private func liveCart(sku: String = "BAG-SYNTHETIC-CA/A", quantity: Any = 1, originalQty: Int = 1) -> [String: Any] {
        ["d": ["hasItems": true], "items": ["c": ["synthetic-item"], "synthetic-item": [
            "d": ["sku": sku], "itemQuantity": ["d": ["quantity": quantity, "originalQty": originalQty]],
            "delivery": ["d": [String: Any]()]
        ]]]
    }
    private func installControls(_ page: BagReadinessPage, legacy: Bool = false, financeOnly: Bool = false) async throws {
        let configuration: [[String: String]]
        if legacy {
            configuration = [["id": financeOnly ? "cart-actions-installmentCheckout" : "synthetic-legacy-checkout", "autom": "bag-checkout-button"]]
        } else {
            let ids = financeOnly ? ["shoppingCart.actions.continueWithInstallmentCheckout", "shoppingCart.actions.apwCheckout"] :
                ["shoppingCart.actions.navCheckout", "shoppingCart.actions.checkout", "shoppingCart.actions.continueWithInstallmentCheckout", "shoppingCart.actions.apwCheckout"]
            configuration = ids.map { ["id": $0, "autom": "checkout"] }
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)
        _ = try await page.evaluate("""
        const container=document.getElementById('synthetic-bag');container.replaceChildren();
        for(const definition of \(json)){
          const button=document.createElement('button');button.type='button';button.id=definition.id;
          button.dataset.autom=definition.autom;button.textContent='Synthetic Checkout';
          button.onclick=()=>{__syntheticBag.checkouts++;document.body.dataset.clickedControl=button.id;};container.append(button);
        }
        return true;
        """)
    }
    private func fixture(_ page: BagReadinessPage, cart: [String: Any]? = nil) async throws {
        let marker = UUID().uuidString
        let initial: [String: Any] = cart.map { ["shoppingCart": $0] } ?? [:]
        let initialJSON = String(decoding: try JSONSerialization.data(withJSONObject: initial), as: UTF8.self)
        let readyJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["shoppingCart": self.cart()]), as: UTF8.self)
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'none'">
        <script id="init_data" type="application/json">\(initialJSON)</script></head><body>
        <main id="synthetic-bag"></main><script>
        window.__syntheticBag={checkouts:0,revealed:false,reveal(){
          this.revealed=true;document.getElementById('init_data').textContent=JSON.stringify(\(readyJSON));
          const button=document.createElement('button');button.type='button';button.dataset.autom='bag-checkout-button';button.textContent='Synthetic Checkout';
          button.onclick=()=>{__syntheticBag.checkouts++;const challenge=document.createElement('input');challenge.type='password';document.body.replaceChildren(challenge);};
          document.getElementById('synthetic-bag').replaceChildren(button);
        }};
        document.addEventListener('DOMContentLoaded',()=>document.documentElement.dataset.bagFixture='\(marker)',{once:true});
        </script></body></html>
        """
        page.native.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        page.native.webView.loadHTMLString(html, baseURL: URL(string: "https://www.apple.com/ca/shop/bag")!)
        var ready = false
        for _ in 0..<150 {
            let value = try? await page.evaluate("return document.documentElement.dataset.bagFixture||'';")
            if value as? String == marker, !page.native.webView.isLoading { ready = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready)
    }

    @Test func delayedCartAfterDOMContentLoadedWaitsForAuthorityBeforeCheckout() async throws {
        let page = BagReadinessPage()
        defer { page.native.clearPage() }
        try await fixture(page)
        #expect(try await page.evaluate("return document.readyState==='complete'&&!__syntheticBag.revealed;") as? Bool == true)
        page.revealAfterFirstSnapshot = true
        let driver = AppleCheckoutDriver(vault: BagReadinessVault(), page: page, webView: page.native.webView)
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(page.phases.first == .loading)
        #expect(page.phases.contains(.bag) && page.phases.last == .authentication)
        #expect(try await page.evaluate("return __syntheticBag.revealed&&__syntheticBag.checkouts===1;") as? Bool == true)
        #expect(page.loads == 1 && page.advances == 1 && page.finalCalls == 0)
        driver.cancel()
    }

    @Test func permanentlyMissingCartAuthorityStopsAtThePreparationDeadline() async throws {
        let page = BagReadinessPage()
        defer { page.native.clearPage() }
        try await fixture(page)
        let clock = BagReadinessClock(), started = clock.value
        let driver = AppleCheckoutDriver(vault: BagReadinessVault(), page: page, webView: page.native.webView,
                                         now: { clock.value }, sleep: { clock.value.addTimeInterval(10) })
        await #expect(throws: CheckoutError.unsupportedPage) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(clock.value == started.addingTimeInterval(30))
        #expect(page.phases == [.loading, .loading])
        #expect(page.loads == 1 && page.advances == 0 && page.finalCalls == 0)
        driver.cancel()
    }

    @Test func explicitOrParsedContradictoryCartIsRejectedImmediately() async throws {
        let contradictions = [cart(sku: "OTHER-SYNTHETIC-CA/A"), cart(quantity: 2), cart(hasItems: false),
                              ["d": ["hasItems": true], "items": [String: Any]()]]
        for contradiction in contradictions {
            let page = BagReadinessPage()
            try await fixture(page, cart: contradiction)
            let driver = AppleCheckoutDriver(vault: BagReadinessVault(), page: page, webView: page.native.webView)
            await #expect(throws: CheckoutError.unsafeReview) { try await driver.prepare(request: request, profile: SecureProfile()) }
            #expect(page.phases == [.bag])
            #expect(page.loads == 1 && page.advances == 0 && page.finalCalls == 0)
            #expect(try await page.evaluate("return __syntheticBag.checkouts;") as? Int == 0)
            driver.cancel()
            page.native.clearPage()
        }
    }

    @Test func liveSKUAndQuantityShapeUsesOneNormalCheckoutAcrossBothMirrors() async throws {
        let page = BagReadinessPage()
        defer { page.native.clearPage() }
        try await fixture(page, cart: liveCart())
        try await installControls(page)
        let snapshot = try await page.native.snapshot()
        #expect(snapshot.phase == .bag && snapshot.productIDs == [request.variant.id] && snapshot.quantities == [1])
        #expect(try await page.native.advance(request: request, profile: SecureProfile()))
        #expect(try await page.evaluate("return document.body.dataset.clickedControl;") as? String == "shoppingCart.actions.checkout")
        for _ in 0..<4 {
            try await installControls(page) // New main/nav DOM elements still share the one workflow latch.
            #expect(try await page.native.advance(request: request, profile: SecureProfile()) == false)
        }
        #expect(try await page.evaluate("return __syntheticBag.checkouts;") as? Int == 1)
        #expect(page.finalCalls == 0)
    }

    @Test func currentQuantityOverridesHistoricalOriginalQuantityWithoutHidingInvalidCurrentData() async throws {
        let page = BagReadinessPage()
        defer { page.native.clearPage() }
        try await fixture(page, cart: liveCart(quantity: 1, originalQty: 2))
        try await installControls(page)
        #expect(try await page.native.snapshot().quantities == [1])
        #expect(try await page.native.advance(request: request, profile: SecureProfile()))
        #expect(try await page.evaluate("return __syntheticBag.checkouts;") as? Int == 1)
    }

    @Test func liveShapeWrongExtraContradictoryOrUnverifiableItemsNeverCheckout() async throws {
        var extra = liveCart()
        var extraItems = try #require(extra["items"] as? [String: Any])
        extraItems["unexpected-item"] = ["d": ["sku": "UNEXPECTED-CA/A"], "itemQuantity": ["d": ["quantity": 1]]]
        extra["items"] = extraItems // Even an item omitted from c must not disappear from validation.
        var contradictory = liveCart()
        var items = try #require(contradictory["items"] as? [String: Any])
        var item = try #require(items["synthetic-item"] as? [String: Any])
        item["d"] = ["sku": request.variant.id, "productId": "DIFFERENT-CA/A"]
        items["synthetic-item"] = item; contradictory["items"] = items
        var missing = liveCart()
        var missingItems = try #require(missing["items"] as? [String: Any]); missingItems["c"] = ["synthetic-item", "missing-item"]
        missing["items"] = missingItems
        let invalid = [liveCart(sku: "WRONG-CA/A"), liveCart(quantity: 2), liveCart(quantity: "invalid"),
                       liveCart(quantity: NSNull()), extra, contradictory, missing]
        for candidate in invalid {
            let page = BagReadinessPage()
            try await fixture(page, cart: candidate)
            try await installControls(page)
            #expect(try await page.native.snapshot().phase == .bag)
            #expect(try await page.native.advance(request: request, profile: SecureProfile()) == false)
            #expect(try await page.evaluate("return __syntheticBag.checkouts;") as? Int == 0)
            let driver = AppleCheckoutDriver(vault: BagReadinessVault(), page: page, webView: page.native.webView)
            await #expect(throws: CheckoutError.unsafeReview) { try await driver.prepare(request: request, profile: SecureProfile()) }
            #expect(page.advances == 0 && page.finalCalls == 0)
            driver.cancel(); page.native.clearPage()
        }
    }

    @Test func normalNavigationMirrorAndLegacyShapeWorkWhileFinanceAndApplePayAreIgnored() async throws {
        let navigation = BagReadinessPage()
        defer { navigation.native.clearPage() }
        try await fixture(navigation, cart: liveCart())
        try await installControls(navigation)
        _ = try await navigation.evaluate("document.getElementById('shoppingCart.actions.checkout').disabled=true;return true;")
        #expect(try await navigation.native.advance(request: request, profile: SecureProfile()))
        #expect(try await navigation.evaluate("return document.body.dataset.clickedControl;") as? String == "shoppingCart.actions.navCheckout")
        let legacy = BagReadinessPage()
        defer { legacy.native.clearPage() }
        try await fixture(legacy, cart: cart())
        try await installControls(legacy, legacy: true)
        #expect(try await legacy.native.advance(request: request, profile: SecureProfile()))
        #expect(try await legacy.evaluate("return __syntheticBag.checkouts;") as? Int == 1)
        for oldSelector in [false, true] {
            let ignored = BagReadinessPage()
            try await fixture(ignored, cart: liveCart())
            try await installControls(ignored, legacy: oldSelector, financeOnly: true)
            #expect(try await ignored.native.advance(request: request, profile: SecureProfile()) == false)
            #expect(try await ignored.evaluate("return __syntheticBag.checkouts;") as? Int == 0)
            ignored.native.clearPage()
        }
    }
}
