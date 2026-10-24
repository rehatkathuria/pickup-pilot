import Foundation

public struct DrivingRoute: Equatable, Sendable {
    public let distanceKilometers: Double
    public let expectedTravelSeconds: Double

    public init(distanceKilometers: Double, expectedTravelSeconds: Double) {
        self.distanceKilometers = distanceKilometers
        self.expectedTravelSeconds = expectedTravelSeconds
    }
}

public struct StoreTravelEstimate: Equatable, Sendable {
    public let straightLineKilometers: Double
    public let drivingRoute: DrivingRoute?

    public init(straightLineKilometers: Double, drivingRoute: DrivingRoute?) {
        self.straightLineKilometers = straightLineKilometers
        self.drivingRoute = drivingRoute
    }

    public var distanceLabel: String {
        guard straightLineKilometers.isFinite, straightLineKilometers >= 0 else {
            return "Distance unavailable"
        }
        return String(format: "%.1f km away", locale: Locale(identifier: "en_US_POSIX"), straightLineKilometers)
    }

    public var travelTimeLabel: String {
        guard let route = drivingRoute,
              route.distanceKilometers.isFinite, route.distanceKilometers >= 0,
              route.expectedTravelSeconds.isFinite, route.expectedTravelSeconds >= 0 else {
            return "Drive time unavailable"
        }
        let fiveMinuteBlocks = max(1, ceil(route.expectedTravelSeconds / 300))
        // Avoid trapping on a numeric conversion if a route provider returns an unrealistic finite duration.
        guard fiveMinuteBlocks < Double(Int.max / 5) else { return "Drive time unavailable" }
        let minutes = Int(fiveMinuteBlocks) * 5
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "~\(minutes) min drive" }
        if remainingMinutes == 0 { return "~\(hours) hr drive" }
        return "~\(hours) hr \(remainingMinutes) min drive"
    }
}
