import Foundation
import PilotCore

/// Controls only the Safari window created for this checkout. Safari owns its
/// website data; this adapter never reads, exports, restores or clears cookies.
/// Safari has no document-start injection API here. Page guards are installed
/// after a validated Apple document is observed; native review-only submission
/// checks remain independent of those best-effort document guards.
@MainActor final class SafariAppleCheckoutPage: AppleCheckoutPage {
    let browserKind: CheckoutBrowserKind = .safari
    let usesBrowserManagedSession = true
    let diagnostics: CheckoutPageDiagnostics? = CheckoutPageDiagnostics()
    private let transport: any SafariControlling
    private let submissionAllowed: Bool
    private var ownedWindow: SafariWindowHandle?
    private var generation = 0
    private var active = false
    private var lastSnapshot: CheckoutSnapshot?
    private var storefrontBlocked = false
    private var cleanup: Task<Void, Never>?

    init(submissionAllowed: Bool = true, transport: any SafariControlling = SafariAutomation()) {
        self.submissionAllowed = submissionAllowed
        self.transport = transport
    }

    func load(_ url: URL) async throws {
        try Task.checkCancellation()
        guard CheckoutPagePolicy.isAppleHTTPS(url) else { throw CheckoutError.unsupportedPage }
        active = true
        let revision = generation
        if let cleanup { await cleanup.value; self.cleanup = nil; try check(revision) }
        let window: SafariWindowHandle
        if let ownedWindow { window = ownedWindow }
        else {
            let created = try await perform { try await self.transport.createWindow() }
            guard generation == revision, active, !Task.isCancelled else {
                // Creation finished after cancellation. It must never become the
                // next session's window or remain an untracked checkout window.
                try? await transport.close(created)
                throw CheckoutError.cancelled
            }
            ownedWindow = created
            window = created
        }
        try check(revision)
        storefrontBlocked = false
        lastSnapshot = nil
        diagnostics?.clearActiveBlock()
        try await perform { try await self.transport.navigate(url, in: window) }
        try check(revision)
        diagnostics?.recordNavigation(url, resetStatus: true)
    }

