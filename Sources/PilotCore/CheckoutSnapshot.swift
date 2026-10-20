import Foundation

/// Sanitized page evidence only: never includes contact, card, address, cookies or page HTML.
public struct CheckoutSnapshot: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case loading, product, bag, fulfillment, contact, payment, review, confirmation, authentication, unavailable, blocked, pageNotFound, unknown }
    public var sourceURL: String
    public var phase: Phase
    public var productIDs: [String]
    public var storeIDs: [String]
    public var quantities: [Int]
    public var totalText: String?
    public var currencyCode: String?
    public var pickupStartISO: String?
    public var pickupEndISO: String?
    public var pickupSlot: String?
    public var orderID: String?
    public var finalActionCount: Int
    public var hasErrors: Bool
    public var pickupOnly: Bool
    public var bagIsEmpty: Bool
    /// Random for each injected document; carries no profile, cookie or server-session information.
    public var documentID: String?
    /// Random capability for the observed billing model and visible billing section; no payment information leaves JavaScript.
    public var reviewStateID: String?
    /// Explicit authoritative pickup-when-ready evidence; missing values retain strict reserved-slot validation.
    public var pickupIsUnscheduled: Bool?
    /// First observed blocking response only; no response headers, body or request values.
    public var blockingStatus: Int?
    /// Fixed diagnostic source: mainFrame, fetch or xhr.
    public var blockingSource: String?
    public init(sourceURL: String, phase: Phase = .unknown, productIDs: [String] = [], storeIDs: [String] = [], quantities: [Int] = [],
                totalText: String? = nil, currencyCode: String? = nil, pickupStartISO: String? = nil,
                pickupEndISO: String? = nil, pickupSlot: String? = nil, orderID: String? = nil,
                finalActionCount: Int = 0, hasErrors: Bool = false, pickupOnly: Bool = false, bagIsEmpty: Bool = false,
                documentID: String? = nil, reviewStateID: String? = nil, pickupIsUnscheduled: Bool? = nil,
                blockingStatus: Int? = nil, blockingSource: String? = nil) {
        self.sourceURL = sourceURL; self.phase = phase; self.productIDs = productIDs; self.storeIDs = storeIDs
        self.quantities = quantities; self.totalText = totalText; self.currencyCode = currencyCode
        self.pickupStartISO = pickupStartISO; self.pickupEndISO = pickupEndISO; self.pickupSlot = pickupSlot
        self.orderID = orderID; self.finalActionCount = finalActionCount; self.hasErrors = hasErrors; self.pickupOnly = pickupOnly
        self.bagIsEmpty = bagIsEmpty
        self.documentID = documentID
        self.reviewStateID = reviewStateID
        self.pickupIsUnscheduled = pickupIsUnscheduled
        self.blockingStatus = blockingStatus
        self.blockingSource = blockingSource
    }
}

