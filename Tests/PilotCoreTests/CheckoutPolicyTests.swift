import Foundation
import Testing
@testable import PilotCore

private let checkoutNow = Date(timeIntervalSince1970: 1_792_166_400)
private func request(market: Market = .ca) -> CheckoutRequest {
    CheckoutRequest(variant: ProductVariant(id: "TEST-CA/A", name: "Synthetic iPhone Duo", storage: "256GB", color: "Night Sky",
                                           productURL: market.productBaseURL.appendingPathComponent("synthetic")),
                    store: RetailStore(id: "R121", name: "Synthetic store"), market: market, maximumTotal: 4000)
}
private func evidence() -> CheckoutSnapshot {
    CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .review,
                     productIDs: ["TEST-CA/A"], storeIDs: ["R121"], quantities: [1], totalText: "CA$3,388.87", currencyCode: "CAD",
                     pickupStartISO: "2026-10-24T14:00:00Z", pickupEndISO: "2026-10-24T14:15:00Z",
                     pickupSlot: "10:00–10:15", finalActionCount: 1, pickupOnly: true,
                     documentID: "00000000-0000-4000-8000-000000000001", reviewStateID: "00000000-0000-4000-8000-000000000002")
}

@Test func checkoutMissingDestinationIsDistinctFromBlockingAndDiagnosticsDecodeLegacySnapshots() throws {
    let old = evidence()
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    object.removeValue(forKey: "blockingStatus"); object.removeValue(forKey: "blockingSource")
    let legacy = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.blockingStatus == nil && legacy.blockingSource == nil && legacy == old)
    var missing = CheckoutSnapshot(sourceURL: "https://www.apple.com/shop/go/404", phase: .pageNotFound,
                                   blockingStatus: 541, blockingSource: "fetch")
    let decoded = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONEncoder().encode(missing))
    #expect(decoded.phase == .pageNotFound && decoded.blockingStatus == 541 && decoded.blockingSource == "fetch")
    #expect(throws: CheckoutError.pageNotFound) { try CheckoutPagePolicy.review(from: decoded, request: request(), now: checkoutNow) }
    missing.sourceURL = "https://apple.com.example.invalid/shop/go/404"
    #expect(throws: CheckoutError.unsupportedPage) { try CheckoutPagePolicy.review(from: missing, request: request(), now: checkoutNow) }
}

@Test func checkoutRejectsLookalikeAndWrongStorefrontURLs() {
    for text in ["http://www.apple.com/ca/shop/bag", "https://apple.com.evil.test/ca/shop/bag", "https://evilapple.com/ca/shop/bag",
                 "file:///ca/shop/bag", "https://name@apple.com/ca/shop/bag", "https://name:pass@apple.com/ca/shop/bag", "https://apple.com:8443/ca/shop/bag"] {
        #expect(!CheckoutPagePolicy.isAppleHTTPS(URL(string: text)!))
    }
    #expect(CheckoutPagePolicy.isAppleHTTPS(URL(string: "https://apple.com:443/ca/shop/bag")!))
    #expect(CheckoutPagePolicy.isStorefront(URL(string: "https://secure6.store.apple.com/ca/shop/checkout")!, market: .ca))
    #expect(!CheckoutPagePolicy.isStorefront(URL(string: "https://www.apple.com/us/shop/bag")!, market: .us))
    #expect(!CheckoutPagePolicy.isStorefront(URL(string: "https://www.apple.com/shop/bag")!, market: .ca))
    #expect(CheckoutPagePolicy.isStorefront(URL(string: "https://www.apple.com/shop/bag")!, market: .us))
    for path in ["/ca/shop/../not-store", "/ca/shop/%2e%2e/not-store", "/ca/shop/./checkout",
                 "/ca/shop/%2E/checkout", "/ca/shop/%2f..%2fother", "/ca/shop/%5ccheckout", "/ca/shop/%0acheckout"] {
        #expect(!CheckoutPagePolicy.isStorefront(URL(string: "https://www.apple.com" + path)!, market: .ca))
    }
}

