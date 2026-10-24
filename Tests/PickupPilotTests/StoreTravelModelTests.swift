import AppKit
import Foundation
import PilotCore
import SwiftUI
import Synchronization
import Testing
import Vision
@testable import PickupPilot

private let travelOrigin = Coordinate(latitude: 43.641234, longitude: -79.391234)
private let travelFar = Coordinate(latitude: 43.741234, longitude: -79.491234)
private let travelQuery = "SYNTHETIC-POSTCODE-A"
private let travelStores = [
    RetailStore(id: "FAR", name: "Synthetic Far Store", latitude: travelFar.latitude, longitude: travelFar.longitude, address: "Synthetic farther address", countryCode: "CA"),
    RetailStore(id: "MISSING", name: "Synthetic Missing Coordinate", address: "Synthetic address", countryCode: "CA"),
    RetailStore(id: "NEAR", name: "Synthetic Near Store", latitude: travelOrigin.latitude, longitude: travelOrigin.longitude, address: "Synthetic nearby address", countryCode: "CA"),
    RetailStore(id: "INVALID", name: "Synthetic Invalid Coordinate", latitude: 999, longitude: 999, countryCode: "CA")
]

private final class TravelPreferencesSpy: PreferencesStore {
    let saves = Mutex<[PilotPreferences]>([])
    func load() -> PilotPreferences {
        var settings = PilotPreferences()
        settings.market = .ca
        settings.selectedStoreIDs = ["NEAR"]
        settings.selectedVariantIDs = ["CA-SYNTHETIC/A"]
        return settings
    }
    func save(_ preferences: PilotPreferences) { saves.withLock { $0.append(preferences) } }
}

private actor TravelVaultSpy: SecureVault {
    var calls: [String] = []
    func saveProfile(_ profile: SecureProfile) { calls.append("saveProfile") }
    func loadProfile() -> SecureProfile? { calls.append("loadProfile"); return nil }
    func deleteProfile() { calls.append("deleteProfile") }
    func saveSession(_ data: Data) { calls.append("saveSession") }
    func loadSession() -> Data? { calls.append("loadSession"); return nil }
    func deleteSession() { calls.append("deleteSession") }
    func saveOrderState(_ data: Data) { calls.append("saveOrderState") }
    func loadOrderState() -> Data? { calls.append("loadOrderState"); return nil }
    func deleteOrderState() { calls.append("deleteOrderState") }
    func clear() { calls.append("clear") }
}

