import Foundation
import PilotCore
import Testing
@testable import PickupPilot

@Suite struct InventoryMapPresentationTests {
    private let stores = [
        RetailStore(id: "MAP-A", name: "Synthetic Eaton", latitude: 43.654, longitude: -79.380),
        RetailStore(id: "MAP-B", name: "Synthetic Yorkdale", latitude: 43.725, longitude: -79.453),
        RetailStore(id: "MAP-C", name: "Synthetic Missing Coordinates")
    ]
    private var variants: [ProductVariant] {
        ["A", "B", "C", "D"].map { ProductVariant(id: $0, name: "Synthetic \($0)", storage: "256GB", color: $0, productURL: Market.ca.productBaseURL) }
    }

    @Test func badgesCountEverySelectedConfigurationWithoutInferringUnitCounts() throws {
        let responses = [StoreAvailability(storeID: "MAP-A", variantID: "A", state: .available, message: "Today"),
                         StoreAvailability(storeID: "MAP-A", variantID: "B", state: .unavailable, message: "Unavailable"),
                         StoreAvailability(storeID: "MAP-A", variantID: "C", state: .disabled, message: "Pickup disabled")]
        let presentation = InventoryMapPresentation(stores: stores, variants: variants, selectedVariantIDs: ["A", "B", "C", "D"],
                                                    availability: responses, isStale: false)
        let first = try #require(presentation.stores.first)
        #expect(first.availableCount == 1 && first.unavailableCount == 1 && first.disabledCount == 1 && first.unverifiedCount == 1)
        #expect(first.badgeTitle == "1 available")
        #expect(first.accessibilitySummary.contains("1 available, 1 unavailable, 1 pickup disabled, 1 unverified configurations"))
        #expect(presentation.storesWithPickup == 1)
    }

    @Test func everyFeedStoreRemainsVisibleIncludingStoresWithoutValidCoordinates() {
        var source = stores
        source.append(RetailStore(id: "MAP-D", name: "Invalid Coordinates", latitude: .nan, longitude: -79))
        let presentation = InventoryMapPresentation(stores: source, variants: variants, selectedVariantIDs: ["A"], availability: [], isStale: false)
        #expect(presentation.stores.map(\.id) == ["MAP-A", "MAP-B", "MAP-C", "MAP-D"])
        #expect(presentation.mappedStores.map(\.id) == ["MAP-A", "MAP-B"])
        #expect(presentation.missingCoordinateCount == 2)
        #expect(presentation.stores.allSatisfy { $0.badgeTitle == "Unverified" })
    }

    @Test func staleInventoryNeverPresentsAStoreAsCurrentlyAvailable() throws {
        let response = StoreAvailability(storeID: "MAP-A", variantID: "A", state: .available, message: "Today")
        let presentation = InventoryMapPresentation(stores: stores, variants: variants, selectedVariantIDs: ["A"], availability: [response], isStale: true)
        let first = try #require(presentation.stores.first)
        #expect(first.badgeTitle == "Previous results" && first.availableCount == 1)
        #expect(first.accessibilitySummary.contains("Previous results"))
        #expect(presentation.storesWithPickup == 0)
    }

    @Test func duplicateAvailabilityIsUnverifiedRatherThanArbitrarilyChoosingAResponse() throws {
        let response = StoreAvailability(storeID: "MAP-A", variantID: "A", state: .available, message: "Today")
        let presentation = InventoryMapPresentation(stores: stores, variants: variants, selectedVariantIDs: ["A"], availability: [response, response], isStale: false)
        let first = try #require(presentation.stores.first)
        #expect(first.availableCount == 0 && first.unverifiedCount == 1 && first.badgeTitle == "Unverified")
        #expect(first.configurations[0].message.contains("ambiguous"))
    }

    @Test func missingSelectedVariantIsNamedExplicitlyAndDuplicateIdentitiesDoNotCreateExtraPins() {
        let presentation = InventoryMapPresentation(stores: stores + [stores[0]], variants: variants, selectedVariantIDs: ["A", "MISSING", "A"], availability: [], isStale: false)
        #expect(presentation.stores.count == 3 && presentation.configurations.count == 2)
        #expect(presentation.configurations[1].id == "MISSING" && presentation.configurations[1].name == "Configuration not loaded")
        #expect(presentation.stores.allSatisfy { $0.unverifiedCount == 2 })
    }

    @Test func mapPresentationUsesCachedDistanceAndTravelLabelsWithoutGeocoding() throws {
        let presentation = InventoryMapPresentation(stores: stores, variants: variants, selectedVariantIDs: ["A"], availability: [], isStale: false,
                                                    distance: { $0.coordinate == nil ? nil : "3.1 km" }, travelTime: { $0.coordinate == nil ? nil : "~12 min drive" })
        let first = try #require(presentation.stores.first)
        #expect(first.distance == "3.1 km" && first.travelTime == "~12 min drive")
        #expect(presentation.stores[2].distance == nil && presentation.stores[2].travelTime == nil)
    }
}
