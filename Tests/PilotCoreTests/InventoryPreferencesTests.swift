import Foundation
import Testing
@testable import PilotCore

@Suite struct InventoryPreferencesTests {
    @Test func newInventorySettingsDefaultToOneSecondAndMigrateExistingPreferences() throws {
        let preferences = PilotPreferences()
        #expect(preferences.inventoryRefreshInterval == 1)
        #expect(preferences.inventoryLocationQuery.isEmpty)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        #expect(legacy["inventoryLocationQuery"] == nil)
        legacy.removeValue(forKey: "inventoryRefreshInterval")
        legacy.removeValue(forKey: "inventoryLocationQuery")
        legacy["pollInterval"] = 17
        let migrated = try JSONDecoder().decode(PilotPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(migrated.inventoryRefreshInterval == 1)
        #expect(migrated.inventoryLocationQuery.isEmpty)
        #expect(migrated.pollInterval == 17)
    }

    @Test func inventorySettingsRoundTripIndependentlyOfRetainedCheckoutSettings() throws {
        var preferences = PilotPreferences()
        preferences.inventoryRefreshInterval = 2
        preferences.inventoryLocationQuery = "Synthetic city"
        preferences.pollInterval = 45
        preferences.selectedStoreIDs = ["OLD-PREFERENCE"]
        let restored = try JSONDecoder().decode(PilotPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored == preferences)
    }
}
