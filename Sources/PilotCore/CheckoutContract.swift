import Foundation

public struct CheckoutRequest: Equatable, Sendable {
    public let variant: ProductVariant
    public let store: RetailStore
    public let market: Market
    public let maximumTotal: Decimal
    public let pickupWindow: DateWindow
    public let pickupHours: DailyWindow
    public let timeZoneIdentifier: String
    public let attemptWindow: DateWindow
    public let attemptHours: DailyWindow
    public init(variant: ProductVariant, store: RetailStore, market: Market, maximumTotal: Decimal,
                pickupWindow: DateWindow = DateWindow(start: .distantPast, end: .distantFuture),
                pickupHours: DailyWindow = DailyWindow(), timeZoneIdentifier: String = TimeZone.current.identifier,
                attemptWindow: DateWindow = DateWindow(start: .distantPast, end: .distantFuture),
                attemptHours: DailyWindow = DailyWindow()) {
        self.variant = variant; self.store = store; self.market = market; self.maximumTotal = maximumTotal
        self.pickupWindow = pickupWindow; self.pickupHours = pickupHours; self.timeZoneIdentifier = timeZoneIdentifier
        self.attemptWindow = attemptWindow; self.attemptHours = attemptHours
    }
    public func permitsAttempt(at date: Date) -> Bool {
        attemptWindow.contains(date) && attemptHours.contains(date, timeZone: timeZoneIdentifier)
    }
    /// Only this verified accessory can use Apple's pickup-when-ready flow without a reserved interval.
    public var allowsUnscheduledPickup: Bool {
        CatalogProduct.usbCHeadphoneAdapter.permits(variant: variant, market: market)
    }
}

public struct CheckoutReview: Equatable, Sendable {
    public let token: UUID
    public let variantID: String
    public let storeID: String
    public let quantity: Int
    public let total: Decimal
    public let currencyCode: String
    public let pickupDate: Date?
    public let pickupEndDate: Date?
    public let pickupSlot: String
    public let expiresAt: Date
    /// Validated Apple host and path only; never retain checkout query or fragment tokens.
    public let sourceURL: String?
    /// Opaque identity of the WebKit document that supplied this review, never an Apple session identifier.
    public let documentID: String?
    /// Opaque identity of the privately observed billing review state, never payment data or a hash of it.
    public let reviewStateID: String?
    public let pickupIsUnscheduled: Bool
    public init(token: UUID = UUID(), variantID: String, storeID: String, quantity: Int, total: Decimal,
                currencyCode: String, pickupDate: Date?, pickupEndDate: Date?, pickupSlot: String, expiresAt: Date,
                sourceURL: String? = nil, documentID: String? = nil, reviewStateID: String? = nil,
                pickupIsUnscheduled: Bool = false) {
        self.token = token; self.variantID = variantID; self.storeID = storeID; self.quantity = quantity
        self.total = total; self.currencyCode = currencyCode; self.pickupDate = pickupDate
        self.pickupEndDate = pickupEndDate; self.pickupSlot = pickupSlot; self.expiresAt = expiresAt
        self.sourceURL = sourceURL
        self.documentID = documentID
        self.reviewStateID = reviewStateID
        self.pickupIsUnscheduled = pickupIsUnscheduled
    }
    public func validate(for request: CheckoutRequest, at now: Date) throws {
        guard now < expiresAt else { throw CheckoutError.expiredReview }
        if let documentID, !CheckoutPagePolicy.isDocumentID(documentID) { throw CheckoutError.unsafeReview }
        if let reviewStateID, !CheckoutPagePolicy.isDocumentID(reviewStateID) { throw CheckoutError.unsafeReview }
        guard variantID == request.variant.id, storeID == request.store.id, quantity == 1,
              !total.isNaN, !request.maximumTotal.isNaN,
              total > 0, total <= request.maximumTotal, currencyCode == request.market.currencyCode,
              !pickupSlot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CheckoutError.unsafeReview
        }
        if pickupIsUnscheduled {
            guard request.allowsUnscheduledPickup, pickupDate == nil, pickupEndDate == nil else {
                throw CheckoutError.unsafeReview
            }
            return
        }
        guard let pickupDate, let pickupEndDate,
              pickupDate >= now, pickupEndDate > pickupDate,
              request.pickupWindow.contains(pickupDate), request.pickupWindow.contains(pickupEndDate),
              request.pickupHours.contains(start: pickupDate, end: pickupEndDate, timeZone: request.timeZoneIdentifier) else {
            throw CheckoutError.unsafeReview
        }
    }
}

