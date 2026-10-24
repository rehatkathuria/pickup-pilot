import Foundation

public struct PurchaseJournal: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, submitting, confirmed, uncertain }
    public var phase: Phase
    public var attemptID: UUID?
    public var orderID: String?
    public var variantID: String?
    public var storeID: String?
    public var receipt: PurchaseReceipt?
    public var updatedAt: Date
    public init(phase: Phase = .idle, attemptID: UUID? = nil, orderID: String? = nil, variantID: String? = nil, storeID: String? = nil, receipt: PurchaseReceipt? = nil, updatedAt: Date = Date()) {
        self.phase = phase; self.attemptID = attemptID; self.orderID = orderID
        self.variantID = variantID; self.storeID = storeID; self.receipt = receipt; self.updatedAt = updatedAt
    }
    public var blocksPurchase: Bool { phase != .idle }
}

public protocol PurchaseJournalStore: Sendable {
    func load() async throws -> PurchaseJournal
    func save(_ journal: PurchaseJournal) async throws
}

public struct KeychainJournalStore: PurchaseJournalStore {
    private let vault: any SecureVault
    public init(vault: any SecureVault) { self.vault = vault }
    public func load() async throws -> PurchaseJournal {
        guard let data = try await vault.loadOrderState() else { return PurchaseJournal() }
        return try JSONDecoder().decode(PurchaseJournal.self, from: data)
    }
    public func save(_ journal: PurchaseJournal) async throws {
        try await vault.saveOrderState(JSONEncoder().encode(journal))
    }
}

public struct PurchaseReceipt: Codable, Equatable, Sendable {
    public let market: Market
    public let variantName: String
    public let storeName: String
    public let total: Decimal
    public let currencyCode: String
    public let pickupStart: Date?
    public let pickupEnd: Date?
    public let pickupSlot: String
    /// Optional so journals written before pickup-when-ready support still decode unchanged.
    public let pickupIsUnscheduled: Bool?
    public init(request: CheckoutRequest, review: CheckoutReview) {
        market = request.market; variantName = request.variant.name; storeName = request.store.name
        total = review.total; currencyCode = review.currencyCode
        pickupStart = review.pickupDate; pickupEnd = review.pickupEndDate; pickupSlot = review.pickupSlot
        pickupIsUnscheduled = review.pickupIsUnscheduled
    }
}
