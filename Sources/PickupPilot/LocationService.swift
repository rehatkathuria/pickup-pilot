import CoreLocation
import Foundation
import Observation

@MainActor protocol LocationDetecting: AnyObject {
    var status: String { get }
    var requesting: Bool { get }
    func locate() async throws -> DetectedLocation
}

/// The native manager conforms directly, so tests can supply a synthetic manager
/// without requesting permission or changing the production Core Location path.
@MainActor protocol LocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func stopUpdatingLocation()
}
extension CLLocationManager: LocationManaging {}

@MainActor protocol LocationGeocoding: AnyObject {
    func reverseGeocodeLocation(_ location: CLLocation) async throws -> [CLPlacemark]
    func cancelGeocode()
}
extension CLGeocoder: LocationGeocoding {}

@MainActor
@Observable
final class LocationService: NSObject, LocationDetecting, @MainActor CLLocationManagerDelegate {
    private let manager: any LocationManaging
    private let geocoder: any LocationGeocoding
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let timeout: TimeInterval
    private var request: CheckedContinuation<DetectedLocation, Error>?
    private var requestID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var geocodeTask: Task<Void, Never>?
    private(set) var status = "Location has not been requested."
    private(set) var requesting = false

    init(manager: any LocationManaging = CLLocationManager(), geocoder: any LocationGeocoding = CLGeocoder(),
         timeout: TimeInterval = 25, now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = LocationClock.sleep) {
        self.manager = manager; self.geocoder = geocoder; self.timeout = timeout
        self.now = now; self.sleep = sleep
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    isolated deinit { timeoutTask?.cancel(); geocodeTask?.cancel() }

    func locate() async throws -> DetectedLocation {
        guard request == nil else { throw LocationFailure.busy }
        try Task.checkCancellation()
        let id = UUID()
        let sleep = sleep
        let timeout = timeout
        requesting = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request = continuation; requestID = id
                // Delegate callbacks require an independently cancellable timeout task.
                timeoutTask = Task { [weak self] in
                    do { try await sleep(timeout) } catch { return }
                    self?.finish(.failure(LocationFailure.unavailable), for: id)
                }
                handleAuthorization(manager.authorizationStatus)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), for: id) }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard request != nil else { return }
        guard self.manager.authorizationStatus != .notDetermined else { return }
        handleAuthorization(self.manager.authorizationStatus)
    }

    private func handleAuthorization(_ authorization: CLAuthorizationStatus) {
        switch authorization {
        case .denied, .restricted: finish(.failure(LocationFailure.denied))
        case .notDetermined:
            status = "Waiting for macOS location permission…"
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            status = "Finding your current location…"
            manager.requestLocation()
        @unknown default: finish(.failure(LocationFailure.unavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let id = requestID, geocodeTask == nil else { return }
        guard let location = locations.last, CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
              (-60...300).contains(now().timeIntervalSince(location.timestamp)) else {
            finish(.failure(LocationFailure.unavailable), for: id); return
        }
        self.manager.stopUpdatingLocation()
        let geocoder = geocoder
        geocodeTask = Task { @MainActor [weak self] in
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                guard let place = placemarks.first,
                      let country = place.isoCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !country.isEmpty else { throw LocationFailure.unavailable }
                let postal = place.postalCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallback = [place.locality, place.administrativeArea].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: ", ")
                let query = postal.isEmpty ? fallback : postal
                guard !query.isEmpty else { throw LocationFailure.unavailable }
                self?.finish(.success(DetectedLocation(countryCode: country.uppercased(), query: query,
                    latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)), for: id)
            } catch { self?.finish(.failure(error), for: id) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<DetectedLocation, Error>, for id: UUID? = nil) {
        if let id, requestID != id { return }
        guard let continuation = request else { return }
        request = nil; requestID = nil; requesting = false
        timeoutTask?.cancel(); timeoutTask = nil
        geocodeTask?.cancel(); geocodeTask = nil
        manager.stopUpdatingLocation()
        geocoder.cancelGeocode()
        switch result {
        case .success: status = "Current location detected. You can override the shopping country below."
        case .failure(let error): status = error is CancellationError ? "Location cancelled." : "Location unavailable. Enter a country and postal code or city."
        }
        continuation.resume(with: result)
    }
}

enum LocationClock {
    static func sleep(_ seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

struct DetectedLocation: Sendable, Equatable {
    let countryCode: String
    let query: String
    let latitude: Double
    let longitude: Double
}
enum LocationFailure: LocalizedError, Equatable {
    case denied, unavailable, busy
    var errorDescription: String? {
        switch self {
        case .denied: "Location permission is off. Enter your shopping country and postal code or city."
        case .unavailable: "Your location could not be resolved. Enter a country and postal code or city."
        case .busy: "A location request is already running."
        }
    }
}
