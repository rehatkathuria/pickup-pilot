import Foundation

/// An immutable copy of the exact ordered product/store scope approved for one run.
/// Location remains in memory with the active coordinator, never in preferences.
public struct MonitoringPlan: Equatable, Sendable {
    public let configuration: PilotPreferences
    public let variants: [ProductVariant]
    public let stores: [RetailStore]
    public let location: String

    /// The caller supplies already-selected variants and stores in priority order.
    public init(configuration: PilotPreferences, variants: [ProductVariant], stores: [RetailStore], location: String) {
        self.configuration = configuration
        self.variants = variants
        self.stores = stores
        self.location = location
    }
}
