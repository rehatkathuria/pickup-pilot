import Foundation
import Testing
@testable import PilotCore

@Suite struct PreferencesTests {
    @Test func selectedCatalogRoundTripsAndOlderPreferencesDefaultToIPhone() throws {
        var preferences = PilotPreferences()
        preferences.catalogProduct = .usbCHeadphoneAdapter
        preferences.selectedStoreIDs = ["R121"]; preferences.selectedVariantIDs = [CatalogProduct.adapterSKU]
        preferences.pollInterval = 1; preferences.maximumTotal = 20
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(PilotPreferences.self, from: data) == preferences)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "catalogProduct")
        let restored = try JSONDecoder().decode(PilotPreferences.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.catalogProduct == .iPhoneDuo && restored.pollInterval == 1 && restored.maximumTotal == 20)
        #expect(restored.selectedStoreIDs == preferences.selectedStoreIDs && restored.selectedVariantIDs == preferences.selectedVariantIDs)
        old["catalogProduct"] = "arbitrary-product"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PilotPreferences.self, from: JSONSerialization.data(withJSONObject: old)) }
        preferences.market = .uk
        #expect(preferences.validationIssues.contains { $0.contains("Canada") })
    }

    @Test func unscheduledAccessorySkipsOnlyHiddenReservedPickupLimits() {
        var preferences = PilotPreferences()
        preferences.catalogProduct = .usbCHeadphoneAdapter
        preferences.selectedStoreIDs = ["R121"]; preferences.selectedVariantIDs = [CatalogProduct.adapterSKU]
        preferences.maximumTotal = 20
        preferences.pickupWindow = DateWindow(start: .distantFuture, end: .distantPast)
        preferences.pickupHours = DailyWindow(startMinute: -1, endMinute: 1500)
        #expect(preferences.validationIssues.isEmpty)
        preferences.catalogProduct = .iPhoneDuo
        #expect(preferences.validationIssues.contains { $0.contains("Pickup end") })
        #expect(preferences.validationIssues.contains { $0.contains("Daily hours") })
        preferences.catalogProduct = .usbCHeadphoneAdapter
        preferences.attemptWindow = DateWindow(start: .distantFuture, end: .distantPast)
        preferences.attemptHours = DailyWindow(startMinute: -1)
        preferences.maximumTotal = 0; preferences.timeZoneIdentifier = "invalid"
        #expect(preferences.validationIssues.contains { $0.contains("Attempt end") })
        #expect(preferences.validationIssues.contains { $0.contains("Daily hours") })
        #expect(preferences.validationIssues.contains { $0.contains("maximum total") })
        #expect(preferences.validationIssues.contains { $0.contains("time zone") })
    }

    @Test func fastHealthyPollingBoundsPreserveExplicitSavedIntervals() throws {
        #expect(PilotPreferences.defaultPollInterval == 5 && PilotPreferences.minimumPollInterval == 1)
        #expect(PilotPreferences.maximumPollInterval == 3600 && PilotPreferences().pollInterval == 5)
        var preferences = PilotPreferences()
        preferences.selectedStoreIDs = ["R"]; preferences.selectedVariantIDs = ["SKU"]
        for interval in [1.0, 5.0, 30.0, 60.0, 3600.0] {
            preferences.pollInterval = interval
            #expect(preferences.validationIssues.isEmpty)
            let decoded = try JSONDecoder().decode(PilotPreferences.self, from: JSONEncoder().encode(preferences))
            #expect(decoded.pollInterval == interval)
        }
        for interval in [0, 0.99, 3601, TimeInterval.nan, TimeInterval.infinity] {
            preferences.pollInterval = interval
            #expect(preferences.validationIssues.contains { $0.contains("Check interval") })
        }
    }

    @Test func windowsHandleBoundsAndOvernightHours() {
        let date = Date(timeIntervalSince1970: 0)
        let window = DateWindow(start: date, end: date.addingTimeInterval(60))
        #expect(window.contains(date)); #expect(window.contains(date.addingTimeInterval(60)))
        #expect(!window.contains(date.addingTimeInterval(-1)))
        #expect(!DateWindow(start: date.addingTimeInterval(1), end: date).contains(date))
        let overnight = DailyWindow(startMinute: 1380, endMinute: 120)
        #expect(overnight.contains(date, timeZone: "UTC"))
        #expect(!overnight.contains(date.addingTimeInterval(12 * 3600), timeZone: "UTC"))
        #expect(!overnight.contains(date, timeZone: "bogus"))
        #expect(!DailyWindow(startMinute: -1).contains(date, timeZone: "UTC"))
    }
    @Test func validationDetectsAllInvalidPreferenceClasses() {
        var p = PilotPreferences()
        #expect(p.validationIssues.count == 2)
        p.maximumTotal = 0; p.pollInterval = 0.5; p.maximumPreparationFailures = 0
        p.attemptWindow = DateWindow(start: .distantFuture, end: .distantPast)
        p.pickupWindow = p.attemptWindow
        p.attemptHours.startMinute = 1500; p.pickupHours.endMinute = -1
        p.timeZoneIdentifier = "invalid"
        #expect(p.validationIssues.count == 9)
        #expect(!p.permitsAttempt(at: Date())); #expect(!p.permitsPickup(at: Date()))
    }
    @Test func preferencesRoundTripAndCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FilePreferencesStore(url: directory.appendingPathComponent("preferences.json"))
        #expect(try store.load().selectedStoreIDs.isEmpty)
        var p = PilotPreferences(); p.market = .uk; p.selectedStoreIDs = ["R092"]; p.selectedVariantIDs = ["REGIONAL-SKU"]
        try store.save(p)
        #expect(try store.load() == p)
        let data = try Data(contentsOf: store.url)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("cardNumber")); #expect(!text.contains("cvv")); #expect(!text.contains("billing")); #expect(!text.contains("searchLocation"))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data("broken".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }
    @Test func exponentialBackoffBounds() {
        let policy = RetryPolicy(base: 1, maximum: 100)
        #expect(policy.delay(failures: 0) == 30)
        #expect(policy.delay(failures: 2) == 60)
        #expect(policy.delay(failures: 100) == 100)
        #expect(policy.delay(failures: 1, retryAfter: 5000) == 5000)
        #expect(policy.delay(failures: 1, retryAfter: -10) == 30)
        #expect(policy.delay(failures: 1, retryAfter: .nan) == 30)
        #expect(policy.delay(failures: 1, retryAfter: .infinity) == 30)
        #expect(RetryPolicy(base: .nan, maximum: .infinity).delay(failures: 1) == 60)
    }
    @Test func singleInstanceLeasePreventsSecondOwnerAndReleases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var first: SingleInstanceLock? = try SingleInstanceLock(url: url)
        #expect(first != nil)
        #expect(throws: SingleInstanceLock.InstanceError.self) { try SingleInstanceLock(url: url) }
        first = nil
        let second = try SingleInstanceLock(url: url)
        withExtendedLifetime(second) {}
        let symlink = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
        #expect(throws: SingleInstanceLock.InstanceError.self) { try SingleInstanceLock(url: symlink) }
    }
    @Test func everyStatusAndCoordinatorErrorHasDisplayText() {
        for status in [PilotStatus.stopped, .checking, .monitoring, .waiting, .preparing, .authenticationRequired, .submitting, .confirmed, .uncertain, .failed] { #expect(!status.title.isEmpty) }
        for error in [CoordinatorError.alreadyRunning, .invalidConfiguration("Test"), .profileIncomplete, .purchaseLocked] { #expect(!error.localizedDescription.isEmpty) }
    }
}
