import Foundation
import WebKit
import PilotCore
import CoreFoundation

/// The content controller retains handlers. Keep its reference to the page weak.
@MainActor private final class CheckoutChangeHandler: NSObject, WKScriptMessageHandler {
    weak var page: WKAppleCheckoutPage?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        page?.observePageChange(message)
    }
}

/// No WebKit website data is persisted to disk. Only this app's Apple cookies are saved in its Keychain item.
@MainActor final class WKAppleCheckoutPage: NSObject, AppleCheckoutPage, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let submissionAllowed: Bool
    private let evaluator: @MainActor (String, [String: Any]) async throws -> Any?
    private var sessionRevision = 0
    private var documentRevision = 0
    private var storefrontBlocked = false
    private var mainFrameNotFound = false
    let diagnostics: CheckoutPageDiagnostics? = CheckoutPageDiagnostics()
    private var manualRecoveryDocument: (id: UUID, url: URL, session: Int, document: Int)?
    private var changeRevision: UInt64 = 0
    private var snapshotRevision: UInt64 = 0
    private struct ChangeWaiter {
        let continuation: CheckedContinuation<Bool, any Error>
        let timeout: Task<Void, Never>
    }
    private var changeWaiters: [UUID: ChangeWaiter] = [:]

    init(submissionAllowed: Bool = true, evaluator: (@MainActor (String, [String: Any]) async throws -> Any?)? = nil) {
        self.submissionAllowed = submissionAllowed
        let configuration = WKWebViewConfiguration()
        let changeHandler = CheckoutChangeHandler()
        configuration.userContentController.add(changeHandler, name: "pickupPilotChanged")
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if !submissionAllowed {
            configuration.userContentController.addUserScript(WKUserScript(
                source: "Object.defineProperty(window, '__pickupPilotReviewOnly', {value:true, writable:false, configurable:false});",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: AppleCheckoutScripts.bootstrap,
                                                                        injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Preparation may begin before SwiftUI attaches the checkout window. Give
        // Apple's initial document a desktop viewport; the host owns later sizing.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        self.webView = webView
        self.evaluator = evaluator ?? { script, arguments in
            try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        }
        super.init()
        changeHandler.page = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ url: URL) async throws {
        try Task.checkCancellation()
        guard CheckoutPagePolicy.isAppleHTTPS(url) else { throw CheckoutError.unsupportedPage }
        storefrontBlocked = false
        mainFrameNotFound = false
        diagnostics?.clearActiveBlock()
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }
    func snapshot() async throws -> CheckoutSnapshot {
        try Task.checkCancellation()
        // Capture before suspension: a signal during evaluation or advance must not be lost
        // when the driver subsequently registers its wait.
        snapshotRevision = changeRevision
        let url = webView.url
        let document = documentRevision
        let sourceURL = Self.evidenceURL(url)
        if webView.isLoading {
            let loading = withBlockingEvidence(CheckoutSnapshot(sourceURL: sourceURL, phase: .loading))
            diagnostics?.recordSnapshot(loading)
            return loading
        }
        if isCurrentPageNotFound(url) { return notFoundSnapshot(sourceURL: sourceURL) }
        guard let url else {
            if storefrontBlocked { throw CheckoutError.storefrontBlocked }
            return CheckoutSnapshot(sourceURL: sourceURL)
        }
        guard CheckoutPagePolicy.isAppleHTTPS(url) else {
            if storefrontBlocked { throw CheckoutError.storefrontBlocked }
            let authentication = CheckoutSnapshot(sourceURL: sourceURL, phase: .authentication)
            diagnostics?.recordSnapshot(authentication)
            return authentication
        }
        do {
            let raw = try await evaluator("return window.__pickupPilot.snapshot();", [:])
            try Task.checkCancellation()
            guard !webView.isLoading, webView.url == url, documentRevision == document else {
                return CheckoutSnapshot(sourceURL: Self.evidenceURL(webView.url), phase: .loading)
            }
            guard let raw, JSONSerialization.isValidJSONObject(raw) else { throw CheckoutError.unsupportedPage }
            var snapshot = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
            snapshot.sourceURL = sourceURL
            ingestBlockingEvidence(snapshot)
            diagnostics?.recordSnapshot(snapshot)
            if snapshot.phase == .pageNotFound { return withBlockingEvidence(snapshot) }
            if storefrontBlocked { throw CheckoutError.storefrontBlocked }
            // A bare phase is not proof of a blocking HTTP response.
            guard snapshot.phase != .blocked else { throw CheckoutError.unsupportedPage }
            return withBlockingEvidence(snapshot)
        } catch {
            try Task.checkCancellation()
            if webView.isLoading || webView.url != url || documentRevision != document {
                return CheckoutSnapshot(sourceURL: Self.evidenceURL(webView.url), phase: .loading)
            }
            if isCurrentPageNotFound(webView.url) { return notFoundSnapshot(sourceURL: Self.evidenceURL(webView.url)) }
            if storefrontBlocked { throw CheckoutError.storefrontBlocked }
            throw CheckoutError.unsupportedPage
        }
    }
    private func ingestBlockingEvidence(_ snapshot: CheckoutSnapshot) {
        guard let status = snapshot.blockingStatus, [403, 429, 541].contains(status),
              let sourceText = snapshot.blockingSource, let source = CheckoutDiagnosticSource(rawValue: sourceText),
              source == .fetch || source == .xhr else { return }
        if !storefrontBlocked { diagnostics?.recordResponse(status: status, source: source, route: .classify(webView.url)) }
        storefrontBlocked = true
    }
    private func withBlockingEvidence(_ snapshot: CheckoutSnapshot) -> CheckoutSnapshot {
        var snapshot = snapshot
        snapshot.blockingStatus = diagnostics?.blockingStatus
        snapshot.blockingSource = diagnostics?.blockingSource?.rawValue
        return snapshot
    }
    private func isCurrentPageNotFound(_ url: URL?) -> Bool {
        guard let url, CheckoutPagePolicy.isAppleHTTPS(url) else { return false }
        return mainFrameNotFound || CheckoutDiagnosticRoute.classify(url) == .pageNotFound
    }
    private func notFoundSnapshot(sourceURL: String) -> CheckoutSnapshot {
        let snapshot = withBlockingEvidence(CheckoutSnapshot(sourceURL: sourceURL, phase: .pageNotFound))
        diagnostics?.recordSnapshot(snapshot)
        return snapshot
    }
    func resetDiagnostics() {
        storefrontBlocked = false; mainFrameNotFound = false; manualRecoveryDocument = nil
        diagnostics?.reset()
    }
    /// Page signals are hints only. The next snapshot and checkout policy remain authoritative.
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) async throws -> Bool {
        try Task.checkCancellation()
        let revision = snapshotRevision
        if revision != changeRevision { return true }
        guard timeout.isFinite, timeout > 0 else { return false }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                guard revision == changeRevision else { continuation.resume(returning: true); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(min(timeout, 30))) }
                    catch { return }
                    self?.finishChangeWait(id, result: .success(false))
                }
                changeWaiters[id] = ChangeWaiter(continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishChangeWait(id, result: .failure(CancellationError())) }
        }
    }
    private func finishChangeWait(_ id: UUID, result: Result<Bool, any Error>) {
        guard let waiter = changeWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(with: result)
    }
    private func signalPageChange() {
        changeRevision &+= 1
        for id in Array(changeWaiters.keys) { finishChangeWait(id, result: .success(true)) }
    }
    fileprivate func observePageChange(_ message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        let host = origin.host.lowercased()
        guard message.name == "pickupPilotChanged", message.frameInfo.isMainFrame,
              origin.protocol == "https", origin.port == 0 || origin.port == 443,
              host == "apple.com" || host.hasSuffix(".apple.com") else { return }
        if let hint = message.body as? NSNumber, CFGetTypeID(hint) != CFBooleanGetTypeID(), hint.doubleValue == 1 { signalPageChange(); return }
        guard let body = message.body as? [String: Any], Set(body.keys) == ["kind", "status", "source", "route"],
              body["kind"] as? String == "checkoutResponse", let number = body["status"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue),
              [403, 429, 541].contains(number.intValue), let sourceText = body["source"] as? String,
              let source = CheckoutDiagnosticSource(rawValue: sourceText), source == .fetch || source == .xhr,
              let routeText = body["route"] as? String, let route = CheckoutDiagnosticRoute(rawValue: routeText),
              route != .idle, route != .external else { return }
        diagnostics?.recordResponse(status: number.intValue, source: source, route: route)
        storefrontBlocked = true
        signalPageChange()
    }
    func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool {
        if isCurrentPageNotFound(webView.url) { throw CheckoutError.pageNotFound }
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        guard let url = webView.url, CheckoutPagePolicy.isStorefront(url, market: request.market) else { throw CheckoutError.unsupportedPage }
        try Task.checkCancellation()
        guard !webView.isLoading else { return false }
        let payload: [String: Any] = ["sku": request.variant.id, "storeID": request.store.id,
                                      "marketPath": request.market.storefrontPath,
                                      "allowsUnscheduledPickup": request.allowsUnscheduledPickup,
                                      "pickupStart": request.pickupWindow.start.timeIntervalSince1970 * 1000,
                                      "pickupEnd": request.pickupWindow.end.timeIntervalSince1970 * 1000,
                                      "startMinute": request.pickupHours.startMinute, "endMinute": request.pickupHours.endMinute,
                                      "timeZone": request.timeZoneIdentifier,
                                      "profile": ["firstName": profile.givenName, "lastName": profile.familyName,
                                                  "emailAddress": profile.email, "email": profile.email,
                                                  "mobilePhone": profile.phone, "phoneNumber": profile.phone,
                                                  "cardholder": profile.cardholder, "cardNumber": profile.cardNumber,
                                                  "expiration": "\(profile.expiryMonth)/\(profile.expiryYear.suffix(2))", "securityCode": profile.cvv,
                                                  "street": profile.billingLine1, "street2": profile.billingLine2,
                                                  "city": profile.billingCity, "state": profile.billingRegion,
                                                  "province": profile.billingRegion, "postalCode": profile.billingPostalCode,
                                                  "country": profile.billingCountry, "searchLocation": profile.searchLocation]]
        // Re-check the executing document as well as the native URL: navigation can start between actor turns.
        let raw = try await evaluator("""
        if (location.protocol !== 'https:' || !/(^|\\.)apple\\.com$/i.test(location.hostname) ||
            !location.pathname.startsWith(payload.marketPath + '/shop/')) return false;
        return window.__pickupPilot.advance(payload);
        """, ["payload": payload])
        return raw as? Bool == true
    }
    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) async throws -> Bool {
        try Task.checkCancellation()
        if isCurrentPageNotFound(webView.url) { throw CheckoutError.pageNotFound }
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        guard snapshot.phase == .authentication, !snapshot.hasErrors, snapshot.finalActionCount == 0,
              let documentID = snapshot.documentID, CheckoutPagePolicy.isDocumentID(documentID), !webView.isLoading,
              let url = webView.url, CheckoutPagePolicy.isStorefront(url, market: request.market),
              url.path == "\(request.market.storefrontPath)/shop/signIn",
              CheckoutPagePolicy.storefrontIdentity(url, market: request.market) == snapshot.sourceURL else { return false }
        let session = sessionRevision, document = documentRevision
        let raw: Any?
        do {
            raw = try await evaluator("""
            return window.__pickupPilot.continueAsGuest(payload);
            """, ["payload": ["marketPath": request.market.storefrontPath, "documentID": documentID]])
        } catch {
            try checkSessionRestore(session)
            if error is CancellationError || (error as? CheckoutError) == .cancelled { throw error }
            if !webView.isLoading, isCurrentPageNotFound(webView.url) { throw CheckoutError.pageNotFound }
            guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
            // The result can be lost after a click begins navigation. That is not
            // proof of no dispatch, so it must never invite a readiness retry.
            throw CheckoutError.guestCheckoutUnavailable
        }
        try checkSessionRestore(session)
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        guard let result = raw as? NSNumber, CFGetTypeID(result) == CFBooleanGetTypeID() else {
            throw CheckoutError.guestCheckoutUnavailable
        }
        // A successful click may have started navigation. Its result is a hint only;
        // the driver must observe a new validated phase before another action.
        if result.boolValue { return true }
        guard !webView.isLoading, webView.url == url, documentRevision == document else { return false }
        return false
    }
    func acknowledgeManualInput(market: Market) async throws {
        try Task.checkCancellation()
        if isCurrentPageNotFound(webView.url) { throw CheckoutError.pageNotFound }
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        guard !webView.isLoading, let url = webView.url, CheckoutPagePolicy.isStorefront(url, market: market)
        else { throw CheckoutError.manualInputRequired }
        let document = documentRevision, session = sessionRevision
        let raw = try await evaluator("""
        if (location.protocol !== 'https:' || !/(^|\\.)apple\\.com$/i.test(location.hostname) ||
            !location.pathname.startsWith(marketPath + '/shop/')) return false;
        const phase = window.__pickupPilot.snapshot().phase;
        if (phase === 'blocked') return 'blocked';
        if (phase === 'pageNotFound') return 'pageNotFound';
        if (phase === 'authentication') return 'guestCheckoutUnavailable';
        return window.__pickupPilot.acknowledgeManualInput();
        """, ["marketPath": market.storefrontPath])
        try checkSessionRestore(session)
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        guard !webView.isLoading, webView.url == url, documentRevision == document else { throw CheckoutError.manualInputRequired }
        if raw as? String == "blocked" { throw CheckoutError.storefrontBlocked }
        if raw as? String == "pageNotFound" { throw CheckoutError.pageNotFound }
        if raw as? String == "guestCheckoutUnavailable" { throw CheckoutError.guestCheckoutUnavailable }
        guard raw as? Bool == true
        else { throw CheckoutError.manualInputRequired }
    }
    func placeOrder(expected: CheckoutSnapshot) async throws -> Bool {
        try await executeOrder(expected: expected, authorization: nil)
    }
    func placeOrder(expected: CheckoutSnapshot, request: CheckoutRequest, review: CheckoutReview) async throws -> Bool {
        guard CheckoutPagePolicy.isDocumentID(review.documentID), review.documentID == expected.documentID,
              CheckoutPagePolicy.isDocumentID(review.reviewStateID), review.reviewStateID == expected.reviewStateID else { return false }
        let authorization: [String: Any] = [
            "attemptStart": request.attemptWindow.start.timeIntervalSince1970 * 1_000,
            "attemptEnd": request.attemptWindow.end.timeIntervalSince1970 * 1_000,
            "startMinute": request.attemptHours.startMinute, "endMinute": request.attemptHours.endMinute,
            "timeZone": request.timeZoneIdentifier, "reviewExpiresAt": review.expiresAt.timeIntervalSince1970 * 1_000
        ]
        return try await executeOrder(expected: expected, authorization: authorization)
    }
    private func executeOrder(expected: CheckoutSnapshot, authorization: [String: Any]?) async throws -> Bool {
        guard submissionAllowed else { return false }
        if isCurrentPageNotFound(webView.url) { throw CheckoutError.pageNotFound }
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        try Task.checkCancellation()
        guard !webView.isLoading, let url = webView.url, CheckoutPagePolicy.isAppleHTTPS(url),
              Self.evidenceURL(url) == expected.sourceURL, expected.phase == .review,
              CheckoutPagePolicy.isDocumentID(expected.documentID), CheckoutPagePolicy.isDocumentID(expected.reviewStateID) else { return false }
        let encoded = try JSONEncoder().encode(expected)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return false }
        // JSONEncoder omits nil optionals; the page emits explicit null dates for
        // pickup-when-ready. Preserve strict atomic equality for that same evidence.
        if expected.pickupStartISO == nil { object["pickupStartISO"] = NSNull() }
        if expected.pickupEndISO == nil { object["pickupEndISO"] = NSNull() }
        var arguments: [String: Any] = ["expected": object, "authorization": NSNull()]
        if let authorization { arguments["authorization"] = authorization }
        let raw = try await evaluator("""
        if (location.protocol !== 'https:' || !/(^|\\.)apple\\.com$/i.test(location.hostname) ||
            location.origin + location.pathname !== expected.sourceURL) return false;
        return window.__pickupPilot.submit(expected, authorization);
        """, arguments)
        return raw as? Bool == true
    }
    func restoreSession(_ data: Data?) async throws {
        sessionRevision += 1
        let revision = sessionRevision
        try checkSessionRestore(revision)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let existing = await store.allCookies()
        try checkSessionRestore(revision)
        for cookie in existing {
            await store.deleteCookie(cookie)
            try checkSessionRestore(revision)
        }
        guard let data else { return }
        let cookies = try JSONDecoder().decode([AppleSessionCookie].self, from: data)
        for value in cookies {
            guard let cookie = value.cookie(at: Date()) else { continue }
            await store.setCookie(cookie)
            try checkSessionRestore(revision)
        }
    }
    func sessionData() async throws -> Data {
        try Task.checkCancellation()
        let recovery = manualRecoveryDocument
        defer { if manualRecoveryDocument?.id == recovery?.id { manualRecoveryDocument = nil } }
        if let recovery { try checkManualRecoveryDocument(recovery) }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        try Task.checkCancellation()
        if let recovery { try checkManualRecoveryDocument(recovery) }
        return try JSONEncoder().encode(cookies.filter { AppleSessionCookie.isAppleDomain($0.domain) }.map(AppleSessionCookie.init))
    }
    func acknowledgeManualRecovery(market: Market) async throws {
        try Task.checkCancellation()
        manualRecoveryDocument = nil
        guard !webView.isLoading, !isCurrentPageNotFound(webView.url), let url = webView.url, CheckoutPagePolicy.isStorefront(url, market: market),
              url.path.lowercased().range(of: "/shop/(?:go/)?(?:403|404|429|541|error)(?:/|$)", options: .regularExpression) == nil
        else { throw CheckoutError.sessionRecoveryNotReady }
        let session = sessionRevision, document = documentRevision
        do {
            let raw = try await evaluator("""
            if (location.protocol !== 'https:' || !/(^|\\.)apple\\.com$/i.test(location.hostname) ||
                !location.pathname.startsWith(marketPath + '/shop/')) return null;
            return window.__pickupPilot.snapshot();
            """, ["marketPath": market.storefrontPath])
            try Task.checkCancellation()
            guard sessionRevision == session else { throw CheckoutError.cancelled }
            guard !webView.isLoading, webView.url == url, documentRevision == document,
                  let raw, JSONSerialization.isValidJSONObject(raw) else { throw CheckoutError.sessionRecoveryNotReady }
            var snapshot = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
            snapshot.sourceURL = Self.evidenceURL(url)
            ingestBlockingEvidence(snapshot)
            diagnostics?.recordSnapshot(snapshot)
            if snapshot.phase == .pageNotFound { throw CheckoutError.sessionRecoveryNotReady }
            if snapshot.blockingStatus.map({ [403, 429, 541].contains($0) }) == true,
               ["fetch", "xhr"].contains(snapshot.blockingSource ?? "") { throw CheckoutError.storefrontBlocked }
            if snapshot.phase == .authentication { throw CheckoutError.guestCheckoutUnavailable }
            guard [.product, .bag, .fulfillment, .contact, .payment, .review].contains(snapshot.phase),
                  !snapshot.hasErrors else { throw CheckoutError.sessionRecoveryNotReady }
            // A successful redirect never clears this latch. Only this explicit acknowledgement
            // of a stable, healthy document does; the page's JavaScript block flag stays untouched.
            storefrontBlocked = false
            mainFrameNotFound = false
            diagnostics?.clearActiveBlock()
            manualRecoveryDocument = (UUID(), url, session, document)
        } catch {
            try Task.checkCancellation()
            if sessionRevision != session { throw CheckoutError.cancelled }
            if (error as? CheckoutError) == .cancelled { throw error }
            if (error as? CheckoutError) == .storefrontBlocked { throw error }
            if (error as? CheckoutError) == .guestCheckoutUnavailable { throw error }
            throw CheckoutError.sessionRecoveryNotReady
        }
    }
    private func checkManualRecoveryDocument(_ recovery: (id: UUID, url: URL, session: Int, document: Int)) throws {
        try checkSessionRestore(recovery.session)
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        guard !webView.isLoading, webView.url == recovery.url,
              documentRevision == recovery.document else { throw CheckoutError.sessionRecoveryNotReady }
    }
    private func checkSessionRestore(_ revision: Int) throws {
        try Task.checkCancellation()
        guard sessionRevision == revision else { throw CheckoutError.cancelled }
    }
    private static func evidenceURL(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "about:blank" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.scheme?.lowercased() == "https", components.port == 443 { components.port = nil }
        return components.url?.absoluteString ?? "about:blank"
    }
    func cancel() {
        sessionRevision += 1; manualRecoveryDocument = nil
        for id in Array(changeWaiters.keys) { finishChangeWait(id, result: .failure(CheckoutError.cancelled)) }
        webView.stopLoading()
    }
    func clearPage() { cancel(); resetDiagnostics(); webView.loadHTMLString("", baseURL: nil) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        observeNavigationResponse(navigationResponse.response, isForMainFrame: navigationResponse.isForMainFrame)
        return .allow
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        documentRevision += 1
        mainFrameNotFound = false
        diagnostics?.recordNavigation(webView.url, resetStatus: true)
        signalPageChange()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { diagnostics?.recordNavigation(webView.url); signalPageChange() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { diagnostics?.recordNavigation(webView.url); signalPageChange() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { signalPageChange() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { signalPageChange() }
    func observeNavigationResponse(_ navigationResponse: URLResponse, isForMainFrame: Bool) {
        if isForMainFrame { documentRevision += 1 }
        if isForMainFrame, let response = navigationResponse as? HTTPURLResponse {
            diagnostics?.recordResponse(status: response.statusCode, source: .mainFrame, route: .classify(response.url))
            mainFrameNotFound = response.url.map(CheckoutPagePolicy.isAppleHTTPS) == true && response.statusCode == 404
        }
        if isForMainFrame, let response = navigationResponse as? HTTPURLResponse,
           let url = response.url, CheckoutPagePolicy.isAppleHTTPS(url), [403, 429, 541].contains(response.statusCode) {
            // Preserve this evidence through Apple's automatic security-error redirects.
            storefrontBlocked = true
        }
        if isForMainFrame { signalPageChange() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // Payment-provider challenges may navigate to their own HTTPS page. Automation never reads or fills there.
        return url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }
}

struct AppleSessionCookie: Codable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    var httpOnly: Bool
    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
    }
    static func isAppleDomain(_ domain: String) -> Bool {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }
    func cookie(at now: Date) -> HTTPCookie? {
        guard Self.isAppleDomain(domain), expires == nil || expires! > now else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}
