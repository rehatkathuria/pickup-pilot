import Foundation
import Testing
@testable import PilotCore

private let whenReadyNow = Date(timeIntervalSince1970: 1_792_166_400)
private let whenReadyLabel = "Pickup after Apple confirms it is ready"

private func whenReadyRequest(variant: ProductVariant? = nil, market: Market = .ca,
                              pickupWindow: DateWindow = DateWindow(start: .distantPast, end: .distantFuture),
                              pickupHours: DailyWindow = DailyWindow()) -> CheckoutRequest {
    CheckoutRequest(variant: variant ?? ProductVariant(id: CatalogProduct.adapterSKU, name: "Synthetic adapter", storage: "", color: "",
                                                       productURL: CatalogProduct.adapterURL),
                    store: RetailStore(id: "R121", name: "Synthetic store"), market: market, maximumTotal: 20,
                    pickupWindow: pickupWindow, pickupHours: pickupHours, timeZoneIdentifier: "UTC")
}

private func whenReadyEvidence() -> CheckoutSnapshot {
    CheckoutSnapshot(sourceURL: "https://secure7.store.apple.com/ca/shop/checkout", phase: .review,
                     productIDs: [CatalogProduct.adapterSKU], storeIDs: ["R121"], quantities: [1],
                     totalText: "CA$11.30", currencyCode: "CAD", pickupSlot: whenReadyLabel,
                     finalActionCount: 1, pickupOnly: true,
                     documentID: "00000000-0000-4000-8000-000000000001",
                     reviewStateID: "00000000-0000-4000-8000-000000000002", pickupIsUnscheduled: true)
}

private func whenReadyReview(request: CheckoutRequest, start: Date? = nil, end: Date? = nil,
                             unscheduled: Bool = true, expiresAt: Date = whenReadyNow.addingTimeInterval(60)) -> CheckoutReview {
    CheckoutReview(variantID: request.variant.id, storeID: request.store.id, quantity: 1, total: Decimal(string: "11.30")!,
                   currencyCode: request.market.currencyCode, pickupDate: start, pickupEndDate: end,
                   pickupSlot: whenReadyLabel, expiresAt: expiresAt, pickupIsUnscheduled: unscheduled)
}

@Test func pickupWhenReadyOptInRequiresTheExactCanadianAccessory() {
    let allowed = whenReadyRequest()
    #expect(allowed.allowsUnscheduledPickup)
    for market in Market.allCases where market != .ca {
        #expect(!whenReadyRequest(market: market).allowsUnscheduledPickup)
    }
    var other = allowed.variant; other.id = "OTHER/A"
    #expect(!whenReadyRequest(variant: other).allowsUnscheduledPickup)
    other = allowed.variant; other.productURL = CatalogProduct.adapterURL.appendingPathComponent("other")
    #expect(!whenReadyRequest(variant: other).allowsUnscheduledPickup)
    other = allowed.variant; other.productURL = URL(string: CatalogProduct.adapterURL.absoluteString + "?other=1")!
    #expect(!whenReadyRequest(variant: other).allowsUnscheduledPickup)
    let phone = ProductVariant(id: "SYNTHETIC-PHONE/A", name: "Synthetic iPhone Duo", storage: "256GB", color: "Night Sky",
                               productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic"))
    #expect(!whenReadyRequest(variant: phone).allowsUnscheduledPickup)
}

@Test func explicitAccessoryPickupWhenReadyNeverInventsAReservedInterval() throws {
    let request = whenReadyRequest(pickupWindow: DateWindow(start: whenReadyNow.addingTimeInterval(-20), end: whenReadyNow.addingTimeInterval(-10)),
                                   pickupHours: DailyWindow(startMinute: 1, endMinute: 2))
    let snapshot = whenReadyEvidence()
    let review = try CheckoutPagePolicy.review(from: snapshot, request: request, now: whenReadyNow)
    #expect(review.pickupIsUnscheduled)
    #expect(review.pickupDate == nil && review.pickupEndDate == nil)
    #expect(review.pickupSlot == whenReadyLabel)
    #expect(review.documentID == snapshot.documentID && review.reviewStateID == snapshot.reviewStateID)
    #expect(review.sourceURL == snapshot.sourceURL && review.expiresAt == whenReadyNow.addingTimeInterval(60))
    try review.validate(for: request, at: whenReadyNow)
    #expect(throws: CheckoutError.expiredReview) { try review.validate(for: request, at: review.expiresAt) }
}

@Test func pickupWhenReadyRejectsMissingFlagsPartialDatesAndContradictoryIntervals() {
    let mutations: [(inout CheckoutSnapshot) -> Void] = [
        { $0.pickupIsUnscheduled = nil }, { $0.pickupIsUnscheduled = false },
        { $0.pickupStartISO = "2026-10-24T14:00:00Z" }, { $0.pickupEndISO = "2026-10-24T14:15:00Z" },
        { $0.pickupStartISO = "2026-10-24T14:00:00Z"; $0.pickupEndISO = "2026-10-24T14:15:00Z" },
        { $0.pickupStartISO = "" }, { $0.pickupEndISO = "" },
        { $0.pickupStartISO = "invalid" }, { $0.pickupEndISO = "invalid" },
        { $0.pickupSlot = nil }, { $0.pickupSlot = "" }, { $0.pickupSlot = " \n\t " }
    ]
    for mutate in mutations {
        var snapshot = whenReadyEvidence(); mutate(&snapshot)
        #expect(throws: CheckoutError.unsafeReview) {
            try CheckoutPagePolicy.review(from: snapshot, request: whenReadyRequest(), now: whenReadyNow)
        }
    }
}

