import CoreLocation
import Foundation
import MapKit
import Testing
@testable import PickupPilot

@MainActor private final class SyntheticLocationManager: LocationManaging {
    var authorizationStatus: CLAuthorizationStatus = .authorized
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: CLLocationAccuracy = 0
    var permissionRequests = 0
    var locationRequests = 0
    var stops = 0
    func requestWhenInUseAuthorization() { permissionRequests += 1 }
    func requestLocation() { locationRequests += 1 }
    func stopUpdatingLocation() { stops += 1 }
}

@MainActor private final class SyntheticGeocoder: LocationGeocoding {
    var result: Result<[CLPlacemark], Error> = .success([])
    var locations: [CLLocation] = []
    var cancelled = 0
    var suspend = false
    var pending: [CheckedContinuation<[CLPlacemark], Error>?] = []
    func reverseGeocodeLocation(_ location: CLLocation) async throws -> [CLPlacemark] {
        locations.append(location)
        if suspend {
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        return try result.get()
    }
    func cancelGeocode() { cancelled += 1 }
    func resolve(_ index: Int, with result: Result<[CLPlacemark], Error>) {
        let continuation = pending[index]; pending[index] = nil
        continuation?.resume(with: result)
    }
}

@MainActor private final class LocationTimeoutGate {
    var pending: [CheckedContinuation<Void, Error>?] = []
    func sleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ index: Int) {
        let continuation = pending[index]; pending[index] = nil
        continuation?.resume()
    }
}

private enum SyntheticLocationError: Error { case failure }
private let locationTestNow = Date(timeIntervalSince1970: 1_792_166_400)

