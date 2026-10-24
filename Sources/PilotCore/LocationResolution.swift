import Foundation

public struct Coordinate: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
    public func distanceKilometers(to other: Coordinate) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (other.latitude - latitude) * radians
        let deltaLongitude = (other.longitude - longitude) * radians
        let a = pow(sin(deltaLatitude / 2), 2) + cos(latitude * radians) * cos(other.latitude * radians) * pow(sin(deltaLongitude / 2), 2)
        return 6_371 * 2 * atan2(sqrt(max(0, min(1, a))), sqrt(max(0, 1 - a)))
    }
}
public enum LocationAuthorization: String, Codable, Sendable { case notDetermined, allowed, denied, restricted }
public enum LocationSource: String, Codable, Sendable { case physical, manual }
public struct LocationSelection: Equatable, Sendable {
    public var market: Market
    public var query: String
    public var coordinate: Coordinate?
    public var source: LocationSource
    public init(market: Market, query: String, coordinate: Coordinate? = nil, source: LocationSource) {
        self.market = market; self.query = query; self.coordinate = coordinate; self.source = source
    }
}
public struct LocationFix: Sendable {
    public var coordinate: Coordinate
    public var countryCode: String
    public var postalCode: String?
    public var timestamp: Date
    public var horizontalAccuracy: Double
    public init(coordinate: Coordinate, countryCode: String, postalCode: String? = nil, timestamp: Date, horizontalAccuracy: Double) {
        self.coordinate = coordinate; self.countryCode = countryCode; self.postalCode = postalCode
        self.timestamp = timestamp; self.horizontalAccuracy = horizontalAccuracy
    }
}
public enum LocationResolution: Equatable, Sendable {
    case ready(LocationSelection)
    case manualRequired(String)
    case unsupportedCountry(String)
}
public enum LocationResolver {
    /// Locale is deliberately absent: language/region preferences do not establish physical location.
    public static func resolve(manual: LocationSelection? = nil, authorization: LocationAuthorization,
                               fix: LocationFix? = nil, now: Date = Date(), maximumAge: TimeInterval = 300) -> LocationResolution {
        if var manual {
            manual.query = manual.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !manual.query.isEmpty else { return .manualRequired("Enter a postal code or city for the selected country.") }
            if let coordinate = manual.coordinate, !coordinate.isValid { return .manualRequired("The manual coordinates are invalid.") }
            manual.source = .manual
            return .ready(manual)
        }
        guard authorization == .allowed else {
            return .manualRequired(authorization == .notDetermined ? "Allow location access or choose a country and postal code." : "Location access is unavailable. Choose a country and postal code.")
        }
        guard let fix else { return .manualRequired("A location could not be obtained. Enter a country and postal code.") }
        guard fix.coordinate.isValid, fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0,
              now.timeIntervalSince(fix.timestamp) <= maximumAge, fix.timestamp.timeIntervalSince(now) <= 60 else {
            return .manualRequired("The location is stale or inaccurate. Try again or enter a country and postal code.")
        }
        guard let market = Market(countryCode: fix.countryCode) else { return .unsupportedCountry(fix.countryCode) }
        let query = fix.postalCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Apple accepts a postal-code location; a coordinate is never silently treated as a postal code.
        guard !query.isEmpty else { return .manualRequired("Your country was detected as \(market.displayName). Enter a nearby postal code or city.") }
        return .ready(LocationSelection(market: market, query: query, coordinate: fix.coordinate, source: .physical))
    }
    public static func rank(_ stores: [RetailStore], near coordinate: Coordinate?) -> [RetailStore] {
        guard let coordinate, coordinate.isValid else { return stores }
        return stores.sorted { lhs, rhs in
            let left = lhs.coordinate.map { coordinate.distanceKilometers(to: $0) } ?? .infinity
            let right = rhs.coordinate.map { coordinate.distanceKilometers(to: $0) } ?? .infinity
            if left == right { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return left < right
        }
    }
    /// A country change invalidates store and SKU selections; identifiers are regional.
    public static func requiresSelectionReset(from old: Market, to new: Market) -> Bool { old != new }
}
