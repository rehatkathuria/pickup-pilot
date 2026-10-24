import CoreLocation
import Foundation
import MapKit
import PilotCore

@MainActor protocol StoreTravelProviding: AnyObject {
    func origin(for query: String, market: Market) async throws -> Coordinate
    func drivingRoute(from origin: Coordinate, to destination: Coordinate) async throws -> DrivingRoute
}

@MainActor protocol StoreAddressGeocoding: AnyObject {
    func geocodeAddressString(_ addressString: String, in region: CLRegion?, preferredLocale locale: Locale?) async throws -> [CLPlacemark]
    func cancelGeocode()
}
extension CLGeocoder: StoreAddressGeocoding {}

@MainActor protocol StoreDirectionsCalculating: AnyObject {
    func calculateETA() async throws -> MKDirections.ETAResponse
    func cancel()
}
extension MKDirections: StoreDirectionsCalculating {}

/// Cancellation handlers run off actor. Transfer only this MainActor-isolated handle;
/// the native geocoder/directions instance remains confined to the main actor.
@MainActor private final class StoreTravelCancellation {
    private let cancelOperation: () -> Void
    init(_ cancelOperation: @escaping () -> Void) { self.cancelOperation = cancelOperation }
    func cancel() { cancelOperation() }
}

/// Manual search and route requests use dedicated native objects. Cancelling an obsolete request
/// can never cancel another store's route or a newer postcode lookup. Nothing is persisted here.
@MainActor final class StoreTravelService: StoreTravelProviding {
    typealias GeocoderFactory = @MainActor () -> any StoreAddressGeocoding
    typealias DirectionsFactory = @MainActor (MKDirections.Request) -> any StoreDirectionsCalculating
    private let geocoderFactory: GeocoderFactory
    private let directionsFactory: DirectionsFactory

    init(geocoderFactory: @escaping GeocoderFactory = StoreTravelService.makeGeocoder,
         directionsFactory: @escaping DirectionsFactory = StoreTravelService.makeDirections) {
        self.geocoderFactory = geocoderFactory
        self.directionsFactory = directionsFactory
    }

    func origin(for query: String, market: Market) async throws -> Coordinate {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw StoreTravelError.emptyQuery }
        let geocoder = geocoderFactory()
        let cancellation = StoreTravelCancellation(geocoder.cancelGeocode)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                // The country qualifies the manual query; locale controls formatting, never physical location.
                // The returned ISO country is independently checked because a geocoder may ignore a query hint.
                let places = try await geocoder.geocodeAddressString("\(query), \(market.displayName)", in: nil,
                                                                     preferredLocale: Locale(identifier: "en_\(market.countryCode)"))
                try Task.checkCancellation()
                guard !places.isEmpty else { throw StoreTravelError.geocodingUnavailable }
                var candidates = Set<Coordinate>()
                for place in places {
                    guard let country = place.isoCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !country.isEmpty else { throw StoreTravelError.ambiguousLocation }
                    guard country.uppercased() == market.countryCode else { throw StoreTravelError.countryMismatch }
                    guard [place.postalCode, place.locality, place.subLocality].contains(where: {
                        !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    }) else { throw StoreTravelError.geocodingUnavailable }
                    guard let position = place.location?.coordinate else { throw StoreTravelError.invalidLocation }
                    let coordinate = Coordinate(latitude: position.latitude, longitude: position.longitude)
                    guard coordinate.isValid else { throw StoreTravelError.invalidLocation }
                    candidates.insert(coordinate)
                }
                guard candidates.count == 1, let coordinate = candidates.first else { throw StoreTravelError.ambiguousLocation }
                return coordinate
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                if let failure = error as? StoreTravelError { throw failure }
                throw StoreTravelError.geocodingUnavailable
            }
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
    }

    func drivingRoute(from origin: Coordinate, to destination: Coordinate) async throws -> DrivingRoute {
        try Task.checkCancellation()
        guard origin.isValid, destination.isValid else { throw StoreTravelError.invalidLocation }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        request.departureDate = Date()
        let directions = directionsFactory(request)
        let cancellation = StoreTravelCancellation(directions.cancel)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let response = try await directions.calculateETA()
                try Task.checkCancellation()
                guard response.transportType == .automobile,
                      response.distance.isFinite, response.distance >= 0,
                      response.expectedTravelTime.isFinite, response.expectedTravelTime >= 0 else {
                    throw StoreTravelError.routeUnavailable
                }
                return DrivingRoute(distanceKilometers: response.distance / 1_000, expectedTravelSeconds: response.expectedTravelTime)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw CancellationError() }
                throw StoreTravelError.routeUnavailable
            }
        } onCancel: {
            Task { @MainActor in cancellation.cancel() }
        }
    }

    static func makeGeocoder() -> any StoreAddressGeocoding { CLGeocoder() }
    static func makeDirections(_ request: MKDirections.Request) -> any StoreDirectionsCalculating { MKDirections(request: request) }
}

enum StoreTravelError: Error, Equatable, LocalizedError {
    case emptyQuery
    case countryMismatch
    case ambiguousLocation
    case invalidLocation
    case geocodingUnavailable
    case routeUnavailable
    var errorDescription: String? {
        switch self {
        case .emptyQuery: "Enter a postal code or city to calculate driving distances."
        case .countryMismatch: "The location did not match the selected shopping country. Enter a postal code or city in that country."
        case .ambiguousLocation: "The location was ambiguous. Enter a more precise postal code or city and region."
        case .invalidLocation: "A valid coordinate could not be resolved for this location."
        case .geocodingUnavailable: "Apple Maps could not resolve this location. Check the postal code or city and try again."
        case .routeUnavailable: "A driving route is unavailable for this store."
        }
    }
}
