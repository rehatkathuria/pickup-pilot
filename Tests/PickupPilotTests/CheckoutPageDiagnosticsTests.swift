import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

/// Synthetic HTML and HTTP metadata only; never loads a remote checkout or user session.
@Suite(.serialized) @MainActor struct CheckoutPageDiagnosticsTests {
    private func load(_ page: WKAppleCheckoutPage, url: String = "https://www.apple.com/ca/shop/checkout", body: String = "Synthetic checkout") async throws {
        let marker = UUID().uuidString
        let html = """
        <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'self'"></head>
        <body data-diagnostic-fixture="\(marker)">\(body)</body></html>
        """
        page.webView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        page.webView.loadHTMLString(html, baseURL: URL(string: url)!)
        for _ in 0..<150 {
            let value = try? await evaluate(page, "return document.body?.dataset.diagnosticFixture||'';")
            if value as? String == marker, !page.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckoutError.unsupportedPage
    }
    private func evaluate(_ page: WKAppleCheckoutPage, _ script: String) async throws -> Any? {
        try await page.webView.callAsyncJavaScript(script, in: nil, contentWorld: .page)
    }
    private func observe(_ page: WKAppleCheckoutPage, status: Int, url: String, main: Bool = true) {
        page.observeNavigationResponse(HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!, isForMainFrame: main)
    }
    private func post(_ page: WKAppleCheckoutPage, _ body: [String: Any], frame: Bool = false) async throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let target = frame ? "document.querySelector('iframe').contentWindow" : "window"
        _ = try await evaluate(page, "\(target).webkit.messageHandlers.pickupPilotChanged.postMessage(\(json));return true;")
        try await Task.sleep(for: .milliseconds(30))
    }
    private func event(status: Any = 541, source: String = "fetch", route: String = "signIn") -> [String: Any] {
        ["kind": "checkoutResponse", "status": status, "source": source, "route": route]
    }