@Test func checkoutReviewIdentityPreservesHostAndPathWithoutSessionTokens() throws {
    var snapshot = evidence()
    snapshot.sourceURL = "https://SECURE6.store.apple.com:443/ca/shop/checkout?session=synthetic-sensitive#synthetic-token"
    let value = try CheckoutPagePolicy.review(from: snapshot, request: request(), now: checkoutNow)
    #expect(value.sourceURL == "https://secure6.store.apple.com/ca/shop/checkout")
    #expect(value.sourceURL?.contains("synthetic") == false)
    #expect(CheckoutPagePolicy.storefrontIdentity(URL(string: "https://secure7.store.apple.com/ca/shop/checkout")!, market: .ca) != value.sourceURL)
    #expect(CheckoutPagePolicy.storefrontIdentity(URL(string: "https://secure6.store.apple.com/ca/shop/bag")!, market: .ca) != value.sourceURL)
    #expect(CheckoutPagePolicy.storefrontIdentity(URL(string: "https://name:pass@secure6.store.apple.com/ca/shop/checkout?session=synthetic")!, market: .ca) == nil)
    #expect(CheckoutPagePolicy.storefrontIdentity(URL(string: "https://secure6.store.apple.com/us/shop/checkout")!, market: .ca) == nil)
}

@Test func checkoutReviewRequiresAndPreservesItsOpaqueDocumentIdentity() throws {
    let snapshot=evidence()
    let encoded=try JSONEncoder().encode(snapshot)
    let restored=try JSONDecoder().decode(CheckoutSnapshot.self,from:encoded)
    #expect(restored.documentID == snapshot.documentID)
    let review=try CheckoutPagePolicy.review(from:restored,request:request(),now:checkoutNow)
    #expect(review.documentID == snapshot.documentID)
    for identity in [nil,"","not-a-document","00000000-0000-4000-8000-00000000000Z"] as [String?] {
        var unknown=snapshot;unknown.documentID=identity
        #expect(!CheckoutPagePolicy.isDocumentID(identity))
        #expect(throws:CheckoutError.unsafeReview) { try CheckoutPagePolicy.review(from:unknown,request:request(),now:checkoutNow) }
    }
    let malformed=CheckoutReview(variantID:review.variantID,storeID:review.storeID,quantity:review.quantity,total:review.total,
                                 currencyCode:review.currencyCode,pickupDate:review.pickupDate,pickupEndDate:review.pickupEndDate,
                                 pickupSlot:review.pickupSlot,expiresAt:review.expiresAt,sourceURL:review.sourceURL,documentID:"unknown")
    #expect(throws:CheckoutError.unsafeReview) { try malformed.validate(for:request(),at:checkoutNow) }
}

@Test func checkoutReviewRequiresOpaqueBillingStateWithoutChangingExpiry() throws {
    let snapshot = evidence()
    let decoded = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONEncoder().encode(snapshot))
    let review = try CheckoutPagePolicy.review(from: decoded, request: request(), now: checkoutNow)
    #expect(review.reviewStateID == snapshot.reviewStateID)
    #expect(review.expiresAt == checkoutNow.addingTimeInterval(60))
    for identity in [nil, "", "unknown", "00000000-0000-4000-8000-00000000000Z"] as [String?] {
        var missing = snapshot; missing.reviewStateID = identity
        #expect(throws: CheckoutError.unsafeReview) { try CheckoutPagePolicy.review(from: missing, request: request(), now: checkoutNow) }
    }
    let malformed = CheckoutReview(variantID: review.variantID, storeID: review.storeID, quantity: 1, total: review.total,
                                   currencyCode: review.currencyCode, pickupDate: review.pickupDate, pickupEndDate: review.pickupEndDate,
                                   pickupSlot: review.pickupSlot, expiresAt: review.expiresAt, reviewStateID: "unknown")
    #expect(throws: CheckoutError.unsafeReview) { try malformed.validate(for: request(), at: checkoutNow) }
    let generic = CheckoutReview(variantID: review.variantID, storeID: review.storeID, quantity: 1, total: review.total,
                                 currencyCode: review.currencyCode, pickupDate: review.pickupDate, pickupEndDate: review.pickupEndDate,
                                 pickupSlot: review.pickupSlot, expiresAt: review.expiresAt)
    try generic.validate(for: request(), at: checkoutNow) // Non-WebKit mocked backends remain source-compatible.
}

