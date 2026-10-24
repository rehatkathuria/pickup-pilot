import Foundation
import WebKit
import PilotCore

enum CheckoutBrowserKind: Equatable, Sendable { case safari, embeddedFixture }

/// Narrow, replaceable browser boundary. Synthetic page clients exercise coordinator paths without orders.
@MainActor protocol AppleCheckoutPage: AnyObject {
    var browserKind: CheckoutBrowserKind { get }
    var usesBrowserManagedSession: Bool { get }
    var diagnostics: CheckoutPageDiagnostics? { get }
    func showBrowser() async throws
    func resetBrowserSession() async throws
    func resetDiagnostics()
    func load(_ url: URL) async throws
    func snapshot() async throws -> CheckoutSnapshot
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) async throws -> Bool
    func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool
    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) async throws -> Bool
    func placeOrder(expected: CheckoutSnapshot) async throws -> Bool
    func placeOrder(expected: CheckoutSnapshot, request: CheckoutRequest, review: CheckoutReview) async throws -> Bool
    func restoreSession(_ data: Data?) async throws
    func sessionData() async throws -> Data
    func acknowledgeManualRecovery(market: Market) async throws
    func acknowledgeManualInput(market: Market) async throws
    func recoverCheckoutNavigation(request: CheckoutRequest) async throws -> Bool
    func cancel()
    func clearPage()
}
extension AppleCheckoutPage {
    var browserKind: CheckoutBrowserKind { .embeddedFixture }
    var usesBrowserManagedSession: Bool { false }
    func showBrowser() async throws {}
    func resetBrowserSession() async throws { try await restoreSession(nil); clearPage() }
    var diagnostics: CheckoutPageDiagnostics? { nil }
    func resetDiagnostics() {}
    func continueAsGuest(request: CheckoutRequest, snapshot: CheckoutSnapshot) async throws -> Bool { false }
    func clearPage() { cancel() }
    func acknowledgeManualRecovery(market: Market) async throws { throw CheckoutError.sessionRecoveryNotReady }
    func acknowledgeManualInput(market: Market) async throws {}
    func recoverCheckoutNavigation(request: CheckoutRequest) async throws -> Bool { false }
    func waitForChange(after snapshot: CheckoutSnapshot, timeout: TimeInterval) async throws -> Bool {
        try await AppleCheckoutTiming.waitForFallback(timeout: timeout)
    }
    func placeOrder(expected: CheckoutSnapshot, request: CheckoutRequest, review: CheckoutReview) async throws -> Bool {
        try await placeOrder(expected: expected)
    }
}

@MainActor final class AppleCheckoutDriver: CheckoutDriver {
    // Native WebKit exists only for injected fixtures and legacy adapter tests.
    // A production Safari driver never constructs or accesses this compatibility view.
    private var embeddedFixtureView: WKWebView?
    var webView: WKWebView {
        if let embeddedFixtureView { return embeddedFixtureView }
        let fixture = WKWebView()
        embeddedFixtureView = fixture
        return fixture
    }
    private let vault: any SecureVault
    private let page: any AppleCheckoutPage
    private let now: () -> Date
    private let monotonicNow: () -> ContinuousClock.Instant
    private let sleep: (() async throws -> Void)?
    private var activeRequest: CheckoutRequest?
    private var pendingReview: CheckoutReview?
    private var reviewAwaitingConfirmation: CheckoutReview?
    private var manualInputAwaiting = false
    private var guestContinuationAttempted = false
    private var emptyBagRecoveryCount = 0
    private var emptyBagRecoveryDocumentID: String?
    private var guestResetAfterBagRecovery = false
    private var browserRecoveryCount = 0
    private var bagCheckoutDispatched = false
    private var cancelled = false
    private var submissionStarted = false
    private var operationInFlight = false
    private var sessionResetInFlight = false

    var requiresPaymentConfirmation: Bool { reviewAwaitingConfirmation != nil }
    var diagnostics: CheckoutPageDiagnostics? { page.diagnostics }
    var browserKind: CheckoutBrowserKind { page.browserKind }
    var usesBrowserManagedSession: Bool { page.usesBrowserManagedSession }
    var hasEmbeddedBrowser: Bool { embeddedFixtureView != nil }