public enum CheckoutOutcome: Equatable, Sendable {
    case confirmed(orderID: String)
    case requiresAuthentication
    case unavailable
    case indeterminate(reason: String)
}

public enum CheckoutError: Error, Equatable, LocalizedError, Sendable {
    case authenticationRequired
    case guestCheckoutUnavailable
    case guestCheckoutRefused
    case manualInputRequired
    case storefrontBlocked
    case pageNotFound
    case sessionRecoveryNotReady
    case unavailable
    case unsupportedPage
    case unsafeReview
    case expiredReview
    case cancelled
    case sessionStorage
    case safariUnavailable
    case safariPermissionRequired
    case safariJavaScriptDisabled
    case safariWindowUnavailable
    case safariNavigationChanged
    case safariAutomationFailed
    public var isSafariFailure: Bool {
        switch self {
        case .safariUnavailable, .safariPermissionRequired, .safariJavaScriptDisabled, .safariWindowUnavailable, .safariNavigationChanged, .safariAutomationFailed: true
        default: false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired, .guestCheckoutUnavailable: "Guest checkout could not continue. This app uses guest checkout only and will not request sign-in or authentication. Automatic checkout has stopped."
        case .guestCheckoutRefused: "Apple refused the guest checkout request with an access response and redirected to an error page. This app will not retry, sign in, or work around Apple's response. Automatic checkout has stopped."
        case .manualInputRequired: "Complete required fields and confirm the payment method on Apple’s final review, then continue."
        case .storefrontBlocked: "An Apple checkout request returned an access or rate-limit response. Review the response details in the checkout window before trying again."
        case .pageNotFound: "Apple's checkout destination could not be found. Return to a working bag or product page before starting a new attempt."
        case .sessionRecoveryNotReady: "The current Apple page is not a stable, verified checkout page. Return to a working bag or product page before saving its session."
        case .unavailable: "Apple no longer offers this pickup configuration or store."
        case .unsupportedPage: "Apple's current checkout page could not be verified. Open the checkout window; automatic submission is blocked."
        case .unsafeReview: "The final SKU, pickup store, quantity, total or pickup slot did not match your armed limits."
        case .expiredReview: "The checkout review expired. Prepare a new review before submitting."
        case .cancelled: "Checkout was cancelled."
        case .sessionStorage: "The secure Apple session could not be saved. Checkout is paused."
        case .safariUnavailable: "Safari could not be opened. Check that Safari is installed, then start a new attempt."
        case .safariPermissionRequired: "Allow Pickup Pilot to control Safari in System Settings > Privacy & Security > Automation, then try again."
        case .safariJavaScriptDisabled: "Enable Allow JavaScript from Apple Events in Safari Settings > Developer > Automation. Enable web developer features in Settings > Advanced if Developer settings are hidden, then try again."
        case .safariWindowUnavailable: "Pickup Pilot's Safari window was closed or changed. Start a new attempt with a dedicated checkout window."
        case .safariNavigationChanged: "Safari is changing checkout pages. Waiting for the current page before continuing."
        case .safariAutomationFailed: "Safari did not complete the checkout action reliably. Automatic attempts have stopped. Inspect the checkout before starting a new attempt."
        }
    }
}

/// WebKit is UI-bound. The coordinator must durably record submission intent before submit is called.
@MainActor public protocol CheckoutDriver: AnyObject {
    func prepare(request: CheckoutRequest, profile: SecureProfile) async throws -> CheckoutReview
    func submit(review: CheckoutReview) async throws -> CheckoutOutcome
    func cancel()
}