@Test func checkoutParsesRegionalTotalsWithoutSilentlyDroppingText() {
    #expect(CheckoutPagePolicy.amount(" CA$3,388.87 ", market: .ca) == Decimal(string: "3388.87"))
    #expect(CheckoutPagePolicy.amount("£2,999.00", market: .uk) == 2999)
    #expect(CheckoutPagePolicy.amount("3.388,87 €", market: .de) == Decimal(string: "3388.87"))
    #expect(CheckoutPagePolicy.amount("3\u{202f}388,87 €", market: .fr) == Decimal(string: "3388.87"))
    #expect(CheckoutPagePolicy.amount("CHF 3388.00", market: .ch) == 3388)
    #expect(CheckoutPagePolicy.amount("¥299900", market: .jp) == 299900)
    for market in Market.allCases { #expect(CheckoutPagePolicy.amount("3000", market: market) == 3000) }
    for bad in ["-1.00", "USD 3999", "not available", "3,88.00", "3.999,00", "NaN", "", "$2.99 per month", "2.9999", "1 2", "US$3999", "$$3999", "$3999 CAD"] {
        #expect(CheckoutPagePolicy.amount(bad, market: .ca) == nil)
    }
    for bad in ["3,888.00", "3.88,00", "2,9999", "-3,00"] { #expect(CheckoutPagePolicy.amount(bad, market: .de) == nil) }
}

@Test func checkoutRequiresExplicitTimestampOffset() {
    #expect(CheckoutPagePolicy.instant("2026-10-24T14:00:00Z") != nil)
    #expect(CheckoutPagePolicy.instant("2026-10-24T10:00:00-04:00") == CheckoutPagePolicy.instant("2026-10-24T14:00:00Z"))
    #expect(CheckoutPagePolicy.instant("2026-10-24T14:00:00.123Z") != nil)
    #expect(CheckoutPagePolicy.instant("2028-02-29T14:00:00Z") != nil)
    #expect(CheckoutPagePolicy.instant("2000-02-29T14:00:00Z") != nil)
    #expect(CheckoutPagePolicy.instant("2026-10-24T10:00:00") == nil)
    #expect(CheckoutPagePolicy.instant("2026-invalidZ") == nil)
    for raw in ["2026-02-30T14:00:00Z", "2026-02-29T14:00:00Z", "2100-02-29T14:00:00Z",
                "2026-04-31T14:00:00Z", "2026-10-24T24:00:00Z", "2026-10-24T14:60:00Z",
                "2026-10-24T14:00:60Z", "2026-10-24T14:00:00+25:00", "2026-10-24T14:00:00+04:60",
                "2026-10-24T14:00:00ZgarbageZ", "2026-10-24T14:00:00Z\nignoredZ", "2026-10-24T14:00:00Z\n",
                "0000-01-01T14:00:00Z", "2026-00-01T14:00:00Z", "2026-13-01T14:00:00Z"] {
        #expect(CheckoutPagePolicy.instant(raw) == nil)
    }
}

@Test func checkoutReviewBindsEveryArmedLimitAndExpires() throws {
    let value = try CheckoutPagePolicy.review(from: evidence(), request: request(), now: checkoutNow)
    #expect(value.variantID == "TEST-CA/A" && value.storeID == "R121" && value.quantity == 1)
    #expect(value.total == Decimal(string: "3388.87") && value.currencyCode == "CAD")
    #expect(value.expiresAt == checkoutNow.addingTimeInterval(60))
    #expect(value.sourceURL == evidence().sourceURL)
    #expect(value.documentID == evidence().documentID)
    try value.validate(for: request(), at: checkoutNow)
    #expect(throws: CheckoutError.expiredReview) { try value.validate(for: request(), at: value.expiresAt) }
    let limited = CheckoutRequest(variant: request().variant, store: request().store, market: .ca, maximumTotal: 100)
    #expect(throws: CheckoutError.unsafeReview) { try value.validate(for: limited, at: checkoutNow) }
    let wrongStore = CheckoutRequest(variant: request().variant, store: RetailStore(id: "R1", name: "Other"), market: .ca, maximumTotal: 4000)
    #expect(throws: CheckoutError.unsafeReview) { try value.validate(for: wrongStore, at: checkoutNow) }
    let wrongWindow = CheckoutRequest(variant: request().variant, store: request().store, market: .ca, maximumTotal: 4000,
                                      pickupWindow: DateWindow(start: checkoutNow, end: checkoutNow.addingTimeInterval(1)))
    #expect(throws: CheckoutError.unsafeReview) { try value.validate(for: wrongWindow, at: checkoutNow) }
    let wrongHours = CheckoutRequest(variant: request().variant, store: request().store, market: .ca, maximumTotal: 4000,
                                     pickupHours: DailyWindow(startMinute: 1, endMinute: 2), timeZoneIdentifier: "UTC")
    #expect(throws: CheckoutError.unsafeReview) { try value.validate(for: wrongHours, at: checkoutNow) }
}

@Test func checkoutReviewRejectsMissingOrConflictingAuthority() {
    let mutations: [(inout CheckoutSnapshot) -> Void] = [
        {$0.sourceURL = "https://evil.test/ca/shop/checkout"}, {$0.documentID = nil}, {$0.documentID = ""}, {$0.documentID = "not-a-document"},
        {$0.reviewStateID = nil}, {$0.reviewStateID = ""}, {$0.reviewStateID = "unknown"},
        {$0.phase = .payment}, {$0.phase = .loading}, {$0.hasErrors = true}, {$0.pickupOnly = false},
        {$0.finalActionCount = 2}, {$0.productIDs = ["OTHER/A"]}, {$0.productIDs.append("EXTRA/A")}, {$0.storeIDs = ["R999"]},
        {$0.quantities = [2]}, {$0.currencyCode = "USD"}, {$0.totalText = nil}, {$0.totalText = "bad"}, {$0.totalText = "$4,001.00"},
        {$0.pickupStartISO = nil}, {$0.pickupEndISO = nil}, {$0.pickupStartISO = "invalidZ"}, {$0.pickupEndISO = "invalidZ"},
        {$0.pickupStartISO = "2020-01-01T00:00:00Z"}, {$0.pickupEndISO = "2026-10-24T13:00:00Z"},
        {$0.pickupEndISO = $0.pickupStartISO}, {$0.pickupSlot = nil}, {$0.pickupSlot = ""}, {$0.pickupSlot = " \n\t "},
        {$0.pickupStartISO = "2026-02-30T14:00:00Z"}, {$0.pickupEndISO = "2026-10-24T24:00:00Z"}
    ]
    for mutate in mutations {
        var snapshot = evidence(); mutate(&snapshot)
        #expect(throws: (any Error).self) { try CheckoutPagePolicy.review(from: snapshot, request: request(), now: checkoutNow) }
    }
    var snapshot = evidence(); snapshot.phase = .authentication
    #expect(throws: CheckoutError.authenticationRequired) { try CheckoutPagePolicy.review(from: snapshot, request: request(), now: checkoutNow) }
    snapshot.phase = .unavailable
    #expect(throws: CheckoutError.unavailable) { try CheckoutPagePolicy.review(from: snapshot, request: request(), now: checkoutNow) }
    snapshot.phase = .blocked
    #expect(throws: CheckoutError.storefrontBlocked) { try CheckoutPagePolicy.review(from: snapshot, request: request(), now: checkoutNow) }
    snapshot.sourceURL = "https://other.test/ca/shop/checkout"
    #expect(throws: CheckoutError.unsupportedPage) { try CheckoutPagePolicy.review(from: snapshot, request: request(), now: checkoutNow) }
}

@Test func checkoutConfirmationNeedsOrderNumberAndTrustedOrigin() throws {
    var snapshot = evidence(); snapshot.phase = .confirmation; snapshot.orderID = "W1234567890"
    #expect(CheckoutPagePolicy.confirmation(from: snapshot, market: .ca) == "W1234567890")
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(CheckoutSnapshot.self, from: encoded) == snapshot)
    for id in [nil, "", "W123", "Thank you", "W1234567890 extra", "w1234567890", "W1234567890\n", "\nW1234567890"] as [String?] {
        snapshot.orderID = id; #expect(CheckoutPagePolicy.confirmation(from: snapshot, market: .ca) == nil)
    }
    snapshot.orderID = "W1234567890"; snapshot.hasErrors = true
    #expect(CheckoutPagePolicy.confirmation(from: snapshot, market: .ca) == nil)
    snapshot.hasErrors = false; snapshot.phase = .review
    #expect(CheckoutPagePolicy.confirmation(from: snapshot, market: .ca) == nil)
    snapshot.phase = .confirmation; snapshot.sourceURL = "https://other.test/ca/shop/thankyou"
    #expect(CheckoutPagePolicy.confirmation(from: snapshot, market: .ca) == nil)
    for error in [CheckoutError.authenticationRequired, .guestCheckoutUnavailable, .manualInputRequired, .storefrontBlocked, .unavailable, .unsupportedPage, .unsafeReview, .expiredReview, .cancelled, .sessionStorage] {
        #expect(!(error.errorDescription ?? "").isEmpty)
    }
    #expect(CheckoutOutcome.confirmed(orderID: "W1") == .confirmed(orderID: "W1"))
    #expect(CheckoutOutcome.indeterminate(reason: "unknown") != .unavailable)
}

@Test func checkoutAttentionStatesAreDistinctAndCodable() throws {
    #expect(CheckoutError.manualInputRequired.errorDescription?.contains("confirm the payment method") == true)
    #expect(CheckoutError.storefrontBlocked != .authenticationRequired)
    var snapshot = evidence(); snapshot.phase = .blocked
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(CheckoutSnapshot.self, from: encoded).phase == .blocked)
    #expect(CheckoutPagePolicy.confirmation(from: snapshot, market: .ca) == nil)
}