    func showBrowser() async throws { try await page.showBrowser() }

    /// Capture teardown synchronously before another rehearsal can begin.
    func endReviewOnlySession() { cancel(); page.clearPage() }

    static func safari(vault: any SecureVault, submissionAllowed: Bool = true) -> AppleCheckoutDriver {
        AppleCheckoutDriver(vault: vault, page: SafariAppleCheckoutPage(submissionAllowed: submissionAllowed))
    }

    convenience init(vault: any SecureVault) {
        let browser = WKAppleCheckoutPage()
        self.init(vault: vault, page: browser, webView: browser.webView)
    }

    init(vault: any SecureVault, page: any AppleCheckoutPage, webView: WKWebView? = nil,
         now: @escaping () -> Date = Date.init,
         sleep: (() async throws -> Void)? = nil,
         monotonicNow: @escaping () -> ContinuousClock.Instant = AppleCheckoutTiming.monotonicNow) {
        self.vault = vault; self.page = page; self.embeddedFixtureView = webView; self.now = now; self.sleep = sleep
        self.monotonicNow = monotonicNow
    }

    func prepare(request: CheckoutRequest, profile: SecureProfile) async throws -> CheckoutReview {
        try Task.checkCancellation()
        guard !operationInFlight, !sessionResetInFlight, !submissionStarted else { throw CheckoutError.unsafeReview }
        guard CheckoutPagePolicy.isStorefront(request.variant.productURL, market: request.market),
              !request.maximumTotal.isNaN, request.maximumTotal > 0 else { throw CheckoutError.unsafeReview }
        operationInFlight = true
        defer { operationInFlight = false }
        cancelled = false
        pendingReview = nil
        let preparationDeadline = now().addingTimeInterval(30)
        let monotonicDeadline = monotonicNow().advanced(by: .seconds(30))
        if activeRequest != request {
            reviewAwaitingConfirmation = nil
            manualInputAwaiting = false
            guestContinuationAttempted = false
            emptyBagRecoveryCount = 0
            emptyBagRecoveryDocumentID = nil
            guestResetAfterBagRecovery = false
            browserRecoveryCount = 0
            bagCheckoutDispatched = false
            page.cancel()
            page.resetDiagnostics()
            if !page.usesBrowserManagedSession {
                let session = try await vault.loadSession()
                try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
                try await page.restoreSession(session)
            }
            try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
            let bagURL = URL(string: "https://www.apple.com\(request.market.storefrontPath)/shop/bag")!
            diagnostics?.recordAction(.openingBag)
            do { try await page.load(bagURL) }
            catch CheckoutError.safariWindowUnavailable { try await reconnectBrowser(request: request) }
            try checkCancellation()
            activeRequest = request
            do {
                _ = try await wait(after: CheckoutSnapshot(sourceURL: bagURL.absoluteString, phase: .loading), until: preparationDeadline, monotonic: monotonicDeadline)
            } catch CheckoutError.safariWindowUnavailable {
                try await reconnectBrowser(request: request)
                try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
            }
        } else if manualInputAwaiting {
            // The coordinator/rehearsal pauses after a handoff. Only a subsequent user-triggered
            // preparation may re-enable an unchanged nonfinal form after the user corrected it.
            do { try await page.acknowledgeManualInput(market: request.market) }
            catch CheckoutError.safariWindowUnavailable { try await reconnectBrowser(request: request) }
            catch CheckoutError.safariNavigationChanged { /* Reobserve the changed form below. */ }
            try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
            manualInputAwaiting = false
        }
        var stalledSince: Date?
        var stalledMonotonic: ContinuousClock.Instant?
        var stalledTimeouts = 0
        var fallbackTimeouts = 0
        var guestTransitionPending = false
        var guestTransitionStarted: ContinuousClock.Instant?
        var guestTimeouts = 0
        var guestReadinessDeadline: Date?
        var guestReadinessMonotonicDeadline: ContinuousClock.Instant?
        var guestReadinessTimeouts = 0
        while fallbackTimeouts < 50 {
            do {
                try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
                let snapshot: CheckoutSnapshot
                do { snapshot = try await page.snapshot() }
                catch CheckoutError.storefrontBlocked where guestContinuationAttempted { throw CheckoutError.guestCheckoutRefused }
                try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
                if !guestContinuationAttempted, snapshot.phase == .loading {
                    guestReadinessDeadline = nil
                    guestReadinessMonotonicDeadline = nil
                    guestReadinessTimeouts = 0
                }
                if guestContinuationAttempted, [.pageNotFound, .blocked].contains(snapshot.phase),
                   snapshot.blockingStatus.map({ [403, 429, 541].contains($0) }) == true {
                    // Apple's own access response to the single guest dispatch. Never redispatched.
                    throw CheckoutError.guestCheckoutRefused
                }
                if guestTransitionPending {
                    if snapshot.phase == .pageNotFound { throw CheckoutError.pageNotFound }
                    if snapshot.phase == .blocked { throw CheckoutError.storefrontBlocked }
                    if snapshot.phase == .loading {
                        // An actual outstanding guest request/navigation may use the full
                        // preparation deadline. It cannot authorize another dispatch.
                        guestTransitionStarted = nil
                        guestTimeouts = 0
                    } else if [.authentication, .unknown].contains(snapshot.phase) {
                        if guestTransitionStarted == nil { guestTransitionStarted = monotonicNow() }
                        if guestTimeouts >= 5 ||
                            guestTransitionStarted.map({ $0.duration(to: monotonicNow()) >= .seconds(AppleCheckoutTiming.stalledInterval) }) == true {
                            if snapshot.phase == .unknown { throw CheckoutError.unsupportedPage }
                            throw CheckoutError.guestCheckoutUnavailable
                        }
                    } else { guestTransitionPending = false }
                }
                var madeProgress = false
                var waitingForGuestReadiness = false
                if snapshot.phase != .bag, snapshot.phase != .loading { bagCheckoutDispatched = false }
                if snapshot.phase != .review, snapshot.phase != .loading { reviewAwaitingConfirmation = nil }
                if [.bag, .product, .fulfillment, .contact, .payment].contains(snapshot.phase) {
                    guard let url = URL(string: snapshot.sourceURL), CheckoutPagePolicy.isStorefront(url, market: request.market) else { throw CheckoutError.unsupportedPage }
                }
                switch snapshot.phase {
                case .loading: break
                case .blocked: throw CheckoutError.storefrontBlocked
                case .pageNotFound: throw CheckoutError.pageNotFound
                case .authentication:
                    let expectedPath = "\(request.market.storefrontPath)/shop/signIn"
                    let signIn = URL(string: snapshot.sourceURL)
                    let healthySignIn = signIn.map { CheckoutPagePolicy.isStorefront($0, market: request.market) && $0.path == expectedPath } == true &&
                        snapshot.finalActionCount == 0 && !snapshot.hasErrors && CheckoutPagePolicy.isDocumentID(snapshot.documentID)
                    guard healthySignIn else { throw CheckoutError.guestCheckoutUnavailable }
                    if !guestContinuationAttempted {
                        if guestReadinessDeadline == nil {
                            guestReadinessDeadline = now().addingTimeInterval(10)
                            guestReadinessMonotonicDeadline = monotonicNow().advanced(by: .seconds(10))
                        }
                        guard let deadline = guestReadinessDeadline, let monotonic = guestReadinessMonotonicDeadline,
                              guestReadinessTimeouts < 17, now() < deadline,
                              monotonicNow() < monotonic else { throw CheckoutError.guestCheckoutUnavailable }
                        diagnostics?.recordAction(.continuingAsGuest)
                        do { madeProgress = try await page.continueAsGuest(request: request, snapshot: snapshot) }
                        catch CheckoutError.safariNavigationChanged {
                            // The click may already have reached Safari. Consume it and observe
                            // the destination; never redispatch an uncertain guest action.
                            madeProgress = true
                        }
                        // A confirmed dispatch is consumed even if cancellation or the
                        // preparation deadline is detected immediately after its result.
                        if madeProgress { guestContinuationAttempted = true }
                        try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
                        if madeProgress {
                            // Only an affirmative dispatch consumes the attempt. Explicit
                            // false means the hydrating control was not clicked; retry only
                            // readiness. The page also latches the actual control once.
                            guestTransitionPending = true
                            guestTransitionStarted = monotonicNow()
                        } else { waitingForGuestReadiness = true }
                    } else if !guestTransitionPending { throw CheckoutError.guestCheckoutUnavailable }
                case .unavailable: throw CheckoutError.unavailable
                case .confirmation:
                    // A previously completed checkout is never a reason to create another order.
                    throw CheckoutError.unsafeReview
                case .review:
                    diagnostics?.recordAction(.awaitingReview)
                    manualInputAwaiting = false
                    let awaiting = reviewAwaitingConfirmation
                    reviewAwaitingConfirmation = nil
                    let review = try CheckoutPagePolicy.review(from: snapshot, request: request, now: now())
                    try await saveSession()
                    try review.validate(for: request, at: now())
                    if let awaiting, now() < awaiting.expiresAt, sameReview(awaiting, review) {
                        pendingReview = awaiting
                        return awaiting
                    }
                    // Payment identity is not authoritative in the parsed review. Require an explicit
                    // human confirmation of this exact review before any final-submit capability exists.
                    reviewAwaitingConfirmation = review
                    throw CheckoutError.manualInputRequired
                case .bag where snapshot.bagIsEmpty:
                    guard snapshot.productIDs.isEmpty, snapshot.quantities.isEmpty, !snapshot.hasErrors,
                          snapshot.finalActionCount == 0, CheckoutPagePolicy.isDocumentID(snapshot.documentID) else {
                        throw CheckoutError.unsafeReview
                    }
                    // The old empty document can remain visible while Safari starts navigation.
                    // Only a different verified bag document, or a bag validated below, may
                    // authorize another refill. The budget survives manual-input/review pauses.
                    if emptyBagRecoveryDocumentID != snapshot.documentID {
                        guard emptyBagRecoveryCount < 3 else { throw CheckoutError.unsupportedPage }
                        emptyBagRecoveryCount += 1
                        bagCheckoutDispatched = false
                        emptyBagRecoveryDocumentID = snapshot.documentID
                        guestResetAfterBagRecovery = guestContinuationAttempted
                        diagnostics?.recordAction(.restoringBag)
                        try await page.load(request.variant.productURL)
                        madeProgress = true
                    }
                case .bag:
                    guard snapshot.productIDs == [request.variant.id], snapshot.quantities == [1], !snapshot.hasErrors else {
                        throw CheckoutError.unsafeReview
                    }
                    if emptyBagRecoveryDocumentID != nil || guestResetAfterBagRecovery {
                        guard !snapshot.hasErrors, snapshot.finalActionCount == 0,
                              CheckoutPagePolicy.isDocumentID(snapshot.documentID) else { throw CheckoutError.unsafeReview }
                        emptyBagRecoveryDocumentID = nil
                        if guestResetAfterBagRecovery {
                            // A replenished, verified bag starts a new nonfinal checkout flow.
                            // Never reset this while navigation could still show an old sign-in.
                            guestContinuationAttempted = false
                            guestTransitionPending = false
                            guestTransitionStarted = nil
                            guestTimeouts = 0
                            guestReadinessDeadline = nil
                            guestReadinessMonotonicDeadline = nil
                            guestReadinessTimeouts = 0
                        }
                        guestResetAfterBagRecovery = false
                    }
                    diagnostics?.recordAction(.openingCheckout)
                    madeProgress = try await advance(request: request, profile: profile)
                    bagCheckoutDispatched = bagCheckoutDispatched || madeProgress
                case .product:
                    guard !snapshot.hasErrors else { throw CheckoutError.unsupportedPage }
                    diagnostics?.recordAction(.addingItem)
                    madeProgress = try await advance(request: request, profile: profile)
                case .fulfillment, .contact, .payment:
                    diagnostics?.recordAction(snapshot.phase == .fulfillment ? .selectingPickup : snapshot.phase == .contact ? .enteringContact : .enteringPayment)
                    if snapshot.hasErrors {
                        try await saveSession()
                        manualInputAwaiting = true
                        throw CheckoutError.manualInputRequired
                    }
                    madeProgress = try await advance(request: request, profile: profile)
                case .unknown: break
                }
                try checkCancellation()
                if madeProgress || snapshot.phase == .loading || waitingForGuestReadiness {
                    stalledSince = nil
                    stalledMonotonic = nil
                    stalledTimeouts = 0
                } else if stalledSince == nil {
                    stalledSince = now()
                    stalledMonotonic = monotonicNow()
                }
                let changed = try await wait(after: snapshot, until: preparationDeadline, monotonic: monotonicDeadline)
                if !changed {
                    fallbackTimeouts += 1
                    if stalledSince != nil { stalledTimeouts += 1 }
                    if guestTransitionPending && snapshot.phase != .loading { guestTimeouts += 1 }
                    if waitingForGuestReadiness { guestReadinessTimeouts += 1 }
                }
                // Hints can arrive rapidly during DOM updates. Only elapsed time or actual bounded
                // timeout waits count as a stall; a burst of observer messages cannot exhaust retries.
                let monotonicStall = stalledMonotonic.map { $0.duration(to: monotonicNow()) >= .seconds(AppleCheckoutTiming.stalledInterval) } ?? false
                if let beganStalling = stalledSince, stalledTimeouts >= 5 || monotonicStall || now().timeIntervalSince(beganStalling) >= AppleCheckoutTiming.stalledInterval {
                    if snapshot.phase == .bag, bagCheckoutDispatched, page.browserKind == .safari {
                        // A merchant popup may leave the old bag on screen. If its handoff
                        // cannot be proven, continue from a new owned bag rather than adopt
                        // an unrelated tab or repeat the old document's checkout click.
                        try await reconnectBrowser(request: request)
                        try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
                        stalledSince = nil
                        stalledMonotonic = nil
                        stalledTimeouts = 0
                        continue
                    }
                    if guestTransitionPending {
                        if snapshot.phase == .unknown { throw CheckoutError.unsupportedPage }
                        throw CheckoutError.guestCheckoutUnavailable
                    }
                    if [.fulfillment, .contact, .payment].contains(snapshot.phase) {
                        try await saveSession()
                        manualInputAwaiting = true
                        throw CheckoutError.manualInputRequired
                    }
                    throw CheckoutError.unsupportedPage
                }
            } catch CheckoutError.safariWindowUnavailable {
                try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
                try await reconnectBrowser(request: request)
                try checkPreparationDeadline(preparationDeadline, monotonic: monotonicDeadline)
                stalledSince = nil
                stalledMonotonic = nil
                stalledTimeouts = 0
            }
        }
        throw CheckoutError.unsupportedPage
    }

