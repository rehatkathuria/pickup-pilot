import Foundation
import Observation
import PilotCore
import WebKit

/// This boundary exposes preparation, explicit session recovery and cancellation only.
@MainActor protocol CheckoutRehearsalPreparing: AnyObject {
    var diagnostics: CheckoutPageDiagnostics? { get }
    var browserKind: CheckoutBrowserKind { get }
    func showBrowser() async throws
    func endReviewOnlySession()
    func prepare(request: CheckoutRequest, profile: SecureProfile) async throws -> CheckoutReview
    func resumeAfterManualRecovery(request: CheckoutRequest) async throws
    func cancel()
}
extension CheckoutRehearsalPreparing {
    var diagnostics: CheckoutPageDiagnostics? { nil }
    var browserKind: CheckoutBrowserKind { .embeddedFixture }
    func showBrowser() async throws {}
    func endReviewOnlySession() {}
    func resumeAfterManualRecovery(request: CheckoutRequest) async throws { throw CheckoutError.sessionRecoveryNotReady }
}
extension AppleCheckoutDriver: CheckoutRehearsalPreparing {}

private struct RehearsalRecoveryUnresolved: Error {}

/// Legacy fixture session bytes stay in memory. Safari owns its website session and does not export it here.
private actor RehearsalSessionVault: SecureVault {
    private var session: Data?
    func saveProfile(_ profile: SecureProfile) throws { throw CheckoutError.sessionStorage }
    func loadProfile() -> SecureProfile? { nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) { session = data }
    func loadSession() -> Data? { session }
    func deleteSession() { session = nil }
    func saveOrderState(_ data: Data) throws { throw CheckoutError.sessionStorage }
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() { session = nil }
}

@MainActor
@Observable
final class CheckoutRehearsal {
    enum State: Equatable {
        case idle, preparing, authenticationRequired, manualInputRequired, reviewReady, blocked, failed
    }

    private(set) var state: State = .idle
    private(set) var detail: String
    private(set) var review: CheckoutReview?
    let embeddedWebView: WKWebView?
    private let driver: any CheckoutRehearsalPreparing
    private let now: () -> Date
    private var request: CheckoutRequest?
    private var profile: SecureProfile?
    private var operation: Task<CheckoutReview, Error>?
    private var operationGeneration: Int?
    private var generation = 0

    var diagnostics: CheckoutPageDiagnostics? { driver.diagnostics }
    var browserKind: CheckoutBrowserKind { embeddedWebView == nil ? driver.browserKind : .embeddedFixture }
    /// Compatibility for injected WebKit fixtures; the Safari path never constructs a WKWebView.
    var webView: WKWebView {
        guard let embeddedWebView else { preconditionFailure("Safari checkout has no embedded web view") }
        return embeddedWebView
    }

    func showBrowser() async {
        let expectedGeneration = generation
        do { try await driver.showBrowser() }
        catch {
            guard generation == expectedGeneration else { return }
            if let error = error as? CheckoutError, error.isSafariFailure {
                detail = error.localizedDescription
            } else {
                detail = "Safari could not be opened. Check Automation permission and Safari’s JavaScript from Apple Events setting."
            }
        }
    }

    var isActive: Bool {
        switch state {
        case .preparing, .manualInputRequired, .reviewReady, .blocked: true
        case .idle, .authenticationRequired, .failed: false
        }
    }

    convenience init() {
        let page = SafariAppleCheckoutPage(submissionAllowed: false)
        let driver = AppleCheckoutDriver(vault: RehearsalSessionVault(), page: page)
        self.init(driver: driver)
    }

    init(driver: any CheckoutRehearsalPreparing, webView: WKWebView? = nil, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.embeddedWebView = webView
        self.now = now
        detail = webView == nil && driver.browserKind == .safari
            ? "Start a review-only checkout test in Safari. Pickup Pilot will not submit an order."
            : "Start a review-only checkout test. The final order control stays disabled."
    }

    func start(request: CheckoutRequest, profile: SecureProfile) async {
        guard operation == nil else { return }
        generation += 1
        driver.cancel()
        self.request = request
        self.profile = profile
        review = nil
        await prepare(request: request, profile: profile, generation: generation)
    }

    func resume() async {
        guard operation == nil, state == .manualInputRequired || state == .blocked,
              let request, let profile else { return }
        await prepare(request: request, profile: profile, generation: generation, recoveringSession: state == .blocked)
    }

    func cancel() {
        generation += 1
        operation?.cancel()
        driver.cancel()
        if let embeddedWebView {
            // Fixtures keep the existing in-process document cleanup contract.
            embeddedWebView.loadHTMLString("", baseURL: nil)
        } else if browserKind == .safari {
            // The driver detaches the owned Safari window synchronously before its
            // asynchronous close, so a later test generation cannot be targeted.
            driver.endReviewOnlySession()
        }
        clearInputs()
        review = nil
        state = .idle
        detail = "Review-only checkout test canceled."
    }