    @Test(arguments: [200, 404])
    func directMissingPageNeverInventsAnAccessOrRateLimitResponse(status: Int) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page, url: "https://www.apple.com/ca/shop/404?syntheticToken=private", body: "<h1>Page Not Found</h1>")
        observe(page, status: status, url: "https://www.apple.com/ca/shop/404?syntheticToken=private")
        let snapshot = try await page.snapshot(), diagnostic = try #require(page.diagnostics)
        #expect(snapshot.phase == .pageNotFound && snapshot.blockingStatus == nil && snapshot.blockingSource == nil)
        #expect(diagnostic.currentRoute == .pageNotFound && diagnostic.mainFrameStatus == status)
        #expect(diagnostic.blockingStatus == nil && !diagnostic.isBlocked)
        await #expect(throws: CheckoutError.sessionRecoveryNotReady) { try await page.acknowledgeManualRecovery(market: .ca) }
        #expect(diagnostic.blockingStatus == nil)
        let history = diagnostic.history
        for _ in 0..<15 { _ = try await page.snapshot() }
        #expect(diagnostic.history == history)
        #expect(!String(describing: diagnostic.history).contains("private"))
    }

    @Test func actualMainFrame404AtAnOtherwiseSupportedURLIsStillPageNotFound() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page)
        observe(page, status: 404, url: "https://www.apple.com/ca/shop/checkout")
        #expect(try await page.snapshot().phase == .pageNotFound)
        #expect(page.diagnostics?.currentRoute == .pageNotFound && page.diagnostics?.mainFrameStatus == 404)
        #expect(page.diagnostics?.blockingStatus == nil)
        await #expect(throws: CheckoutError.sessionRecoveryNotReady) { try await page.acknowledgeManualRecovery(market: .ca) }
    }

    @Test(arguments: [403, 429, 541])
    func actualBlockIsRetainedSeparatelyFromTheFollowingMissingPage(status: Int) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page, url: "https://www.apple.com/ca/shop/signIn")
        page.diagnostics?.recordAction(.continuingAsGuest)
        observe(page, status: status, url: "https://www.apple.com/ca/shop/signInx?syntheticToken=private")
        try await load(page, url: "https://www.apple.com/ca/shop/go/404")
        observe(page, status: 404, url: "https://www.apple.com/ca/shop/go/404")
        let snapshot = try await page.snapshot(), diagnostic = try #require(page.diagnostics)
        #expect(snapshot.phase == .pageNotFound && snapshot.blockingStatus == status && snapshot.blockingSource == "mainFrame")
        #expect(diagnostic.currentRoute == .pageNotFound && diagnostic.mainFrameStatus == 404)
        #expect(diagnostic.action == .continuingAsGuest && diagnostic.blockingStatus == status && diagnostic.blockingSource == .mainFrame)
        #expect(diagnostic.isBlocked)
        #expect(diagnostic.history.contains { $0.status == status && $0.source == .mainFrame })
    }

    @Test func immediateResponseEventSurvivesDocumentReplacementAndLateEventsCannotChangeCurrentRoute() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page, url: "https://www.apple.com/ca/shop/signIn")
        page.diagnostics?.recordAction(.continuingAsGuest)
        try await post(page, event(status: 541, source: "fetch", route: "otherApple"))
        #expect(page.diagnostics?.blockingStatus == 541 && page.diagnostics?.blockingSource == .fetch)
        try await load(page, url: "https://www.apple.com/ca/shop/404")
        observe(page, status: 404, url: "https://www.apple.com/ca/shop/404")
        let missing = try await page.snapshot()
        #expect(missing.phase == .pageNotFound && missing.blockingStatus == 541 && missing.blockingSource == "fetch")
        try await post(page, event(status: 429, source: "xhr", route: "signIn"))
        #expect(page.diagnostics?.currentRoute == .pageNotFound && page.diagnostics?.mainFrameStatus == 404)
        #expect(page.diagnostics?.blockingStatus == 541 && page.diagnostics?.blockingSource == .fetch)
        #expect(page.diagnostics?.history.first?.route == .signIn && page.diagnostics?.history.first?.source == .xhr)
    }

    @Test func malformedForeignAndSubframeEventsCannotCreateBlockEvidence() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page, body: "<iframe srcdoc='<body>Synthetic child</body>'></iframe>")
        var extra = event(); extra["rawURL"] = "synthetic-private-value"
        for invalid in [event(status: 404), event(status: "541"), event(status: 541.5), event(status: true),
                        event(source: "mainFrame"), event(source: "arbitrary-private-value"), event(route: "external"),
                        event(route: "idle"), event(route: "https://www.apple.com/ca/shop/checkout?private"), extra] {
            try await post(page, invalid)
        }
        #expect(page.diagnostics?.blockingStatus == nil)
        _ = try await evaluate(page, "await new Promise(resolve=>setTimeout(resolve,40));return true;")
        try await post(page, event(), frame: true)
        #expect(page.diagnostics?.blockingStatus == nil)
        try await load(page, url: "https://synthetic-bank.example.invalid/challenge")
        try await post(page, event())
        #expect(page.diagnostics?.blockingStatus == nil)
        try await load(page, url: "https://www.apple.com:8443/ca/shop/checkout")
        try await post(page, event())
        #expect(page.diagnostics?.blockingStatus == nil)
    }

    @Test func nonAppleAndSubframeHTTPResponsesNeverBecomeAppleBlocks() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page)
        observe(page, status: 541, url: "https://www.apple.com/ca/shop/checkout", main: false)
        observe(page, status: 403, url: "https://synthetic-bank.example.invalid/challenge")
        #expect(page.diagnostics?.blockingStatus == nil)
        #expect(try await page.snapshot().phase == .unknown)
    }

    @Test func diagnosticsBoundAndRedactHistoryWhileKeepingFirstCauseAndAction() throws {
        let diagnostic = CheckoutPageDiagnostics()
        diagnostic.recordAction(.continuingAsGuest)
        diagnostic.recordResponse(status: 541, source: .fetch, route: .signIn)
        for index in 0..<30 {
            diagnostic.recordNavigation(URL(string: index.isMultiple(of: 2) ? "https://www.apple.com/ca/shop/checkout?syntheticSecret=hidden" : "https://www.apple.com/ca/shop/404#syntheticSecret"))
            diagnostic.recordResponse(status: index.isMultiple(of: 2) ? 200 : 404, source: .mainFrame, route: index.isMultiple(of: 2) ? .checkout : .pageNotFound)
        }
        #expect(diagnostic.history.count == 8 && diagnostic.blockingStatus == 541 && diagnostic.blockingSource == .fetch)
        #expect(diagnostic.action == .continuingAsGuest && !String(describing: diagnostic.history).contains("syntheticSecret"))
        let history = diagnostic.history
        diagnostic.recordResponse(status: 404, source: .mainFrame, route: .pageNotFound)
        #expect(diagnostic.history == history)
        diagnostic.reset()
        #expect(diagnostic.action == .idle && diagnostic.currentRoute == .idle && diagnostic.history.isEmpty)
        #expect(diagnostic.blockingStatus == nil && diagnostic.blockingSource == nil && diagnostic.mainFrameStatus == nil && !diagnostic.isBlocked)
    }

    @Test func unknownRecoveryWithoutObservedBlockingResponseIsNeutral() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await load(page)
        await #expect(throws: CheckoutError.sessionRecoveryNotReady) { try await page.acknowledgeManualRecovery(market: .ca) }
        #expect(page.diagnostics?.blockingStatus == nil && page.diagnostics?.isBlocked == false)
        #expect(try await page.snapshot().phase == .unknown)
    }
}
