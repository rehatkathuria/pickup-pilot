import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

@MainActor private final class DocumentBindingBridge {
    weak var page: WKAppleCheckoutPage?
    var replaceBeforeSubmission = false
    var replaceDuringSnapshot = false
    var staleSnapshot: CheckoutSnapshot?
    var finalBridgeCalls = 0
    var mutateBeforeSubmission = false
}

private actor DocumentBindingVault: SecureVault {
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

/// Navigation is suppressed so the real driver can only inspect this suite's local document.
@MainActor private final class DocumentBindingDriverPage: AppleCheckoutPage {
    let native: WKAppleCheckoutPage
    init(_ native: WKAppleCheckoutPage) { self.native = native }
    func load(_ url: URL) {}
    func snapshot() async throws -> CheckoutSnapshot { try await native.snapshot() }
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) -> Bool { true }
    func advance(request: CheckoutRequest, profile: SecureProfile) -> Bool { false }
    func placeOrder(expected: CheckoutSnapshot) async throws -> Bool { try await native.placeOrder(expected: expected) }
    func placeOrder(expected: CheckoutSnapshot, request: CheckoutRequest, review: CheckoutReview) async throws -> Bool {
        try await native.placeOrder(expected: expected, request: request, review: review)
    }
    func restoreSession(_ data: Data?) {}
    func sessionData() -> Data { Data() }
    func cancel() { native.cancel() }
}