@Suite(.serialized) @MainActor struct LocationServiceTests {
    private func fix(age: TimeInterval = 0, accuracy: Double = 100, latitude: Double = 43.65) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -79.38), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 0, timestamp: locationTestNow.addingTimeInterval(-age))
    }
    private func place(country: String? = "CA", postal: String? = "M5V 3L9", city: String? = "Toronto", region: String? = "ON") -> CLPlacemark {
        var fields: [String: Any] = [:]
        fields["CountryCode"] = country; fields["ZIP"] = postal; fields["City"] = city; fields["State"] = region
        return MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 43.65, longitude: -79.38), addressDictionary: fields)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw SyntheticLocationError.failure
    }

    @Test func nativeDefaultsCanBeConstructedWithoutRequestingPermission() {
        let service = LocationService()
        #expect(!service.requesting)
        #expect(service.status == "Location has not been requested.")
        for error in [LocationFailure.denied, .unavailable, .busy] { #expect(error.errorDescription?.isEmpty == false) }
    }

    @Test func realDefaultTimeoutSleepCanBeCancelledRepeatedly() async throws {
        for _ in 0..<5 {
            let manager = SyntheticLocationManager()
            let service = LocationService(manager: manager, geocoder: SyntheticGeocoder())
            let task = Task { try await service.locate() }
            try await waitUntil { service.requesting }
            // Let the actual default clock suspend before cancelling its owning request.
            try await Task.sleep(for: .milliseconds(5))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!service.requesting)
        }
    }

    @Test func currentClockAcceptsFreshSyntheticFixWithoutInjectedDate() async throws {
        let manager = SyntheticLocationManager()
        let geocoder = SyntheticGeocoder(); geocoder.result = .success([place()])
        let service = LocationService(manager: manager, geocoder: geocoder)
        let task = Task { try await service.locate() }
        try await waitUntil { service.requesting }
        service.locationManager(CLLocationManager(), didUpdateLocations: [CLLocation(latitude: 43.65, longitude: -79.38)])
        #expect(try await task.value.countryCode == "CA")
        #expect(!service.requesting)
    }

    @Test func allowedFixUsesGeocoderAndCompletesExactlyOnce() async throws {
        let manager = SyntheticLocationManager()
        let geocoder = SyntheticGeocoder(); geocoder.result = .success([place()])
        let service = LocationService(manager: manager, geocoder: geocoder, now: { locationTestNow })
        #expect(manager.delegate === service)
        #expect(manager.desiredAccuracy == kCLLocationAccuracyKilometer)
        let request = Task { try await service.locate() }
        try await waitUntil { service.requesting }
        #expect(manager.locationRequests == 1 && manager.permissionRequests == 0)
        let native = CLLocationManager()
        service.locationManager(native, didUpdateLocations: [fix()])
        let found = try await request.value
        #expect(found == DetectedLocation(countryCode: "CA", query: "M5V 3L9", latitude: 43.65, longitude: -79.38))
        #expect(!service.requesting && service.status.contains("Current location detected"))
        #expect(geocoder.locations.count == 1 && geocoder.cancelled == 1)
        let completedStatus = service.status
        service.locationManager(native, didUpdateLocations: [fix()])
        service.locationManagerDidChangeAuthorization(native)
        service.locationManager(native, didFailWithError: SyntheticLocationError.failure)
        #expect(service.status == completedStatus && geocoder.locations.count == 1)
    }

    @Test func permissionTransitionAndBusyRequestDoNotReplaceActiveContinuation() async throws {
        let manager = SyntheticLocationManager(); manager.authorizationStatus = .notDetermined
        let geocoder = SyntheticGeocoder(); geocoder.result = .success([place(postal: nil)])
        let service = LocationService(manager: manager, geocoder: geocoder, now: { locationTestNow })
        let task = Task { try await service.locate() }
        try await waitUntil { service.requesting }
        #expect(manager.permissionRequests == 1 && manager.locationRequests == 0)
        let native = CLLocationManager()
        service.locationManagerDidChangeAuthorization(native)
        #expect(manager.permissionRequests == 1)
        await #expect(throws: LocationFailure.busy) { try await service.locate() }
        manager.authorizationStatus = .authorizedAlways
        service.locationManagerDidChangeAuthorization(native)
        #expect(manager.locationRequests == 1)
        service.locationManager(native, didUpdateLocations: [fix()])
        #expect(try await task.value.query == "Toronto, ON")
        #expect(!service.requesting)
    }

    @Test func deniedRestrictedUnknownAndRevokedPermissionsFinishCleanly() async throws {
        let native = CLLocationManager()
        for authorization in [CLAuthorizationStatus.denied, .restricted] {
            let manager = SyntheticLocationManager(); manager.authorizationStatus = authorization
            let service = LocationService(manager: manager, geocoder: SyntheticGeocoder())
            await #expect(throws: LocationFailure.denied) { try await service.locate() }
            #expect(!service.requesting && manager.locationRequests == 0)
        }
        let manager = SyntheticLocationManager()
        let service = LocationService(manager: manager, geocoder: SyntheticGeocoder())
        let task = Task { try await service.locate() }
        try await waitUntil { service.requesting }
        manager.authorizationStatus = .denied
        service.locationManagerDidChangeAuthorization(native)
        await #expect(throws: LocationFailure.denied) { try await task.value }
        manager.authorizationStatus = CLAuthorizationStatus(rawValue: 99)!
        await #expect(throws: LocationFailure.unavailable) { try await service.locate() }
        #expect(!service.requesting)
    }

    @Test func staleFutureInvalidAndEmptyFixesAreRejectedBeforeGeocoding() async throws {
        let invalid = [fix(age: 301), fix(age: -61), fix(accuracy: -1), fix(accuracy: .infinity), fix(latitude: 999)]
        for locations in invalid.map({ [$0] }) + [[]] {
            let manager = SyntheticLocationManager()
            let geocoder = SyntheticGeocoder()
            let service = LocationService(manager: manager, geocoder: geocoder, now: { locationTestNow })
            let task = Task { try await service.locate() }
            try await waitUntil { service.requesting }
            service.locationManager(CLLocationManager(), didUpdateLocations: locations)
            await #expect(throws: LocationFailure.unavailable) { try await task.value }
            #expect(geocoder.locations.isEmpty && !service.requesting)
        }
    }

    @Test func geocoderFailuresMissingCountryAndMissingAddressRequireManualFallback() async throws {
        let responses: [Result<[CLPlacemark], Error>] = [
            .failure(SyntheticLocationError.failure), .success([]), .success([place(country: nil)]),
            .success([place(country: " ")]), .success([place(postal: nil, city: nil, region: nil)])
        ]
        for response in responses {
            let manager = SyntheticLocationManager()
            let geocoder = SyntheticGeocoder(); geocoder.result = response
            let service = LocationService(manager: manager, geocoder: geocoder, now: { locationTestNow })
            let task = Task { try await service.locate() }
            try await waitUntil { service.requesting }
            service.locationManager(CLLocationManager(), didUpdateLocations: [fix()])
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(!service.requesting && service.status.contains("Location unavailable"))
        }
        let manager = SyntheticLocationManager()
        let geocoder = SyntheticGeocoder(); geocoder.result = .success([place(postal: " ", city: " Toronto ", region: " ")])
        let service = LocationService(manager: manager, geocoder: geocoder, now: { locationTestNow })
        let task = Task { try await service.locate() }
        try await waitUntil { service.requesting }
        service.locationManager(CLLocationManager(), didUpdateLocations: [fix()])
        #expect(try await task.value.query == "Toronto")
    }

    @Test func cancellationAndLateGeocodeCannotFinishTheNextRequest() async throws {
        let manager = SyntheticLocationManager()
        let geocoder = SyntheticGeocoder(); geocoder.suspend = true
        let service = LocationService(manager: manager, geocoder: geocoder, now: { locationTestNow })
        let native = CLLocationManager()
        let first = Task { try await service.locate() }
        try await waitUntil { service.requesting }
        service.locationManager(native, didUpdateLocations: [fix()])
        try await waitUntil { geocoder.pending.count == 1 }
        service.locationManager(native, didUpdateLocations: [fix()])
        #expect(geocoder.locations.count == 1)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(service.status == "Location cancelled." && !service.requesting)
        let second = Task { try await service.locate() }
        try await waitUntil { service.requesting }
        service.locationManager(native, didUpdateLocations: [fix()])
        try await waitUntil { geocoder.pending.count == 2 }
        geocoder.resolve(0, with: .success([place(postal: "OLD")]))
        try await Task.sleep(for: .milliseconds(5))
        #expect(service.requesting)
        geocoder.resolve(1, with: .success([place(postal: "NEW")]))
        #expect(try await second.value.query == "NEW")
        #expect(!service.requesting)
        let cancelled = Task { try await service.locate() }; cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!service.requesting)
    }

    @Test func timeoutUsesRequestGenerationAndNativeFailurePropagates() async throws {
        let manager = SyntheticLocationManager()
        let gate = LocationTimeoutGate()
        let service = LocationService(manager: manager, geocoder: SyntheticGeocoder(), sleep: gate.sleep)
        let first = Task { try await service.locate() }
        try await waitUntil { gate.pending.count == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = Task { try await service.locate() }
        try await waitUntil { gate.pending.count == 2 }
        gate.resolve(0)
        try await Task.sleep(for: .milliseconds(5))
        #expect(service.requesting)
        gate.resolve(1)
        await #expect(throws: LocationFailure.unavailable) { try await second.value }
        #expect(!service.requesting)
        let third = Task { try await service.locate() }
        try await waitUntil { gate.pending.count == 3 }
        service.locationManager(CLLocationManager(), didFailWithError: SyntheticLocationError.failure)
        await #expect(throws: SyntheticLocationError.failure) { try await third.value }
        gate.resolve(2)
    }
}
