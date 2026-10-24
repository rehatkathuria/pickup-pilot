import Foundation
import PilotCore

/// Map badges count selected configurations, never the number of physical units in a store.
struct InventoryMapPresentation: Equatable, Sendable {
    struct Configuration: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    struct Availability: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let state: AvailabilityState?
        let message: String

        var title: String {
            switch state {
            case .available: "Pickup available"
            case .unavailable: "Unavailable"
            case .disabled: "Pickup disabled"
            case nil: "Unverified"
            }
        }
        var symbol: String {
            switch state {
            case .available: "checkmark.circle.fill"
            case .unavailable: "minus.circle"
            case .disabled: "nosign"
            case nil: "questionmark.circle"
            }
        }
    }

    struct Store: Identifiable, Equatable, Sendable {
        let retailer: RetailStore
        let configurations: [Availability]
        let isStale: Bool
        let distance: String?
        let travelTime: String?
        var id: String { retailer.id }
        var coordinate: Coordinate? { retailer.coordinate }
        var availableCount: Int { configurations.filter { $0.state == .available }.count }
        var unavailableCount: Int { configurations.filter { $0.state == .unavailable }.count }
        var disabledCount: Int { configurations.filter { $0.state == .disabled }.count }
        var unverifiedCount: Int { configurations.filter { $0.state == nil }.count }
        var badgeTitle: String {
            if isStale { return "Previous results" }
            if configurations.isEmpty || unverifiedCount == configurations.count { return "Unverified" }
            if availableCount > 0 { return "\(availableCount) available" }
            if unverifiedCount > 0 { return "\(unverifiedCount) unverified" }
            if disabledCount == configurations.count { return "Pickup disabled" }
            return "No pickup"
        }
        var accessibilitySummary: String {
            let counts = "\(availableCount) available, \(unavailableCount) unavailable, \(disabledCount) pickup disabled, \(unverifiedCount) unverified configurations"
            return "\(retailer.name). \(isStale ? "Previous results. " : "")\(counts)."
        }
    }

    let configurations: [Configuration]
    let stores: [Store]
    var mappedStores: [Store] { stores.filter { $0.coordinate != nil } }
    var missingCoordinateCount: Int { stores.filter { $0.coordinate == nil }.count }
    var storesWithPickup: Int { stores.filter { !$0.isStale && $0.availableCount > 0 }.count }

    init(stores: [RetailStore], variants: [ProductVariant], selectedVariantIDs: [String],
         availability: [StoreAvailability], isStale: Bool,
         distance: (RetailStore) -> String? = { _ in nil },
         travelTime: (RetailStore) -> String? = { _ in nil }) {
        var seenConfigurations = Set<String>()
        configurations = selectedVariantIDs.filter { seenConfigurations.insert($0).inserted }.map { id in
            let matches = variants.filter { $0.id == id }
            return Configuration(id: id, name: matches.count == 1 ? matches[0].name : "Configuration not loaded")
        }
        let selected = configurations
        var seenStores = Set<String>()
        self.stores = stores.filter { seenStores.insert($0.id).inserted }.map { store in
            let responses = selected.map { configuration in
                let matches = availability.filter { $0.storeID == store.id && $0.variantID == configuration.id }
                let response = matches.count == 1 ? matches[0] : nil
                return Availability(id: configuration.id, name: configuration.name, state: response?.state,
                                    message: response?.message ?? (matches.isEmpty ? "No verified response for this configuration." : "Apple returned ambiguous responses for this configuration."))
            }
            return Store(retailer: store, configurations: responses, isStale: isStale,
                         distance: distance(store), travelTime: travelTime(store))
        }
    }
}
