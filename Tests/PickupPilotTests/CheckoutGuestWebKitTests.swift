import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

@MainActor private final class GuestBridgeProbe {
    weak var page: WKAppleCheckoutPage?
    var payloadKeys: [String] = []
    var argumentKeys: [String] = []
    var suppliedMarketPath: String?
    var suppliedDocumentID: String?
}

/// Production native/JavaScript guest navigation against local Apple-origin HTML only.
/// CSP denies network, frames and form destinations; all eligible controls only increment a counter.
@Suite(.serialized) @MainActor struct CheckoutGuestWebKitTests {
    private func request(market: Market = .ca) -> CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "GUEST-SYNTHETIC/A", name: "Synthetic", storage: "256GB", color: "Synthetic",
                                               productURL: market.productBaseURL.appendingPathComponent("synthetic")),
                        store: RetailStore(id: "R121", name: "Synthetic"), market: market, maximumTotal: 4000)
    }
    private func control(_ kind: String = "button") -> String {
        if kind == "anchor" {
            return "<a href='#synthetic' onclick='event.preventDefault();window.__guestClicks++'>Check Out as Guest</a>"
        }
        if kind == "input" {
            return "<input type='button' value='continue as guest' onclick='window.__guestClicks++'>"
        }
        if kind == "wrapped" {
            return "<button type='button' onclick='window.__guestClicks++'><span>Continue\n as&nbsp;</span><span>guest</span></button>"
        }
        return "<button type='button' onclick='window.__guestClicks++'>Continue as Guest</button>"
    }
    private func evaluate(_ page: WKAppleCheckoutPage, _ script: String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }
    private func clicks(_ page: WKAppleCheckoutPage) async throws -> Int {
        try await evaluate(page, "return window.__guestClicks;") as? Int ?? -1
    }
    private func fixture(_ page: WKAppleCheckoutPage, controls: String? = nil, extra: String = "",
                         path: String = "/ca/shop/signIn", beforeBootstrap: String = "") async throws {
        if !beforeBootstrap.isEmpty {
            let controller = page.webView.configuration.userContentController
            let scripts = controller.userScripts.map { (source: $0.source, injectionTime: $0.injectionTime, mainOnly: $0.isForMainFrameOnly) }
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: beforeBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            for script in scripts {
                controller.addUserScript(WKUserScript(source: script.source, injectionTime: script.injectionTime, forMainFrameOnly: script.mainOnly))
            }
        }
        let marker = UUID().uuidString
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'none'">
        </head><body data-guest-fixture='\(marker)'>
        <input type='password' autocomplete='current-password' aria-label='Synthetic sign in'>
        <main id='synthetic-guest-controls'>\(controls ?? control())</main>\(extra)
        <script>window.__guestClicks=0;</script></body></html>
        """
        page.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://www.apple.com" + path)!)
        var ready = false
        for _ in 0..<150 {
            let value = try? await evaluate(page, "return document.readyState==='complete'?document.body?.dataset.guestFixture||'':'';")
            if value as? String == marker, !page.webView.isLoading { ready = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready)
    }

    @Test(arguments: ["button", "anchor", "input", "wrapped"])
    func exactGuestControlClicksOnceAcrossSameDocumentRerenders(_ kind: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let html = control(kind)
        try await fixture(page, controls: html)
        let original = try await page.snapshot()
        #expect(original.phase == .authentication && CheckoutPagePolicy.isDocumentID(original.documentID))
        #expect(try await page.continueAsGuest(request: request(), snapshot: original))
        #expect(try await clicks(page) == 1)
        #expect(try await page.continueAsGuest(request: request(), snapshot: original) == false)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed]), as: UTF8.self)
        _ = try await evaluate(page, "document.getElementById('synthetic-guest-controls').innerHTML=\(encoded);return true;")
        let rerendered = try await page.snapshot()
        #expect(rerendered.documentID == original.documentID)
        #expect(try await page.continueAsGuest(request: request(), snapshot: rerendered) == false)
        #expect(try await clicks(page) == 1)
    }

    @Test(arguments: ["ambiguous", "disabled", "ariaDisabled", "disabledFieldset", "hidden", "nonexact"])
    func ineligibleGuestControlsNeverClick(_ kind: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let html: String
        switch kind {
        case "ambiguous": html = control() + control("anchor")
        case "disabled": html = control().replacingOccurrences(of: "type='button'", with: "type='button' disabled")
        case "ariaDisabled": html = "<div aria-disabled='true'>" + control("anchor") + "</div>"
        case "disabledFieldset": html = "<fieldset disabled>" + control() + "</fieldset>"
        case "hidden": html = control().replacingOccurrences(of: "type='button'", with: "type='button' hidden")
        default: html = control().replacingOccurrences(of: "Continue as Guest", with: "Continue as Guest quickly")
        }
        try await fixture(page, controls: html)
        let snapshot = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request(), snapshot: snapshot) == false)
        #expect(try await clicks(page) == 0)
    }

    @Test func wrongMarketPathSourceAndDocumentCannotAuthorizeGuestNavigation() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, path: "/ca/shop/signin") // Case-sensitive production sign-in route.
        let wrongPath = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request(), snapshot: wrongPath) == false)
        try await fixture(page)
        let original = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request(market: .uk), snapshot: original) == false)
        var wrongSource = original; wrongSource.sourceURL = "https://www.apple.com/ca/shop/checkout"
        #expect(try await page.continueAsGuest(request: request(), snapshot: wrongSource) == false)
        var wrongDocument = original; wrongDocument.documentID = UUID().uuidString
        #expect(try await page.continueAsGuest(request: request(), snapshot: wrongDocument) == false)
        try await fixture(page) // A replacement at the same URL cannot use the old document capability.
        #expect(try await page.continueAsGuest(request: request(), snapshot: original) == false)
        #expect(try await clicks(page) == 0)
        let current = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request(), snapshot: current))
        #expect(try await clicks(page) == 1)
    }

    @Test(arguments: ["otp", "captcha", "verification", "challengeFrame", "error", "finalControl"])
    func challengesValidationErrorsAndFinalControlsPreventGuestNavigation(_ kind: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let extra: String
        switch kind {
        case "otp": extra = "<input autocomplete='one-time-code'>"
        case "captcha": extra = "<input name='captcha'>"
        case "verification": extra = "<input name='verificationCode'>"
        case "challengeFrame": extra = "<iframe src='https://www.apple.com/ca/shop/challenge' sandbox></iframe>"
        case "error": extra = "<input aria-invalid='true'>"
        default: extra = "<button type='button' data-autom='continue-button-placeOrder'>Inert final control</button>"
        }
        try await fixture(page, extra: extra)
        let snapshot = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request(), snapshot: snapshot) == false)
        #expect(try await clicks(page) == 0)
    }

    @Test func pendingNetworkAndModelCaptureMustSettleBeforeGuestCanContinue() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, beforeBootstrap: "window.fetch=()=>new Promise(resolve=>{window.__resolveGuestResponse=resolve;});")
        let original = try await page.snapshot()
        _ = try await evaluate(page, "window.__guestConsumer=window.fetch('/ca/shop/signIn');return true;")
        #expect(try await page.snapshot().phase == .loading)
        #expect(try await page.continueAsGuest(request: request(), snapshot: original) == false)
        _ = try await evaluate(page, """
        const response=new Response('{}',{status:200,headers:{'content-type':'application/json'}});
        Object.defineProperty(response,'url',{value:'https://www.apple.com/ca/shop/signIn'});
        response.clone=()=>({json:()=>new Promise(resolve=>{window.__resolveGuestModel=resolve;})});
        window.__resolveGuestResponse(response);await window.__guestConsumer;return true;
        """)
        #expect(try await page.snapshot().phase == .loading)
        #expect(try await page.continueAsGuest(request: request(), snapshot: original) == false)
        #expect(try await clicks(page) == 0)
        _ = try await evaluate(page, "window.__resolveGuestModel({});await Promise.resolve();await Promise.resolve();return true;")
        let settled = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request(), snapshot: settled))
        #expect(try await clicks(page) == 1)
    }

    private var syntheticResponses: String {
        """
        window.__guestStatus=541;
        window.fetch=async()=>{const response=new Response('Synthetic response',{status:window.__guestStatus});
        Object.defineProperty(response,'url',{value:'https://www.apple.com/ca/shop/signInx'});return response;};
        class SyntheticGuestXHR extends EventTarget {
          open(method,url){this.responseURL=new URL(url,location.href).href;}
          send(){this.status=window.__guestStatus;this.responseType='';this.responseText='Synthetic response';
            this.dispatchEvent(new Event('load'));this.dispatchEvent(new Event('loadend'));}
        }
        window.XMLHttpRequest=SyntheticGuestXHR;
        """
    }

    @Test(arguments: [403, 429, 541], ["fetch", "xhr"])
    func blockingResponseStopsGuestAndPreservesItsFirstStatusAndSource(_ status: Int, _ source: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, beforeBootstrap: syntheticResponses)
        let original = try await page.snapshot()
        _ = try await evaluate(page, "window.__guestStatus=\(status);return true;")
        let response: Any?
        if source == "fetch" {
            response = try await evaluate(page, "const response=await window.fetch('/ca/shop/signInx');return [response.status,await response.text()];")
        } else {
            response = try await evaluate(page, "const xhr=new XMLHttpRequest();xhr.open('POST','/ca/shop/signInx');xhr.send();return [xhr.status,xhr.responseText];")
        }
        let result = try #require(response as? [Any])
        #expect(result[0] as? Int == status && result[1] as? String == "Synthetic response")
        let evidence = try #require(try await evaluate(page, "return window.__pickupPilot.snapshot();") as? [String: Any])
        #expect(evidence["phase"] as? String == "blocked")
        #expect(evidence["blockingStatus"] as? Int == status && evidence["blockingSource"] as? String == source)
        // A later different failing response cannot replace the diagnostic cause.
        _ = try await evaluate(page, "window.__guestStatus=429;await window.fetch('/ca/shop/signInx');return true;")
        let retained = try #require(try await evaluate(page, "return window.__pickupPilot.snapshot();") as? [String: Any])
        #expect(retained["blockingStatus"] as? Int == status && retained["blockingSource"] as? String == source)
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.snapshot() }
        await #expect(throws: CheckoutError.storefrontBlocked) { try await page.continueAsGuest(request: request(), snapshot: original) }
        #expect(try await clicks(page) == 0)
    }

    @Test func ordinary404ResponseDoesNotClaimBlockingOrAlterTheGuestResponse() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, beforeBootstrap: syntheticResponses)
        #expect(try await evaluate(page, "window.__guestStatus=404;return (await window.fetch('/ca/shop/signInx')).status;") as? Int == 404)
        let snapshot = try await page.snapshot()
        #expect(snapshot.phase == .authentication && snapshot.blockingStatus == nil && snapshot.blockingSource == nil)
        #expect(try await clicks(page) == 0)
    }

    @Test(arguments: ["/ca/shop/404", "/shop/go/404", "/ca/shop/signIn"])
    func errorRouteOrExactVisibleAppleHeadingStopsGuestAndRetainsEarlierBlockEvidence(_ path: String) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, extra: "<h1>The page you’re looking for can’t be found.</h1>", path: path, beforeBootstrap: syntheticResponses)
        _ = try await evaluate(page, "await window.fetch('/ca/shop/signInx');return true;")
        let snapshot = try await page.snapshot()
        #expect(snapshot.phase == .pageNotFound && snapshot.blockingStatus == 541 && snapshot.blockingSource == "fetch")
        #expect(try await clicks(page) == 0)
    }

    @Test func ordinaryErrorRouteIsDistinctFromBlockingAndUnrelatedOrHiddenHeadingsAreIgnored() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, path: "/ca/shop/404")
        let missing = try await page.snapshot()
        #expect(missing.phase == .pageNotFound && missing.blockingStatus == nil && missing.blockingSource == nil)
        try await fixture(page, extra: "<h1>Help with a Page Not Found message</h1><h1 hidden>Page Not Found</h1>")
        #expect(try await page.snapshot().phase == .authentication)
        #expect(try await clicks(page) == 0)
    }

    @Test func nativeGuestPayloadContainsOnlyMarketPathAndDocumentIdentity() async throws {
        let probe = GuestBridgeProbe()
        let page = WKAppleCheckoutPage(submissionAllowed: false, evaluator: { script, arguments in
            guard let current = probe.page else { throw CheckoutError.unsupportedPage }
            if script.contains("window.__pickupPilot.continueAsGuest") {
                probe.argumentKeys = arguments.keys.sorted()
                let payload = arguments["payload"] as? [String: Any] ?? [:]
                probe.payloadKeys = payload.keys.sorted()
                probe.suppliedMarketPath = payload["marketPath"] as? String
                probe.suppliedDocumentID = payload["documentID"] as? String
            }
            return try await current.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        })
        probe.page = page
        defer { page.clearPage() }
        try await fixture(page)
        let snapshot = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request(), snapshot: snapshot))
        #expect(probe.argumentKeys == ["payload"] && probe.payloadKeys == ["documentID", "marketPath"])
        #expect(probe.suppliedMarketPath == "/ca" && probe.suppliedDocumentID == snapshot.documentID)
        #expect(try await clicks(page) == 1)
    }
}