@Test func pickupWhenReadyStillRequiresEveryAuthoritativeCheckoutLimit() {
    let mutations: [(inout CheckoutSnapshot) -> Void] = [
        { $0.sourceURL = "https://evil.test/ca/shop/checkout" }, { $0.sourceURL = "https://secure7.store.apple.com/shop/checkout" },
        { $0.phase = .payment }, { $0.hasErrors = true }, { $0.pickupOnly = false },
        { $0.productIDs = ["OTHER/A"] }, { $0.productIDs.append("EXTRA/A") }, { $0.storeIDs = ["R999"] },
        { $0.quantities = [2] }, { $0.quantities = [1, 1] }, { $0.totalText = "CA$20.01" }, { $0.totalText = "CA$0.00" },
        { $0.currencyCode = "USD" }, { $0.totalText = "invalid" }, { $0.finalActionCount = 0 }, { $0.finalActionCount = 2 },
        { $0.documentID = nil }, { $0.documentID = "invalid" }, { $0.reviewStateID = nil }, { $0.reviewStateID = "invalid" }
    ]
    for mutate in mutations {
        var snapshot = whenReadyEvidence(); mutate(&snapshot)
        #expect(throws: (any Error).self) {
            try CheckoutPagePolicy.review(from: snapshot, request: whenReadyRequest(), now: whenReadyNow)
        }
    }
}

@Test func pickupWhenReadyCannotBeAppliedToPhonesOrReviewsWithDates() throws {
    let adapter = whenReadyRequest()
    let date = whenReadyNow.addingTimeInterval(3600)
    for (start, end) in [(date, nil), (nil, date), (date, date.addingTimeInterval(900))] as [(Date?, Date?)] {
        let contradictory = whenReadyReview(request: adapter, start: start, end: end)
        #expect(throws: CheckoutError.unsafeReview) { try contradictory.validate(for: adapter, at: whenReadyNow) }
    }
    for (start, end) in [(nil, nil), (date, nil), (nil, date)] as [(Date?, Date?)] {
        let incomplete = whenReadyReview(request: adapter, start: start, end: end, unscheduled: false)
        #expect(throws: CheckoutError.unsafeReview) { try incomplete.validate(for: adapter, at: whenReadyNow) }
    }
    let phone = ProductVariant(id: "SYNTHETIC-PHONE/A", name: "Synthetic phone", storage: "256GB", color: "Night Sky",
                               productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic"))
    let phoneRequest = whenReadyRequest(variant: phone)
    let unreservedPhone = whenReadyReview(request: phoneRequest)
    #expect(throws: CheckoutError.unsafeReview) { try unreservedPhone.validate(for: phoneRequest, at: whenReadyNow) }
    var snapshot = whenReadyEvidence(); snapshot.productIDs = [phone.id]
    #expect(throws: CheckoutError.unsafeReview) {
        try CheckoutPagePolicy.review(from: snapshot, request: phoneRequest, now: whenReadyNow)
    }
    let reservedPhone = whenReadyReview(request: phoneRequest, start: date, end: date.addingTimeInterval(900), unscheduled: false)
    try reservedPhone.validate(for: phoneRequest, at: whenReadyNow)
    let expired = whenReadyReview(request: adapter, expiresAt: whenReadyNow)
    #expect(throws: CheckoutError.expiredReview) { try expired.validate(for: adapter, at: whenReadyNow) }
}