    private func prepare(request: CheckoutRequest, profile: SecureProfile, generation expectedGeneration: Int, recoveringSession: Bool = false) async {
        guard generation == expectedGeneration else { return }
        guard !Task.isCancelled else { cancel(); return }
        state = .preparing
        if browserKind == .safari {
            detail = recoveringSession
                ? "Checking the current Apple page in Safari before continuing to review. Pickup Pilot will not submit an order."
                : "Preparing the selected guest pickup checkout in Safari up to its final review. Pickup Pilot will not submit an order."
        } else {
            detail = recoveringSession
                ? "Checking the current Apple page in this window before continuing to review. The order control stays disabled."
                : "Preparing the selected pickup checkout up to its final review. The order control stays disabled."
        }
        let driver = driver
        let work = Task {
            if recoveringSession {
                do { try await driver.resumeAfterManualRecovery(request: request) }
                catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? CheckoutError) == .cancelled { throw error }
                    if [.authenticationRequired, .guestCheckoutUnavailable, .guestCheckoutRefused].contains(error as? CheckoutError)
                        || (error as? CheckoutError)?.isSafariFailure == true { throw error }
                    // Recovery errors must not expose page, session or profile details.
                    throw RehearsalRecoveryUnresolved()
                }
                try Task.checkCancellation()
            }
            return try await driver.prepare(request: request, profile: profile)
        }
        operation = work
        operationGeneration = expectedGeneration
        defer {
            if operationGeneration == expectedGeneration {
                operation = nil
                operationGeneration = nil
            }
        }
        do {
            let prepared = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    self.cancel()
                }
            }
            guard generation == expectedGeneration else { return }
            guard !Task.isCancelled else { cancel(); return }
            operation = nil
            try prepared.validate(for: request, at: now())
            review = prepared
            clearInputs()
            state = .reviewReady
            detail = browserKind == .safari
                ? "Apple's final pickup review in Safari matches your selected limits. Pickup Pilot will not submit an order."
                : "Apple's final pickup review matches your selected limits. The order control remains disabled."
        } catch {
            guard generation == expectedGeneration else { return }
            operation = nil
            if Task.isCancelled || error is CancellationError || (error as? CheckoutError) == .cancelled {
                cancel()
                return
            }
            if error is RehearsalRecoveryUnresolved {
                state = .blocked
                detail = browserKind == .safari
                    ? "The Apple page is not ready to resume. Check the page in Safari before continuing. Pickup Pilot will not submit an order."
                    : "The Apple page is not ready to resume. Check the page in this window before continuing. The order control stays disabled."
                return
            }
            switch error as? CheckoutError {
            case .safariUnavailable, .safariPermissionRequired, .safariJavaScriptDisabled, .safariWindowUnavailable, .safariAutomationFailed:
                finish(state: .failed, detail: (error as? CheckoutError)?.localizedDescription ?? "Safari checkout could not continue.")
            case .authenticationRequired, .guestCheckoutUnavailable:
                finish(state: .failed, detail: "Guest checkout could not continue. This review-only test uses guest checkout only and will not request sign-in or authentication. The test stopped without placing an order.")
            case .guestCheckoutRefused:
                finish(state: .failed, detail: "Apple refused the guest checkout request with an access response. This review-only test will not retry, sign in, or work around Apple's response. The test stopped without placing an order.")
            case .manualInputRequired:
                state = .manualInputRequired
                detail = browserKind == .safari
                    ? "Complete required fields in Safari and confirm the payment method on Apple’s final review, then continue the review-only test. Do not place the order in Safari."
                    : "Complete required fields and confirm the payment method on Apple’s final review, then continue the review-only test."
            case .storefrontBlocked:
                state = .blocked
                detail = browserKind == .safari
                    ? "An Apple checkout request returned an access or rate-limit response; the current page may be an error redirect. Check the Apple page in Safari before continuing. Pickup Pilot will not submit an order."
                    : "An Apple checkout request returned an access or rate-limit response; the current page may be an error redirect. Check the Apple page in this window before continuing. The order control stays disabled."
            case .pageNotFound:
                finish(state: .failed, detail: "Apple's checkout page was not found. This review-only test stopped without placing an order. Check the product and checkout page before starting a new test.")
            case .sessionRecoveryNotReady:
                let detail = browserKind == .safari
                    ? "The Apple page in Safari is not ready to resume. Check the page before trying again. Pickup Pilot will not submit an order."
                    : "The Apple page is not ready to resume. Check the page before trying again. The order control stays disabled."
                if recoveringSession {
                    state = .blocked
                    self.detail = detail
                } else {
                    finish(state: .failed, detail: detail)
                }
            case .unavailable:
                finish(state: .failed, detail: "Apple no longer offers the selected pickup configuration or store.")
            case .unsafeReview, .expiredReview:
                finish(state: .failed, detail: "The checkout review did not match the selected pickup limits or has expired.")
            case .sessionStorage:
                finish(state: .failed, detail: "The temporary checkout session could not be retained. Start a new review-only test.")
            case .unsupportedPage:
                finish(state: .failed, detail: "Apple's current checkout page could not be verified. Review the page before trying again.")
            default:
                finish(state: .failed, detail: "Checkout could not be prepared. Review the Apple page and try again.")
            }
        }
    }

    private func clearInputs() {
        profile = nil
        request = nil
    }

    private func finish(state: State, detail: String) {
        driver.cancel()
        clearInputs()
        review = nil
        self.state = state
        self.detail = detail
    }
}
