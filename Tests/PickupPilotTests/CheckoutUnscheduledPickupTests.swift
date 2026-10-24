import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

@MainActor private final class UnscheduledBridge {
    weak var page: WKAppleCheckoutPage?
    var invalidateBeforeFinal = false
}

/// Network-denied local Apple-origin documents exercise the actual bridge. The
/// synthetic final control only increments a counter; it cannot create an order.
@Suite(.serialized) @MainActor struct CheckoutUnscheduledPickupTests {
    private var request: CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: CatalogProduct.adapterSKU, name: "Synthetic Adapter", storage: "", color: "",
                                               productURL: CatalogProduct.adapterURL),
                        store: RetailStore(id: "R121", name: "Synthetic Store"), market: .ca, maximumTotal: 25)
    }
    private func evaluate(_ page: WKAppleCheckoutPage, _ script: String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }
    private func fixture(_ page: WKAppleCheckoutPage, data: [String: Any], controls: String,
                         path: String = "/ca/shop/checkout") async throws {
        let marker = UUID().uuidString
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        let html = """
        <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'none'">
        <script id="init_data" type="application/json">\(json)</script>
        <script id="metrics" type="application/json">{"data":{"properties":{"currencyCode":"CAD"}}}</script>
        </head><body data-unscheduled-fixture="\(marker)">\(controls)</body></html>
        """
        page.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://www.apple.com\(path)")!)
        for _ in 0..<150 {
            let value = try? await evaluate(page, "return document.body?.dataset.unscheduledFixture||'';")
            if value as? String == marker, !page.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckoutError.unsupportedPage
    }
    private var fulfillmentControls: String {
        """
        <input type="radio" name="fulfillment" value="PICKUP" checked>
        <input type="radio" name="store-locator-result" value="R121" checked>
        <button type="button" data-autom="fulfillment-continue-button" onclick="document.body.dataset.continues=String(Number(document.body.dataset.continues||0)+1)">Continue</button>
        """
    }
    private func fulfillment(_ pickup: Any?) -> [String: Any] {
        var tab: [String: Any] = [:]
        if let pickup { tab["pickup"] = pickup }
        return ["checkout": ["fulfillment": ["pickupTab": tab]]]
    }
    private func review(_ pickup: [String: Any], sku: String = CatalogProduct.adapterSKU,
                        quantity: Int = 1, delivery: Bool = false) -> [String: Any] {
        var group: [String: Any] = ["d": ["pickup": pickup], "items": ["adapter": ["d": ["productId": sku, "quantity": quantity]]]]
        if delivery { group["delivery"] = ["d": ["delivers": true]] }
        return ["checkout": ["review": ["billingReview": ["d": ["paymentLabel": "Synthetic Payment"]], "fulfillmentReview": ["group": group]]]]
    }
    private var reviewControls: String {
        """
        <section class="rs-review-billing"><p>Synthetic Payment</p></section>
        <span data-autom="orderTotalValue">CA$11.30</span>
        <button type="button" data-autom="continue-button-placeOrder" onclick="document.body.dataset.finalClicks=String(Number(document.body.dataset.finalClicks||0)+1)">Synthetic final control</button>
        """
    }

    @Test func exactAdapterWithAuthoritativeNoSlotModuleAdvancesOnce() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, data: fulfillment(["d": ["pickupQuote": "Synthetic pickup when ready"]]), controls: fulfillmentControls)
        #expect(try await page.snapshot().phase == .fulfillment)
        #expect(request.allowsUnscheduledPickup)
        #expect(try await page.advance(request: request, profile: SecureProfile()))
        #expect(try await page.advance(request: request, profile: SecureProfile()) == false)
        #expect(try await evaluate(page, "return Number(document.body.dataset.continues||0);") as? Int == 1)
    }

    @Test(arguments: ["phone", "other-market", "missing-module", "empty-module", "null-module", "null-picker", "hidden-picker", "unknown-reservation", "invalid-time", "wrong-store", "disabled-store", "disabled-fieldset", "aria-disabled-parent"])
    func absenceOfVisibleSlotAloneNeverGrantsUnscheduledPickup(_ kind: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        var section: Any? = ["d": [String: Any]()]
        var controls = fulfillmentControls, selected = request, path = "/ca/shop/checkout"
        switch kind {
        case "phone":
            selected = CheckoutRequest(variant: ProductVariant(id: "SYNTHETIC-CA/A", name: "Synthetic Duo", storage: "256GB", color: "Synthetic",
                                                               productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                                       store: request.store, market: .ca, maximumTotal: 4_000)
        case "other-market":
            selected = CheckoutRequest(variant: request.variant, store: request.store, market: .us, maximumTotal: 25)
            path = "/shop/checkout"
        case "missing-module": section = nil
        case "empty-module": section = [String: Any]()
        case "null-module": section = NSNull()
        case "null-picker": section = ["d": [String: Any](), "timeSlot": ["dateTimeSlots": NSNull()]]
        case "hidden-picker": section = ["d": [String: Any](), "timeSlot": ["dateTimeSlots": ["d": [String: Any]()]]]
        case "unknown-reservation": section = ["d": ["reservationWindow": "unsupported"]]
        case "invalid-time": section = ["d": ["startTime": NSNull()]]
        case "wrong-store": controls = controls.replacingOccurrences(of: "value=\"R121\"", with: "value=\"R999\"")
        case "disabled-fieldset": controls = "<fieldset disabled>" + controls + "</fieldset>"
        case "aria-disabled-parent": controls = "<div aria-disabled=\"TRUE\">" + controls + "</div>"
        default: controls = controls.replacingOccurrences(of: "value=\"R121\" checked", with: "value=\"R121\" checked disabled")
        }
        try await fixture(page, data: fulfillment(section), controls: controls, path: path)
        #expect(try await page.advance(request: selected, profile: SecureProfile()) == false)
        #expect(try await evaluate(page, "return Number(document.body.dataset.continues||0);") as? Int == 0)
    }

    @Test func finalUnscheduledEvidenceHasNoInventedDatesAndStillUsesNativeLimits() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, data: review(["storeNumber": "R121", "quote": "Synthetic available today", "timeslot": ""]), controls: reviewControls)
        let snapshot = try await page.snapshot()
        #expect(snapshot.pickupIsUnscheduled == true && snapshot.pickupOnly)
        #expect(snapshot.pickupStartISO == nil && snapshot.pickupEndISO == nil)
        #expect(snapshot.pickupSlot == "Pickup after Apple confirms it is ready")
        let approved = try CheckoutPagePolicy.review(from: snapshot, request: request, now: Date())
        #expect(approved.pickupIsUnscheduled && approved.pickupDate == nil && approved.pickupEndDate == nil)
        var overBudget = snapshot; overBudget.totalText = "CA$25.01"
        #expect(throws: CheckoutError.unsafeReview) { try CheckoutPagePolicy.review(from: overBudget, request: request, now: Date()) }
        var otherStore = snapshot; otherStore.storeIDs = ["R999"]
        #expect(throws: CheckoutError.unsafeReview) { try CheckoutPagePolicy.review(from: otherStore, request: request, now: Date()) }
        #expect(try await page.placeOrder(expected: snapshot, request: request, review: approved) == false)
        #expect(try await evaluate(page, "return Number(document.body.dataset.finalClicks||0);") as? Int == 0)
    }

    @Test(arguments: ["startTime", "endTime", "checkInStart", "checkInEnd", "timeSlot", "dateTimeSlots", "pickupWindow", "reservationDate", "timeZone", "timeslot", "phone", "delivery", "quantity"])
    func contradictoryOrUnknownTimingNeverBecomesUnscheduled(_ kind: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        var pickup: [String: Any] = ["storeNumber": "R121"]
        if kind == "timeslot" { pickup[kind] = "Synthetic unknown slot" }
        else if !["phone", "delivery", "quantity"].contains(kind) { pickup[kind] = NSNull() }
        let sku = kind == "phone" ? "SYNTHETIC-CA/A" : CatalogProduct.adapterSKU
        try await fixture(page, data: review(pickup, sku: sku, quantity: kind == "quantity" ? 2 : 1, delivery: kind == "delivery"), controls: reviewControls)
        let snapshot = try await page.snapshot()
        #expect(snapshot.pickupIsUnscheduled == false)
        #expect(throws: CheckoutError.unsafeReview) { try CheckoutPagePolicy.review(from: snapshot, request: request, now: Date()) }
        #expect(try await evaluate(page, "return Number(document.body.dataset.finalClicks||0);") as? Int == 0)
    }

    @Test func atomicFinalComparisonBindsUnscheduledFlagAndAcceptsOnlyUnchangedSyntheticReview() async throws {
        let bridge = UnscheduledBridge()
        let page = WKAppleCheckoutPage(evaluator: { script, arguments in
            guard let current = bridge.page else { throw CheckoutError.unsupportedPage }
            if bridge.invalidateBeforeFinal, script.contains("window.__pickupPilot.submit") {
                bridge.invalidateBeforeFinal = false
                _ = try await current.webView.callAsyncJavaScript("""
                const element=document.getElementById('init_data'),data=JSON.parse(element.textContent);
                data.checkout.review.fulfillmentReview.group.d.pickup.startTime=null;element.textContent=JSON.stringify(data);return true;
                """, in: nil, contentWorld: .page)
            }
            return try await current.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        })
        bridge.page = page
        defer { page.clearPage() }
        let data = review(["storeNumber": "R121"])
        try await fixture(page, data: data, controls: reviewControls)
        let snapshot = try await page.snapshot(), approved = try CheckoutPagePolicy.review(from: snapshot, request: request, now: Date())
        bridge.invalidateBeforeFinal = true
        #expect(try await page.placeOrder(expected: snapshot, request: request, review: approved) == false)
        #expect(try await evaluate(page, "return Number(document.body.dataset.finalClicks||0);") as? Int == 0)
        // A new local document and newly validated review can click this synthetic control once.
        try await fixture(page, data: data, controls: reviewControls)
        let fresh = try await page.snapshot(), newApproval = try CheckoutPagePolicy.review(from: fresh, request: request, now: Date())
        #expect(try await page.placeOrder(expected: fresh, request: request, review: newApproval))
        #expect(try await evaluate(page, "return Number(document.body.dataset.finalClicks||0);") as? Int == 1)
        #expect(try await page.placeOrder(expected: fresh, request: request, review: newApproval) == false)
    }
}
