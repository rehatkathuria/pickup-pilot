import Foundation
import Testing
@testable import PilotCore

@Suite struct StoreTravelEstimateTests {
    @Test func distanceShowsOneDecimalAndNeverDerivesTravelTime() {
        let estimate = StoreTravelEstimate(straightLineKilometers: 5.24, drivingRoute: nil)
        #expect(estimate.distanceLabel == "5.2 km away")
        #expect(estimate.travelTimeLabel == "Drive time unavailable")
        #expect(StoreTravelEstimate(straightLineKilometers: 5.26, drivingRoute: nil).distanceLabel == "5.3 km away")
        #expect(StoreTravelEstimate(straightLineKilometers: 0, drivingRoute: nil).distanceLabel == "0.0 km away")
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -0.1])
    func invalidStraightLineDistanceIsUnavailable(distance: Double) {
        let estimate = StoreTravelEstimate(straightLineKilometers: distance, drivingRoute: DrivingRoute(distanceKilometers: 6, expectedTravelSeconds: 900))
        #expect(estimate.distanceLabel == "Distance unavailable")
        // A valid independently supplied driving route remains useful even when straight-line distance failed.
        #expect(estimate.travelTimeLabel == "~15 min drive")
    }

    @Test(arguments: [
        (0.0, "~5 min drive"), (1.0, "~5 min drive"), (299.9, "~5 min drive"),
        (300.0, "~5 min drive"), (300.1, "~10 min drive"), (601.0, "~15 min drive"),
        (900.0, "~15 min drive"), (3300.0, "~55 min drive"), (3300.1, "~1 hr drive"),
        (3600.0, "~1 hr drive"), (3600.1, "~1 hr 5 min drive"), (3901.0, "~1 hr 10 min drive"),
        (7200.0, "~2 hr drive"), (10801.0, "~3 hr 5 min drive")
    ])
    func actualRouteTimeRoundsUpInFiveMinuteSteps(seconds: Double, label: String) {
        let route = DrivingRoute(distanceKilometers: 25, expectedTravelSeconds: seconds)
        #expect(StoreTravelEstimate(straightLineKilometers: 5, drivingRoute: route).travelTimeLabel == label)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1])
    func invalidRouteDistancePreventsTravelEstimate(distance: Double) {
        let route = DrivingRoute(distanceKilometers: distance, expectedTravelSeconds: 900)
        #expect(StoreTravelEstimate(straightLineKilometers: 5, drivingRoute: route).travelTimeLabel == "Drive time unavailable")
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude])
    func invalidOrUnrepresentableRouteTimeCannotTrap(seconds: Double) {
        let route = DrivingRoute(distanceKilometers: 6, expectedTravelSeconds: seconds)
        #expect(StoreTravelEstimate(straightLineKilometers: 5, drivingRoute: route).travelTimeLabel == "Drive time unavailable")
    }

    @Test func routesAndEstimatesPreserveValuesAndCompareAsValues() {
        let route = DrivingRoute(distanceKilometers: 6.7, expectedTravelSeconds: 901)
        #expect(route.distanceKilometers == 6.7)
        #expect(route.expectedTravelSeconds == 901)
        #expect(route == DrivingRoute(distanceKilometers: 6.7, expectedTravelSeconds: 901))
        let estimate = StoreTravelEstimate(straightLineKilometers: 5.2, drivingRoute: route)
        #expect(estimate.straightLineKilometers == 5.2)
        #expect(estimate.drivingRoute == route)
        #expect(estimate == StoreTravelEstimate(straightLineKilometers: 5.2, drivingRoute: route))
        #expect(estimate != StoreTravelEstimate(straightLineKilometers: 5.2, drivingRoute: nil))
        #expect(StoreTravelEstimate(straightLineKilometers: 0, drivingRoute: DrivingRoute(distanceKilometers: 0, expectedTravelSeconds: 0)).travelTimeLabel == "~5 min drive")
    }
}