@Test func reservedAccessorySlotsRetainTheFullIntervalPolicyWithLegacyFlags() throws {
    for flag in [nil, false] as [Bool?] {
        var snapshot = whenReadyEvidence(); snapshot.pickupIsUnscheduled = flag
        snapshot.pickupStartISO = "2026-10-24T14:00:00Z"; snapshot.pickupEndISO = "2026-10-24T14:15:00Z"
        let review = try CheckoutPagePolicy.review(from: snapshot, request: whenReadyRequest(), now: whenReadyNow)
        #expect(!review.pickupIsUnscheduled && review.pickupDate != nil && review.pickupEndDate != nil)
        let outsideWindow = whenReadyRequest(pickupWindow: DateWindow(start: whenReadyNow, end: whenReadyNow.addingTimeInterval(1)))
        #expect(throws: CheckoutError.unsafeReview) { try review.validate(for: outsideWindow, at: whenReadyNow) }
        let outsideHours = whenReadyRequest(pickupHours: DailyWindow(startMinute: 1, endMinute: 2))
        #expect(throws: CheckoutError.unsafeReview) { try review.validate(for: outsideHours, at: whenReadyNow) }
    }
}

@Test func whenReadySnapshotAndReceiptRoundTripsPreserveNoDates() throws {
    let snapshot = whenReadyEvidence()
    let decoded = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot && decoded.pickupIsUnscheduled == true)
    let request = whenReadyRequest()
    let review = try CheckoutPagePolicy.review(from: decoded, request: request, now: whenReadyNow)
    let receipt = PurchaseReceipt(request: request, review: review)
    let data = try JSONEncoder().encode(receipt)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["pickupStart"] == nil && object["pickupEnd"] == nil && object["pickupIsUnscheduled"] as? Bool == true)
    #expect(try JSONDecoder().decode(PurchaseReceipt.self, from: data) == receipt)
    let journal = PurchaseJournal(phase: .confirmed, orderID: "W1234567890", variantID: request.variant.id,
                                  storeID: request.store.id, receipt: receipt, updatedAt: whenReadyNow)
    let restored = try JSONDecoder().decode(PurchaseJournal.self, from: JSONEncoder().encode(journal))
    #expect(restored == journal && restored.blocksPurchase)
    #expect(restored.receipt?.pickupStart == nil && restored.receipt?.pickupEnd == nil && restored.receipt?.pickupIsUnscheduled == true)
}

@Test func oldReservedReceiptsAndSnapshotsDecodeWithoutUnscheduledFlags() throws {
    let start = whenReadyNow.addingTimeInterval(3600), end = whenReadyNow.addingTimeInterval(4500)
    let receipt = PurchaseReceipt(request: whenReadyRequest(), review: whenReadyReview(request: whenReadyRequest(), start: start, end: end, unscheduled: false))
    // A literal legacy payload avoids converting Decimal through NSNumber/Double.
    let old = Data("""
    {"market":"ca","variantName":"Synthetic adapter","storeName":"Synthetic store","total":11.30,"currencyCode":"CAD","pickupStart":813862800,"pickupEnd":813863700,"pickupSlot":"Pickup after Apple confirms it is ready"}
    """.utf8)
    let decoded = try JSONDecoder().decode(PurchaseReceipt.self, from: old)
    #expect(decoded.pickupIsUnscheduled == nil && decoded.pickupStart == start && decoded.pickupEnd == end)
    #expect(decoded.pickupSlot == receipt.pickupSlot && decoded.total == receipt.total)
    var snapshot = whenReadyEvidence(); snapshot.pickupIsUnscheduled = nil
    snapshot.pickupStartISO = "2026-10-24T14:00:00Z"; snapshot.pickupEndISO = "2026-10-24T14:15:00Z"
    let legacySnapshot = try JSONDecoder().decode(CheckoutSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(legacySnapshot.pickupIsUnscheduled == nil)
    let review = try CheckoutPagePolicy.review(from: legacySnapshot, request: whenReadyRequest(), now: whenReadyNow)
    #expect(!review.pickupIsUnscheduled && review.pickupDate != nil && review.pickupEndDate != nil)
}
