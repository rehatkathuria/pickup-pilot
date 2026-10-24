import Foundation
import Testing
import WebKit
@testable import PickupPilot
@testable import PilotCore

/// Local HTML and instrumented native APIs only: no remote resources or real order submission.
@Suite(.serialized) @MainActor struct CheckoutGuardTests {
    private let sourceURL = "https://www.apple.com/ca/shop/checkout"

    private var nativeFormProbe: String {
        """
        window.__guardProbe={nativeSubmitCalls:0,nativeRequestSubmitCalls:0};
        const fixtureSubmit=HTMLFormElement.prototype.submit;
        HTMLFormElement.prototype.submit=function(...args){
          window.__guardProbe.nativeSubmitCalls++;return fixtureSubmit.apply(this,args);
        };
        const fixtureRequestSubmit=HTMLFormElement.prototype.requestSubmit;
        HTMLFormElement.prototype.requestSubmit=function(...args){
          window.__guardProbe.nativeRequestSubmitCalls++;return fixtureRequestSubmit.apply(this,args);
        };
        """
    }

    private func reviewHTML(onClick: String = "") -> String {
        let formatter = ISO8601DateFormatter()
        let start = Date().addingTimeInterval(86400)
        let startISO = formatter.string(from: start), endISO = formatter.string(from: start.addingTimeInterval(900))
        return """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; form-action about:; frame-src about:">
        </head><body>
        <script type="application/json" id="metrics">{"data":{"properties":{"currencyCode":"CAD"}}}</script>
        <script type="application/json" id="init_data">{"checkout":{"review":{"billingReview":{"d":{"paymentLabel":"Synthetic Payment A"}},"fulfillmentReview":{"group":{"d":{"pickup":{"storeNumber":"R121","startTime":"\(startISO)","endTime":"\(endISO)","timeslot":"Synthetic 15 minute slot"}},"items":{"phone":{"d":{"productId":"TEST-CA/A","quantity":1}}}}}}}}</script>
        <section class="rs-review-billing"><p class="rs-review-cardnumber">Synthetic Payment A</p></section>
        <span data-autom="orderTotalValue">CA$3,388.87</span>
        <iframe name="synthetic-order-target" src="about:blank" hidden></iframe>
        <form id="synthetic-order" action="about:blank" target="synthetic-order-target"
          onsubmit="event.preventDefault();document.body.dataset.submissions=String(Number(document.body.dataset.submissions||0)+1)">
          <input id="synthetic-entry" aria-label="Synthetic checkout field">
          <button type="submit" data-autom="continue-button-placeOrder"
            onclick="document.body.dataset.finalClicks=String(Number(document.body.dataset.finalClicks||0)+1);\(onClick)">Synthetic Place Order</button>
        </form>
        <script>
          document.getElementById('synthetic-entry').addEventListener('keydown',()=>{
            document.body.dataset.keyEvents=String(Number(document.body.dataset.keyEvents||0)+1);
          });
        </script>
        </body></html>
        """
    }

