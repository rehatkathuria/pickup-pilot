import Foundation

public struct RetailStore: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
    public var address: String
    public var countryCode: String?
    public init(id: String, name: String, latitude: Double? = nil, longitude: Double? = nil, address: String = "", countryCode: String? = nil) {
        self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude; self.address = address; self.countryCode = countryCode
    }
    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }
}