public enum CheckoutPagePolicy {
    public static func isDocumentID(_ value: String?) -> Bool {
        guard let value, value.count == 36 else { return false }
        return UUID(uuidString: value) != nil
    }
    public static func isAppleHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil,
              url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }
    public static func isStorefront(_ url: URL, market: Market) -> Bool {
        guard isAppleHTTPS(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        // Browser URL normalization must not turn an apparently trusted prefix into a different path.
        let encodedPath = components.percentEncodedPath.lowercased()
        guard !encodedPath.contains("%2f"), !encodedPath.contains("%5c"),
              !url.path.contains("\\"), !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !url.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return url.path.hasPrefix("\(market.storefrontPath)/shop/")
    }
    public static func storefrontIdentity(_ url: URL, market: Market) -> String? {
        guard isStorefront(url, market: market), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"; components.host = url.host?.lowercased(); components.port = nil
        components.query = nil; components.fragment = nil
        return components.string
    }
    public static func review(from snapshot: CheckoutSnapshot, request: CheckoutRequest, now: Date) throws -> CheckoutReview {
        guard let url = URL(string: snapshot.sourceURL), isAppleHTTPS(url) else { throw CheckoutError.unsupportedPage }
        if snapshot.phase == .pageNotFound { throw CheckoutError.pageNotFound }
        guard let sourceURL = storefrontIdentity(url, market: request.market) else { throw CheckoutError.unsupportedPage }
        if snapshot.phase == .authentication { throw CheckoutError.authenticationRequired }
        if snapshot.phase == .blocked { throw CheckoutError.storefrontBlocked }
        if snapshot.phase == .unavailable { throw CheckoutError.unavailable }
        guard snapshot.phase == .review, !snapshot.hasErrors, snapshot.pickupOnly, isDocumentID(snapshot.documentID), isDocumentID(snapshot.reviewStateID),
              snapshot.finalActionCount == 1, snapshot.productIDs == [request.variant.id],
              snapshot.storeIDs == [request.store.id], snapshot.quantities == [1],
              snapshot.currencyCode == request.market.currencyCode,
              let totalText = snapshot.totalText, let total = amount(totalText, market: request.market),
              let slot = snapshot.pickupSlot else { throw CheckoutError.unsafeReview }
        let start: Date?
        let end: Date?
        let unscheduled = snapshot.pickupIsUnscheduled == true
        if unscheduled {
            guard request.allowsUnscheduledPickup, snapshot.pickupStartISO == nil, snapshot.pickupEndISO == nil else {
                throw CheckoutError.unsafeReview
            }
            start = nil; end = nil
        } else {
            guard let startText = snapshot.pickupStartISO, let endText = snapshot.pickupEndISO,
                  let reservedStart = instant(startText), let reservedEnd = instant(endText) else { throw CheckoutError.unsafeReview }
            start = reservedStart; end = reservedEnd
        }
        let review = CheckoutReview(variantID: request.variant.id, storeID: request.store.id, quantity: 1,
                                    total: total, currencyCode: request.market.currencyCode, pickupDate: start,
                                    pickupEndDate: end, pickupSlot: slot, expiresAt: now.addingTimeInterval(60), sourceURL: sourceURL,
                                    documentID: snapshot.documentID, reviewStateID: snapshot.reviewStateID,
                                    pickupIsUnscheduled: unscheduled)
        try review.validate(for: request, at: now)
        return review
    }
    public static func confirmation(from snapshot: CheckoutSnapshot, market: Market) -> String? {
        guard let url = URL(string: snapshot.sourceURL), isStorefront(url, market: market),
              snapshot.phase == .confirmation, !snapshot.hasErrors,
              let id = snapshot.orderID, id.range(of: "\\A[A-Z][0-9]{8,14}\\z", options: .regularExpression) != nil else { return nil }
        return id
    }
    public static func amount(_ raw: String, market: Market) -> Decimal? {
        // Restrict characters rather than silently stripping arbitrary text or negative signs.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbols: [String]
        switch market {
        case .ca: symbols = ["CAD", "CA$", "C$", "$"]
        case .us: symbols = ["USD", "US$", "$"]
        case .uk: symbols = ["GBP", "£"]
        case .au: symbols = ["AUD", "A$", "$"]
        case .de, .fr, .it, .es, .nl, .at, .be: symbols = ["EUR", "€"]
        case .jp: symbols = ["JPY", "¥", "￥", "円"]
        case .cn: symbols = ["CNY", "RMB", "¥", "￥", "元"]
        case .hk: symbols = ["HKD", "HK$", "$"]
        case .sg: symbols = ["SGD", "S$", "$"]
        case .ae: symbols = ["AED"]
        case .in: symbols = ["INR", "₹"]
        case .mx: symbols = ["MXN", "$"]
        case .kr: symbols = ["KRW", "₩"]
        case .tw: symbols = ["TWD", "NT$", "$"]
        case .th: symbols = ["THB", "฿"]
        case .my: symbols = ["MYR", "RM"]
        case .se: symbols = ["SEK", "kr"]
        case .ch: symbols = ["CHF"]
        }
        for symbol in symbols {
            if text.hasPrefix(symbol) { text.removeFirst(symbol.count); break }
            if text.hasSuffix(symbol) { text.removeLast(symbol.count); break }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let commaDecimal: Set<Market> = [.de, .fr, .it, .es, .nl, .at, .be, .se]
        if commaDecimal.contains(market) {
            guard text.range(of: "^[0-9]{1,3}([. \\u{00a0}\\u{202f}][0-9]{3})*(,[0-9]{2})?$|^[0-9]+(,[0-9]{2})?$", options: .regularExpression) != nil else { return nil }
            text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: ",", with: ".")
        } else {
            guard text.range(of: "^[0-9]{1,3}(,[0-9]{3})*(\\.[0-9]{1,2})?$|^[0-9]+(\\.[0-9]{1,2})?$", options: .regularExpression) != nil else { return nil }
            text = text.replacingOccurrences(of: ",", with: "")
        }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func instant(_ raw: String) -> Date? {
        // ISO8601DateFormatter accepts prefixes and normalizes invalid calendar dates; verify both first.
        let pattern = "\\A[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\\z"
        guard raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let dateParts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3, dateParts[0] > 0 else { return nil }
        let year = dateParts[0], month = dateParts[1], day = dateParts[2]
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= monthDays[month - 1] else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: raw)
    }
}
