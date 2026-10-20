import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

private enum GuestNativeFailure: Error { case syntheticPrivateBridgeFailure }

@MainActor private final class GuestNativeBridge {
    weak var page: WKAppleCheckoutPage?
    var mode = "actual"
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    func release() { pending?.resume(); pending = nil }
    func evaluate(_ script: String, arguments: [String: Any]) async throws -> Any? {
        guard let page else { throw CheckoutError.unsupportedPage }
        guard script.contains("window.__pickupPilot.continueAsGuest") else {
            return try await page.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        }
        calls += 1
        switch mode {
        case "nil": return nil
        case "integer": return NSNumber(value: 1)
        case "string": return "true"
        case "object": return ["dispatched": true]
        case "false": return false
        case "error": throw GuestNativeFailure.syntheticPrivateBridgeFailure
        case "suspended": await withCheckedContinuation { pending = $0 }; return true
        default:
            let result = try await page.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            if mode == "lost-after-click" { throw GuestNativeFailure.syntheticPrivateBridgeFailure }
            if mode == "new-document-after-click" { page.webView(page.webView, didStartProvisionalNavigation: nil) }
            return result
        }
    }
}

/// Local, network-denied sign-in fixtures and a production native bridge. No
/// account fields are filled; guest controls only increment a synthetic counter.
@Suite(.serialized) @MainActor struct CheckoutGuestNativeResultTests {
    private var request: CheckoutRequest {
        CheckoutRequest(variant: ProductVariant(id: "SYNTHETIC-GUEST/CA", name: "Synthetic", storage: "256GB", color: "Synthetic",
                                               productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic")),
                        store: RetailStore(id: "R121", name: "Synthetic"), market: .ca, maximumTotal: 4_000)
    }
    private func fixture(_ page: WKAppleCheckoutPage, hasGuest: Bool = true) async throws {
        let marker = UUID().uuidString
        let control = hasGuest ? "<button type='button' onclick='window.__nativeGuestClicks++'>Continue as Guest</button>" : ""
        let html = """
        <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; frame-src 'none'"></head>
        <body data-native-guest-fixture='\(marker)'><main id='synthetic-guest'>\(control)</main><script>window.__nativeGuestClicks=0;</script></body></html>
        """
        page.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://www.apple.com/ca/shop/signIn")!)
        for _ in 0..<150 {
            let value = try? await page.webView.callAsyncJavaScript("return document.readyState==='complete'?document.body?.dataset.nativeGuestFixture||'':'';", in: nil, contentWorld: .page)
            if value as? String == marker, !page.webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckoutError.unsupportedPage
    }
    private func makePage(_ bridge: GuestNativeBridge) -> WKAppleCheckoutPage {
        let page = WKAppleCheckoutPage(submissionAllowed: false, evaluator: { script, arguments in
            try await bridge.evaluate(script, arguments: arguments)
        })
        bridge.page = page
        return page
    }
    private func clicks(_ page: WKAppleCheckoutPage) async throws -> Int {
        try await page.webView.callAsyncJavaScript("return window.__nativeGuestClicks;", in: nil, contentWorld: .page) as? Int ?? -1
    }
    private func waitForBridge(_ bridge: GuestNativeBridge) async throws {
        for _ in 0..<2_000 { if bridge.pending != nil { return }; await Task.yield() }
        throw CheckoutError.unsupportedPage
    }

    @Test func absentGuestControlCanHydrateBeforeTheOneActualDispatch() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page, hasGuest: false)
        let before = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request, snapshot: before) == false)
        #expect(try await clicks(page) == 0)
        _ = try await page.webView.callAsyncJavaScript("""
        const button=document.createElement('button');button.type='button';button.textContent='Continue as Guest';
        button.onclick=()=>window.__nativeGuestClicks++;document.getElementById('synthetic-guest').append(button);return true;
        """, in: nil, contentWorld: .page)
        let ready = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request, snapshot: ready))
        #expect(try await page.continueAsGuest(request: request, snapshot: ready) == false)
        #expect(try await clicks(page) == 1)
    }

    @Test(arguments: ["nil", "integer", "string", "object", "error"])
    func ambiguousBridgeResultsNeverPretendNoActionWasDispatched(_ mode: String) async throws {
        let bridge = GuestNativeBridge(); bridge.mode = mode
        let page = makePage(bridge)
        defer { page.clearPage() }
        try await fixture(page)
        let snapshot = try await page.snapshot()
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await page.continueAsGuest(request: request, snapshot: snapshot) }
        #expect(bridge.calls == 1)
        #expect(try await clicks(page) == 0)
    }

    @Test func explicitFalseRemainsAReadinessResultAndDoesNotLatchTheGuestControl() async throws {
        let bridge = GuestNativeBridge(); bridge.mode = "false"
        let page = makePage(bridge)
        defer { page.clearPage() }
        try await fixture(page)
        let snapshot = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request, snapshot: snapshot) == false)
        bridge.mode = "actual"
        #expect(try await page.continueAsGuest(request: request, snapshot: snapshot))
        #expect(try await page.continueAsGuest(request: request, snapshot: snapshot) == false)
        #expect(try await clicks(page) == 1)
    }

    @Test func lostResultAfterTheSyntheticClickStopsInsteadOfInvitingARetry() async throws {
        let bridge = GuestNativeBridge(); bridge.mode = "lost-after-click"
        let page = makePage(bridge)
        defer { page.clearPage() }
        try await fixture(page)
        let snapshot = try await page.snapshot()
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await page.continueAsGuest(request: request, snapshot: snapshot) }
        #expect(bridge.calls == 1)
        #expect(try await clicks(page) == 1)
    }

    @Test func confirmedDispatchStaysTrueWhenItStartsANewDocumentRevision() async throws {
        let bridge = GuestNativeBridge(); bridge.mode = "new-document-after-click"
        let page = makePage(bridge)
        defer { page.clearPage() }
        try await fixture(page)
        let snapshot = try await page.snapshot()
        #expect(try await page.continueAsGuest(request: request, snapshot: snapshot))
        #expect(bridge.calls == 1)
        #expect(try await clicks(page) == 1)
    }

    @Test(arguments: [false, true])
    func cancellationOverridesALateGuestResult(cancelTask: Bool) async throws {
        let bridge = GuestNativeBridge(); bridge.mode = "suspended"
        let page = makePage(bridge)
        defer { page.clearPage() }
        try await fixture(page)
        let snapshot = try await page.snapshot()
        let work = Task { try await page.continueAsGuest(request: request, snapshot: snapshot) }
        try await waitForBridge(bridge)
        if cancelTask { work.cancel() } else { page.cancel() }
        bridge.release()
        if cancelTask { await #expect(throws: CancellationError.self) { try await work.value } }
        else { await #expect(throws: CheckoutError.cancelled) { try await work.value } }
        #expect(try await clicks(page) == 0)
    }

    @Test func accountPageCannotBeAcknowledgedOrSavedAsARecoveredGuestSession() async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        try await fixture(page)
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await page.acknowledgeManualInput(market: .ca) }
        await #expect(throws: CheckoutError.guestCheckoutUnavailable) { try await page.acknowledgeManualRecovery(market: .ca) }
        #expect(try await clicks(page) == 0)
    }
}
