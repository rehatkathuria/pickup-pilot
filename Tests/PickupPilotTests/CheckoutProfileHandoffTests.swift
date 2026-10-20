import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

fileprivate enum SyntheticPaymentGap: String, CaseIterable, Sendable {
    case savedCardOnly, opaqueCardFrame, readOnlyCardNumber, unsupportedCountry, duplicateCardNumbers
}

private actor ProfileHandoffVault: SecureVault {
    private var session: Data?
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) { session = data }
    func loadSession() -> Data? { session }
    func deleteSession() { session = nil }
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() { session = nil }
}

/// The real page/bridge runs only local HTML; driver loads cannot reach a service.
@MainActor private final class ProfileHandoffPage: AppleCheckoutPage {
    let native: WKAppleCheckoutPage
    private(set) var loads = 0
    init(_ native: WKAppleCheckoutPage) { self.native = native }
    func load(_ url: URL) { loads += 1 }
    func snapshot() async throws -> CheckoutSnapshot { try await native.snapshot() }
    func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool { try await native.advance(request: request, profile: profile) }
    func acknowledgeManualInput(market: Market) async throws { try await native.acknowledgeManualInput(market: market) }
    func placeOrder(expected: CheckoutSnapshot) -> Bool { false }
    func restoreSession(_ data: Data?) {}
    func sessionData() async throws -> Data { try await native.sessionData() }
    func cancel() { native.cancel() }
}