    func submit(review: CheckoutReview) async throws -> CheckoutOutcome {
        try checkCancellation()
        guard !operationInFlight, !sessionResetInFlight, !submissionStarted, let request = activeRequest,
              pendingReview == review else { throw CheckoutError.unsafeReview }
        operationInFlight = true
        defer { operationInFlight = false }
        try review.validate(for: request, at: now())
        let before = try await page.snapshot()
        try checkCancellation()
        try review.validate(for: request, at: now())
        guard request.permitsAttempt(at: now()) else { throw CheckoutError.expiredReview }
        guard !submissionStarted, pendingReview == review, activeRequest == request else { throw CheckoutError.unsafeReview }
        if before.phase == .authentication { return .requiresAuthentication }
        let latest = try CheckoutPagePolicy.review(from: before, request: request, now: now())
        guard sameReview(latest, review) else { throw CheckoutError.unsafeReview }
        // Consume in memory BEFORE touching the browser. The coordinator also holds a durable journal lock.
        submissionStarted = true
        pendingReview = nil
        do {
            guard try await page.placeOrder(expected: before, request: request, review: review) else { return .indeterminate(reason: "The order control changed. Check Apple order status before any new attempt.") }
            let confirmationDeadline = now().addingTimeInterval(18)
            let confirmationMonotonicDeadline = monotonicNow().advanced(by: .seconds(18))
            var observation = before
            var fallbackTimeouts = 0
            while fallbackTimeouts < 30, now() < confirmationDeadline, monotonicNow() < confirmationMonotonicDeadline {
                try checkCancellation()
                let changed = try await wait(after: observation, until: confirmationDeadline, monotonic: confirmationMonotonicDeadline)
                if !changed { fallbackTimeouts += 1 }
                try checkCancellation()
                let after = try await page.snapshot()
                if let orderID = CheckoutPagePolicy.confirmation(from: after, market: request.market) {
                    try await saveSession()
                    return .confirmed(orderID: orderID)
                }
                if after.phase == .authentication { return .requiresAuthentication }
                if after.phase == .unavailable { return .unavailable }
                if after.phase == .pageNotFound || after.phase == .blocked {
                    return .indeterminate(reason: "Apple returned an error page after submission began. Check Apple order status; automatic retry is locked.")
                }
                observation = after
            }
            return .indeterminate(reason: "Apple did not provide a verified order number. Check order status; automatic retry is locked.")
        } catch {
            return .indeterminate(reason: "The connection ended after submission began. Check Apple order status; automatic retry is locked.")
        }
    }