/// Apple-origin local HTML only. The final control increments a synthetic counter;
/// CSP denies forms, network and frames, and this suite never accesses a real checkout.
@Suite(.serialized) @MainActor struct CheckoutDocumentBindingTests {
    private let sourceURL = "https://secure6.store.apple.com/ca/shop/checkout"
    private let pickupStart = Date().addingTimeInterval(122_400)
    private var request: CheckoutRequest {
        CheckoutRequest(variant:ProductVariant(id:"DOCUMENT-SYNTHETIC-CA/A",name:"Synthetic Duo",storage:"256GB",color:"Night Sky",
                                               productURL:URL(string:"https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                        store:RetailStore(id:"R121",name:"Synthetic Store"),market:.ca,maximumTotal:4_000,timeZoneIdentifier:"UTC")
    }
    private func load(_ page: WKAppleCheckoutPage, paymentLabel: String) async throws {
        let marker=UUID().uuidString,formatter=ISO8601DateFormatter()
        // Fixed within a test run so only the document and the displayed synthetic payment change.
        let start=pickupStart
        let startISO=formatter.string(from:start),endISO=formatter.string(from:start.addingTimeInterval(900))
        let html="""
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; form-action 'none'; connect-src 'none'; frame-src 'none'">
        </head><body data-document-fixture="\(marker)">
        <script id="metrics" type="application/json">{"data":{"properties":{"currencyCode":"CAD"}}}</script>
        <script id="init_data" type="application/json">{"checkout":{"review":{"billingReview":{"d":{"paymentLabel":"\(paymentLabel)","reference":"synthetic-reference"}},"fulfillmentReview":{"group":{"d":{"pickup":{"storeNumber":"R121","startTime":"\(startISO)","endTime":"\(endISO)","timeslot":"Synthetic 15 minute slot"}},"items":{"phone":{"d":{"productId":"DOCUMENT-SYNTHETIC-CA/A","quantity":1}}}}}}}}</script>
        <section class="rs-review-billing"><p class="rs-review-cardnumber" data-synthetic-payment>\(paymentLabel)</p></section><span data-autom="orderTotalValue">CA$3,388.87</span>
        <button type="button" data-autom="continue-button-placeOrder" onclick="document.body.dataset.syntheticClicks=String(Number(document.body.dataset.syntheticClicks||0)+1)">Synthetic Final Control</button>
        </body></html>
        """
        page.webView.frame=CGRect(x:0,y:0,width:900,height:700)
        page.webView.loadHTMLString(html,baseURL:URL(string:sourceURL)!)
        for _ in 0..<150 {
            let current=try? await page.webView.callAsyncJavaScript("return document.body?.dataset.documentFixture||'';",in:nil,contentWorld:.page)
            if current as? String == marker,!page.webView.isLoading { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        throw CheckoutError.unsupportedPage
    }
    private func clicks(_ page: WKAppleCheckoutPage) async throws -> Int {
        try await page.webView.callAsyncJavaScript("return Number(document.body.dataset.syntheticClicks||0);",in:nil,contentWorld:.page) as? Int ?? -1
    }
    private func evaluate(_ page: WKAppleCheckoutPage, _ script: String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }
    private func changePayment(_ page: WKAppleCheckoutPage, kind: String) async throws {
        if kind == "dom" {
            _ = try await evaluate(page, "document.querySelector('[data-synthetic-payment]').textContent='Synthetic Payment B';return true;")
        } else {
            _ = try await evaluate(page, """
            const element=document.getElementById('init_data'),data=JSON.parse(element.textContent);
            data.checkout.review.billingReview.d.paymentLabel='Synthetic Payment B';element.textContent=JSON.stringify(data);return true;
            """)
        }
    }

    @Test func sameURLReplacementHasANewIdentityAndRejectsTheEarlierSnapshot() async throws {
        let page=WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page,paymentLabel:"Synthetic Payment A")
        let original=try await page.snapshot()
        #expect(CheckoutPagePolicy.isDocumentID(original.documentID))
        #expect(try await page.snapshot().documentID == original.documentID)
        let approved=try CheckoutPagePolicy.review(from:original,request:request,now:Date())
        try await load(page,paymentLabel:"Synthetic Payment B")
        let replacement=try await page.snapshot()
        #expect(CheckoutPagePolicy.isDocumentID(replacement.documentID) && replacement.documentID != original.documentID)
        var sameValues=replacement;sameValues.documentID=original.documentID;sameValues.reviewStateID=original.reviewStateID
        #expect(sameValues == original) // All formerly compared fields, including the URL, are unchanged.
        #expect(try await page.placeOrder(expected:original,request:request,review:approved) == false)
        #expect(try await clicks(page) == 0)
        // A fresh snapshot cannot be paired with approval from the earlier document either.
        #expect(try await page.placeOrder(expected:replacement,request:request,review:approved) == false)
        #expect(try await clicks(page) == 0)
        let fresh=try CheckoutPagePolicy.review(from:replacement,request:request,now:Date())
        #expect(try await page.placeOrder(expected:replacement,request:request,review:fresh))
        #expect(try await clicks(page) == 1)
    }

    @Test func replacementAfterNativeChecksIsRejectedInsideTheFinalJavaScriptTurn() async throws {
        let bridge=DocumentBindingBridge()
        let page=WKAppleCheckoutPage(evaluator:{ script,arguments in
            guard let current=bridge.page else { throw CheckoutError.unsupportedPage }
            if script.contains("window.__pickupPilot.submit") {
                bridge.finalBridgeCalls += 1
                if bridge.replaceBeforeSubmission {
                    bridge.replaceBeforeSubmission=false
                    try await load(current,paymentLabel:"Synthetic Queued Replacement")
                }
            }
            return try await current.webView.callAsyncJavaScript(script,arguments:arguments,in:nil,contentWorld:.page)
        })
        bridge.page=page
        defer { page.clearPage() }
        try await load(page,paymentLabel:"Synthetic Confirmed Payment")
        let original=try await page.snapshot()
        let approved=try CheckoutPagePolicy.review(from:original,request:request,now:Date())
        bridge.replaceBeforeSubmission=true
        #expect(try await page.placeOrder(expected:original,request:request,review:approved) == false)
        #expect(bridge.finalBridgeCalls == 1 && bridge.replaceBeforeSubmission == false)
        #expect(try await clicks(page) == 0)
        #expect(try await page.snapshot().documentID != original.documentID)
    }

    @Test func sameURLReplacementDuringSnapshotNeverReturnsTheOldReviewEvidence() async throws {
        let bridge=DocumentBindingBridge()
        let page=WKAppleCheckoutPage(evaluator:{ script,arguments in
            guard let current=bridge.page else { throw CheckoutError.unsupportedPage }
            if bridge.replaceDuringSnapshot,script.contains("window.__pickupPilot.snapshot"),let stale=bridge.staleSnapshot {
                bridge.replaceDuringSnapshot=false
                try await load(current,paymentLabel:"Synthetic Replacement While Reading")
                return try JSONSerialization.jsonObject(with:JSONEncoder().encode(stale))
            }
            return try await current.webView.callAsyncJavaScript(script,arguments:arguments,in:nil,contentWorld:.page)
        })
        bridge.page=page
        defer { page.clearPage() }
        try await load(page,paymentLabel:"Synthetic Original")
        bridge.staleSnapshot=try await page.snapshot()
        bridge.replaceDuringSnapshot=true
        #expect(try await page.snapshot().phase == .loading)
        let replacement=try await page.snapshot()
        #expect(replacement.phase == .review && replacement.documentID != bridge.staleSnapshot?.documentID)
        #expect(try await clicks(page) == 0)
    }

    @Test(arguments: ["dom", "model"])
    func sameDocumentBillingChangeRejectsOldApprovalAndAcceptsFreshState(_ kind: String) async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        let original = try await page.snapshot()
        let approved = try CheckoutPagePolicy.review(from: original, request: request, now: Date())
        try await changePayment(page, kind: kind)
        let changed = try await page.snapshot()
        #expect(changed.documentID == original.documentID)
        #expect(CheckoutPagePolicy.isDocumentID(changed.reviewStateID) && changed.reviewStateID != original.reviewStateID)
        var unchangedOrder = changed; unchangedOrder.reviewStateID = original.reviewStateID
        #expect(unchangedOrder == original)
        #expect(try await page.placeOrder(expected: original, request: request, review: approved) == false)
        #expect(try await page.placeOrder(expected: changed, request: request, review: approved) == false)
        #expect(try await clicks(page) == 0)
        let fresh = try CheckoutPagePolicy.review(from: changed, request: request, now: Date())
        #expect(try await page.placeOrder(expected: changed, request: request, review: fresh))
        #expect(try await clicks(page) == 1)
        let serialized = String(decoding: try JSONEncoder().encode(changed), as: UTF8.self)
        #expect(!serialized.contains("Synthetic Payment") && !serialized.contains("synthetic-reference"))
    }

    @Test func queuedSameDocumentBillingChangeIsRejectedInTheFinalJavaScriptTurn() async throws {
        let bridge = DocumentBindingBridge()
        let page = WKAppleCheckoutPage(evaluator: { script, arguments in
            guard let current = bridge.page else { throw CheckoutError.unsupportedPage }
            if script.contains("window.__pickupPilot.submit"), bridge.mutateBeforeSubmission {
                bridge.finalBridgeCalls += 1; bridge.mutateBeforeSubmission = false
                try await changePayment(current, kind: "dom")
            }
            return try await current.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        })
        bridge.page = page
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        let original = try await page.snapshot()
        let approved = try CheckoutPagePolicy.review(from: original, request: request, now: Date())
        bridge.mutateBeforeSubmission = true
        #expect(try await page.placeOrder(expected: original, request: request, review: approved) == false)
        #expect(bridge.finalBridgeCalls == 1 && !bridge.mutateBeforeSubmission)
        #expect(try await page.snapshot().documentID == original.documentID)
        #expect(try await page.snapshot().reviewStateID != original.reviewStateID)
        #expect(try await clicks(page) == 0)
    }

    @Test func realDriverRequiresFreshHumanConfirmationOfChangedNativeBillingState() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        let driver = AppleCheckoutDriver(vault: DocumentBindingVault(), page: DocumentBindingDriverPage(page), webView: page.webView)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: SecureProfile()) }
        let approved = try await driver.prepare(request: request, profile: SecureProfile())
        try await changePayment(page, kind: "dom")
        await #expect(throws: CheckoutError.unsafeReview) { try await driver.submit(review: approved) }
        #expect(try await clicks(page) == 0)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: SecureProfile()) }
        #expect(driver.requiresPaymentConfirmation)
        let fresh = try await driver.prepare(request: request, profile: SecureProfile())
        #expect(fresh.documentID == approved.documentID && fresh.reviewStateID != approved.reviewStateID && fresh.token != approved.token)
        let expected = try await page.snapshot()
        #expect(try await page.placeOrder(expected: expected, request: request, review: fresh))
        #expect(try await clicks(page) == 1)
        driver.cancel()
    }