private actor TravelCatalogFixture: ProductCatalogFetching {
    func variants(market: Market) -> [ProductVariant] {
        [ProductVariant(id: market.countryCode + "-SYNTHETIC/A", name: "Synthetic Duo 256GB Night Sky", storage: "256GB", color: "Night Sky",
                        productURL: market.productBaseURL.appendingPathComponent("synthetic"))]
    }
}
private actor TravelInventoryFixture: InventoryFetching {
    var stores = travelStores
    var failure = false
    func replaceStores(_ stores: [RetailStore]) { self.stores = stores }
    func setFailure() { failure = true }
    func fetch(market: Market, location: String, variants: [ProductVariant]) throws -> InventorySnapshot {
        if failure { throw AppleServiceError.httpStatus(503) }
        return InventorySnapshot(stores: stores, availability: stores.flatMap { store in
            variants.map { StoreAvailability(storeID: store.id, variantID: $0.id, state: .disabled, message: "Synthetic pickup quote") }
        })
    }
}
@MainActor private final class TravelLocationFixture: LocationDetecting {
    let status = "Synthetic physical origin"
    let requesting = false
    var calls = 0
    var coordinate = travelOrigin
    func locate() -> DetectedLocation {
        calls += 1
        return DetectedLocation(countryCode: "CA", query: "Synthetic physical location", latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

enum TravelSuspensionStage: String, CaseIterable, Sendable { case origin, route }
@MainActor private final class TravelProviderSpy: StoreTravelProviding {
    struct OriginCall { let query: String; let market: Market }
    struct RouteCall { let origin: Coordinate; let destination: Coordinate }
    var origins: [OriginCall] = []
    var routes: [RouteCall] = []
    var originResult: Result<Coordinate, Error> = .success(travelOrigin)
    var holdOrigin = false
    var holdNearRoute = false
    var pendingOrigins: [CheckedContinuation<Coordinate, Error>?] = []
    var pendingRoutes: [CheckedContinuation<DrivingRoute, Error>?] = []
    func origin(for query: String, market: Market) async throws -> Coordinate {
        origins.append(OriginCall(query: query, market: market))
        if holdOrigin { return try await withCheckedThrowingContinuation { pendingOrigins.append($0) } }
        return try originResult.get()
    }
    func drivingRoute(from origin: Coordinate, to destination: Coordinate) async throws -> DrivingRoute {
        routes.append(RouteCall(origin: origin, destination: destination))
        if holdNearRoute, destination == travelOrigin {
            // Deliberately ignore cancellation until resolved, to test late platform callbacks.
            return try await withCheckedThrowingContinuation { pendingRoutes.append($0) }
        }
        if destination == travelFar { throw StoreTravelError.routeUnavailable }
        return DrivingRoute(distanceKilometers: 2.3456789, expectedTravelSeconds: 760)
    }
    func resolveOrigin(_ index: Int, result: Result<Coordinate, Error>) {
        let continuation = pendingOrigins[index]; pendingOrigins[index] = nil
        continuation?.resume(with: result)
    }
    func resolveRoute(_ index: Int, result: Result<DrivingRoute, Error>) {
        let continuation = pendingRoutes[index]; pendingRoutes[index] = nil
        continuation?.resume(with: result)
    }
}

@Suite(.serialized) @MainActor struct StoreTravelModelTests {
    private struct Fixture {
        let model: PilotModel
        let preferences: TravelPreferencesSpy
        let vault: TravelVaultSpy
        let inventory: TravelInventoryFixture
        let provider: TravelProviderSpy
        let location: TravelLocationFixture
    }
    private func fixture() -> Fixture {
        let provider = TravelProviderSpy()
        let preferences = TravelPreferencesSpy()
        let vault = TravelVaultSpy()
        let inventory = TravelInventoryFixture()
        let location = TravelLocationFixture()
        let model = PilotModel(vault: vault, preferencesStore: preferences, catalog: TravelCatalogFixture(), inventory: inventory,
                               locationService: location, travelService: provider)
        model.locationQuery = travelQuery
        model.changedLocationManually()
        return Fixture(model: model, preferences: preferences, vault: vault, inventory: inventory, provider: provider, location: location)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw StoreTravelError.routeUnavailable
    }

    @Test func manualOriginRanksStoresAndShowsHonestRouteFailuresWithoutStoringLocation() async throws {
        let f = fixture()
        await f.model.discover()
        let near = try #require(f.model.stores.first { $0.id == "NEAR" })
        let far = try #require(f.model.stores.first { $0.id == "FAR" })
        let missing = try #require(f.model.stores.first { $0.id == "MISSING" })
        let invalid = try #require(f.model.stores.first { $0.id == "INVALID" })
        #expect(f.provider.origins.count == 1 && f.provider.origins[0].query == travelQuery && f.provider.origins[0].market == .ca)
        #expect(f.model.stores.first?.id == "NEAR")
        #expect(f.model.distance(to: near) == "0.0 km")
        #expect(f.model.travelEstimate(to: near)?.straightLineKilometers == 0)
        #expect(f.model.travelTime(to: near) == "~15 min drive")
        #expect(f.model.travelTime(to: far) == "Drive time unavailable")
        #expect(f.model.travelEstimate(to: far)?.straightLineKilometers ?? 0 > 0)
        #expect(f.model.travelEstimate(to: missing) == nil && f.model.travelEstimate(to: invalid) == nil)
        #expect(f.provider.routes.count == 2 && f.provider.routes.allSatisfy { $0.origin == travelOrigin && $0.destination.isValid })
        #expect(f.model.availability.count == 4 && f.model.error == nil && !f.model.resolvingTravel)
        #expect(!f.model.travelStatus.isEmpty)
        #expect(await f.vault.calls.isEmpty)
        for preferences in f.preferences.saves.withLock({ $0 }) {
            let encoded = try JSONEncoder().encode(preferences)
            let text = String(decoding: encoded, as: UTF8.self)
            #expect(!text.contains(travelQuery) && !text.contains("43.641234") && !text.contains("-79.391234"))
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(!object.keys.contains { $0.lowercased().contains("route") || $0.lowercased().contains("coordinate") || $0.lowercased().contains("location") || $0.lowercased().contains("travel") })
        }
    }

    @Test func AppleInventoryIsVisibleWhileRoutesArePendingAndSuccessfulRoutesAreCachedInMemory() async throws {
        let f = fixture(); f.provider.holdNearRoute = true
        let discovery = Task { await f.model.discover() }
        try await waitUntil { f.provider.pendingRoutes.count == 1 }
        let near = try #require(f.model.stores.first { $0.id == "NEAR" })
        #expect(f.model.stores.count == 4 && f.model.availability.count == 4 && f.model.resolvingTravel)
        #expect(f.model.travelTime(to: near) == "Estimating drive…")
        let pendingEstimate = try #require(f.model.travelEstimate(to: near))
        #expect(pendingEstimate.straightLineKilometers == 0 && pendingEstimate.drivingRoute == nil)
        await f.model.detectLocation()
        #expect(f.location.calls == 0 && f.model.locationQuery == travelQuery)
        #expect(f.model.travelTime(to: near) == "Estimating drive…")
        f.provider.holdNearRoute = false
        f.provider.resolveRoute(0, result: .success(DrivingRoute(distanceKilometers: 2.5, expectedTravelSeconds: 760)))
        await discovery.value
        #expect(f.model.travelTime(to: near) == "~15 min drive" && !f.model.resolvingTravel)
        await f.model.discover()
        #expect(f.provider.routes.filter { $0.destination == travelOrigin }.count == 1)
        #expect(f.provider.routes.filter { $0.destination == travelFar }.count == 2)
        f.model.locationQuery = "SYNTHETIC-POSTCODE-B"
        f.model.changedLocationManually()
        #expect(f.model.travelEstimates.isEmpty && f.model.distance(to: near) == nil && f.model.travelStatus.isEmpty)
        await f.model.discover()
        #expect(f.provider.routes.filter { $0.destination == travelOrigin }.count == 2)
        #expect(await f.vault.calls.isEmpty)
    }

    @Test(arguments: TravelSuspensionStage.allCases)
    func returningToSameQueryNeverPublishesAnOldOriginOrRoute(_ stage: TravelSuspensionStage) async throws {
        let f = fixture()
        f.provider.holdOrigin = stage == .origin; f.provider.holdNearRoute = stage == .route
        let old = Task { await f.model.discover() }
        try await waitUntil { stage == .origin ? !f.provider.pendingOrigins.isEmpty : !f.provider.pendingRoutes.isEmpty }
        f.model.locationQuery = "SYNTHETIC-POSTCODE-B"; f.model.changedLocationManually()
        f.model.locationQuery = travelQuery; f.model.changedLocationManually()
        #expect(f.model.travelEstimates.isEmpty && !f.model.resolvingTravel && f.model.travelStatus.isEmpty)
        if stage == .origin { f.provider.resolveOrigin(0, result: .success(Coordinate(latitude: 45, longitude: -81))) }
        else { f.provider.resolveRoute(0, result: .success(DrivingRoute(distanceKilometers: 90, expectedTravelSeconds: 5400))) }
        await old.value
        #expect(f.model.travelEstimates.isEmpty && f.model.travelStatus.isEmpty && !f.model.resolvingTravel)
        let near = try #require(f.model.stores.first { $0.id == "NEAR" })
        #expect(f.model.distance(to: near) == nil && f.model.travelTime(to: near) == "Drive time unavailable")
        f.provider.holdOrigin = false; f.provider.holdNearRoute = false
        await f.model.discover()
        #expect(f.model.distance(to: near) == "0.0 km" && f.model.travelTime(to: near) == "~15 min drive")
    }

    @Test func countryChangeAndCancellationPreventLateRoutesFromRestoringOldRows() async throws {
        let f = fixture(); f.provider.holdNearRoute = true
        let old = Task { await f.model.discover() }
        try await waitUntil { f.provider.pendingRoutes.count == 1 }
        f.model.preferences.market = .us; f.model.changedMarket()
        #expect(f.model.stores.isEmpty && f.model.travelEstimates.isEmpty && !f.model.resolvingTravel)
        f.provider.resolveRoute(0, result: .success(DrivingRoute(distanceKilometers: 2, expectedTravelSeconds: 300)))
        await old.value
        #expect(f.model.stores.isEmpty && f.model.travelEstimates.isEmpty && f.model.preferences.market == .us)
        let cancelled = fixture(); cancelled.provider.holdNearRoute = true
        let task = Task { await cancelled.model.discover() }
        try await waitUntil { cancelled.provider.pendingRoutes.count == 1 }
        task.cancel()
        cancelled.provider.resolveRoute(0, result: .success(DrivingRoute(distanceKilometers: 2, expectedTravelSeconds: 300)))
        await task.value
        #expect(cancelled.model.travelEstimates.isEmpty && !cancelled.model.resolvingTravel)
    }

    @Test func geocodingFailureInvalidOriginAndEmptyInventoryKeepAvailabilitySeparateFromTravel() async throws {
        for result in [Result<Coordinate, Error>.failure(StoreTravelError.countryMismatch), .success(Coordinate(latitude: 999, longitude: 999))] {
            let f = fixture(); f.provider.originResult = result
            await f.model.discover()
            #expect(f.model.stores.count == 4 && f.model.availability.count == 4 && f.model.error == nil)
            #expect(f.provider.routes.isEmpty && f.model.travelEstimates.isEmpty && !f.model.resolvingTravel)
            #expect(!f.model.travelStatus.isEmpty && f.model.travelEstimate(to: travelStores[2]) == nil)
        }
        let empty = fixture(); await empty.inventory.replaceStores([])
        await empty.model.discover()
        #expect(empty.provider.origins.isEmpty && empty.provider.routes.isEmpty && !empty.model.resolvingTravel)
        let failed = fixture(); await failed.inventory.setFailure()
        await failed.model.discover()
        #expect(failed.provider.origins.isEmpty && failed.model.error != nil)
        let changed = fixture(); await changed.model.discover()
        await changed.inventory.replaceStores([travelStores[0]])
        await changed.model.discover()
        #expect(changed.model.stores.map(\.id) == ["FAR"] && Set(changed.model.travelEstimates.keys) == ["FAR"])
    }

    @Test func physicalOriginSkipsPostalGeocodingAndRoutesRemainEphemeral() async throws {
        let f = fixture()
        await f.model.detectLocation()
        #expect(f.provider.origins.isEmpty && f.provider.routes.count == 2)
        #expect(f.model.distance(to: travelStores[2]) == "0.0 km")
        #expect(f.model.travelTime(to: travelStores[2]) == "~15 min drive")
        #expect(f.model.travelStatus.lowercased().contains("detected location"))
        #expect(await f.vault.calls.isEmpty)
    }

    @Test func invalidPhysicalCoordinateKeepsInventoryButNeverInventsTravelOrPersistsTheFix() async throws {
        let f = fixture(); f.location.coordinate = Coordinate(latitude: 999, longitude: 999)
        await f.model.detectLocation()
        #expect(f.location.calls == 1 && f.model.stores.count == 4 && f.model.availability.count == 4)
        #expect(f.provider.origins.isEmpty && f.provider.routes.isEmpty)
        #expect(f.model.travelEstimates.isEmpty && !f.model.resolvingTravel && !f.model.busy)
        #expect(f.model.error == nil && f.model.travelStatus.lowercased().contains("unavailable"))
        for store in f.model.stores {
            #expect(f.model.distance(to: store) == nil && f.model.travelEstimate(to: store) == nil)
            #expect(f.model.travelTime(to: store) == "Drive time unavailable")
        }
        #expect(await f.vault.calls.isEmpty)
        for saved in f.preferences.saves.withLock({ $0 }) {
            let text = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
            #expect(!text.contains("Synthetic physical location"))
        }
    }

    @Test func nativeStoreRowsRenderRealEstimateLabelsAndFallbackWithoutMappingRequests() async throws {
        let f = fixture(); await f.inventory.replaceStores([travelStores[0], travelStores[2]])
        await f.model.discover()
        _ = NSApplication.shared
        let size = NSSize(width: 960, height: 1100)
        let root = ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Synthetic travel preview").font(.headline)
                    Text("Synthetic postcode and stores. Times are fixture data, not live directions.").font(.caption).foregroundStyle(.secondary)
                }
                StoreSetupView(model: f.model)
            }.padding(28)
        }
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_CA"))
            .background(Color(nsColor: .windowBackgroundColor))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller; controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.frame = NSRect(origin: .zero, size: size); window.setContentSize(size)
        defer { window.close() }
        for _ in 0..<4 {
            window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let fit = controller.sizeThatFits(in: size)
        #expect(fit.width > 0 && fit.height > 0 && fit.width <= size.width && fit.height <= size.height)
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 3_000)
        if ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_PREVIEWS"] == "1" {
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let url = project.appendingPathComponent("outputs/previews/store-travel.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        }
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]; request.minimumTextHeight = 0.005
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        #expect(text.contains("synthetic near store") && text.contains("synthetic far store"))
        #expect(text.contains("min drive") && text.contains("drive time unavailable"))
        #expect(text.contains("km away") && text.contains("synthetic pickup quote"))
        #expect(text.contains("straight-line") && text.contains("rough apple maps estimates"))
        #expect(f.provider.origins.count == 1 && f.provider.routes.count == 2)
        #expect(await f.vault.calls.isEmpty)
    }
}
