import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

/// Real WebKit runs the production bridge over local HTML. Synthetic transports
/// expose response handling; CSP forbids actual connections and form submission.
@Suite(.serialized) @MainActor struct CheckoutResponseInstrumentationTests {
    private func cart(_ sku: String) -> [String: Any] {
        ["shoppingCart": ["d": ["hasItems": true], "items": ["item": ["d": ["productId": sku, "quantity": 1]]]]]
    }

    private var transports: String {
        """
        window.__instrumentation={status:200,url:'https://www.apple.com/ca/shop/checkout',body:'{}',
          cloneCalls:0,responseReads:0,outcome:'success',returnValue:{synthetic:true}};
        window.fetch=function(...args){
          __instrumentation.fetchReceiver=this;__instrumentation.fetchArguments=args;
          const response=new Response(__instrumentation.body,{status:__instrumentation.status,
            headers:{'content-type':'application/json','x-synthetic-response':'unchanged'}});
          Object.defineProperty(response,'url',{value:__instrumentation.url});
          const clone=response.clone.bind(response);
          response.clone=()=>{__instrumentation.cloneCalls++;return clone();};
          __instrumentation.lastResponse=response;return Promise.resolve(response);
        };
        class SyntheticInstrumentationXHR extends EventTarget {
          open(...args){this.openArguments=args;this.responseURL=__instrumentation.url;return __instrumentation.returnValue;}
          get responseText(){__instrumentation.responseReads++;return __instrumentation.body;}
          send(...args){
            this.sendArguments=args;this.status=__instrumentation.status;this.responseType='';
            if(__instrumentation.outcome==='throw')throw __instrumentation.sendError;
            if(__instrumentation.outcome==='pending')return __instrumentation.returnValue;
            this.settle(__instrumentation.outcome);return __instrumentation.returnValue;
          }
          settle(outcome){
            this.dispatchEvent(new Event(outcome==='success'?'load':outcome));
            this.dispatchEvent(new Event('loadend'));
          }
        }
        window.XMLHttpRequest=SyntheticInstrumentationXHR;
        """
    }

    private func evaluate(_ page: WKAppleCheckoutPage, _ script: String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }

    private func fixture(_ page: WKAppleCheckoutPage) async throws {
        let controller = page.webView.configuration.userContentController
        let scripts = controller.userScripts.map { (source: $0.source, time: $0.injectionTime, main: $0.isForMainFrameOnly) }
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: transports, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for script in scripts {
            controller.addUserScript(WKUserScript(source: script.source, injectionTime: script.time, forMainFrameOnly: script.main))
        }
        let marker = UUID().uuidString
        let initial = String(decoding: try JSONSerialization.data(withJSONObject: cart("INITIAL-SYNTHETIC/A")), as: UTF8.self)
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'none'">
        <script id='init_data' type='application/json'>\(initial)</script></head>
        <body data-response-fixture='\(marker)'>Synthetic instrumentation fixture</body></html>
        """
        page.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://www.apple.com/ca/shop/bag")!)
        var ready = false
        for _ in 0..<150 {
            let raw = try? await evaluate(page, "return document.readyState==='complete'?document.body?.dataset.responseFixture:'';")
            if raw as? String == marker, !page.webView.isLoading { ready = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready)
    }

    private func configure(_ page: WKAppleCheckoutPage, url: String, status: Int, sku: String, outcome: String = "success") async throws {
        let values: [String: Any] = ["url": url, "status": status, "body": String(decoding: try JSONSerialization.data(withJSONObject: cart(sku)), as: UTF8.self), "outcome": outcome]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        _ = try await evaluate(page, "Object.assign(__instrumentation,\(json),{cloneCalls:0,responseReads:0});return true;")
    }

    private func settledProducts(_ page: WKAppleCheckoutPage) async throws -> [String] {
        for _ in 0..<100 {
            let snapshot = try await page.snapshot()
            if snapshot.phase != .loading { return snapshot.productIDs }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Synthetic response capture did not settle")
        return []
    }

    @Test(arguments: ["fetch", "xhr"])
    func onlySuccessfulTrustedAppleShopResponsesMayReplaceCartAuthority(_ transport: String) async throws {
        let rejected: [(String, Int)] = [
            ("https://api.example.invalid/shop/checkout", 200),
            ("https://apple.com.example.invalid/ca/shop/checkout", 200),
            ("http://www.apple.com/ca/shop/checkout", 200),
            ("https://www.apple.com:8443/ca/shop/checkout", 200),
            ("https://name@www.apple.com/ca/shop/checkout", 200),
            ("https://www.apple.com/ca/support/checkout", 200),
            ("https://www.apple.com/ca/shop/checkout", 500)
        ]
        for (url, status) in rejected {
            let page = WKAppleCheckoutPage(submissionAllowed: false)
            try await fixture(page)
            try await configure(page, url: url, status: status, sku: "UNTRUSTED-SYNTHETIC/A")
            if transport == "fetch" {
                #expect(try await evaluate(page, """
                const response=await window.fetch('/ca/shop/checkout');
                return response===__instrumentation.lastResponse&&response.status===__instrumentation.status&&
                  response.headers.get('x-synthetic-response')==='unchanged'&&await response.text()===__instrumentation.body;
                """) as? Bool == true)
            } else {
                #expect(try await evaluate(page, """
                const xhr=new XMLHttpRequest();xhr.open('POST','/ca/shop/checkout');
                const returned=xhr.send('synthetic-body');
                return returned===__instrumentation.returnValue&&xhr.status===__instrumentation.status&&xhr.responseText===__instrumentation.body;
                """) as? Bool == true)
            }
            #expect(try await settledProducts(page) == ["INITIAL-SYNTHETIC/A"])
            #expect(try await evaluate(page, "return __instrumentation.cloneCalls;") as? Int == 0)
            page.clearPage()
        }

        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page)
        try await configure(page, url: "https://secure7.store.apple.com/ca/shop/checkout", status: 201, sku: "NEXT-SYNTHETIC/A")
        #expect(try await evaluate(page, transport == "fetch" ? """
            const options={method:'POST',headers:{'x-synthetic-request':'unchanged'},body:'synthetic-body',credentials:'same-origin'};
            const response=await window.fetch.call(window,'/ca/shop/checkout',options);
            return response===__instrumentation.lastResponse&&__instrumentation.fetchReceiver===window&&
              __instrumentation.fetchArguments[0]==='/ca/shop/checkout'&&__instrumentation.fetchArguments[1]===options;
            """ : """
            const xhr=new XMLHttpRequest();xhr.open('POST','/ca/shop/checkout');
            return xhr.send()===__instrumentation.returnValue;
            """) as? Bool == true)
        #expect(try await settledProducts(page) == ["NEXT-SYNTHETIC/A"])
        #expect(try await evaluate(page, "return __instrumentation.cloneCalls;") as? Int == (transport == "fetch" ? 1 : 0))
    }

    @Test func blockingJSONIsReportedWithoutCapturingItsModelOrChangingTheResponse() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page)
        try await configure(page, url: "https://www.apple.com/ca/shop/checkout", status: 541, sku: "ERROR-SYNTHETIC/A")
        #expect(try await evaluate(page, """
        const response=await fetch('/ca/shop/checkout');
        return response===__instrumentation.lastResponse&&response.status===541&&await response.text()===__instrumentation.body;
        """) as? Bool == true)
        let snapshot = try #require(try await evaluate(page, "return window.__pickupPilot.snapshot();") as? [String: Any])
        #expect(snapshot["phase"] as? String == "blocked" && snapshot["blockingStatus"] as? Int == 541)
        #expect(snapshot["productIDs"] as? [String] == ["INITIAL-SYNTHETIC/A"])
        #expect(try await evaluate(page, "return __instrumentation.cloneCalls;") as? Int == 0)
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.snapshot() }
    }

    @Test(arguments: ["success", "error", "abort", "timeout", "throw"])
    func settledXHRObserversNeverReadAReusedRequestMoreThanOnce(_ outcome: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page)
        try await configure(page, url: "https://www.apple.com/ca/shop/checkout", status: 200, sku: "FIRST-SYNTHETIC/A", outcome: outcome)
        #expect(try await evaluate(page, """
        window.__reusedXHR=new XMLHttpRequest();
        __instrumentation.sendError=new Error('Synthetic send failure');
        __reusedXHR.open('POST','/ca/shop/checkout');
        try{return __reusedXHR.send('synthetic-first')===__instrumentation.returnValue&&__instrumentation.outcome!=='throw';}
        catch(error){return error===__instrumentation.sendError&&__instrumentation.outcome==='throw';}
        """) as? Bool == true)
        #expect(try await page.snapshot().phase == .bag)
        try await configure(page, url: "https://www.apple.com/ca/shop/checkout", status: 200, sku: "SECOND-SYNTHETIC/A")
        #expect(try await evaluate(page, """
        __reusedXHR.open('POST','/ca/shop/checkout');
        const returned=__reusedXHR.send('synthetic-second');
        return returned===__instrumentation.returnValue&&__instrumentation.responseReads===1&&
          __reusedXHR.openArguments[0]==='POST'&&__reusedXHR.sendArguments[0]==='synthetic-second';
        """) as? Bool == true)
        #expect(try await settledProducts(page) == ["SECOND-SYNTHETIC/A"])
        // An extra load event after completion must not replay a removed observer.
        _ = try await evaluate(page, "__reusedXHR.dispatchEvent(new Event('load'));return true;")
        #expect(try await evaluate(page, "return __instrumentation.responseReads;") as? Int == 1)
    }
}