    private func fixture(_ page: WKAppleCheckoutPage, html: String, url: String? = nil, beforeBootstrap: String = "") async throws {
        let controller = page.webView.configuration.userContentController
        // Copy values before changing the controller: its bridged script array is live.
        let productionScripts = controller.userScripts.map {
            (source: $0.source, injectionTime: $0.injectionTime, mainFrameOnly: $0.isForMainFrameOnly)
        }
        controller.removeAllUserScripts()
        if !beforeBootstrap.isEmpty {
            controller.addUserScript(WKUserScript(source: beforeBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // Reinstall equivalent fresh instances; removed WebKit script identities cannot be reused.
        for script in productionScripts {
            controller.addUserScript(WKUserScript(source: script.source, injectionTime: script.injectionTime,
                                                  forMainFrameOnly: script.mainFrameOnly))
        }
        page.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let marker = UUID().uuidString
        page.webView.loadHTMLString(html + "<script>document.documentElement.dataset.guardFixture='\(marker)'</script>", baseURL: URL(string: url ?? sourceURL)!)
        var ready = false
        for _ in 0..<150 {
            let value = try? await evaluate(page, "return document.documentElement.dataset.guardFixture||'';")
            if value as? String == marker, !page.webView.isLoading { ready = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready)
        #expect(try await evaluate(page, "return typeof window.__pickupPilot==='object';") as? Bool == true)
    }

    private func evaluate(_ page: WKAppleCheckoutPage, _ script: String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }

    private func request(at now: Date = Date(), attemptWindow: DateWindow? = nil, attemptHours: DailyWindow = DailyWindow()) -> CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "TEST-CA/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky",
                                               productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!),
                        store: RetailStore(id: "R121", name: "Synthetic store"), market: .ca, maximumTotal: 4000,
                        timeZoneIdentifier: "UTC", attemptWindow: attemptWindow ?? DateWindow(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(300)),
                        attemptHours: attemptHours)
    }

    @Test func deferredFetchCaptureReturnsResponseImmediatelyButCannotExposeAStaleReview() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: """
        window.__syntheticResponseReturned=false;
        window.fetch=async()=>{
          const response=new Response('{}',{status:200,headers:{'content-type':'application/json'}});
          Object.defineProperty(response,'url',{value:'https://www.apple.com/ca/shop/checkout'});
          response.clone=()=>({json:()=>new Promise(resolve=>{window.__resolveSyntheticCapture=resolve;})});
          return response;
        };
        """)
        let original = try await page.snapshot()
        let request = request()
        let review = try CheckoutPagePolicy.review(from: original, request: request, now: Date())
        let returned = try await evaluate(page, """
        const response=await window.fetch('/ca/shop/checkout');
        window.__syntheticResponseReturned=true;
        return response.status===200&&typeof window.__resolveSyntheticCapture==='function';
        """)
        #expect(returned as? Bool == true) // Apple's consumer never waits for our clone JSON.
        let pending = try await page.snapshot()
        #expect(pending.phase == .loading)
        #expect(try await page.placeOrder(expected: original, request: request, review: review) == false)
        let ready = Task { try await page.waitForChange(after: pending, timeout: 1) }
        _ = try await evaluate(page, """
        const captured=JSON.parse(document.getElementById('init_data').textContent);
        captured.checkout.review.fulfillmentReview.group.items.phone.d.quantity=2;
        window.__resolveSyntheticCapture(captured);return true;
        """)
        #expect(try await ready.value)
        let updated = try await page.snapshot()
        #expect(updated.phase == .review && updated.quantities == [2])
        #expect(try await page.placeOrder(expected: original, request: request, review: review) == false)
        #expect(try await evaluate(page, "return Number(document.body.dataset.finalClicks||0);") as? Int == 0)
    }

    @Test func forwardActionCannotRepeatOnIncidentalDOMChangesOrReplacementControls() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let html = """
        <html><head><script type='application/json' id='init_data'>
        {"shoppingCart":{"items":{"phone":{"d":{"productId":"TEST-CA/A","quantity":1}}}}}
        </script></head><body>
        <button data-autom='bag-checkout-button' onclick="window.__syntheticForwards=(window.__syntheticForwards||0)+1;this.replaceWith(this.cloneNode(true));document.body.append(document.createElement('span'))">Synthetic Checkout</button>
        </body></html>
        """
        try await fixture(page, html: html, url: "https://www.apple.com/ca/shop/bag")
        #expect(try await page.advance(request: request(), profile: SecureProfile()))
        #expect(try await page.snapshot().phase == .bag)
        for _ in 0..<5 {
            _ = try await evaluate(page, "document.body.append(document.createElement('span'));return true;")
            #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        }
        #expect(try await evaluate(page, "return window.__syntheticForwards;") as? Int == 1)
        // Even a supported phase transition and a later same-phase replacement do not
        // grant a second click to a previously dispatched workflow identity.
        _ = try await evaluate(page, "document.body.innerHTML='<section class=rs-pickup-contact-details>Synthetic contact</section>';return true;")
        #expect(try await page.snapshot().phase == .contact)
        _ = try await evaluate(page, """
        document.body.innerHTML='<button data-autom="bag-checkout-button" onclick="window.__syntheticForwards++">Synthetic replacement</button>';
        return true;
        """)
        #expect(try await page.snapshot().phase == .bag)
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        #expect(try await evaluate(page, "return window.__syntheticForwards;") as? Int == 1)
        try await fixture(page, html: html, url: "https://www.apple.com/ca/shop/bag")
        #expect(try await page.advance(request: request(), profile: SecureProfile())) // New document, fresh validated bag.
    }

    @Test func deferredModelsKeepResponseArrivalOrderWhenClonesFinishOutOfOrder() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: """
        window.__syntheticCaptures=[];
        window.fetch=async()=>{
          const response=new Response('{}',{status:200,headers:{'content-type':'application/json'}});
          Object.defineProperty(response,'url',{value:'https://www.apple.com/ca/shop/checkout'});
          response.clone=()=>({json:()=>new Promise(resolve=>window.__syntheticCaptures.push(resolve))});
          return response;
        };
        """)
        _ = try await evaluate(page, "await window.fetch('/ca/shop/checkout?synthetic=older');await window.fetch('/ca/shop/checkout?synthetic=newer');return true;")
        #expect(try await page.snapshot().phase == .loading)
        _ = try await evaluate(page, """
        const newest=JSON.parse(document.getElementById('init_data').textContent);
        newest.checkout.review.fulfillmentReview.group.items.phone.d.quantity=3;
        window.__syntheticCaptures[1](newest);
        await new Promise(resolve=>setTimeout(resolve,10));return true;
        """)
        let stillPending = try await page.snapshot()
        #expect(stillPending.phase == .loading) // The older clone still has to settle.
        let complete = Task { try await page.waitForChange(after: stillPending, timeout: 1) }
        _ = try await evaluate(page, """
        const oldest=JSON.parse(document.getElementById('init_data').textContent);
        oldest.checkout.review.fulfillmentReview.group.items.phone.d.quantity=2;
        window.__syntheticCaptures[0](oldest);return true;
        """)
        #expect(try await complete.value)
        let latest = try await page.snapshot()
        #expect(latest.phase == .review && latest.quantities == [3]) // Latest response, not latest clone completion.
    }

    @Test func initialModelCacheReparsesOnlyWhenItsExactTextChanges() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: """
        window.__syntheticInitParses=0;
        const parse=JSON.parse;
        JSON.parse=function(text,...args){
          if(text===document.getElementById('init_data')?.textContent)window.__syntheticInitParses++;
          return parse.call(this,text,...args);
        };
        """)
        for _ in 0..<5 { #expect(try await page.snapshot().quantities == [1]) }
        #expect(try await evaluate(page, "return window.__syntheticInitParses;") as? Int == 1)
        _ = try await evaluate(page, "document.getElementById('init_data').textContent='{}';return true;")
        #expect(try await page.snapshot().quantities.isEmpty == true)
        #expect(try await evaluate(page, "return window.__syntheticInitParses;") as? Int == 2)
        _ = try await evaluate(page, "document.getElementById('init_data').textContent='{malformed';return true;")
        #expect(try await page.snapshot().quantities.isEmpty == true)
        #expect(try await page.snapshot().quantities.isEmpty == true)
        #expect(try await evaluate(page, "return window.__syntheticInitParses;") as? Int == 3)
    }

    @Test func unresolvedCheckoutFetchCannotRepeatAfterThreeSecondsOrExplicitAcknowledgement() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let html = """
        <html><head><script type='application/json' id='init_data'>
        {"shoppingCart":{"items":{"phone":{"d":{"productId":"TEST-CA/A","quantity":1}}}}}
        </script></head><body>
        <button data-autom='bag-checkout-button' onclick="window.__syntheticForwards=(window.__syntheticForwards||0)+1;window.__consumer=fetch(new Request('https://www.apple.com/ca/shop/checkout')).catch(()=>null)">Synthetic Checkout</button>
        </body></html>
        """
        try await fixture(page, html: html, url: "https://www.apple.com/ca/shop/bag", beforeBootstrap: """
        window.__pendingSyntheticFetch=[];
        window.fetch=()=>new Promise((resolve,reject)=>window.__pendingSyntheticFetch.push({resolve,reject}));
        """)
        #expect(try await page.advance(request: request(), profile: SecureProfile()))
        try await Task.sleep(for: .milliseconds(3_050)) // Deliberately exceeds the driver's ordinary no-progress handoff.
        #expect(try await page.snapshot().phase == .loading)
        await #expect(throws: CheckoutError.manualInputRequired) { try await page.acknowledgeManualInput(market: .ca) }
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false)
        #expect(try await evaluate(page, "return window.__syntheticForwards;") as? Int == 1)
        _ = try await evaluate(page, """
        const response=new Response(document.getElementById('init_data').textContent,{status:200,headers:{'content-type':'application/json'}});
        Object.defineProperty(response,'url',{value:'https://www.apple.com/ca/shop/checkout'});
        window.__pendingSyntheticFetch[0].resolve(response);
        await window.__consumer;await new Promise(resolve=>setTimeout(resolve,0));return true;
        """)
        #expect(try await page.snapshot().phase == .bag)
        #expect(try await page.advance(request: request(), profile: SecureProfile()) == false) // Settling is not another grant.
        try await page.acknowledgeManualInput(market: .ca)
        #expect(try await page.advance(request: request(), profile: SecureProfile()))
        #expect(try await evaluate(page, "return window.__syntheticForwards;") as? Int == 2)
        _ = try await evaluate(page, "window.__pendingSyntheticFetch[1].reject(new Error('synthetic failure'));await window.__consumer;return true;")
        #expect(try await page.snapshot().phase == .bag) // Rejection cleans the pending latch.
        try await page.acknowledgeManualInput(market: .ca)
        #expect(try await page.advance(request: request(), profile: SecureProfile()))
        _ = try await evaluate(page, """
        const malformed=new Response('{malformed',{status:200,headers:{'content-type':'application/json'}});
        Object.defineProperty(malformed,'url',{value:'https://www.apple.com/ca/shop/checkout'});
        window.__pendingSyntheticFetch[2].resolve(malformed);
        await window.__consumer;await new Promise(resolve=>setTimeout(resolve,0));return true;
        """)
        #expect(try await page.snapshot().phase == .bag) // Failed clone parsing also cleans both counters.
    }

    @Test func requestClassificationAndFetchFailureNeverLeaveAnUnrelatedPendingLatch() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: """
        window.fetch=()=>new Promise((resolve,reject)=>{window.__rejectSyntheticFetch=reject;});
        """)
        for input in ["'/ca/shop/checkout'", "new URL('https://secure6.store.apple.com/ca/shop/checkout')", "new Request('https://www.apple.com/ca/shop/checkout')"] {
            _ = try await evaluate(page, "window.__consumer=window.fetch(\(input)).catch(()=>null);return true;")
            #expect(try await page.snapshot().phase == .loading)
            _ = try await evaluate(page, "window.__rejectSyntheticFetch(new Error('synthetic unavailable'));await window.__consumer;return true;")
            #expect(try await page.snapshot().phase == .review)
        }
        for input in ["'https://synthetic-bank.example.invalid/shop/checkout'", "'https://evilapple.com/shop/checkout'", "'http://www.apple.com/ca/shop/checkout'", "'https://www.apple.com/assets/synthetic.json'"] {
            _ = try await evaluate(page, "window.__consumer=window.fetch(\(input)).catch(()=>null);return true;")
            #expect(try await page.snapshot().phase == .review)
            _ = try await evaluate(page, "window.__rejectSyntheticFetch(new Error('synthetic unavailable'));await window.__consumer;return true;")
            #expect(try await page.snapshot().phase == .review)
        }
        #expect(try await page.placeOrder(expected: page.snapshot()) == false)
    }

    @Test func xhrPendingLatchEndsOnLoadAbortFailureOrSynchronousSendError() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: """
        XMLHttpRequest.prototype.open=function(){};
        XMLHttpRequest.prototype.send=function(){if(window.__throwSyntheticSend)throw new Error('synthetic send failure');};
        """)
        for ending in ["load", "abort", "error", "timeout"] {
            _ = try await evaluate(page, "window.__syntheticXHR=new XMLHttpRequest();window.__syntheticXHR.open('POST','/ca/shop/checkout');window.__syntheticXHR.send();return true;")
            #expect(try await page.snapshot().phase == .loading)
            _ = try await evaluate(page, """
            const xhr=window.__syntheticXHR;
            Object.defineProperty(xhr,'responseURL',{value:'https://www.apple.com/ca/shop/checkout'});
            Object.defineProperty(xhr,'status',{value:200});Object.defineProperty(xhr,'responseText',{value:'{}'});
            xhr.dispatchEvent(new Event('\(ending)'));xhr.dispatchEvent(new Event('loadend'));return true;
            """)
            #expect(try await page.snapshot().phase == .review)
        }
        _ = try await evaluate(page, """
        window.__throwSyntheticSend=true;
        const xhr=new XMLHttpRequest();xhr.open('POST',new URL('https://www.apple.com/ca/shop/checkout'));
        try{xhr.send();}catch(_){}return true;
        """)
        #expect(try await page.snapshot().phase == .review)
        _ = try await evaluate(page, """
        window.__throwSyntheticSend=false;
        const xhr=new XMLHttpRequest();xhr.open('POST','https://synthetic-bank.example.invalid/shop/checkout');xhr.send();
        window.__syntheticForeignXHR=xhr;return true;
        """)
        #expect(try await page.snapshot().phase == .review)
        _ = try await evaluate(page, "window.__syntheticForeignXHR.dispatchEvent(new Event('loadend'));return true;")
        #expect(try await page.snapshot().phase == .review)
    }

    @Test func unissuedFinalEventsAndNativeFormCallsAreBlocked() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: nativeFormProbe)
        let originalReview = try await page.snapshot()
        #expect(originalReview.phase == .review)
        let observed = try #require(try await evaluate(page, """
        const form=document.getElementById('synthetic-order'),field=document.getElementById('synthetic-entry');
        const button=form.querySelector('button');
        button.click();
        const enter=new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true});
        const space=new KeyboardEvent('keydown',{key:' ',bubbles:true,cancelable:true});
        field.dispatchEvent(enter);button.dispatchEvent(space);
        const submit=new Event('submit',{bubbles:true,cancelable:true});form.dispatchEvent(submit);
        HTMLFormElement.prototype.submit.call(form);HTMLFormElement.prototype.requestSubmit.call(form,button);
        return {enterBlocked:enter.defaultPrevented,spaceBlocked:space.defaultPrevented,submitBlocked:submit.defaultPrevented,
          clicks:Number(document.body.dataset.finalClicks||0),submissions:Number(document.body.dataset.submissions||0),
          keys:Number(document.body.dataset.keyEvents||0),...window.__guardProbe};
        """) as? [String: Any])
        #expect(observed["enterBlocked"] as? Bool == true)
        #expect(observed["spaceBlocked"] as? Bool == true)
        #expect(observed["submitBlocked"] as? Bool == true)
        for key in ["clicks", "submissions", "keys", "nativeSubmitCalls", "nativeRequestSubmitCalls"] {
            #expect(observed[key] as? Int == 0)
        }
    }

    @Test func reviewOnlyModeRejectsNativeAndJavaScriptSubmissionWithImmutableFlag() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: nativeFormProbe)
        let snapshot = try await page.snapshot()
        #expect(snapshot.phase == .review)
        #expect(try await page.placeOrder(expected: snapshot) == false)
        let request = request()
        let review = try CheckoutPagePolicy.review(from: snapshot, request: request, now: Date())
        #expect(try await page.placeOrder(expected: snapshot, request: request, review: review) == false)
        let observed = try #require(try await evaluate(page, """
        const descriptor=Object.getOwnPropertyDescriptor(window,'__pickupPilotReviewOnly');
        let redefineBlocked=false;
        try{Object.defineProperty(window,'__pickupPilotReviewOnly',{value:false});}catch(_){redefineBlocked=true;}
        window.__pickupPilotReviewOnly=false;
        const submitted=window.__pickupPilot.submit(window.__pickupPilot.snapshot());
        const now=Date.now(),authorization={attemptStart:now-60000,attemptEnd:now+300000,startMinute:0,endMinute:1439,
          timeZone:'UTC',reviewExpiresAt:now+300000};
        const authorizedSubmitted=window.__pickupPilot.submit(window.__pickupPilot.snapshot(),authorization);
        document.querySelector('[data-autom="continue-button-placeOrder"]').click();
        return {submitted,authorizedSubmitted,flag:window.__pickupPilotReviewOnly,redefineBlocked,writable:descriptor.writable,
          configurable:descriptor.configurable,clicks:Number(document.body.dataset.finalClicks||0),
          submissions:Number(document.body.dataset.submissions||0),...window.__guardProbe};
        """) as? [String: Any])
        #expect(observed["submitted"] as? Bool == false)
        #expect(observed["authorizedSubmitted"] as? Bool == false)
        #expect(observed["flag"] as? Bool == true)
        #expect(observed["redefineBlocked"] as? Bool == true)
        #expect(observed["writable"] as? Bool == false)
        #expect(observed["configurable"] as? Bool == false)
        for key in ["clicks", "submissions", "nativeSubmitCalls", "nativeRequestSubmitCalls"] {
            #expect(observed[key] as? Int == 0)
        }
    }

    @Test(arguments: [false, true]) func authorizedFinalClickAllowsOnlyOneSynchronousFormSubmission(nativeSubmitFirst: Bool) async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        // The handler attempts every submission API, followed by the button's native default action.
        let attempts = nativeSubmitFirst ? "this.form.submit();this.form.submit();this.form.requestSubmit();"
                                        : "this.form.requestSubmit();this.form.requestSubmit();this.form.submit();"
        try await fixture(page, html: reviewHTML(onClick: attempts), beforeBootstrap: nativeFormProbe)
        let snapshot = try await page.snapshot()
        let request = request()
        let review = try CheckoutPagePolicy.review(from: snapshot, request: request, now: Date())
        #expect(try await page.placeOrder(expected: snapshot, request: request, review: review))
        #expect(try await page.placeOrder(expected: snapshot, request: request, review: review) == false)
        let observed = try #require(try await evaluate(page, """
        const form=document.getElementById('synthetic-order');
        form.submit();form.requestSubmit();
        const second=window.__pickupPilot.submit(window.__pickupPilot.snapshot());
        return {second,clicks:Number(document.body.dataset.finalClicks||0),submissions:Number(document.body.dataset.submissions||0),...window.__guardProbe};
        """) as? [String: Any])
        #expect(observed["second"] as? Bool == false)
        #expect(observed["clicks"] as? Int == 1)
        #expect(observed["submissions"] as? Int == (nativeSubmitFirst ? 0 : 1))
        #expect(observed["nativeRequestSubmitCalls"] as? Int == (nativeSubmitFirst ? 0 : 1))
        #expect(observed["nativeSubmitCalls"] as? Int == (nativeSubmitFirst ? 1 : 0))
    }

    @Test func snapshotsRemoveSessionQueryAndFragmentInBothBridges() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), url: sourceURL + "?session=synthetic-private-session#synthetic-private-fragment")
        let native = try await page.snapshot()
        let script = try #require(try await evaluate(page, "return window.__pickupPilot.snapshot();") as? [String: Any])
        #expect(native.sourceURL == sourceURL)
        #expect(script["sourceURL"] as? String == sourceURL)
        let encoded = String(decoding: try JSONEncoder().encode(native), as: UTF8.self)
        #expect(!encoded.contains("synthetic-private"))
    }

    @Test func finalBrowserTurnRejectsClosedAttemptWindowAndExpiredReview() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: nativeFormProbe)
        let snapshot = try await page.snapshot()
        let now = Date(), permitted = request()
        let review = try CheckoutPagePolicy.review(from: snapshot, request: permitted, now: now)
        let later = request(attemptWindow: DateWindow(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200)))
        #expect(try await page.placeOrder(expected: snapshot, request: later, review: review) == false)
        let earlier = request(attemptWindow: DateWindow(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600)))
        #expect(try await page.placeOrder(expected: snapshot, request: earlier, review: review) == false)
        let expired = CheckoutReview(variantID: review.variantID, storeID: review.storeID, quantity: review.quantity,
                                     total: review.total, currencyCode: review.currencyCode, pickupDate: review.pickupDate,
                                     pickupEndDate: review.pickupEndDate, pickupSlot: review.pickupSlot,
                                     expiresAt: now.addingTimeInterval(-60), sourceURL: review.sourceURL, documentID: review.documentID, reviewStateID: review.reviewStateID)
        #expect(try await page.placeOrder(expected: snapshot, request: permitted, review: expired) == false)
        #expect(try await evaluate(page, "return Number(document.body.dataset.finalClicks||0);") as? Int == 0)
        #expect(try await evaluate(page, "return Number(document.body.dataset.submissions||0);") as? Int == 0)
        // Rejections must not consume the single authorized submission for a still-valid review.
        #expect(try await page.placeOrder(expected: snapshot, request: permitted, review: review))
        #expect(try await evaluate(page, "return Number(document.body.dataset.finalClicks||0);") as? Int == 1)
        #expect(try await evaluate(page, "return Number(document.body.dataset.submissions||0);") as? Int == 1)
    }

    @Test func browserAuthorizationRejectsMissingAndMalformedTimingLimits() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML(), beforeBootstrap: nativeFormProbe)
        let observed = try #require(try await evaluate(page, """
        const snapshot=window.__pickupPilot.snapshot(),now=Date.now();
        const valid={attemptStart:now-60000,attemptEnd:now+300000,startMinute:0,endMinute:1439,
          timeZone:'UTC',reviewExpiresAt:now+300000};
        const minute=(new Date(now).getUTCHours()*60+new Date(now).getUTCMinutes()+60)%1440;
        const invalid=[undefined,null,{},
          {...valid,reviewExpiresAt:now-60000},{...valid,attemptStart:now+60000},
          {...valid,attemptEnd:now-60000},{...valid,startMinute:minute,endMinute:minute},
          {...valid,startMinute:-1},{...valid,endMinute:1440},{...valid,timeZone:'Synthetic/Invalid'},
          {...valid,reviewExpiresAt:'future'},{...valid,attemptStart:NaN}];
        const rejected=invalid.map(authorization=>window.__pickupPilot.submit(snapshot,authorization));
        return {rejected,clicks:Number(document.body.dataset.finalClicks||0),submissions:Number(document.body.dataset.submissions||0)};
        """) as? [String: Any])
        let rejected = try #require(observed["rejected"] as? [Bool])
        #expect(rejected.count == 12 && rejected.allSatisfy { !$0 })
        #expect(observed["clicks"] as? Int == 0)
        #expect(observed["submissions"] as? Int == 0)
    }

    @Test func malformedCalendarEvidenceNeverNormalizesIntoAnotherPickupDate() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        try await fixture(page, html: reviewHTML())
        let observed = try #require(try await evaluate(page, """
        const element=document.getElementById('init_data'),model=JSON.parse(element.textContent);
        const invalid=['2026-02-30T14:00:00Z','2026-02-29T14:00:00Z','2100-02-29T14:00:00Z',
          '2026-04-31T14:00:00Z','2026-10-24T24:00:00Z','2026-10-24T14:00:00ZgarbageZ'];
        return invalid.map(raw=>{
          model.checkout.review.fulfillmentReview.group.d.pickup.startTime=raw;
          element.textContent=JSON.stringify(model);return window.__pickupPilot.snapshot().pickupStartISO;
        });
        """) as? [Any])
        #expect(observed.count == 6 && observed.allSatisfy { $0 is NSNull })
        let snapshot = try await page.snapshot()
        #expect(snapshot.phase == .review && snapshot.pickupStartISO == nil)
        #expect(throws: CheckoutError.unsafeReview) {
            try CheckoutPagePolicy.review(from: snapshot, request: request(), now: Date())
        }
    }

    @Test func blockedFetchIsObservedWithoutChangingResponseOrSendingNetworkTraffic() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        let mock = """
        window.__fixtureFetchCalls=0;
        window.fetch=async function(){
          window.__fixtureFetchCalls++;
          const response=new Response('synthetic-blocked-body',{status:541,headers:{'content-type':'text/plain','x-synthetic-fixture':'unchanged'}});
          Object.defineProperty(response,'url',{value:'https://www.apple.com/ca/shop/checkout'});
          window.__fixtureOriginalResponse=response;return response;
        };
        """
        try await fixture(page, html: reviewHTML(), beforeBootstrap: mock)
        let originalReview = try await page.snapshot()
        #expect(originalReview.phase == .review)
        let observed = try #require(try await evaluate(page, """
        const response=await fetch('/ca/shop/checkout');
        return {same:response===window.__fixtureOriginalResponse,status:response.status,body:await response.text(),
          header:response.headers.get('x-synthetic-fixture'),calls:window.__fixtureFetchCalls};
        """) as? [String: Any])
        #expect(observed["same"] as? Bool == true)
        #expect(observed["status"] as? Int == 541)
        #expect(observed["body"] as? String == "synthetic-blocked-body")
        #expect(observed["header"] as? String == "unchanged")
        #expect(observed["calls"] as? Int == 1)
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.snapshot() }
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.acknowledgeManualInput(market: .ca) }
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.placeOrder(expected: originalReview) }
    }

    @Test func blockedXHRIsObservedWithoutChangingResponseOrSendingNetworkTraffic() async throws {
        let page = WKAppleCheckoutPage()
        defer { page.clearPage() }
        let mock = """
        window.__fixtureXHRCalls=0;
        XMLHttpRequest.prototype.open=function(method,url){this.__fixtureURL=new URL(url,location.href).href;};
        XMLHttpRequest.prototype.send=function(){
          window.__fixtureXHRCalls++;
          Object.defineProperties(this,{status:{value:541},responseURL:{value:this.__fixtureURL},
            responseText:{value:'synthetic-xhr-blocked-body'}});
          this.dispatchEvent(new Event('load'));
        };
        """
        try await fixture(page, html: reviewHTML(), beforeBootstrap: mock)
        #expect(try await page.snapshot().phase == .review)
        let observed = try #require(try await evaluate(page, """
        const xhr=new XMLHttpRequest();let delivered=false;
        xhr.addEventListener('load',()=>{delivered=true;});xhr.open('POST','/ca/shop/checkout');xhr.send();
        return {delivered,status:xhr.status,url:xhr.responseURL,body:xhr.responseText,calls:window.__fixtureXHRCalls};
        """) as? [String: Any])
        #expect(observed["delivered"] as? Bool == true)
        #expect(observed["status"] as? Int == 541)
        #expect(observed["url"] as? String == sourceURL)
        #expect(observed["body"] as? String == "synthetic-xhr-blocked-body")
        #expect(observed["calls"] as? Int == 1)
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.snapshot() }
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.acknowledgeManualInput(market: .ca) }
    }
}
