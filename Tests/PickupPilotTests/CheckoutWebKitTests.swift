import Foundation
import Testing
import WebKit
@testable import PickupPilot
@testable import PilotCore

@Suite(.serialized) @MainActor struct CheckoutWebKitTests {
    private func fixture(_ page: WKAppleCheckoutPage, html: String, path: String = "/ca/shop/checkout") async throws {
        let token = UUID().uuidString
        page.webView.loadHTMLString(html + "<script>document.documentElement.dataset.ppFixture='\(token)'</script>", baseURL: URL(string: "https://www.apple.com\(path)")!)
        for _ in 0..<100 {
            let marker = try? await page.webView.callAsyncJavaScript("return document.documentElement.dataset.ppFixture || '';", in: nil, contentWorld: .page)
            if marker as? String == token, !page.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        // loadHTMLString uses the supplied Apple base origin; no remote resource or checkout action is requested.
        let installed = try await page.webView.callAsyncJavaScript("return typeof window.__pickupPilot === 'object';", in: nil, contentWorld: .page)
        #expect(installed as? Bool == true)
    }
    private func evaluate(_ page: WKAppleCheckoutPage, _ script: String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }
    private var syntheticReviewHTML: String {
        let start = Date().addingTimeInterval(7 * 86_400)
        let formatter = ISO8601DateFormatter()
        return """
        <!doctype html><html><body>
        <script type="application/json" id="metrics">{"data":{"properties":{"currencyCode":"CAD"}}}</script>
        <script type="application/json" id="init_data">{"checkout":{"review":{"billingReview":{"d":{"paymentLabel":"Synthetic Payment A"}},"fulfillmentReview":{"group":{"d":{"pickup":{"storeNumber":"R121","startTime":"\(formatter.string(from: start))","endTime":"\(formatter.string(from: start.addingTimeInterval(900)))","timeslot":"10:00–10:15"}},"items":{"phone":{"d":{"productId":"TEST-CA/A","quantity":1}}}}}}}}</script>
        <section class="rs-review-billing"><p class="rs-review-cardnumber">Synthetic Payment A</p></section>
        <span data-autom="orderTotalValue">CA$3,388.87</span>
        <button type="button" data-autom="continue-button-placeOrder" onclick="document.body.dataset.syntheticClicks=String(Number(document.body.dataset.syntheticClicks||0)+1)">Synthetic Place Order</button>
        </body></html>
        """
    }
    private func syntheticRequest() -> CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "TEST-CA/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky", productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                        store: RetailStore(id: "R121", name: "Synthetic store"), market: .ca, maximumTotal: 4000)
    }
    @Test func actualWebKitBridgeExtractsSanitizedReviewAndRechecksBeforeClick() async throws {
        let page = WKAppleCheckoutPage()
        #expect(!page.webView.configuration.websiteDataStore.isPersistent)
        try await fixture(page, html: syntheticReviewHTML)
        let snapshot = try await page.snapshot()
        #expect(snapshot.phase == .review && snapshot.productIDs == ["TEST-CA/A"])
        #expect(snapshot.storeIDs == ["R121"] && snapshot.quantities == [1])
        #expect(snapshot.pickupOnly && !snapshot.hasErrors)
        _ = try await evaluate(page, """
        const element=document.getElementById('init_data');const data=JSON.parse(element.textContent);
        data.checkout.review.fulfillmentReview.group.items.phone.recommendedSystemCartMoreProducts={d:{productId:'SUGGESTION/A',quantity:1}};
        element.textContent=JSON.stringify(data);return true;
        """)
        #expect(try await page.snapshot().productIDs == ["TEST-CA/A"])
        let request = syntheticRequest()
        let review = try CheckoutPagePolicy.review(from: snapshot, request: request, now: Date())
        _ = try await evaluate(page, "document.querySelector('[data-autom=continue-button-placeOrder]').click(); return true;")
        #expect(try await evaluate(page, "return document.body.dataset.syntheticClicks || '0';") as? String == "0")
        _ = try await evaluate(page, "document.querySelector('[data-autom=orderTotalValue]').textContent='CA$3,500.00';")
        #expect(try await page.placeOrder(expected: snapshot, request: request, review: review) == false)
        #expect(try await evaluate(page, "return document.body.dataset.syntheticClicks || '0';") as? String == "0")
        let updated = try await page.snapshot()
        let updatedReview = try CheckoutPagePolicy.review(from: updated, request: request, now: Date())
        #expect(try await page.placeOrder(expected: updated, request: request, review: updatedReview))
        #expect(try await evaluate(page, "return document.body.dataset.syntheticClicks;") as? String == "1")
        #expect(try await page.placeOrder(expected: updated, request: request, review: updatedReview) == false)
        page.cancel()
    }
    @Test func actualWebKitBridgeFillsSyntheticCardAndContactFields() async throws {
        let page = WKAppleCheckoutPage()
        let html = """
        <html><body><input data-autom="form-field-firstName"><input data-autom="form-field-lastName">
        <input data-autom="form-field-emailAddress"><input data-autom="form-field-mobilePhone">
        <input data-autom="card-number-input"><input data-autom="expiration-input"><input data-autom="security-code-input">
        <input data-autom="form-field-cardholder"><input data-autom="form-field-street">
        <input data-autom="form-field-city"><input data-autom="form-field-state"><input data-autom="form-field-postalCode"><input data-autom="form-field-country">
        <button data-autom="continue-button-review" onclick="document.body.dataset.continued='yes'">Synthetic Review</button></body></html>
        """
        try await fixture(page, html: html)
        let profile = SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid", phone: "+15555550100",
                                    cardholder: "Synthetic Tester", cardNumber: "4242424242424242", expiryMonth: "12", expiryYear: "2030", cvv: "123",
                                    billingLine1: "1 Synthetic Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
        #expect(try await page.advance(request: syntheticRequest(), profile: profile))
        #expect(try await evaluate(page, "return document.querySelector('[data-autom=card-number-input]').value;") as? String == "4242424242424242")
        #expect(try await evaluate(page, "return document.querySelector('[data-autom=security-code-input]').value;") as? String == "123")
        #expect(try await evaluate(page, "return document.querySelector('[data-autom=form-field-firstName]').value;") as? String == "Synthetic")
        #expect(try await page.advance(request: syntheticRequest(), profile: profile))
        #expect(try await evaluate(page, "return document.body.dataset.continued;") as? String == "yes")
        let snapshot = try await page.snapshot()
        let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!text.contains("424242") && !text.contains("example.invalid") && !text.contains("Tester"))
    }
    @Test func actualWebKitProductControlsCannotAddTwiceAndAuthIsDetected() async throws {
        let page = WKAppleCheckoutPage()
        try await fixture(page, html: """
        <html><body><form data-part-number="TEST-CA/A" onsubmit="event.preventDefault()">
        <input type="radio" data-autom="choose-noTradeIn"><input type="radio" data-autom="noapplecare">
        <button type="button" data-autom="add-to-cart" onclick="document.body.dataset.syntheticAdds=String(Number(document.body.dataset.syntheticAdds||0)+1)">Add</button>
        </form></body></html>
        """, path: "/ca/shop/buy-iphone/iphone-duo/synthetic")
        #expect(try await page.snapshot().phase == .product)
        for _ in 0..<3 { #expect(try await page.advance(request: syntheticRequest(), profile: SecureProfile())) }
        #expect(try await page.advance(request: syntheticRequest(), profile: SecureProfile()) == false)
        #expect(try await evaluate(page, "return document.body.dataset.syntheticAdds;") as? String == "1")
        try await fixture(page, html: "<html><body><input type='password'></body></html>", path: "/ca/shop/signIn")
        #expect(try await page.snapshot().phase == .authentication)
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.load(URL(string: "https://example.invalid/")!) }
    }
    @Test func actualWebKitChoosesOnlyConfiguredStoreAndPermittedPickupSlot() async throws {
        let page = WKAppleCheckoutPage()
        let html = """
        <html><body>
        <script id="init_data" type="application/json">{"checkout":{"fulfillment":{"pickupTab":{"pickup":{"timeSlot":{"d":{
        "pickUpDates":[{"dayOfMonth":"24","date":"2026-10-24"}],"timeSlotWindows":[{"24":[
        {"timeSlotValue":"24-outside","checkInStart":"08:00","checkInEnd":"08:15","timeZone":"America/Toronto"},
        {"timeSlotValue":"24-restricted","checkInStart":"10:00","checkInEnd":"10:15","timeZone":"America/Toronto","isRestricted":true},
        {"timeSlotValue":"24-valid","checkInStart":"10:00","checkInEnd":"10:15","timeZone":"America/Toronto"}
        ]}]}}}}}}}</script>
        <input type="radio" name="fulfillment" value="PICKUP"><input type="radio" name="store-locator-result" value="R999">
        <input type="radio" name="store-locator-result" value="R121">
        <input type="radio" name="bartPickupDateSelectorButtonGroup" value="24">
        <select data-autom="pickup-availablewindow-dropdown"><option value="">Pick one</option><option value="24-valid">10:00–10:15</option></select>
        <button data-autom="fulfillment-continue-button" onclick="document.body.dataset.syntheticContinued='yes'">Continue</button>
        </body></html>
        """
        try await fixture(page, html: html)
        let base = syntheticRequest()
        let request = CheckoutRequest(variant: base.variant, store: base.store, market: .ca, maximumTotal: 4000,
                                      pickupWindow: DateWindow(start: Date(timeIntervalSince1970: 1_792_166_400), end: Date(timeIntervalSince1970: 1_793_894_400)),
                                      pickupHours: DailyWindow(startMinute: 600, endMinute: 660), timeZoneIdentifier: "America/Toronto")
        for _ in 0..<5 { #expect(try await page.advance(request: request, profile: SecureProfile())) }
        #expect(try await evaluate(page, "return document.querySelector('input[name=store-locator-result]:checked').value;") as? String == "R121")
        #expect(try await evaluate(page, "return document.querySelector('[data-autom=pickup-availablewindow-dropdown]').value;") as? String == "24-valid")
        #expect(try await evaluate(page, "return document.body.dataset.syntheticContinued;") as? String == "yes")
        _ = try await evaluate(page, "document.getElementById('init_data').textContent='{}'; return true;")
        #expect(try await page.advance(request: request, profile: SecureProfile()) == false)
        page.clearPage()
    }
    @Test func cookieSerializationScopesOnlyAppleAndExpiresCorrectly() async throws {
        let now = Date()
        let apple = try #require(HTTPCookie(properties: [.name:"synthetic",.value:"synthetic-cookie-value",.domain:".apple.com",.path:"/",.secure:"TRUE",.expires:now.addingTimeInterval(600),HTTPCookiePropertyKey("HttpOnly"):"TRUE"]))
        let value = AppleSessionCookie(apple)
        #expect(value.name == "synthetic" && value.secure && value.httpOnly)
        #expect(value.cookie(at: now)?.value == "synthetic-cookie-value")
        #expect(value.cookie(at: now.addingTimeInterval(1000)) == nil)
        var foreign = value; foreign.domain = "apple.com.evil.invalid"
        #expect(foreign.cookie(at: now) == nil)
        #expect(!AppleSessionCookie.isAppleDomain("evilapple.com"))
        #expect(AppleSessionCookie.isAppleDomain("secure6.store.apple.com"))
        let page = WKAppleCheckoutPage()
        try await page.restoreSession(try JSONEncoder().encode([value,foreign]))
        let stored = try JSONDecoder().decode([AppleSessionCookie].self, from: await page.sessionData())
        #expect(stored.count == 1 && stored[0].value == "synthetic-cookie-value")
        try await page.restoreSession(nil)
        #expect(try JSONDecoder().decode([AppleSessionCookie].self, from: await page.sessionData()).isEmpty)
        let noExpiry = try #require(HTTPCookie(properties:[.name:"synthetic-session",.value:"value",.domain:"apple.com",.path:"/"]))
        #expect(AppleSessionCookie(noExpiry).cookie(at: now) != nil)
        await #expect(throws: (any Error).self) { try await page.restoreSession(Data("broken".utf8)) }
    }
}