    func snapshot() async throws -> CheckoutSnapshot {
        let revision = generation
        try check(revision, requiresActive: false)
        guard let window = ownedWindow else { throw CheckoutError.safariWindowUnavailable }
        let observedURL = try await perform { try await self.transport.currentURL(in: window) }
        try check(revision, requiresActive: false)
        guard let url = observedURL, url.absoluteString != "about:blank" else {
            return CheckoutSnapshot(sourceURL: "about:blank", phase: .loading)
        }
        guard CheckoutPagePolicy.isAppleHTTPS(url) else { throw CheckoutError.unsupportedPage }
        let source = Self.evidenceURL(url)
        if CheckoutDiagnosticRoute.classify(url) == .pageNotFound {
            let value = applyingBlockingEvidence(CheckoutSnapshot(sourceURL: source, phase: .pageNotFound))
            lastSnapshot = value
            diagnostics?.recordNavigation(url, resetStatus: true)
            diagnostics?.recordSnapshot(value)
            return value
        }
        let object = try await evaluate(in: window, url: url, revision: revision, readOnly: true, body: "const value=window.__pickupPilot.snapshot(); if (document.readyState !== 'complete') value.phase='loading'; return value;")
        let after = try await perform { try await self.transport.currentURL(in: window) }
        try check(revision, requiresActive: false)
        guard after.map(Self.evidenceURL) == source else {
            lastSnapshot = nil
            return CheckoutSnapshot(sourceURL: Self.evidenceURL(after), phase: .loading)
        }
        guard let raw = object as? [String: Any], JSONSerialization.isValidJSONObject(raw) else { throw CheckoutError.unsupportedPage }
        var value: CheckoutSnapshot
        do { value = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONSerialization.data(withJSONObject: raw)) }
        catch { throw CheckoutError.unsupportedPage }
        // Native Safari metadata supplies the source identity. Never accept page
        // URLs with queries or fragments as retained checkout evidence.
        value.sourceURL = source
        if value.phase != .loading, !CheckoutPagePolicy.isDocumentID(value.documentID) { throw CheckoutError.unsupportedPage }
        if let status = value.blockingStatus, [403, 429, 541].contains(status),
           let sourceText = value.blockingSource, let source = CheckoutDiagnosticSource(rawValue: sourceText),
           source == .fetch || source == .xhr {
            diagnostics?.recordResponse(status: status, source: source, route: .classify(url))
            storefrontBlocked = true
        }
        value = applyingBlockingEvidence(value)
        diagnostics?.recordNavigation(url, resetStatus: true)
        diagnostics?.recordSnapshot(value)
        lastSnapshot = value
        if value.phase == .pageNotFound { return value }
        if storefrontBlocked { throw CheckoutError.storefrontBlocked }
        guard value.phase != .blocked else { throw CheckoutError.unsupportedPage }
        return value
    }

    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) async throws -> Bool {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { return false }
        let revision = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(min(timeout, 30)))
        repeat {
            try check(revision)
            if try await self.snapshot() != snapshot { return true }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero { return false }
            try await Task.sleep(for: min(remaining, .milliseconds(100)))
        } while ContinuousClock.now < deadline
        return false
    }

    func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool {
        let revision = generation
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        guard let previous = lastSnapshot, CheckoutPagePolicy.isDocumentID(previous.documentID) else { return false }
        if previous.phase == .pageNotFound { throw CheckoutError.pageNotFound }
        let (window, url) = try await currentAppleDocument(revision: revision, market: request.market)
        guard Self.evidenceURL(url) == previous.sourceURL else { return false }
        let payload: [String: Any] = [
            "sku": request.variant.id, "storeID": request.store.id, "marketPath": request.market.storefrontPath,
            "allowsUnscheduledPickup": request.allowsUnscheduledPickup,
            "pickupStart": request.pickupWindow.start.timeIntervalSince1970 * 1_000,
            "pickupEnd": request.pickupWindow.end.timeIntervalSince1970 * 1_000,
            "startMinute": request.pickupHours.startMinute, "endMinute": request.pickupHours.endMinute,
            "timeZone": request.timeZoneIdentifier,
            "profile": ["firstName": profile.givenName, "lastName": profile.familyName,
                        "emailAddress": profile.email, "email": profile.email,
                        "mobilePhone": profile.phone, "phoneNumber": profile.phone,
                        "cardholder": profile.cardholder, "cardNumber": profile.cardNumber,
                        "expiration": "\(profile.expiryMonth)/\(profile.expiryYear.suffix(2))", "securityCode": profile.cvv,
                        "street": profile.billingLine1, "street2": profile.billingLine2,
                        "city": profile.billingCity, "state": profile.billingRegion, "province": profile.billingRegion,
                        "postalCode": profile.billingPostalCode, "country": profile.billingCountry, "searchLocation": profile.searchLocation]
        ]
        return try await evaluate(in: window, url: url, revision: revision, documentID: previous.documentID,
                                  body: "return window.__pickupPilot.advance(\(try Self.json(payload)));", market: request.market) as? Bool == true
    }

    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) async throws -> Bool {
        let revision = generation
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        if snapshot.phase == .pageNotFound { throw CheckoutError.pageNotFound }
        guard snapshot.phase == .authentication, !snapshot.hasErrors, snapshot.finalActionCount == 0,
              CheckoutPagePolicy.isDocumentID(snapshot.documentID) else { return false }
        let (window, url) = try await currentAppleDocument(revision: revision, market: request.market)
        guard url.path == "\(request.market.storefrontPath)/shop/signIn", Self.evidenceURL(url) == snapshot.sourceURL else { return false }
        let payload: [String: Any] = ["marketPath": request.market.storefrontPath, "documentID": snapshot.documentID!]
        do {
            return try await evaluate(in: window, url: url, revision: revision, documentID: snapshot.documentID,
                                      body: "return window.__pickupPilot.continueAsGuest(\(try Self.json(payload)));", market: request.market) as? Bool == true
        } catch {
            try check(revision)
            if let failure = error as? CheckoutError, failure.isSafariFailure { throw failure }
            // A lost Apple Event result can follow a dispatched click. Never
            // report false and invite another guest click after that uncertainty.
            throw CheckoutError.guestCheckoutUnavailable
        }
    }

    func acknowledgeManualInput(market: Market) async throws {
        let revision = generation
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        let (window, url) = try await currentAppleDocument(revision: revision, market: market)
        let result = try await evaluate(in: window, url: url, revision: revision, body: """
        const phase = window.__pickupPilot.snapshot().phase;
        if (phase === 'authentication') return 'guestCheckoutUnavailable';
        if (phase === 'blocked') return 'blocked';
        if (phase === 'pageNotFound') return 'pageNotFound';
        return window.__pickupPilot.acknowledgeManualInput();
        """, market: market)
        if result as? String == "guestCheckoutUnavailable" { throw CheckoutError.guestCheckoutUnavailable }
        if result as? String == "blocked" { throw CheckoutError.storefrontBlocked }
        if result as? String == "pageNotFound" { throw CheckoutError.pageNotFound }
        guard result as? Bool == true else { throw CheckoutError.manualInputRequired }
    }

    func placeOrder(expected: CheckoutSnapshot) async throws -> Bool {
        // No request authorization means no order, even in an order-enabled page.
        false
    }

    func placeOrder(expected: CheckoutSnapshot, request: CheckoutRequest, review: CheckoutReview) async throws -> Bool {
        // This check precedes every transport operation, including URL metadata.
        // Review-only execution therefore cannot dispatch a final Apple Event.
        guard submissionAllowed else { return false }
        let revision = generation
        guard !storefrontBlocked else { throw CheckoutError.storefrontBlocked }
        try check(revision)
        guard expected.phase == .review, CheckoutPagePolicy.isDocumentID(expected.documentID),
              CheckoutPagePolicy.isDocumentID(expected.reviewStateID), review.documentID == expected.documentID,
              review.reviewStateID == expected.reviewStateID else { return false }
        try review.validate(for: request, at: Date())
        let (window, url) = try await currentAppleDocument(revision: revision, market: request.market)
        guard Self.evidenceURL(url) == expected.sourceURL else { return false }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! [String: Any]
        object["pickupStartISO"] = expected.pickupStartISO.map { $0 as Any } ?? NSNull()
        object["pickupEndISO"] = expected.pickupEndISO.map { $0 as Any } ?? NSNull()
        let authorization: [String: Any] = [
            "attemptStart": request.attemptWindow.start.timeIntervalSince1970 * 1_000,
            "attemptEnd": request.attemptWindow.end.timeIntervalSince1970 * 1_000,
            "startMinute": request.attemptHours.startMinute, "endMinute": request.attemptHours.endMinute,
            "timeZone": request.timeZoneIdentifier, "reviewExpiresAt": review.expiresAt.timeIntervalSince1970 * 1_000
        ]
        return try await evaluate(in: window, url: url, revision: revision, documentID: expected.documentID,
                                  body: "return window.__pickupPilot.submit(\(try Self.json(object)),\(try Self.json(authorization)));", market: request.market) as? Bool == true
    }

    func showBrowser() async throws {
        guard let ownedWindow else { throw CheckoutError.safariWindowUnavailable }
        try await perform { try await self.transport.activate(ownedWindow) }
    }

    func restoreSession(_ data: Data?) async throws {
        // Intentionally ignore legacy embedded-browser cookie bytes. Safari's
        // existing website session is managed by Safari and never serialized.
        try Task.checkCancellation()
    }
    func sessionData() async throws -> Data { throw CheckoutError.sessionStorage }

    func acknowledgeManualRecovery(market: Market) async throws {
        // Safari does not export a recovered session. This only verifies that the
        // owned window is currently a stable usable page before another attempt.
        active = true
        let blocked = storefrontBlocked
        storefrontBlocked = false
        do {
            let value = try await snapshot()
            guard let url = URL(string: value.sourceURL), CheckoutPagePolicy.isStorefront(url, market: market),
                  [.product, .bag, .fulfillment, .contact, .payment, .review].contains(value.phase), !value.hasErrors else {
                throw CheckoutError.sessionRecoveryNotReady
            }
            storefrontBlocked = false
            diagnostics?.clearActiveBlock()
        } catch {
            storefrontBlocked = blocked || storefrontBlocked
            if error as? CheckoutError == .cancelled { throw CheckoutError.cancelled }
            if let failure = error as? CheckoutError, failure.isSafariFailure { throw failure }
            throw CheckoutError.sessionRecoveryNotReady
        }
    }

    func resetDiagnostics() {
        storefrontBlocked = false
        lastSnapshot = nil
        diagnostics?.reset()
    }

    func cancel() {
        generation &+= 1
        active = false
        lastSnapshot = nil
        transport.cancel()
    }

    func clearPage() {
        // Detach synchronously: delayed close can only address the captured old
        // window, never one created by a subsequent load or reset.
        cancel()
        let closing = ownedWindow
        ownedWindow = nil
        resetDiagnostics()
        if let closing {
            let transport = transport
            let previous = cleanup
            cleanup = Task {
                if let previous { await previous.value }
                try? await transport.close(closing)
            }
        }
    }

    func resetBrowserSession() async throws {
        cancel()
        let closing = ownedWindow
        ownedWindow = nil
        resetDiagnostics()
        if let cleanup { await cleanup.value; self.cleanup = nil }
        if let closing { try await perform { try await self.transport.close(closing) } }
    }

    private func currentAppleDocument(revision: Int, market: Market? = nil) async throws -> (SafariWindowHandle, URL) {
        try check(revision)
        guard let window = ownedWindow else { throw CheckoutError.safariWindowUnavailable }
        let url = try await perform { try await self.transport.currentURL(in: window) }
        try check(revision)
        guard let url, CheckoutPagePolicy.isAppleHTTPS(url), market.map({ CheckoutPagePolicy.isStorefront(url, market: $0) }) ?? true else {
            throw CheckoutError.unsupportedPage
        }
        return (window, url)
    }

    /// Native metadata and a same-turn JavaScript URL/document check both apply.
    /// Payloads exist only in memory and are never logged or written to a script file.
    private func evaluate(in window: SafariWindowHandle, url: URL, revision: Int, documentID: String? = nil, readOnly: Bool = false,
                          body: String, market: Market? = nil) async throws -> Any? {
        try check(revision, requiresActive: !readOnly)
        let source = try Self.json(Self.evidenceURL(url))
        let marketGuard = try market.map { "if (!location.pathname.startsWith(\(try Self.json($0.storefrontPath + "/shop/")))) return JSON.stringify({ok:false});" } ?? ""
        let documentGuard = try documentID.map { "if (window.__pickupPilot.snapshot().documentID !== \(try Self.json($0))) return JSON.stringify({ok:false});" } ?? ""
        let reviewGuard = submissionAllowed ? "" : """
        if (window.__pickupPilotReviewOnly !== true) Object.defineProperty(window,'__pickupPilotReviewOnly',{value:true,writable:false,configurable:false});
        """
        let script = """
        (() => {
          if (location.protocol !== 'https:' || !/(^|\\.)apple\\.com$/i.test(location.hostname) ||
              location.username || location.password || (location.port && location.port !== '443') ||
              location.origin + location.pathname !== \(source)) return JSON.stringify({ok:false});
          \(marketGuard)
          \(reviewGuard)
          if (!window.__pickupPilot) { \(AppleCheckoutScripts.bootstrap) }
          if (!window.__pickupPilot) return JSON.stringify({ok:false});
          \(documentGuard)
          const value = (() => { \(body) })();
          return JSON.stringify({ok:true,value});
        })()
        """
        let encoded = try await perform { try await self.transport.evaluate(script: script, in: window) }
        try check(revision, requiresActive: !readOnly)
        guard let bytes = encoded.data(using: .utf8), bytes.count <= 128_000,
              let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(envelope.keys).isSubset(of: ["ok", "value"]), envelope["ok"] as? Bool == true else {
            throw CheckoutError.unsupportedPage
        }
        return envelope["value"]
    }

    private func check(_ revision: Int, requiresActive: Bool = true) throws {
        try Task.checkCancellation()
        guard (!requiresActive || active), generation == revision else { throw CheckoutError.cancelled }
    }
    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is CancellationError { throw CheckoutError.cancelled }
        catch let error as CheckoutError { throw error }
        catch let error as SafariAutomationError {
            switch error {
            case .cancelled: throw CheckoutError.cancelled
            case .unavailable: throw CheckoutError.safariUnavailable
            case .permissionDenied: throw CheckoutError.safariPermissionRequired
            case .javascriptDisabled: throw CheckoutError.safariJavaScriptDisabled
            case .windowLost, .ambiguousWindow: throw CheckoutError.safariWindowUnavailable
            default: throw CheckoutError.safariAutomationFailed
            }
        }
        catch { throw CheckoutError.safariAutomationFailed }
    }
    private func applyingBlockingEvidence(_ snapshot: CheckoutSnapshot) -> CheckoutSnapshot {
        var value = snapshot
        value.blockingStatus = diagnostics?.blockingStatus
        value.blockingSource = diagnostics?.blockingSource?.rawValue
        return value
    }
    private static func evidenceURL(_ url: URL?) -> String {
        guard let url, var value = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "about:blank" }
        value.user = nil; value.password = nil; value.query = nil; value.fragment = nil
        value.scheme = value.scheme?.lowercased(); value.host = value.host?.lowercased()
        if value.scheme == "https", value.port == 443 { value.port = nil }
        return value.string ?? "about:blank"
    }
    private static func json(_ object: Any) throws -> String {
        do { return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self) }
        catch { throw CheckoutError.unsupportedPage }
    }
}
