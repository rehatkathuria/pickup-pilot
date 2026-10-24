import Foundation
import Testing
import WebKit
@testable import PickupPilot
@testable import PilotCore

@MainActor private final class SyntheticNavigationAction: WKNavigationAction {
    private let syntheticRequest: URLRequest
    init(_ url: URL?) {
        var request = URLRequest(url: URL(string: "about:blank")!)
        request.url = url
        syntheticRequest = request
        super.init()
    }
    override var request: URLRequest { syntheticRequest }
}

@MainActor private final class SyntheticCheckoutEvidence {
    var value: CheckoutSnapshot
    init(_ value: CheckoutSnapshot) { self.value = value }
}

@Suite(.serialized) @MainActor struct CheckoutPageEdgeTests {
    private func load(_ page: WKAppleCheckoutPage, origin: String, body: String = "Synthetic browser boundary fixture") async throws {
        let marker = UUID().uuidString
        page.webView.loadHTMLString("<body data-marker='\(marker)'>\(body)</body>", baseURL: URL(string: origin)!)
        var ready = false
        for _ in 0..<100 {
            let value = try? await page.webView.callAsyncJavaScript("return document.body?.dataset.marker || '';", in: nil, contentWorld: .page)
            if value as? String == marker, !page.webView.isLoading { ready = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready)
    }
    private var request: CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "SYNTHETIC/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky", productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                        store: RetailStore(id: "R121", name: "Synthetic"), market: .ca, maximumTotal: 4000)
    }
    @Test func changeWaitTimeoutAndTaskCancellationAreIndependent() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let snapshot = try await page.snapshot()
        let start = ContinuousClock.now
        #expect(try await page.waitForChange(after: snapshot, timeout: 0.025) == false)
        #expect(start.duration(to: .now) >= .milliseconds(20))
        #expect(try await page.waitForChange(after: snapshot, timeout: 0) == false)
        #expect(try await page.waitForChange(after: snapshot, timeout: .nan) == false)
        var cancelledStarted = false, activeStarted = false
        let cancelled = Task { cancelledStarted = true; return try await page.waitForChange(after: snapshot, timeout: 2) }
        let active = Task { activeStarted = true; return try await page.waitForChange(after: snapshot, timeout: 2) }
        for _ in 0..<1_000 { if cancelledStarted && activeStarted { break }; await Task.yield() }
        try #require(cancelledStarted && activeStarted)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        page.webView(page.webView, didFinish: nil)
        #expect(try await active.value)
        // A previously cancelled timer/continuation cannot consume a later wait.
        let current = try await page.snapshot()
        #expect(try await page.waitForChange(after: current, timeout: 0.025) == false)
    }
    @Test func pageCancelFinishesAllWaitsAndLateSignalsCannotResumeThemTwice() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let snapshot = try await page.snapshot()
        var firstStarted = false, secondStarted = false
        let first = Task { firstStarted = true; return try await page.waitForChange(after: snapshot, timeout: 2) }
        let second = Task { secondStarted = true; return try await page.waitForChange(after: snapshot, timeout: 2) }
        for _ in 0..<1_000 { if firstStarted && secondStarted { break }; await Task.yield() }
        try #require(firstStarted && secondStarted)
        page.cancel()
        await #expect(throws: CheckoutError.cancelled) { try await first.value }
        await #expect(throws: CheckoutError.cancelled) { try await second.value }
        page.webView(page.webView, didCommit: nil)
        page.webView(page.webView, didFinish: nil)
        page.webView(page.webView, didFail: nil, withError: CancellationError())
        page.webView(page.webView, didFailProvisionalNavigation: nil, withError: CancellationError())
        #expect(try await page.waitForChange(after: page.snapshot(), timeout: 0.025) == false)
        let preCancelled = Task { try await page.waitForChange(after: snapshot, timeout: 2) }
        preCancelled.cancel()
        await #expect(throws: CancellationError.self) { try await preCancelled.value }
    }
    @Test func mainDocumentDOMHintsWakeBeforeAndAfterWaitRegistration() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page, origin: "https://www.apple.com/ca/shop/checkout", body: "<section id='fixture'>Synthetic state</section>")
        let before = try await page.snapshot()
        _ = try await page.webView.callAsyncJavaScript("""
        document.getElementById('fixture').textContent='Synthetic changed state';
        await new Promise(resolve=>setTimeout(resolve,20));return true;
        """, in: nil, contentWorld: .page)
        #expect(try await page.waitForChange(after: before, timeout: 1))
        let current = try await page.snapshot()
        let wait = Task { try await page.waitForChange(after: current, timeout: 1) }
        _ = try await page.webView.callAsyncJavaScript("""
        for(let i=0;i<100;i++)document.getElementById('fixture').append(document.createElement('span'));
        return true;
        """, in: nil, contentWorld: .page)
        #expect(try await wait.value)
        #expect(try await page.snapshot().phase == .unknown) // A hint is never a checkout authorization.
    }
    @Test func externalAndSubframeHintsDoNotWakeTheMainAppleDocument() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page, origin: "https://synthetic-bank.example.invalid/challenge")
        let snapshot = try await page.snapshot()
        _ = try await page.webView.callAsyncJavaScript("window.webkit.messageHandlers.pickupPilotChanged.postMessage(1);return true;", in: nil, contentWorld: .page)
        #expect(try await page.waitForChange(after: snapshot, timeout: 0.05) == false)
        try await load(page, origin: "https://www.apple.com/ca/shop/checkout", body: "<iframe srcdoc='<body>Synthetic child</body>'></iframe>")
        _ = try await page.webView.callAsyncJavaScript("await new Promise(resolve=>setTimeout(resolve,40));return true;", in: nil, contentWorld: .page)
        let main = try await page.snapshot()
        _ = try await page.webView.callAsyncJavaScript("""
        document.querySelector('iframe').contentWindow.webkit.messageHandlers.pickupPilotChanged.postMessage(1);
        return true;
        """, in: nil, contentWorld: .page)
        #expect(try await page.waitForChange(after: main, timeout: 0.05) == false)
    }
    @Test func contentControllerDoesNotKeepItsCheckoutPageAlive() {
        weak var reference: WKAppleCheckoutPage?
        autoreleasepool {
            let page = WKAppleCheckoutPage(submissionAllowed: false)
            reference = page
            page.cancel()
        }
        #expect(reference == nil)
    }
    @Test func blankAndExternalChallengeOriginsNeverRunProfileInjection() async throws {
        var evaluatorCalls = 0
        let page = WKAppleCheckoutPage(evaluator: { _, _ in evaluatorCalls += 1; return nil })
        let blank = try await page.snapshot()
        #expect(blank.phase == .unknown && blank.sourceURL == "about:blank")
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.advance(request: request, profile: SecureProfile()) }
        try await load(page, origin: "https://synthetic-bank.example.invalid/challenge")
        #expect(try await page.snapshot().phase == .authentication)
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.advance(request: request, profile: SecureProfile()) }
        #expect(evaluatorCalls == 0)
        page.clearPage()
        #expect(!page.webView.configuration.websiteDataStore.isPersistent)
    }
    @Test func malformedJavaScriptResultsFailClosedAndNeverBecomeSuccess() async throws {
        let page = WKAppleCheckoutPage(evaluator: { _, _ in 7 })
        try await load(page, origin: "https://www.apple.com/ca/shop/checkout")
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.snapshot() }
        #expect(try await page.advance(request: request, profile: SecureProfile()) == false)
        #expect(try await page.placeOrder(expected: CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/checkout")) == false)
        let missing = WKAppleCheckoutPage(evaluator: { _, _ in nil })
        try await load(missing, origin: "https://www.apple.com/ca/shop/checkout")
        await #expect(throws: CheckoutError.unsupportedPage) { try await missing.snapshot() }
        page.clearPage(); missing.clearPage()
    }
    @Test func navigationPolicyAllowsHTTPSChallengesAndRejectsUnsafeSchemes() async throws {
        let page = WKAppleCheckoutPage()
        for address in ["https://www.apple.com/ca/shop/bag", "https://synthetic-bank.example.invalid/challenge", "about:blank"] {
            #expect(await page.webView(page.webView, decidePolicyFor: SyntheticNavigationAction(URL(string: address)!)) == .allow)
        }
        for address in ["http://www.apple.com/ca/shop/bag", "javascript:alert(1)", "file:///private/tmp/synthetic.html", "data:text/html,synthetic"] {
            #expect(await page.webView(page.webView, decidePolicyFor: SyntheticNavigationAction(URL(string: address)!)) == .cancel)
        }
        #expect(await page.webView(page.webView, decidePolicyFor: SyntheticNavigationAction(nil)) == .cancel)
        let configuration = WKWebViewConfiguration()
        #expect(page.webView(page.webView, createWebViewWith: configuration, for: SyntheticNavigationAction(nil), windowFeatures: WKWindowFeatures()) == nil)
        #expect(page.webView(page.webView, createWebViewWith: configuration, for: SyntheticNavigationAction(URL(string: "http://example.invalid")!), windowFeatures: WKWindowFeatures()) == nil)
        // A synthetic challenge popup is rerouted into the same private view, then immediately cancelled.
        #expect(page.webView(page.webView, createWebViewWith: configuration, for: SyntheticNavigationAction(URL(string: "https://synthetic-bank.example.invalid/challenge")!), windowFeatures: WKWindowFeatures()) == nil)
        page.cancel()
        // Exercise the real public-page loader without waiting on or mutating any Apple service.
        try await page.load(URL(string: "https://www.apple.com/ca/shop/bag")!)
        page.cancel()
        await #expect(throws: CheckoutError.unsupportedPage) { try await page.load(URL(string: "http://www.apple.com/ca/shop/bag")!) }
    }
    @Test func nativeNavigationReportsLoadingBeforeReadingAnyOldDocument() async throws {
        var evaluatorCalls = 0
        let ready = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/bag", phase: .bag, bagIsEmpty: true)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ready))
        let page = WKAppleCheckoutPage(evaluator: { _, _ in evaluatorCalls += 1; return object })
        page.webView.loadHTMLString("<body>Synthetic loading fixture</body>", baseURL: URL(string: "https://www.apple.com/ca/shop/bag")!)
        #expect(page.webView.isLoading)
        #expect(try await page.snapshot().phase == .loading)
        #expect(evaluatorCalls == 0)
        try await load(page, origin: "https://www.apple.com/ca/shop/bag")
        #expect(try await page.snapshot() == ready)
        #expect(evaluatorCalls == 1)
        page.clearPage()
    }
    @Test func explicitHealthyDocumentAcknowledgementPreservesCurrentBrowserCookies() async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        let cookie=HTTPCookie(properties:[.name:"SyntheticManualRecovery",.value:"synthetic-local-value",.domain:"www.apple.com",.path:"/",.secure:"TRUE"])!
        await page.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let blocked=HTTPURLResponse(url:URL(string:"https://www.apple.com/ca/shop/541")!,statusCode:541,httpVersion:nil,headerFields:nil)!
        page.observeNavigationResponse(blocked,isForMainFrame:true)
        try await load(page,origin:"https://www.apple.com/ca/shop/checkout",body:"<section class='rs-pickup-contact-details'>Synthetic required contact</section>")
        page.observeNavigationResponse(HTTPURLResponse(url:page.webView.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,isForMainFrame:true)
        await #expect(throws:CheckoutError.storefrontBlocked) { try await page.snapshot() }
        try await page.acknowledgeManualRecovery(market:.ca)
        #expect(try await page.snapshot().phase == .contact)
        let cookies=await page.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        #expect(cookies.contains(where:{$0.name==cookie.name && $0.value==cookie.value}))
        #expect(try await page.webView.callAsyncJavaScript("return window.__pickupPilotReviewOnly===true;",in:nil,contentWorld:.page) as? Bool == true)
        _ = try await page.sessionData()
        try await page.acknowledgeManualRecovery(market:.ca)
        // A same-URL new document is not the document the user acknowledged.
        try await load(page,origin:"https://www.apple.com/ca/shop/checkout",body:"<section class='rs-pickup-contact-details'>New synthetic contact document</section>")
        await #expect(throws:CheckoutError.sessionRecoveryNotReady) { try await page.sessionData() }
    }
    @Test func recoveryAllowsWorkingCheckoutPagesAndRejectsAccountChallenges() async throws {
        let page=WKAppleCheckoutPage(submissionAllowed:false)
        defer { page.clearPage() }
        let cases:[(String,String,CheckoutSnapshot.Phase)]=[
            ("buy-iphone/synthetic","<form data-part-number='SYNTHETIC/A'><button data-autom='add-to-cart'>Synthetic Add</button></form>",.product),
            ("bag","<script id='init_data' type='application/json'>{\"shoppingCart\":{\"d\":{\"hasItems\":false},\"items\":{}}}</script>Synthetic empty bag",.bag),
            ("checkout","<button data-autom='fulfillment-continue-button'>Synthetic Pickup</button>",.fulfillment),
            ("checkout","<button data-autom='continue-button-review'>Synthetic Payment</button>",.payment),
            ("checkout","<button data-autom='continue-button-placeOrder'>Synthetic Final Review</button>",.review)]
        for (path,body,phase) in cases {
            try await load(page,origin:"https://www.apple.com/ca/shop/\(path)",body:body)
            try await page.acknowledgeManualRecovery(market:.ca)
            #expect(try await page.snapshot().phase == phase)
        }
        try await load(page,origin:"https://www.apple.com/ca/shop/signIn",body:"<input type='password' value=''>")
        await #expect(throws:CheckoutError.guestCheckoutUnavailable) { try await page.acknowledgeManualRecovery(market:.ca) }
        // A bag URL without cart data is still initializing and cannot acknowledge recovery.
        try await load(page,origin:"https://www.apple.com/ca/shop/bag",body:"Synthetic uninitialized bag")
        await #expect(throws:CheckoutError.sessionRecoveryNotReady) { try await page.acknowledgeManualRecovery(market:.ca) }
    }
    @Test func recoveryRejectsWrongMarketErrorRedirectAndUnhealthyParsedPages() async throws {
        let blocked=HTTPURLResponse(url:URL(string:"https://www.apple.com/ca/shop/541")!,statusCode:541,httpVersion:nil,headerFields:nil)!
        let evidence=SyntheticCheckoutEvidence(CheckoutSnapshot(sourceURL:"https://www.apple.com/ca/shop/checkout",phase:.contact))
        var reads=0
        let page=WKAppleCheckoutPage(submissionAllowed:false,evaluator:{ _,_ in
            reads += 1;return try JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence.value))
        })
        defer { page.clearPage() }
        for origin in ["https://www.apple.com/us/shop/checkout","https://synthetic-bank.example.invalid/challenge","https://www.apple.com/ca/shop/go/404","https://www.apple.com/ca/shop/541"] {
            try await load(page,origin:origin)
            page.observeNavigationResponse(blocked,isForMainFrame:true)
            await #expect(throws:CheckoutError.sessionRecoveryNotReady) { try await page.acknowledgeManualRecovery(market:.ca) }
            #expect(reads == 0)
        }
        try await load(page,origin:"https://www.apple.com/ca/shop/checkout")
        for phase in [CheckoutSnapshot.Phase.blocked,.unknown,.unavailable,.confirmation,.loading] {
            evidence.value.phase=phase
            await #expect(throws:CheckoutError.sessionRecoveryNotReady) { try await page.acknowledgeManualRecovery(market:.ca) }
            await #expect(throws:CheckoutError.storefrontBlocked) { try await page.snapshot() }
        }
        evidence.value.phase = .contact;evidence.value.hasErrors=true
        await #expect(throws:CheckoutError.sessionRecoveryNotReady) { try await page.acknowledgeManualRecovery(market:.ca) }
        evidence.value.hasErrors=false
        try await page.acknowledgeManualRecovery(market:.ca)
        #expect(try await page.snapshot().phase == .contact)
    }
    @Test func recoveryCancellationOrNewResponseCannotClearTheStickyBlock() async throws {
        let evidence=CheckoutSnapshot(sourceURL:"https://www.apple.com/ca/shop/checkout",phase:.contact)
        let raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence))
        let blocked=HTTPURLResponse(url:URL(string:"https://www.apple.com/ca/shop/541")!,statusCode:541,httpVersion:nil,headerFields:nil)!
        var continuation:CheckedContinuation<Void,Never>?
        let page=WKAppleCheckoutPage(evaluator:{ script,_ in
            if script == "return window.__pickupPilot.snapshot();" { return raw }
            await withCheckedContinuation { continuation=$0 };return raw
        })
        defer { page.clearPage() }
        try await load(page,origin:"https://www.apple.com/ca/shop/checkout")
        page.observeNavigationResponse(blocked,isForMainFrame:true)
        let acknowledgement=Task { try await page.acknowledgeManualRecovery(market:.ca) }
        for _ in 0..<1_000 { if continuation != nil { break };await Task.yield() }
        #expect(continuation != nil)
        page.cancel();continuation?.resume();continuation=nil
        await #expect(throws:CheckoutError.cancelled) { try await acknowledgement.value }
        await #expect(throws:CheckoutError.storefrontBlocked) { try await page.snapshot() }
        let changed=Task { try await page.acknowledgeManualRecovery(market:.ca) }
        for _ in 0..<1_000 { if continuation != nil { break };await Task.yield() }
        page.observeNavigationResponse(blocked,isForMainFrame:true)
        continuation?.resume();continuation=nil
        await #expect(throws:CheckoutError.sessionRecoveryNotReady) { try await changed.value }
        await #expect(throws:CheckoutError.storefrontBlocked) { try await page.snapshot() }
    }
}