    /// A browser refresh can recover a confirmed order after 3-D Secure without ever clicking Place Order again.
    func recoverOutcome() async throws -> CheckoutOutcome {
        guard !operationInFlight, !sessionResetInFlight, submissionStarted, let request = activeRequest else { throw CheckoutError.unsafeReview }
        operationInFlight = true
        defer { operationInFlight = false }
        let snapshot = try await page.snapshot()
        guard submissionStarted, activeRequest == request else { throw CheckoutError.unsafeReview }
        if let id = CheckoutPagePolicy.confirmation(from: snapshot, market: request.market) { return .confirmed(orderID: id) }
        return snapshot.phase == .authentication ? .requiresAuthentication : .indeterminate(reason: "No verified order confirmation is visible. Check Apple order status.")
    }

    /// Explicit user action only: preserve the repaired browser's cookies for a later normal attempt.
    func recoverSessionAfterManualInput(market: Market) async throws {
        try await preserveManuallyRecoveredSession(market: market, resuming: nil)
    }

    /// Explicit user action only: a subsequent preparation may continue this same document.
    func resumeAfterManualRecovery(request: CheckoutRequest) async throws {
        guard CheckoutPagePolicy.isStorefront(request.variant.productURL, market: request.market),
              !request.maximumTotal.isNaN, request.maximumTotal > 0 else { throw CheckoutError.unsafeReview }
        try await preserveManuallyRecoveredSession(market: request.market, resuming: request)
    }