@Suite(.serialized) @MainActor struct CheckoutProfileHandoffTests {
    private var request: CheckoutRequest {
        CheckoutRequest(variant:ProductVariant(id:"PROFILE-SYNTHETIC-CA/A",name:"Synthetic Duo",storage:"256GB",color:"Night Sky",
                                               productURL:URL(string:"https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                        store:RetailStore(id:"R121",name:"Synthetic Store"),market:.ca,maximumTotal:4_000)
    }
    private var profile: SecureProfile {
        SecureProfile(givenName:"Synthetic",familyName:"Tester",email:"synthetic@example.invalid",phone:"+14165550100",
                      cardholder:"Synthetic Tester",cardNumber:"4111111111111111",expiryMonth:"12",expiryYear:"2099",cvv:"123",
                      billingLine1:"1 Synthetic Street",billingCity:"Toronto",billingRegion:"ON",billingPostalCode:"M5V 3L9",billingCountry:"CA")
    }
    private func fixture(_ page: WKAppleCheckoutPage, body: String, market: Market = .ca) async throws {
        let marker=UUID().uuidString
        let html="""
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; form-action 'none'; frame-src 'none'; connect-src 'none'"></head>
        <body>\(body)<script>document.documentElement.dataset.profileFixture='\(marker)'</script></body></html>
        """
        page.webView.frame=CGRect(x:0,y:0,width:900,height:700)
        page.webView.loadHTMLString(html,baseURL:URL(string:"https://www.apple.com\(market.storefrontPath)/shop/checkout")!)
        for _ in 0..<150 {
            let value=try? await evaluate(page,"return document.documentElement.dataset.profileFixture||'';")
            if value as? String == marker,!page.webView.isLoading { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        Issue.record("Synthetic profile fixture did not load")
    }
    private func evaluate(_ page:WKAppleCheckoutPage,_ script:String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script,in:nil,contentWorld:.page)
    }
    private func paymentHTML(gap:SyntheticPaymentGap?=nil,formatted:Bool=false)->String {
        let billing=["cardholder","street","city","state","postalCode"].map { "<input data-autom='form-field-\($0)'>" }.joined()
        let country=gap == .unsupportedCountry ? "<select data-autom='form-field-country'><option value='US'>United States</option></select>" : "<input data-autom='form-field-country'>"
        let cards:String
        switch gap {
        case .savedCardOnly: cards="<p data-autom='saved-card'>Synthetic saved card ending 4242</p>"
        case .opaqueCardFrame: cards="<iframe sandbox srcdoc='&lt;input data-autom=card-number-input&gt;'></iframe>"
        default:
            let readonly=gap == .readOnlyCardNumber ? "readonly" : ""
            let number=formatted ? "4111-1111-1111-1111" : ""
            let expiry=formatted ? "12 / 2099" : ""
            let cvv=formatted ? "123" : ""
            cards="""
            <input data-autom='card-number-input' value='\(number)' \(readonly)>
            <input data-autom='expiration-input' value='\(expiry)'><input data-autom='security-code-input' value='\(cvv)'>
            """+(gap == .duplicateCardNumbers ? "<input data-autom='card-number-input'>" : "")
        }
        return billing+country+cards+"<button type='button' data-autom='continue-button-review' onclick=\"document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1)\">Synthetic Review</button>"
    }
    private func contactHTML(split: Bool = true, extraFields: String = "") -> String {
        """
        <section class='rs-pickup-contact-details'>
        <input data-autom='form-field-firstName' name='firstName' maxlength='14'>
        <input data-autom='form-field-lastName' name='lastName' maxlength='20'>
        <input data-autom='form-field-emailAddress' name='emailAddress' maxlength='50'>
        \(split ? "<input name='mobilePhoneAreaCode' maxlength='3'>" : "")
        <input data-autom='form-field-mobilePhone' name='mobilePhone' maxlength='\(split ? 7 : 20)'>
        \(extraFields)
        <input type='checkbox' name='isDaytimePhoneSelected'>
        <button type='button' data-autom='continue-button-label' onclick="document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1)">Synthetic Continue</button>
        </section>
        """
    }
    private func request(for market: Market) -> CheckoutRequest {
        let base = request
        let variant = ProductVariant(id:base.variant.id,name:base.variant.name,storage:base.variant.storage,color:base.variant.color,
                                     productURL:URL(string:"https://www.apple.com\(market.storefrontPath)/shop/buy-iphone/iphone-duo/synthetic")!)
        return CheckoutRequest(variant:variant,store:base.store,market:market,maximumTotal:base.maximumTotal)
    }

    @Test func validationErrorRequiresExplicitDriverResumeAfterLocalCorrection() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let html = contactHTML().replacingOccurrences(of:
            "document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1)", with: """
            window.__syntheticContinues=(window.__syntheticContinues||0)+1;
            if(window.__syntheticContinues===1)document.querySelector('[name=firstName]').setAttribute('aria-invalid','true');
            else document.body.innerHTML='<button type=button data-autom=continue-button-review>Synthetic Payment</button>'
            """)
        try await fixture(page, body: html)
        let boundary = ProfileHandoffPage(page)
        let driver = AppleCheckoutDriver(vault: ProfileHandoffVault(), page: boundary, webView: page.webView, sleep: {})
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: profile) }
        let invalid = try await page.snapshot()
        #expect(invalid.phase == .contact && invalid.hasErrors) // Validation never stays hidden behind loading.
        #expect(try await evaluate(page, "return window.__syntheticContinues;") as? Int == 1)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: profile) }
        _ = try await evaluate(page, "document.querySelector('[name=firstName]').removeAttribute('aria-invalid');return true;")
        #expect(try await page.advance(request: request, profile: profile) == false) // DOM correction alone cannot repeat Continue.
        #expect(try await evaluate(page, "return window.__syntheticContinues;") as? Int == 1)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: profile) }
        #expect(try await evaluate(page, "return window.__syntheticContinues;") as? Int == 2)
        #expect(try await page.snapshot().phase == .payment) // Explicit resume progressed to the next required form.
        #expect(boundary.loads == 1 && !driver.requiresPaymentConfirmation)
        driver.cancel()
    }

    @Test func unchangedForwardControlPausesAndOnlyExplicitPreparationCanRetryIt() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let html = contactHTML().replacingOccurrences(of:
            "document.body.dataset.continued=String(Number(document.body.dataset.continued||0)+1)", with: """
            window.__syntheticContinues=(window.__syntheticContinues||0)+1;
            if(window.__syntheticContinues===2)document.body.innerHTML='<button type=button data-autom=continue-button-review>Synthetic Payment</button>'
            """)
        try await fixture(page, body: html)
        let boundary = ProfileHandoffPage(page)
        let driver = AppleCheckoutDriver(vault: ProfileHandoffVault(), page: boundary, webView: page.webView, sleep: {})
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: profile) }
        let unchanged = try await page.snapshot()
        #expect(unchanged.phase == .contact && !unchanged.hasErrors)
        #expect(try await evaluate(page, "return window.__syntheticContinues;") as? Int == 1)
        #expect(try await page.advance(request: request, profile: profile) == false)
        #expect(try await evaluate(page, "return window.__syntheticContinues;") as? Int == 1)
        await #expect(throws: CheckoutError.manualInputRequired) { try await driver.prepare(request: request, profile: profile) }
        #expect(try await evaluate(page, "return window.__syntheticContinues;") as? Int == 2)
        #expect(try await page.snapshot().phase == .payment)
        #expect(boundary.loads == 1 && !driver.requiresPaymentConfirmation)
        driver.cancel()
    }

    @Test(arguments:SyntheticPaymentGap.allCases)
    fileprivate func incompleteOrInaccessiblePaymentNeverAutoContinues(gap:SyntheticPaymentGap) async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        try await fixture(page,body:paymentHTML(gap:gap))
        #expect(try await page.snapshot().phase == .payment)
        for _ in 0..<5 { #expect(try await page.advance(request:request,profile:profile) == false) }
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
    }
    @Test func equivalentCardFormattingIsVerifiedWithoutRepeatedOverwrite() async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        try await fixture(page,body:paymentHTML(formatted:true))
        #expect(try await page.advance(request:request,profile:profile))
        #expect(try await evaluate(page,"return document.querySelector('[data-autom=card-number-input]').value==='4111-1111-1111-1111';") as? Bool == true)
        #expect(try await evaluate(page,"return document.querySelector('[data-autom=expiration-input]').value==='12 / 2099';") as? Bool == true)
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
        #expect(try await page.advance(request:request,profile:profile))
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 1)
    }
    @Test func missingContactFieldsAndEmptyProfileRequireHumanInput() async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        try await fixture(page,body:"""
        <section class='rs-pickup-contact-details'><input data-autom='form-field-firstName'>
        <button type='button' data-autom='continue-button-label' onclick="document.body.dataset.continued='yes'">Synthetic Continue</button></section>
        """)
        #expect(try await page.advance(request:request,profile:profile) == false)
        #expect(try await evaluate(page,"return document.body.dataset.continued||'';") as? String == "")
        try await fixture(page,body:paymentHTML())
        #expect(try await page.advance(request:request,profile:SecureProfile()) == false)
        #expect(try await evaluate(page,"return document.querySelector('[data-autom=expiration-input]').value;") as? String == "")
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
    }
    @Test func northAmericanContactSplitsOnlyExplicitAreaCodeLayouts() async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        for market in [Market.ca,.us] {
            for phone in ["+1 (416) 555-0100","14165550100","4165550100"] {
                var supplied=profile; supplied.phone=phone
                try await fixture(page,body:contactHTML(),market:market)
                #expect(try await page.snapshot().phase == .contact)
                #expect(try await page.advance(request:request(for:market),profile:supplied))
                #expect(try await evaluate(page,"return document.querySelector('[name=mobilePhoneAreaCode]').value==='416'&&document.querySelector('[name=mobilePhone]').value==='5550100';") as? Bool == true)
                #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
                #expect(try await page.advance(request:request(for:market),profile:supplied))
                #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 1)
                #expect(try await evaluate(page,"return document.querySelector('[name=isDaytimePhoneSelected]').checked;") as? Bool == false)
            }
        }
        try await fixture(page,body:contactHTML(split:false))
        #expect(try await page.advance(request:request,profile:profile))
        #expect(try await evaluate(page,"return document.querySelector('[name=mobilePhone]').value==='+14165550100';") as? Bool == true)
        #expect(try await page.advance(request:request,profile:profile))
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 1)
    }
    @Test(arguments:["+44 20 7946 0958","+1416555010","+4165550100","141655501001","4165550100 ext 2","0005550100","4160550100"])
    func unsupportedSplitPhoneNeverGuessesOrContinues(phone:String) async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        var supplied=profile; supplied.phone=phone
        try await fixture(page,body:contactHTML())
        for _ in 0..<2 { #expect(try await page.advance(request:request,profile:supplied) == false) }
        #expect(try await evaluate(page,"return document.querySelector('[name=mobilePhoneAreaCode]').value===''&&document.querySelector('[name=mobilePhone]').value==='';") as? Bool == true)
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
    }
    @Test func splitPhoneRequiresSupportedMarketAndUniqueEditablePair() async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        try await fixture(page,body:contactHTML(),market:.uk)
        #expect(try await page.advance(request:request(for:.uk),profile:profile) == false)
        #expect(try await evaluate(page,"return document.querySelector('[name=mobilePhoneAreaCode]').value===''&&document.querySelector('[name=mobilePhone]').value==='';") as? Bool == true)
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
        for extra in ["<input data-autom='form-field-mobilePhoneAreaCode'>","<input name='mobilePhone'>","<input name='phoneNumber'>"] {
            try await fixture(page,body:contactHTML(extraFields:extra))
            #expect(try await page.advance(request:request,profile:profile) == false)
            #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
        }
        try await fixture(page,body:contactHTML())
        _ = try await evaluate(page,"document.querySelector('[name=mobilePhoneAreaCode]').readOnly=true;return true;")
        #expect(try await page.advance(request:request,profile:profile) == false)
        #expect(try await evaluate(page,"return Number(document.body.dataset.continued||0);") as? Int == 0)
    }
}
