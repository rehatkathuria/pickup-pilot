import AppKit
import Foundation
import PilotCore
import Testing
import WebKit
@testable import PickupPilot

private let rehearsalNow = Date(timeIntervalSince1970: 1_792_166_400)
private func rehearsalRequest() -> CheckoutRequest {
    CheckoutRequest(variant: ProductVariant(id: "REHEARSAL-CA/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky",
                                           productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic")),
                    store: RetailStore(id: "RTEST", name: "Synthetic Store", countryCode: "CA"), market: .ca,
                    maximumTotal: 4000, pickupWindow: DateWindow(start: rehearsalNow, end: rehearsalNow.addingTimeInterval(10 * 86400)),
                    timeZoneIdentifier: "UTC")
}
private func rehearsalProfile() -> SecureProfile {
    SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid", phone: "+14165550100",
                  cardholder: "Synthetic Tester", cardNumber: "4111111111111111", expiryMonth: "12", expiryYear: "2099", cvv: "123",
                  billingLine1: "1 Synthetic Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
}
private func rehearsalReview(quantity: Int = 1) -> CheckoutReview {
    CheckoutReview(variantID: "REHEARSAL-CA/A", storeID: "RTEST", quantity: quantity, total: 3388.87, currencyCode: "CAD",
                   pickupDate: rehearsalNow.addingTimeInterval(86400), pickupEndDate: rehearsalNow.addingTimeInterval(86400 + 900),
                   pickupSlot: "Synthetic 10:00–10:15", expiresAt: rehearsalNow.addingTimeInterval(600),
                   sourceURL: "https://secure6.store.apple.com/ca/shop/checkout")
}
private enum RehearsalRawFailure: Error, LocalizedError {
    case sensitive
    var errorDescription: String? { "Raw error containing 4111111111111111 and synthetic@example.invalid" }
}
@MainActor private final class RehearsalPrepareFixture: CheckoutRehearsalPreparing {
    var browserKind: CheckoutBrowserKind = .embeddedFixture
    private(set) var browserShows = 0
    private(set) var endedSessions = 0
    var browserShowError: (any Error)?
    var suspendBrowserShow = false
    var pendingBrowserShow: CheckedContinuation<Void, Error>?
    func showBrowser() async throws {
        browserShows += 1
        if suspendBrowserShow {
            return try await withCheckedThrowingContinuation { pendingBrowserShow = $0 }
        }
        if let browserShowError { throw browserShowError }
    }
    func resolveBrowserShow(_ result: Result<Void, Error>) {
        let continuation = pendingBrowserShow; pendingBrowserShow = nil
        continuation?.resume(with: result)
    }
    func endReviewOnlySession() { endedSessions += 1 }
    var requests: [CheckoutRequest] = []
    var profiles: [SecureProfile] = []
    var events: [String] = []
    var cancellations = 0
    var result: Result<CheckoutReview, Error> = .success(rehearsalReview())
    var suspend = false
    var pending: CheckedContinuation<CheckoutReview, Error>?
    var recoveryRequests: [CheckoutRequest] = []
    var recoveryResult: Result<Void, Error> = .success(())
    var suspendRecovery = false
    var pendingRecovery: CheckedContinuation<Void, Error>?
    func prepare(request: CheckoutRequest, profile: SecureProfile) async throws -> CheckoutReview {
        events.append("prepare")
        requests.append(request); profiles.append(profile)
        if suspend { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try result.get()
    }
    func resumeAfterManualRecovery(request: CheckoutRequest) async throws {
        events.append("recover")
        recoveryRequests.append(request)
        if suspendRecovery { return try await withCheckedThrowingContinuation { pendingRecovery = $0 } }
        return try recoveryResult.get()
    }
    func cancel() { cancellations += 1; events.append("cancel") }
    func resolve(_ value: Result<CheckoutReview, Error>) {
        let continuation = pending; pending = nil
        continuation?.resume(with: value)
    }
    func resolveRecovery(_ value: Result<Void, Error>) {
        let continuation = pendingRecovery; pendingRecovery = nil
        continuation?.resume(with: value)
    }
}

@MainActor private final class RehearsalRecoveryUnavailableFixture: CheckoutRehearsalPreparing {
    private(set) var preparations = 0
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        preparations += 1; throw CheckoutError.storefrontBlocked
    }
    func cancel() {}
}

@MainActor private final class RehearsalTestClock {
    var now = rehearsalNow
}

@Suite(.serialized) @MainActor struct CheckoutRehearsalTests {
    private func controller(_ fixture: RehearsalPrepareFixture) -> CheckoutRehearsal {
        CheckoutRehearsal(driver: fixture, webView: WKWebView(), now: { rehearsalNow })
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Expected rehearsal state transition did not finish")
    }
    private func waitForBrowserText(_ expected: String, in browser: WKWebView) async throws {
        for _ in 0..<100 {
            if let text = try? await browser.evaluateJavaScript("document.body?.textContent ?? ''") as? String,
               text == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The synthetic browser document did not reach its expected state")
    }

    @Test func initialStateAndInactiveResumeDoNotPrepareAnything() async {
        let fixture = RehearsalPrepareFixture(); let rehearsal = controller(fixture)
        #expect(rehearsal.state == .idle && !rehearsal.isActive && rehearsal.review == nil)
        #expect(rehearsal.detail.contains("order control stays disabled"))
        await rehearsal.resume()
        #expect(fixture.requests.isEmpty && fixture.recoveryRequests.isEmpty)
    }

    @Test func startupRejectionIsVisibleWithoutPreparingAndCannotReplaceAnActiveTest() async {
        let fixture = RehearsalPrepareFixture(), rehearsal = controller(fixture)
        rehearsal.rejectStartup("Choose a synthetic store before testing.")
        #expect(rehearsal.state == .notStarted && !rehearsal.isActive && rehearsal.review == nil)
        #expect(rehearsal.detail.contains("did not start") && rehearsal.detail.contains("synthetic store"))
        await rehearsal.resume()
        #expect(fixture.requests.isEmpty && fixture.cancellations == 0)
        fixture.result = .failure(CheckoutError.manualInputRequired)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        let activeDetail = rehearsal.detail
        rehearsal.rejectStartup("This must not replace the active checkout.")
        #expect(rehearsal.state == .manualInputRequired && rehearsal.detail == activeDetail)
        #expect(fixture.requests.count == 1 && fixture.cancellations == 1)
        rehearsal.cancel()
    }

    @Test func validReviewStopsAtVisibleReviewAndCannotResumeAnotherOperation() async {
        let fixture = RehearsalPrepareFixture(); let rehearsal = controller(fixture)
        let expected = rehearsalReview(); fixture.result = .success(expected)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && rehearsal.isActive)
        #expect(rehearsal.review == expected)
        #expect(rehearsal.detail.contains("order control remains disabled"))
        #expect(fixture.requests == [rehearsalRequest()] && fixture.profiles == [rehearsalProfile()])
        await rehearsal.resume()
        #expect(fixture.requests.count == 1)
        rehearsal.cancel()
        #expect(rehearsal.state == .idle && rehearsal.review == nil && !rehearsal.isActive)
        await rehearsal.resume()
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [CheckoutError.manualInputRequired])
    func humanHandoffResumesSameDriverRequestAndProfileWithoutCanceling(error: CheckoutError) async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(error)
        let rehearsal = controller(fixture); let browser = rehearsal.webView
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .manualInputRequired)
        #expect(rehearsal.isActive && rehearsal.review == nil)
        #expect(fixture.cancellations == 1)
        fixture.result = .success(rehearsalReview())
        await rehearsal.resume()
        #expect(rehearsal.state == .reviewReady && rehearsal.webView === browser)
        #expect(fixture.requests == [rehearsalRequest(), rehearsalRequest()])
        #expect(fixture.profiles == [rehearsalProfile(), rehearsalProfile()])
        #expect(fixture.cancellations == 1)
        #expect(fixture.recoveryRequests.isEmpty)
    }

    @Test(arguments: [CheckoutError.manualInputRequired, .storefrontBlocked])
    func cancelClearsLocalCheckoutDocumentWhileHumanHandoffPreservesIt(error: CheckoutError) async throws {
        _ = NSApplication.shared
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(error)
        let rehearsal = controller(fixture)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = rehearsal.webView
        window.orderFront(nil)
        defer { window.close() }
        rehearsal.webView.loadHTMLString("<html><body>Synthetic checkout details</body></html>", baseURL: nil)
        try await waitForBrowserText("Synthetic checkout details", in: rehearsal.webView)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        try await waitForBrowserText("Synthetic checkout details", in: rehearsal.webView)
        #expect(rehearsal.isActive && fixture.cancellations == 1)
        rehearsal.cancel()
        try await waitForBrowserText("", in: rehearsal.webView)
        #expect(rehearsal.state == .idle && rehearsal.review == nil)
        await rehearsal.resume()
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [CheckoutError.unsupportedPage, .pageNotFound, .sessionRecoveryNotReady, .unsafeReview, .expiredReview, .unavailable, .sessionStorage])
    func terminalFailuresAreSanitizedAndCannotResumeWithoutFreshInputs(error: CheckoutError) async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(error)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .failed)
        #expect(!rehearsal.isActive && rehearsal.review == nil)
        #expect(!rehearsal.detail.contains(rehearsalProfile().cardNumber))
        #expect(!rehearsal.detail.contains(rehearsalProfile().email))
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.cancellations == 2)
    }

    @Test(arguments: [CheckoutError.authenticationRequired, .guestCheckoutUnavailable])
    func guestOnlyRequirementsEndTheTestAndCannotResumeCapturedInputs(error: CheckoutError) async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(error)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .failed && !rehearsal.isActive && rehearsal.review == nil)
        #expect(rehearsal.detail.contains("guest checkout only") && rehearsal.detail.contains("will not request"))
        #expect(rehearsal.detail.contains("without placing an order"))
        #expect(!rehearsal.detail.contains("Complete Apple") && !rehearsal.detail.contains("then continue"))
        #expect(!rehearsal.detail.contains(rehearsalProfile().email) && !rehearsal.detail.contains(rehearsalProfile().cardNumber))
        fixture.result = .success(rehearsalReview())
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.isEmpty && fixture.cancellations == 2)
    }

    @Test func pageNotFoundEndsTheTestWithoutInventingAuthenticationOrAccessEvidence() async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.pageNotFound)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .failed && !rehearsal.isActive && rehearsal.review == nil)
        let detail = rehearsal.detail.lowercased()
        #expect(detail.contains("page was not found") && detail.contains("without placing an order"))
        #expect(!detail.contains("blocked") && !detail.contains("authentication") && !detail.contains("resolve") && !detail.contains("session"))
        fixture.result = .success(rehearsalReview())
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.isEmpty && fixture.cancellations == 2)
        // Captured inputs are gone; a fresh explicit start is required.
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && fixture.requests.count == 2)
    }

    @Test func unreadyRecoveryErrorWithoutPriorAccessResponseCannotCreateAPausedBlock() async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.sessionRecoveryNotReady)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .failed && !rehearsal.isActive)
        #expect(rehearsal.detail.contains("page is not ready"))
        #expect(!rehearsal.detail.contains("access or rate-limit") && !rehearsal.detail.contains("Apple blocked"))
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.isEmpty)
    }

    @Test func blockedSessionWaitsForExplicitRecoveryAndRetainsSameInputsAndBrowser() async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
        let rehearsal = controller(fixture); let browser = rehearsal.webView
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .blocked && rehearsal.isActive && rehearsal.review == nil)
        #expect(rehearsal.detail.contains("access or rate-limit response") && rehearsal.detail.contains("may be an error redirect"))
        #expect(!rehearsal.detail.contains("Apple blocked this checkout session") && !rehearsal.detail.contains("banned"))
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.isEmpty && fixture.cancellations == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.isEmpty)
        fixture.result = .success(rehearsalReview())
        await rehearsal.resume()
        #expect(rehearsal.state == .reviewReady && rehearsal.webView === browser)
        #expect(fixture.recoveryRequests == [rehearsalRequest()])
        #expect(fixture.requests == [rehearsalRequest(), rehearsalRequest()])
        #expect(fixture.profiles == [rehearsalProfile(), rehearsalProfile()] && fixture.cancellations == 1)
        #expect(fixture.events == ["cancel", "prepare", "recover", "prepare"])
    }

    @Test func unresolvedRepairsStayBlockedAndSanitizedUntilAnotherExplicitRecovery() async {
        for error: any Error in [CheckoutError.sessionRecoveryNotReady, CheckoutError.storefrontBlocked, CheckoutError.unsupportedPage, CheckoutError.unsafeReview,
                                CheckoutError.sessionStorage, RehearsalRawFailure.sensitive] {
            let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
            let rehearsal = controller(fixture)
            await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
            fixture.result = .success(rehearsalReview()); fixture.recoveryResult = .failure(error)
            await rehearsal.resume()
            #expect(rehearsal.state == .blocked && rehearsal.isActive && rehearsal.review == nil)
            #expect(rehearsal.detail.contains("not ready to resume"))
            #expect(!rehearsal.detail.contains("access or rate-limit") && !rehearsal.detail.contains("Apple blocked"))
            #expect(!rehearsal.detail.contains("4111111111111111") && !rehearsal.detail.contains("synthetic@example.invalid"))
            #expect(fixture.requests.count == 1 && fixture.recoveryRequests.count == 1 && fixture.cancellations == 1)
            fixture.recoveryResult = .success(())
            await rehearsal.resume()
            #expect(rehearsal.state == .reviewReady && fixture.requests.count == 2 && fixture.recoveryRequests.count == 2)
            #expect(fixture.profiles == [rehearsalProfile(), rehearsalProfile()])
        }
    }

    @Test func missingRecoveryCapabilityFailsClosedWithoutPreparingAgain() async {
        let fixture = RehearsalRecoveryUnavailableFixture()
        await #expect(throws: CheckoutError.sessionRecoveryNotReady) {
            try await fixture.resumeAfterManualRecovery(request: rehearsalRequest())
        }
        let rehearsal = CheckoutRehearsal(driver: fixture, webView: WKWebView(), now: { rehearsalNow })
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        await rehearsal.resume()
        #expect(rehearsal.state == .blocked && rehearsal.isActive && fixture.preparations == 1)
        #expect(rehearsal.detail.contains("page is not ready") && !rehearsal.detail.contains("access or rate-limit"))
        rehearsal.cancel(); await rehearsal.resume()
        #expect(rehearsal.state == .idle && !rehearsal.isActive && fixture.preparations == 1)
    }

    @Test(arguments: [CheckoutError.authenticationRequired, .guestCheckoutUnavailable])
    func authenticationDuringRecoveryEndsGuestOnlyTestWithoutPreparingAgain(error: CheckoutError) async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        fixture.recoveryResult = .failure(error)
        await rehearsal.resume()
        #expect(rehearsal.state == .failed && !rehearsal.isActive && rehearsal.review == nil)
        #expect(rehearsal.detail.contains("guest checkout only") && rehearsal.detail.contains("will not request"))
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.count == 1 && fixture.cancellations == 2)
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.count == 1)
    }

    @Test func pageNotFoundAfterExplicitRecoveryEndsThePausedTestAndCannotRetryCapturedInputs() async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        fixture.result = .failure(CheckoutError.pageNotFound)
        await rehearsal.resume()
        #expect(rehearsal.state == .failed && !rehearsal.isActive && rehearsal.review == nil)
        #expect(rehearsal.detail.contains("page was not found") && !rehearsal.detail.contains("access or rate-limit"))
        #expect(fixture.requests.count == 2 && fixture.recoveryRequests.count == 1 && fixture.cancellations == 2)
        await rehearsal.resume()
        #expect(fixture.requests.count == 2 && fixture.recoveryRequests.count == 1)
    }

    @Test(arguments: [CheckoutError.manualInputRequired, .storefrontBlocked])
    func recoveredPreparationCanPauseAgainWithoutAutomaticRecovery(error: CheckoutError) async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        fixture.result = .failure(error)
        await rehearsal.resume()
        #expect(rehearsal.state == (error == .manualInputRequired ? .manualInputRequired : .blocked))
        #expect(rehearsal.isActive && fixture.requests.count == 2 && fixture.recoveryRequests.count == 1)
        fixture.result = .success(rehearsalReview())
        await rehearsal.resume()
        #expect(rehearsal.state == .reviewReady && fixture.requests.count == 3)
        #expect(fixture.recoveryRequests.count == (error == .storefrontBlocked ? 2 : 1))
    }

    @Test(arguments: [false, true]) func cancelDuringRecoveryBlocksOverlapsAndIgnoresLateResults(lateError: Bool) async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        fixture.suspendRecovery = true; fixture.result = .success(rehearsalReview())
        let recovering = Task { await rehearsal.resume() }
        await waitUntil { fixture.pendingRecovery != nil }
        #expect(rehearsal.state == .preparing && rehearsal.isActive)
        await rehearsal.resume(); await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(fixture.recoveryRequests.count == 1 && fixture.requests.count == 1)
        rehearsal.cancel()
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .idle && fixture.requests.count == 1)
        fixture.resolveRecovery(lateError ? .failure(RehearsalRawFailure.sensitive) : .success(()))
        await recovering.value
        #expect(rehearsal.state == .idle && rehearsal.review == nil && !rehearsal.isActive && fixture.requests.count == 1)
        await rehearsal.resume(); #expect(fixture.recoveryRequests.count == 1)
        fixture.suspendRecovery = false
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && fixture.requests.count == 2)
    }

    @Test func parentCancellationDuringRecoveryClearsInputsBeforeUncooperativeSuccess() async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        fixture.suspendRecovery = true; fixture.result = .success(rehearsalReview())
        let recovering = Task { await rehearsal.resume() }
        await waitUntil { fixture.pendingRecovery != nil }
        recovering.cancel()
        await waitUntil { rehearsal.state == .idle }
        fixture.resolveRecovery(.success(())); await recovering.value
        #expect(rehearsal.state == .idle && rehearsal.review == nil && !rehearsal.isActive)
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.count == 1)
        await rehearsal.resume(); #expect(fixture.requests.count == 1)
    }

    @Test func cancellationErrorsDuringRecoveryReturnToIdle() async {
        for error: any Error in [CheckoutError.cancelled, CancellationError()] {
            let fixture = RehearsalPrepareFixture(); fixture.result = .failure(CheckoutError.storefrontBlocked)
            let rehearsal = controller(fixture)
            await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
            fixture.recoveryResult = .failure(error)
            await rehearsal.resume()
            #expect(rehearsal.state == .idle && !rehearsal.isActive && fixture.requests.count == 1)
            await rehearsal.resume(); #expect(fixture.recoveryRequests.count == 1)
        }
    }

    @Test func arbitraryUnderlyingErrorNeverExposesSensitiveDescription() async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .failure(RehearsalRawFailure.sensitive)
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .failed)
        #expect(!rehearsal.detail.contains("Raw error") && !rehearsal.detail.contains("4111111111111111"))
        #expect(!rehearsal.detail.contains("synthetic@example.invalid"))
    }

    @Test func controllerRevalidatesAnUnsafePreparedReview() async {
        let fixture = RehearsalPrepareFixture(); fixture.result = .success(rehearsalReview(quantity: 2))
        let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .failed && rehearsal.review == nil)
    }

    @Test func delayedPreparationRevalidatesExpiryAtCompletionAndClearsCapturedInputs() async {
        let fixture = RehearsalPrepareFixture(); fixture.suspend = true
        let clock = RehearsalTestClock()
        let rehearsal = CheckoutRehearsal(driver: fixture, webView: WKWebView(), now: { clock.now })
        let pending = Task { await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile()) }
        await waitUntil { fixture.pending != nil }
        let prepared = rehearsalReview()
        clock.now = prepared.expiresAt
        fixture.resolve(.success(prepared))
        await pending.value
        #expect(rehearsal.state == .failed && rehearsal.review == nil && !rehearsal.isActive)
        #expect(rehearsal.detail.contains("expired") && fixture.cancellations == 2)
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.isEmpty)
        // Expiration ends that captured attempt; fresh inputs can still start a new test.
        clock.now = rehearsalNow; fixture.suspend = false
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && fixture.requests.count == 2)
    }

    @Test func staleParentCancellationAfterExplicitEndCannotCancelAFreshGeneration() async {
        let fixture = RehearsalPrepareFixture(); fixture.suspend = true
        let rehearsal = controller(fixture)
        let old = Task { await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile()) }
        await waitUntil { fixture.pending != nil }
        rehearsal.cancel()
        old.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(rehearsal.state == .idle && fixture.cancellations == 2)
        fixture.resolve(.failure(CheckoutError.authenticationRequired))
        await old.value
        #expect(rehearsal.state == .idle && rehearsal.review == nil && !rehearsal.isActive)
        fixture.suspend = false
        let expectedFreshReview = rehearsalReview()
        fixture.result = .success(expectedFreshReview)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        let freshReview = rehearsal.review
        for _ in 0..<20 { await Task.yield() }
        #expect(rehearsal.state == .reviewReady && freshReview == expectedFreshReview)
        #expect(rehearsal.review == freshReview && fixture.requests.count == 2 && fixture.cancellations == 3)
    }

    @Test(arguments: [false, true]) func cancelInvalidatesLateSuccessAndLateHumanHandoff(lateError: Bool) async {
        let fixture = RehearsalPrepareFixture(); fixture.suspend = true
        let rehearsal = controller(fixture)
        let first = Task { await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile()) }
        await waitUntil { fixture.pending != nil }
        #expect(rehearsal.state == .preparing && rehearsal.isActive)
        await rehearsal.resume()
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(fixture.requests.count == 1)
        rehearsal.cancel()
        #expect(rehearsal.state == .idle && rehearsal.review == nil && !rehearsal.isActive)
        // The canceled driver must unwind before another preparation is allowed to overlap it.
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(fixture.requests.count == 1)
        fixture.resolve(lateError ? .failure(CheckoutError.authenticationRequired) : .success(rehearsalReview()))
        await first.value
        #expect(rehearsal.state == .idle && rehearsal.review == nil)
        await rehearsal.resume()
        #expect(fixture.requests.count == 1)
        fixture.suspend = false
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && fixture.requests.count == 2)
    }

    @Test func parentTaskCancellationClearsActiveInputsAndIgnoresUncooperativeDriverResult() async {
        let fixture = RehearsalPrepareFixture(); fixture.suspend = true
        let rehearsal = controller(fixture)
        let run = Task { await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile()) }
        await waitUntil { fixture.pending != nil }
        run.cancel()
        await waitUntil { rehearsal.state == .idle }
        #expect(rehearsal.review == nil && !rehearsal.isActive)
        fixture.resolve(.success(rehearsalReview()))
        await run.value
        #expect(rehearsal.state == .idle && rehearsal.review == nil)
    }

    @Test func newStartClearsPreviousReviewBeforePreparingFreshInputs() async {
        let fixture = RehearsalPrepareFixture(); let rehearsal = controller(fixture)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.review != nil)
        fixture.suspend = true
        let second = Task { await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile()) }
        await waitUntil { fixture.pending != nil }
        #expect(rehearsal.state == .preparing && rehearsal.review == nil)
        fixture.resolve(.success(rehearsalReview())); await second.value
        #expect(rehearsal.state == .reviewReady)
    }

    @Test func canceledDriverAndCancellationErrorReturnToIdle() async {
        for error: any Error in [CheckoutError.cancelled, CancellationError()] {
            let fixture = RehearsalPrepareFixture(); fixture.result = .failure(error)
            let rehearsal = controller(fixture)
            await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
            #expect(rehearsal.state == .idle && !rehearsal.isActive && rehearsal.review == nil)
        }
    }

    @Test func alreadyCanceledCallerCannotBeginNativePreparation() async {
        let fixture = RehearsalPrepareFixture(); let rehearsal = controller(fixture)
        let run = Task { await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile()) }
        run.cancel(); await run.value
        #expect(fixture.requests.isEmpty && rehearsal.state == .idle)
    }

    @Test func productionRehearsalUsesSafariWithoutConstructingAnEmbeddedBrowser() {
        let rehearsal = CheckoutRehearsal()
        #expect(rehearsal.browserKind == .safari)
        #expect(rehearsal.embeddedWebView == nil)
        #expect(rehearsal.detail.contains("in Safari") && rehearsal.detail.contains("will not submit an order"))
        #expect(!rehearsal.detail.contains("order control stays disabled"))
        rehearsal.cancel()
    }

    @Test func injectedWebKitFixtureRetainsItsImmutableReviewOnlyGuard() {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        let fixture = RehearsalPrepareFixture()
        let rehearsal = CheckoutRehearsal(driver: fixture, webView: page.webView)
        #expect(rehearsal.browserKind == .embeddedFixture)
        #expect(rehearsal.embeddedWebView === page.webView)
        let scripts = page.webView.configuration.userContentController.userScripts
        #expect(scripts.first?.source.contains("__pickupPilotReviewOnly") == true)
        #expect(scripts.first?.source.contains("writable:false") == true)
        #expect(scripts.first?.source.contains("configurable:false") == true)
        #expect(scripts.first?.injectionTime == .atDocumentStart)
        rehearsal.cancel()
    }

    @Test func safariReviewUsesNoEmbeddedBrowserAndEndingTestClosesOnlyItsDriverSession() async {
        let fixture = RehearsalPrepareFixture(); fixture.browserKind = .safari
        let rehearsal = CheckoutRehearsal(driver: fixture, now: { rehearsalNow })
        #expect(rehearsal.browserKind == .safari && rehearsal.embeddedWebView == nil)
        await rehearsal.showBrowser()
        #expect(fixture.browserShows == 1 && fixture.requests.isEmpty)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && rehearsal.embeddedWebView == nil)
        #expect(rehearsal.detail.contains("in Safari") && rehearsal.detail.contains("will not submit an order"))
        #expect(!rehearsal.detail.contains("order control remains disabled"))
        rehearsal.cancel()
        // End is synchronous so the old window handle is detached before a fresh start.
        #expect(fixture.endedSessions == 1 && rehearsal.state == .idle)
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && fixture.endedSessions == 1)
    }

    @Test(arguments: [CheckoutError.safariUnavailable, .safariPermissionRequired, .safariJavaScriptDisabled, .safariWindowUnavailable, .safariAutomationFailed])
    func safariSetupFailuresEndTheTestWithoutAuthenticationOrRetry(error: CheckoutError) async {
        let fixture = RehearsalPrepareFixture(); fixture.browserKind = .safari; fixture.result = .failure(error)
        let rehearsal = CheckoutRehearsal(driver: fixture, now: { rehearsalNow })
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .failed && !rehearsal.isActive && rehearsal.review == nil)
        #expect(rehearsal.detail == error.localizedDescription)
        #expect(!rehearsal.detail.contains(rehearsalProfile().email) && !rehearsal.detail.contains(rehearsalProfile().cardNumber))
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.isEmpty)
        fixture.result = .success(rehearsalReview())
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        #expect(rehearsal.state == .reviewReady && fixture.requests.count == 2)
    }

    @Test func safariSetupFailureDuringRecoveryEndsCapturedAttempt() async {
        let fixture = RehearsalPrepareFixture(); fixture.browserKind = .safari
        fixture.result = .failure(CheckoutError.storefrontBlocked)
        let rehearsal = CheckoutRehearsal(driver: fixture, now: { rehearsalNow })
        await rehearsal.start(request: rehearsalRequest(), profile: rehearsalProfile())
        fixture.recoveryResult = .failure(CheckoutError.safariPermissionRequired)
        await rehearsal.resume()
        #expect(rehearsal.state == .failed && !rehearsal.isActive)
        #expect(rehearsal.detail == CheckoutError.safariPermissionRequired.localizedDescription)
        await rehearsal.resume()
        #expect(fixture.requests.count == 1 && fixture.recoveryRequests.count == 1)
    }

    @Test func delayedSafariPermissionFailureCannotOverwriteAnEndedTest() async {
        let fixture = RehearsalPrepareFixture(); fixture.browserKind = .safari; fixture.suspendBrowserShow = true
        let rehearsal = CheckoutRehearsal(driver: fixture, now: { rehearsalNow })
        let showing = Task { await rehearsal.showBrowser() }
        await waitUntil { fixture.pendingBrowserShow != nil }
        rehearsal.cancel()
        let endedDetail = rehearsal.detail
        fixture.resolveBrowserShow(.failure(CheckoutError.safariPermissionRequired))
        await showing.value
        #expect(rehearsal.state == .idle && rehearsal.detail == endedDetail && fixture.endedSessions == 1)
    }

    @Test func openingSafariUsesSanitizedSetupErrorsWithoutPreparingOrRevealingInputs() async {
        let fixture = RehearsalPrepareFixture(); fixture.browserKind = .safari
        let rehearsal = CheckoutRehearsal(driver: fixture, now: { rehearsalNow })
        fixture.browserShowError = CheckoutError.safariJavaScriptDisabled
        await rehearsal.showBrowser()
        #expect(rehearsal.detail == CheckoutError.safariJavaScriptDisabled.localizedDescription)
        fixture.browserShowError = RehearsalRawFailure.sensitive
        await rehearsal.showBrowser()
        #expect(fixture.browserShows == 2 && fixture.requests.isEmpty && fixture.endedSessions == 0)
        #expect(rehearsal.detail.contains("Automation permission"))
        #expect(!rehearsal.detail.contains(rehearsalProfile().email) && !rehearsal.detail.contains(rehearsalProfile().cardNumber))
    }
}