    /// Explicit navigation only: it does not restore/save a session or start another purchase attempt.
    func returnToBag(market: Market) async throws {
        try Task.checkCancellation()
        guard !operationInFlight, !sessionResetInFlight, !submissionStarted else { throw CheckoutError.unsafeReview }
        operationInFlight = true
        defer { operationInFlight = false }
        cancel()
        cancelled = false
        activeRequest = nil
        guestContinuationAttempted = false
        page.resetDiagnostics()
        diagnostics?.recordAction(.openingBag)
        let bagURL = URL(string: "https://www.apple.com\(market.storefrontPath)/shop/bag")!
        try await page.load(bagURL)
        try checkCancellation()
    }

    private func preserveManuallyRecoveredSession(market: Market, resuming request: CheckoutRequest?) async throws {
        try Task.checkCancellation()
        guard !operationInFlight, !sessionResetInFlight, !submissionStarted else { throw CheckoutError.unsafeReview }
        operationInFlight = true
        defer { operationInFlight = false }
        cancelled = false
        pendingReview = nil
        reviewAwaitingConfirmation = nil
        manualInputAwaiting = false
        activeRequest = nil
        if page.usesBrowserManagedSession {
            try await page.acknowledgeManualRecovery(market: market)
            try checkCancellation()
            activeRequest = request
            return
        }
        let documentURL = webView.url
        try await page.acknowledgeManualRecovery(market: market)
        try checkRecoveryDocument(documentURL)
        let data = try await page.sessionData()
        try checkRecoveryDocument(documentURL)
        do { try await vault.saveSession(data) }
        catch {
            try checkCancellation()
            if error is CancellationError { throw error }
            throw CheckoutError.sessionStorage
        }
        try checkRecoveryDocument(documentURL)
        activeRequest = request
    }

