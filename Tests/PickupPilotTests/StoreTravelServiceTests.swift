import CoreLocation
import Foundation
import MapKit
import PilotCore
import Testing
@testable import PickupPilot

private enum TravelSyntheticError: Error { case unavailable }

@MainActor private final class TravelGeocoderFixture: StoreAddressGeocoding {
    var response: Result<[CLPlacemark], Error> = .success([])
    var suspended = false
    var requests: [(String, CLRegion?, Locale?)] = []
    private(set) var cancellations = 0
    private var continuation: CheckedContinuation<[CLPlacemark], Error>?
    func geocodeAddressString(_ addressString: String, in region: CLRegion?, preferredLocale locale: Locale?) async throws -> [CLPlacemark] {
        requests.append((addressString, region, locale))
        if suspended { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try response.get()
    }
    func cancelGeocode() {
        cancellations += 1
        let pending = continuation; continuation = nil
        pending?.resume(throwing: CancellationError())
    }
    func finish(_ response: Result<[CLPlacemark], Error>) {
        let pending = continuation; continuation = nil
        pending?.resume(with: response)
    }
}

private final class TravelETAResponse: MKDirections.ETAResponse {
    private let meters: Double
    private let seconds: Double
    private let transport: MKDirectionsTransportType
    init(meters: Double = 4_200, seconds: Double = 800, transport: MKDirectionsTransportType = .automobile) {
        self.meters = meters; self.seconds = seconds; self.transport = transport
        super.init()
    }
    override var distance: CLLocationDistance { meters }
    override var expectedTravelTime: TimeInterval { seconds }
    override var transportType: MKDirectionsTransportType { transport }
}

@MainActor private final class TravelDirectionsFixture: StoreDirectionsCalculating {
    var response: Result<MKDirections.ETAResponse, Error> = .success(TravelETAResponse())
    var suspended = false
    private(set) var calculations = 0
    private(set) var cancellations = 0
    private var continuation: CheckedContinuation<MKDirections.ETAResponse, Error>?
    func calculateETA() async throws -> MKDirections.ETAResponse {
        calculations += 1
        if suspended { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try response.get()
    }
    func cancel() {
        cancellations += 1
        let pending = continuation; continuation = nil
        pending?.resume(throwing: CancellationError())
    }
    func finish(_ response: sending Result<MKDirections.ETAResponse, Error>) {
        let pending = continuation; continuation = nil
        pending?.resume(with: response)
    }
}

@Suite(.serialized) @MainActor struct StoreTravelServiceTests {
    private let origin = Coordinate(latitude: 43.6426, longitude: -79.3871)
    private let destination = Coordinate(latitude: 43.6544, longitude: -79.3807)
    private func place(country: String? = "CA", latitude: Double = 43.6426, longitude: Double = -79.3871,
                       postal: String? = "M5V 3L9", city: String? = "Toronto", subLocality: String? = nil) -> CLPlacemark {
        var fields: [String: Any] = [:]
        fields["CountryCode"] = country; fields["ZIP"] = postal; fields["City"] = city
        fields["SubLocality"] = subLocality
        return MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), addressDictionary: fields)
    }
    private func awaitCondition(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw TravelSyntheticError.unavailable
    }
    @Test func countryQualifiedManualLookupAcceptsOnePreciseMatchingOrigin() async throws {
        let geocoder = TravelGeocoderFixture()
        geocoder.response = .success([place(),place()])
        let service = StoreTravelService(geocoderFactory: { geocoder })
        #expect(try await service.origin(for: "  M5V 3L9\n", market: .ca) == origin)
        #expect(geocoder.requests.count == 1)
        #expect(geocoder.requests[0].0 == "M5V 3L9, Canada")
        #expect(geocoder.requests[0].1 == nil)
        #expect(geocoder.requests[0].2?.region?.identifier == "CA")
        #expect(geocoder.cancellations == 0)
        geocoder.response = .success([place(country: "GB", latitude: 51.5, longitude: -0.12, postal: nil, city: "London")])
        #expect(try await service.origin(for: "London", market: .uk) == Coordinate(latitude: 51.5, longitude: -0.12))
        #expect(geocoder.requests[1].0 == "London, United Kingdom")
        #expect(geocoder.requests[1].2?.region?.identifier == "GB")
    }
    @Test func manualLookupRejectsEmptyWrongCountryBroadAndAmbiguousResults() async {
        var factories = 0
        let geocoder = TravelGeocoderFixture()
        let service = StoreTravelService(geocoderFactory: { factories += 1; return geocoder })
        await #expect(throws: StoreTravelError.emptyQuery) { try await service.origin(for: " \n", market: .ca) }
        #expect(factories == 0)
        let cases: [([CLPlacemark],StoreTravelError)] = [
            ([], .geocodingUnavailable),
            ([place(country: nil)], .ambiguousLocation),
            ([place(country: " ")], .ambiguousLocation),
            ([place(country: "US")], .countryMismatch),
            ([place(),place(country: "US")], .countryMismatch),
            ([place(postal: nil,city: nil)], .geocodingUnavailable),
            ([place(postal: " ",city: " ")], .geocodingUnavailable),
            ([place(latitude: 100)], .invalidLocation),
            ([place(),place(latitude: 43.70)], .ambiguousLocation)
        ]
        for (places, failure) in cases {
            geocoder.response = .success(places)
            await #expect(throws: failure) { try await service.origin(for: "Synthetic location", market: .ca) }
        }
        geocoder.response = .failure(TravelSyntheticError.unavailable)
        await #expect(throws: StoreTravelError.geocodingUnavailable) { try await service.origin(for: "Synthetic", market: .ca) }
        geocoder.response = .failure(CancellationError())
        await #expect(throws: CancellationError.self) { try await service.origin(for: "Synthetic", market: .ca) }
        for failure in [StoreTravelError.emptyQuery,.countryMismatch,.ambiguousLocation,.invalidLocation,.geocodingUnavailable,.routeUnavailable] {
            #expect(failure.errorDescription?.isEmpty == false)
            #expect(!failure.localizedDescription.contains("Synthetic"))
        }
    }
    @Test func automobileETAUsesNativeRequestAndConvertsMetersWithoutSpeedGuessing() async throws {
        let directions = TravelDirectionsFixture()
        var requests: [MKDirections.Request] = []
        let service = StoreTravelService(directionsFactory: { request in requests.append(request); return directions })
        #expect(try await service.drivingRoute(from: origin,to: destination) == DrivingRoute(distanceKilometers: 4.2, expectedTravelSeconds: 800))
        let request = try #require(requests.first)
        #expect(request.transportType == .automobile && !request.requestsAlternateRoutes)
        #expect(request.departureDate != nil)
        #expect(request.source?.placemark.coordinate.latitude == origin.latitude)
        #expect(request.source?.placemark.coordinate.longitude == origin.longitude)
        #expect(request.destination?.placemark.coordinate.latitude == destination.latitude)
        #expect(request.destination?.placemark.coordinate.longitude == destination.longitude)
        directions.response = .success(TravelETAResponse(meters: 0,seconds: 0))
        #expect(try await service.drivingRoute(from: origin,to: origin) == DrivingRoute(distanceKilometers: 0,expectedTravelSeconds: 0))
    }
    @Test func routeValidationFailsClosedForInvalidCoordinatesAndUnavailableNumbers() async {
        let directions = TravelDirectionsFixture()
        var factories = 0
        let service = StoreTravelService(directionsFactory: { _ in factories += 1; return directions })
        await #expect(throws: StoreTravelError.invalidLocation) { try await service.drivingRoute(from: Coordinate(latitude: .nan,longitude: 0),to: destination) }
        await #expect(throws: StoreTravelError.invalidLocation) { try await service.drivingRoute(from: origin,to: Coordinate(latitude: 91,longitude: 0)) }
        #expect(factories == 0)
        for response in [TravelETAResponse(meters: -.infinity), TravelETAResponse(meters: -1),TravelETAResponse(meters: .nan),
                         TravelETAResponse(seconds: .infinity),TravelETAResponse(seconds: -1),TravelETAResponse(transport: .walking)] {
            directions.response = .success(response)
            await #expect(throws: StoreTravelError.routeUnavailable) { try await service.drivingRoute(from: origin,to: destination) }
        }
        directions.response = .failure(TravelSyntheticError.unavailable)
        await #expect(throws: StoreTravelError.routeUnavailable) { try await service.drivingRoute(from: origin,to: destination) }
        directions.response = .failure(CancellationError())
        await #expect(throws: CancellationError.self) { try await service.drivingRoute(from: origin,to: destination) }
    }
    @Test func cancellationOnlyCancelsItsOwnManualGeocodeAndLeavesNewRequestAlive() async throws {
        let first = TravelGeocoderFixture(); first.suspended = true
        let second = TravelGeocoderFixture(); second.suspended = true
        var factories = 0
        let service = StoreTravelService(geocoderFactory: { factories += 1; return factories == 1 ? first : second })
        let old = Task { try await service.origin(for: "First synthetic",market: .ca) }
        try await awaitCondition { first.requests.count == 1 }
        let newer = Task { try await service.origin(for: "Second synthetic",market: .ca) }
        try await awaitCondition { second.requests.count == 1 }
        old.cancel()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(first.cancellations == 1 && second.cancellations == 0)
        second.finish(.success([place()]))
        #expect(try await newer.value == origin)
    }
    @Test func cancellationOnlyCancelsItsOwnStoreRouteAndLeavesOtherStoreAlive() async throws {
        let first = TravelDirectionsFixture(); first.suspended = true
        let second = TravelDirectionsFixture(); second.suspended = true
        var factories = 0
        let service = StoreTravelService(directionsFactory: { _ in factories += 1; return factories == 1 ? first : second })
        let old = Task { try await service.drivingRoute(from: origin,to: destination) }
        try await awaitCondition { first.calculations == 1 }
        let newer = Task { try await service.drivingRoute(from: origin,to: destination) }
        try await awaitCondition { second.calculations == 1 }
        old.cancel()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(first.cancellations == 1 && second.cancellations == 0)
        second.finish(.success(TravelETAResponse(meters: 2_000,seconds: 100)))
        #expect(try await newer.value == DrivingRoute(distanceKilometers: 2,expectedTravelSeconds: 100))
    }
    @Test func alreadyCancelledTasksNeverStartNativeRequests() async {
        var factoryCalls = 0
        let service = StoreTravelService(geocoderFactory: { factoryCalls += 1; return TravelGeocoderFixture() },
                                         directionsFactory: { _ in factoryCalls += 1; return TravelDirectionsFixture() })
        let geocode = Task { try await service.origin(for: "Synthetic",market: .ca) }
        geocode.cancel()
        await #expect(throws: CancellationError.self) { try await geocode.value }
        let route = Task { try await service.drivingRoute(from: origin,to: destination) }
        route.cancel()
        await #expect(throws: CancellationError.self) { try await route.value }
        #expect(factoryCalls == 0)
    }
    @Test func nativeFactoriesConstructDedicatedIdleOperationsWithoutLocationPermission() {
        _ = StoreTravelService()
        let first = StoreTravelService.makeGeocoder()
        let second = StoreTravelService.makeGeocoder()
        #expect(first !== second)
        first.cancelGeocode(); second.cancelGeocode()
        let request = MKDirections.Request()
        let one = StoreTravelService.makeDirections(request)
        let two = StoreTravelService.makeDirections(request)
        #expect(one !== two)
        one.cancel(); two.cancel()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PICKUP_PILOT_LIVE_TRAVEL"] == "1"))
    func publicTorontoLandmarksResolveAndReturnLiveDrivingETA() async throws {
        let service = StoreTravelService()
        let coordinate = try await service.origin(for: "M5V 3L9",market: .ca)
        #expect(coordinate.isValid && (43.5...43.9).contains(coordinate.latitude) && (-79.6 ... -79.1).contains(coordinate.longitude))
        let route = try await service.drivingRoute(from: coordinate,to: destination)
        #expect(route.distanceKilometers.isFinite && route.distanceKilometers > 0)
        #expect(route.expectedTravelSeconds.isFinite && route.expectedTravelSeconds > 0)
    }
}
