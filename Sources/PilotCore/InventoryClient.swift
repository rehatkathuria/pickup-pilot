import Foundation

public enum AvailabilityState: String, Codable, Sendable { case available, unavailable, disabled }
public struct StoreAvailability: Codable, Equatable, Sendable {
    public var storeID: String
    public var variantID: String
    public var state: AvailabilityState
    public var message: String
    public init(storeID: String, variantID: String, state: AvailabilityState, message: String) {
        self.storeID = storeID; self.variantID = variantID; self.state = state; self.message = message
    }
}
public struct InventorySnapshot: Codable, Equatable, Sendable {
    public var stores: [RetailStore]
    public var availability: [StoreAvailability]
    public init(stores: [RetailStore], availability: [StoreAvailability]) { self.stores = stores; self.availability = availability }
}
public protocol InventoryFetching: Sendable {
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot
}
public actor AppleInventoryClient: InventoryFetching {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }
    public func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty, !variants.isEmpty, variants.count <= 20,
              Set(variants.map(\.id)).count == variants.count,
              variants.allSatisfy({ !$0.id.isEmpty && $0.productURL.host == "www.apple.com" &&
                  $0.productURL.scheme == "https" && $0.productURL.path.hasPrefix(market.storefrontPath + "/shop/") }) else {
            throw AppleServiceError.invalidInput("Choose a location and one to twenty variants from the selected country's catalog.")
        }
        var components = URLComponents(string: "https://www.apple.com\(market.storefrontPath)/shop/retail/pickup-message")!
        components.queryItems = [URLQueryItem(name: "pl", value: "true"), URLQueryItem(name: "location", value: location)] +
            variants.enumerated().map { URLQueryItem(name: "parts.\($0.offset)", value: $0.element.id) }
        try Task.checkCancellation()
        let response = try await transport.data(for: AppleHTTP.request(url: components.url!))
        try Task.checkCancellation()
        try AppleHTTP.validate(response)
        return try InventoryParser.parse(response.data, variantIDs: variants.map(\.id), market: market)
    }
}
public enum InventoryParser {
    public static func parse(_ data: Data, variantIDs: [String], market: Market? = nil) throws -> InventorySnapshot {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw AppleServiceError.invalidResponse("Missing or malformed product pickup fields") }
        var stores: [RetailStore] = []
        var availability: [StoreAvailability] = []
        var seen = Set<String>()
        for store in envelope.body.stores {
            if let market {
                guard store.country?.uppercased() == market.countryCode else {
                    throw AppleServiceError.invalidResponse("Pickup stores did not match the selected country")
                }
            }
            guard !store.storeNumber.isEmpty, !store.storeName.isEmpty, seen.insert(store.storeNumber).inserted else {
                throw AppleServiceError.invalidResponse("Missing or duplicate store identity")
            }
            let address = [store.address?.address2, store.city, store.state, store.address?.postalCode].compactMap { $0 }.joined(separator: ", ")
            stores.append(RetailStore(id: store.storeNumber, name: store.storeName, latitude: store.storelatitude,
                                      longitude: store.storelongitude, address: address, countryCode: store.country))
            for id in variantIDs {
                guard let part = store.partsAvailability[id], let regular = part.messageTypes?.regular,
                      let display = part.pickupDisplay, let selectionEnabled = regular.storeSelectionEnabled,
                      let searchEnabled = regular.storeSearchEnabled else {
                    throw AppleServiceError.invalidResponse("Product availability or enablement is missing for \(id)")
                }
                // Generic retailStore.availableNow describes the store, never requested-product stock.
                let state: AvailabilityState
                if !selectionEnabled || !searchEnabled || part.storePickEligible == false { state = .disabled }
                else if display == "available" { state = .available }
                else if ["unavailable", "default", "ineligible", "notAvailable"].contains(display) { state = .unavailable }
                else { throw AppleServiceError.invalidResponse("Unknown pickupDisplay value: \(display)") }
                availability.append(StoreAvailability(storeID: store.storeNumber, variantID: id, state: state,
                    message: regular.storePickupQuote ?? part.pickupSearchQuote ?? "No pickup quote supplied"))
            }
        }
        return InventorySnapshot(stores: stores, availability: availability)
    }
    private struct Envelope: Decodable { let body: Body }
    private struct Body: Decodable { let stores: [Store] }
    private struct Store: Decodable {
        let storeNumber: String; let storeName: String; let storelatitude: Double?; let storelongitude: Double?
        let city: String?; let state: String?; let country: String?; let address: Address?; let partsAvailability: [String: Part]
    }
    private struct Address: Decodable { let address2: String?; let postalCode: String? }
    private struct Part: Decodable {
        let storePickEligible: Bool?; let pickupDisplay: String?; let pickupSearchQuote: String?; let messageTypes: Messages?
    }
    private struct Messages: Decodable { let regular: Regular? }
    private struct Regular: Decodable {
        let storeSelectionEnabled: Bool?; let storeSearchEnabled: Bool?; let storePickupQuote: String?
    }
}