    @Test func unrelatedHintsSpinnerClassesAndModelKeyOrderKeepTheReviewCapability() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        let original = try await page.snapshot()
        #expect(CheckoutPagePolicy.isDocumentID(original.reviewStateID))
        _ = try await evaluate(page, """
        const section=document.querySelector('.rs-review-billing');section.classList.add('synthetic-decoration');section.setAttribute('aria-busy','true');
        const spinner=document.createElement('span');spinner.className='waitindicator';spinner.textContent='Synthetic transient progress';section.append(spinner);
        const progress=document.createElement('span');progress.setAttribute('role','progressbar');progress.textContent='Synthetic transient percent';section.append(progress);
        const outside=document.createElement('p');outside.textContent='Unrelated synthetic page hint';document.body.append(outside);
        outside.dispatchEvent(new Event('input',{bubbles:true}));
        const element=document.getElementById('init_data'),data=JSON.parse(element.textContent),old=data.checkout.review.billingReview.d;
        data.checkout.review.billingReview={d:{reference:old.reference,paymentLabel:old.paymentLabel}};element.textContent=JSON.stringify(data);
        return true;
        """)
        #expect(try await page.snapshot() == original)
        #expect(try await page.snapshot().reviewStateID == original.reviewStateID)
    }

    @Test func nestedObjectAndArrayBillingStatesCannotShareAnIdentity() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        _ = try await evaluate(page, """
        const element=document.getElementById('init_data'),data=JSON.parse(element.textContent);
        data.checkout.review.billingReview.d.identity={a:1};element.textContent=JSON.stringify(data);return true;
        """)
        let original = try await page.snapshot()
        _ = try await evaluate(page, """
        const element=document.getElementById('init_data'),data=JSON.parse(element.textContent);
        data.checkout.review.billingReview.d.identity=[['a',1]];element.textContent=JSON.stringify(data);return true;
        """)
        let changed = try await page.snapshot()
        #expect(changed.documentID == original.documentID && changed.reviewStateID != original.reviewStateID)
    }

    @Test(arguments: ["selectedText", "selectedLabel", "accessibleLabel"])
    func visibleControlMeaningChangesInvalidateTheReview(_ kind: String) async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        _ = try await evaluate(page, """
        const select=document.createElement('select');select.setAttribute('aria-label','Synthetic Payment A');
        const option=document.createElement('option');option.value='same-reference';option.textContent='Synthetic Payment A';select.append(option);
        document.querySelector('.rs-review-billing').append(select);return true;
        """)
        let original = try await page.snapshot()
        let approved = try CheckoutPagePolicy.review(from: original, request: request, now: Date())
        let mutation: String
        switch kind {
        case "selectedText": mutation = "select.selectedOptions[0].textContent='Synthetic Payment B'"
        case "selectedLabel": mutation = "select.selectedOptions[0].label='Synthetic Payment B'"
        default: mutation = "select.setAttribute('aria-label','Synthetic Payment B')"
        }
        _ = try await evaluate(page, "const select=document.querySelector('.rs-review-billing select');\(mutation);return true;")
        #expect(try await page.snapshot().reviewStateID != original.reviewStateID)
        #expect(try await page.placeOrder(expected: original, request: request, review: approved) == false)
        #expect(try await clicks(page) == 0)
    }

    @Test(arguments: ["aria-checked", "aria-selected", "aria-pressed", "role", "indeterminate"])
    func semanticSelectionChangesCannotKeepAnEarlierReviewCapability(_ kind: String) async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        if kind == "indeterminate" {
            _ = try await evaluate(page, """
            const input=document.createElement('input');input.type='checkbox';input.setAttribute('aria-label','Synthetic choice');
            document.querySelector('.rs-review-billing').append(input);return true;
            """)
        } else {
            let role = kind == "aria-selected" ? "option" : kind == "aria-pressed" ? "button" : "radio"
            let state = kind == "role" ? "aria-checked" : kind
            _ = try await evaluate(page, """
            const section=document.querySelector('.rs-review-billing');
            for(const [label,selected] of [['Synthetic choice A','true'],['Synthetic choice B','false']]){
              const choice=document.createElement('button');choice.type='button';choice.setAttribute('role','\(role)');
              choice.setAttribute('\(state)',selected);choice.textContent=label;section.append(choice);
            }
            return true;
            """)
        }
        let original = try await page.snapshot()
        let approved = try CheckoutPagePolicy.review(from: original, request: request, now: Date())
        let mutation: String
        if kind == "indeterminate" {
            mutation = "document.querySelector('.rs-review-billing input').indeterminate=true;"
        } else if kind == "role" {
            mutation = "document.querySelector('.rs-review-billing button').setAttribute('role','checkbox');"
        } else {
            mutation = "const choices=document.querySelectorAll('.rs-review-billing button');choices[0].setAttribute('\(kind)','false');choices[1].setAttribute('\(kind)','true');"
        }
        _ = try await evaluate(page, mutation + "return true;")
        let changed = try await page.snapshot()
        #expect(changed.documentID == original.documentID && changed.reviewStateID != original.reviewStateID)
        var unchangedOrder = changed; unchangedOrder.reviewStateID = original.reviewStateID
        #expect(unchangedOrder == original)
        #expect(try await page.placeOrder(expected: original, request: request, review: approved) == false)
        #expect(try await clicks(page) == 0)
    }

    @Test(arguments: ["missingDOM", "unknownDOM", "duplicateDOM", "missingModel", "emptyModel", "unknownModel", "opaqueFrame"])
    func missingUnknownOrAmbiguousBillingScopeNeverAuthorizes(_ kind: String) async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await load(page, paymentLabel: "Synthetic Payment A")
        let original = try await page.snapshot()
        let approved = try CheckoutPagePolicy.review(from: original, request: request, now: Date())
        let script: String
        switch kind {
        case "missingDOM": script = "document.querySelector('.rs-review-billing').remove();"
        case "unknownDOM": script = "document.querySelector('.rs-review-billing').className='unknown-billing-layout';"
        case "duplicateDOM": script = "const section=document.querySelector('.rs-review-billing');document.body.append(section.cloneNode(true));"
        case "opaqueFrame": script = "const frame=document.createElement('iframe');document.querySelector('.rs-review-billing').append(frame);"
        default:
            let value = kind == "missingModel" ? "null" : kind == "emptyModel" ? "{}" : "'unknown-model'"
            script = "const element=document.getElementById('init_data'),data=JSON.parse(element.textContent);data.checkout.review.billingReview=\(value);element.textContent=JSON.stringify(data);"
        }
        _ = try await evaluate(page, script + "return true;")
        let unknown = try await page.snapshot()
        #expect(unknown.phase == .review && unknown.reviewStateID == nil)
        #expect(throws: CheckoutError.unsafeReview) { try CheckoutPagePolicy.review(from: unknown, request: request, now: Date()) }
        #expect(try await page.placeOrder(expected: original, request: request, review: approved) == false)
        #expect(try await clicks(page) == 0)
    }
}