    private func checkRecoveryDocument(_ expectedURL: URL?) throws {
        try checkCancellation()
        guard !webView.isLoading, webView.url == expectedURL else { throw CheckoutError.sessionRecoveryNotReady }
    }

    func cancel() {
        cancelled = true
        pendingReview = nil
        reviewAwaitingConfirmation = nil
        manualInputAwaiting = false
        if !submissionStarted { activeRequest = nil }
        // submissionStarted intentionally survives cancellation: cancellation cannot prove Apple did not charge.
        page.cancel()
    }

    func clearSession() async throws {
        guard !sessionResetInFlight else { throw CheckoutError.unsafeReview }
        sessionResetInFlight = true
        defer { sessionResetInFlight = false }
        cancel()
        activeRequest = nil
        try await page.resetBrowserSession()
    }

    /// Called only after the coordinator's durable order journal has been explicitly reconciled and reset.
    func resetAfterReconciliation() async throws {
        try await clearSession()
        submissionStarted = false
    }

    private func checkCancellation() throws {
        guard !cancelled, !Task.isCancelled else { throw CheckoutError.cancelled }
    }
    private func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool {
        do { return try await page.advance(request: request, profile: profile) }
        catch CheckoutError.safariNavigationChanged {
            // Reobserve after a potentially delivered nonfinal action. The document's
            // action latch remains consumed if Safari already dispatched its click.
            return true
        }
    }
    private func reconnectBrowser(request: CheckoutRequest) async throws {
        try checkCancellation()
        guard !submissionStarted, browserRecoveryCount < 2 else { throw CheckoutError.safariWindowUnavailable }
        browserRecoveryCount += 1
        guard try await page.recoverCheckoutNavigation(request: request) else { throw CheckoutError.safariWindowUnavailable }
        try checkCancellation()
        pendingReview = nil
        reviewAwaitingConfirmation = nil
        manualInputAwaiting = false
        guestResetAfterBagRecovery = guestContinuationAttempted
        bagCheckoutDispatched = false
    }
    private func checkPreparationDeadline(_ deadline: Date, monotonic: ContinuousClock.Instant) throws {
        try checkCancellation()
        guard now() < deadline, monotonicNow() < monotonic else { throw CheckoutError.unsupportedPage }
    }
    private func wait(after snapshot: CheckoutSnapshot, until deadline: Date, monotonic: ContinuousClock.Instant) async throws -> Bool {
        try checkCancellation()
        let remaining = min(deadline.timeIntervalSince(now()), AppleCheckoutTiming.seconds(monotonicNow().duration(to: monotonic)))
        guard remaining > 0 else { throw CheckoutError.unsupportedPage }
        let changed: Bool
        if let sleep {
            try await sleep()
            changed = false
        } else {
            changed = try await page.waitForChange(after: snapshot, timeout: min(remaining, AppleCheckoutTiming.fallbackInterval))
        }
        try checkCancellation()
        return changed
    }
    private func sameReview(_ left: CheckoutReview, _ right: CheckoutReview) -> Bool {
        left.pickupIsUnscheduled == right.pickupIsUnscheduled && left.documentID == right.documentID && left.reviewStateID == right.reviewStateID && left.sourceURL == right.sourceURL && left.variantID == right.variantID && left.storeID == right.storeID &&
        left.quantity == right.quantity && left.total == right.total && left.currencyCode == right.currencyCode &&
        left.pickupDate == right.pickupDate && left.pickupEndDate == right.pickupEndDate && left.pickupSlot == right.pickupSlot
    }
    private func saveSession() async throws {
        guard !page.usesBrowserManagedSession else { try checkCancellation(); return }
        do {
            let data = try await page.sessionData()
            try checkCancellation()
            try await vault.saveSession(data)
            try checkCancellation()
        } catch {
            try checkCancellation()
            if error is CancellationError { throw error }
            throw CheckoutError.sessionStorage
        }
    }
}