@Test func checkoutRequestAttemptPolicyChecksDateHoursAndTimeZone() throws {
    let base = request()
    let start = try #require(CheckoutPagePolicy.instant("2026-10-24T14:00:00Z"))
    let end = start.addingTimeInterval(3600)
    let bounded = CheckoutRequest(variant: base.variant, store: base.store, market: base.market, maximumTotal: base.maximumTotal,
                                  timeZoneIdentifier: "America/Toronto", attemptWindow: DateWindow(start: start, end: end),
                                  attemptHours: DailyWindow(startMinute: 600, endMinute: 660))
    #expect(bounded.permitsAttempt(at: start))
    #expect(bounded.permitsAttempt(at: end))
    #expect(!bounded.permitsAttempt(at: start.addingTimeInterval(-1)))
    #expect(!bounded.permitsAttempt(at: end.addingTimeInterval(1)))
    let outsideHours = CheckoutRequest(variant: base.variant, store: base.store, market: base.market, maximumTotal: base.maximumTotal,
                                      timeZoneIdentifier: "UTC", attemptWindow: DateWindow(start: start, end: end),
                                      attemptHours: DailyWindow(startMinute: 600, endMinute: 660))
    #expect(!outsideHours.permitsAttempt(at: start))
    let invalidZone = CheckoutRequest(variant: base.variant, store: base.store, market: base.market, maximumTotal: base.maximumTotal,
                                     timeZoneIdentifier: "Synthetic/Invalid")
    #expect(!invalidZone.permitsAttempt(at: start))
    #expect(base.permitsAttempt(at: start))
    let overnight = CheckoutRequest(variant: base.variant, store: base.store, market: base.market, maximumTotal: base.maximumTotal,
                                   timeZoneIdentifier: "UTC", attemptHours: DailyWindow(startMinute: 1320, endMinute: 120))
    #expect(overnight.permitsAttempt(at: try #require(CheckoutPagePolicy.instant("2026-10-24T23:00:00Z"))))
    #expect(overnight.permitsAttempt(at: try #require(CheckoutPagePolicy.instant("2026-10-25T01:00:00Z"))))
    #expect(!overnight.permitsAttempt(at: start))
}
