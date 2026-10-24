import Foundation
import PilotCore
import Synchronization
import Testing
import UserNotifications
@testable import PickupPilot

private enum InventoryModelFailure: Error { case unexpectedAccess, timeout }

private let inventoryModelProduct = ProductVariant(id: "SYNTHETIC-INVENTORY/A", name: "Synthetic iPhone", storage: "256 GB", color: "Blue",
    productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic-inventory"))
private let inventoryModelSecondProduct = ProductVariant(id: "SYNTHETIC-INVENTORY/B", name: "Synthetic iPhone", storage: "512 GB", color: "Green",
    productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic-inventory-second"))
private let inventoryModelThirdProduct = ProductVariant(id: "SYNTHETIC-INVENTORY/C", name: "Synthetic iPhone", storage: "1 TB", color: "Purple",
    productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic-inventory-third"))
private func inventoryModelProducts(market: Market, count: Int = 3) -> [ProductVariant] {
    var products = [inventoryModelProduct, inventoryModelSecondProduct, inventoryModelThirdProduct].map { original in
        var variant = original
        variant.productURL = market.productBaseURL.appendingPathComponent(original.productURL.lastPathComponent)
        return variant
    }
    if count > products.count {
        products += (4...count).map { index in
            ProductVariant(id: "SYNTHETIC-INVENTORY/\(index)", name: "Synthetic iPhone", storage: "\(index) GB", color: "Synthetic \(index)",
                           productURL: market.productBaseURL.appendingPathComponent("synthetic-inventory-\(index)"))
        }
    }
    return Array(products.prefix(count))
}
private let inventoryModelStores = [
    RetailStore(id: "STORE-ONE", name: "Store One", latitude: 43.65, longitude: -79.38, countryCode: "CA"),
    RetailStore(id: "STORE-TWO", name: "Store Two", latitude: 43.7, longitude: -79.4, countryCode: "CA")
]
private func inventoryModelSnapshot(stores: [RetailStore] = inventoryModelStores, state: AvailabilityState = .unavailable,
                                    variants: [ProductVariant] = [inventoryModelProduct]) -> InventorySnapshot {
    InventorySnapshot(stores: stores, availability: stores.flatMap { store in
        variants.map { StoreAvailability(storeID: store.id, variantID: $0.id, state: state,
                                         message: state == .available ? "Pickup today" : "Unavailable") }
    })
}

private final class InventoryModelPreferences: PreferencesStore {
    private struct State { var preferences: PilotPreferences; var saves = 0 }
    private let state: Mutex<State>
    init(_ preferences: PilotPreferences) { state = Mutex(State(preferences: preferences)) }
    func load() -> PilotPreferences { state.withLock { $0.preferences } }
    func save(_ preferences: PilotPreferences) { state.withLock { $0.preferences = preferences; $0.saves += 1 } }
    var saved: PilotPreferences { state.withLock { $0.preferences } }
    var saveCount: Int { state.withLock { $0.saves } }
}

private actor InventoryModelVault: SecureVault {
    private(set) var calls: [String] = []
    private func accessed(_ operation: String) throws { calls.append(operation); throw InventoryModelFailure.unexpectedAccess }
    func saveProfile(_ profile: SecureProfile) throws { try accessed("saveProfile") }
    func loadProfile() throws -> SecureProfile? { try accessed("loadProfile"); return nil }
    func loadProfileForUserInitiatedRestore() async throws -> SecureProfile? { try accessed("restoreProfile"); return nil }
    func deleteProfile() throws { try accessed("deleteProfile") }
    func saveSession(_ data: Data) throws { try accessed("saveSession") }
    func loadSession() throws -> Data? { try accessed("loadSession"); return nil }
    func deleteSession() throws { try accessed("deleteSession") }
    func saveOrderState(_ data: Data) throws { try accessed("saveOrderState") }
    func loadOrderState() throws -> Data? { try accessed("loadOrderState"); return nil }
    func deleteOrderState() throws { try accessed("deleteOrderState") }
    func clear() throws { try accessed("clear") }
}

private actor InventoryModelCatalog: ProductCatalogFetching {
    private(set) var calls = 0
    private(set) var requestedProducts: [CatalogProduct] = []
    private var variantCount = 3
    func setVariantCount(_ count: Int) { variantCount = count }
    func variants(market: Market) async -> [ProductVariant] {
        calls += 1; requestedProducts.append(.iPhoneDuo)
        return inventoryModelProducts(market: market, count: variantCount)
    }
    func variants(market: Market, product: CatalogProduct) async -> [ProductVariant] {
        calls += 1; requestedProducts.append(product)
        if product == .usbCHeadphoneAdapter {
            return [ProductVariant(id: CatalogProduct.adapterSKU, name: "Synthetic adapter", storage: "", color: "White", productURL: CatalogProduct.adapterURL)]
        }
        return inventoryModelProducts(market: market, count: variantCount)
    }
}

private actor InventoryModelFeed: InventoryFetching {
    struct Call: Sendable { let market: Market; let location: String; let products: [ProductVariant] }
    private(set) var calls: [Call] = []
    private var response: InventorySnapshot?
    private var failure: AppleServiceError?
    private var suspended = false
    private var continuations: [(CheckedContinuation<InventorySnapshot, Never>, InventorySnapshot)] = []
    private var activeRequests = 0
    private(set) var maximumConcurrentRequests = 0
    var isWaiting: Bool { !continuations.isEmpty }
    func setResponse(_ response: InventorySnapshot) { self.response = response }
    func setFailure(_ error: AppleServiceError?) { failure = error }
    func suspend() { suspended = true }
    func release() {
        suspended = false
        let pending = continuations; continuations = []
        for (continuation, response) in pending { continuation.resume(returning: response) }
    }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        calls.append(Call(market: market, location: location, products: variants))
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        defer { activeRequests -= 1 }
        if let failure { throw failure }
        let stores = inventoryModelStores.map { store in
            RetailStore(id: store.id, name: store.name, latitude: store.latitude, longitude: store.longitude, countryCode: market.countryCode)
        }
        let response = response ?? inventoryModelSnapshot(stores: stores, variants: variants)
        if suspended { return await withCheckedContinuation { continuations.append(($0, response)) } }
        return response
    }
}

@MainActor private final class InventoryModelLocation: LocationDetecting {
    var status = "Synthetic location is not requested."
    var requesting = false
    private(set) var calls = 0
    func locate() throws -> DetectedLocation { calls += 1; throw InventoryModelFailure.unexpectedAccess }
}

@MainActor private final class InventoryModelTravel: StoreTravelProviding {
    private(set) var queries: [String] = []
    var suspendOrigin = false
    var isWaiting: Bool { originContinuation != nil }
    private var originContinuation: CheckedContinuation<Coordinate, Never>?
    func origin(for query: String, market: Market) async -> Coordinate {
        queries.append(query)
        if suspendOrigin { return await withCheckedContinuation { originContinuation = $0 } }
        return Coordinate(latitude: 43.65, longitude: -79.38)
    }
    func release() { suspendOrigin = false; let pending = originContinuation; originContinuation = nil; pending?.resume(returning: Coordinate(latitude: 43.65, longitude: -79.38)) }
    func drivingRoute(from origin: Coordinate, to destination: Coordinate) -> DrivingRoute {
        DrivingRoute(distanceKilometers: 3, expectedTravelSeconds: 600)
    }
}

@MainActor private final class InventoryModelPage: AppleCheckoutPage {
    private(set) var calls: [String] = []
    func showBrowser() async throws { calls.append("showBrowser") }
    func load(_ url: URL) async throws { calls.append("load") }
    func snapshot() async throws -> CheckoutSnapshot { calls.append("snapshot"); return CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/bag") }
    func advance(request: CheckoutRequest, profile: SecureProfile) async throws -> Bool { calls.append("advance"); return false }
    func placeOrder(expected: CheckoutSnapshot) async throws -> Bool { calls.append("placeOrder"); return false }
    func restoreSession(_ data: Data?) async throws { calls.append("restoreSession") }
    func sessionData() async throws -> Data { calls.append("sessionData"); return Data() }
    func cancel() { calls.append("cancel") }
    func clearPage() { calls.append("clearPage") }
}

@MainActor private final class InventoryModelAlertCenter: InventoryAlertCenter {
    private(set) var installs = 0
    private(set) var permissionRequests = 0
    private(set) var settingsReads = 0
    private(set) var payloads: [InventoryAlertPayload] = []
    var authorization: InventoryAlertAuthorization = .authorized
    var suspendPermission = false
    var isWaiting: Bool { permissionContinuation != nil }
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    func install(delegate: any UNUserNotificationCenterDelegate) { installs += 1 }
    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        permissionRequests += 1
        if suspendPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return authorization == .authorized
    }
    func release() { suspendPermission = false; let pending = permissionContinuation; permissionContinuation = nil; pending?.resume(returning: authorization == .authorized) }
    func settings() -> InventoryAlertSettings {
        settingsReads += 1
        return InventoryAlertSettings(authorization: authorization, alerts: .enabled, sounds: .enabled, badges: .enabled, timeSensitive: .enabled)
    }
    func add(_ payload: InventoryAlertPayload) { payloads.append(payload) }
    func setBadgeCount(_ count: Int) {}
    func removeDelivered(identifiers: [String]) {}
}

@MainActor private final class InventoryModelAttention: InventoryAlertAttention {
    private(set) var requests = 0
    private(set) var badges: [String?] = []
    func setBadgeLabel(_ label: String?) { badges.append(label) }
    func requestAttention() -> Int { requests += 1; return requests }
    func cancelAttention(_ identifier: Int) {}
}

@MainActor private struct InventoryModelFixture {
    let model: PilotModel
    let vault = InventoryModelVault()
    let feed = InventoryModelFeed()
    let catalog = InventoryModelCatalog()
    let location = InventoryModelLocation()
    let travel = InventoryModelTravel()
    let page = InventoryModelPage()
    let alerts = InventoryModelAlertCenter()
    let attention = InventoryModelAttention()
    let preferences: InventoryModelPreferences
    init(smoke: Bool = false, configure: (inout PilotPreferences) -> Void = { _ in }) {
        var initial = PilotPreferences()
        initial.market = .ca; initial.inventoryLocationQuery = "Synthetic City"
        initial.selectedVariantIDs = [inventoryModelProduct.id]
        initial.selectedStoreIDs = [inventoryModelStores[0].id]
        configure(&initial)
        preferences = InventoryModelPreferences(initial)
        let checkout = AppleCheckoutDriver(vault: vault, page: page)
        model = PilotModel(vault: vault, preferencesStore: preferences, smoke: smoke, catalog: catalog, inventory: feed,
                           locationService: location, travelService: travel, checkout: checkout,
                           rehearsal: CheckoutRehearsal(driver: checkout), isApplicationActive: { true }, inventoryOnly: true,
                           inventoryAlerts: InventoryAlertService(center: alerts, attention: attention))
    }
    func finish() async {
        model.stopInventoryMonitoring()
        await feed.release()
        alerts.release()
        travel.release()
        await model.inventoryMonitor.stopAndWait()
    }
}

@MainActor private func withInventoryModelFixture(smoke: Bool = false, configure: (inout PilotPreferences) -> Void = { _ in },
                                                 _ operation: (InventoryModelFixture) async throws -> Void) async throws {
    let fixture = InventoryModelFixture(smoke: smoke, configure: configure)
    do { try await operation(fixture) }
    catch { await fixture.finish(); throw error }
    await fixture.finish()
}

@MainActor private func inventoryModelEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<4000 {
        if await condition() { return }
        await Task.yield()
    }
    throw InventoryModelFailure.timeout
}

@Suite(.serialized) @MainActor struct InventoryModelTests {
    @Test func savedLocationStartupAutomaticallyObservesAllSelectedProductsWithoutPrivateStorage() async throws {
        try await withInventoryModelFixture(configure: { $0.selectedVariantIDs = [inventoryModelProduct.id, inventoryModelSecondProduct.id] }) { fixture in
            await fixture.model.startup()
            await fixture.model.startup()
            #expect(fixture.model.locationQuery == "Synthetic City")
            #expect(fixture.location.calls == 0)
            #expect(await fixture.catalog.calls == 1)
            #expect(await fixture.feed.calls.count == 1)
            let first = try #require(await fixture.feed.calls.first)
            #expect(Set(first.products.map(\.id)) == [inventoryModelProduct.id, inventoryModelSecondProduct.id])
            #expect(fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryMonitor.checkCount == 1)
            #expect(fixture.model.inventoryStores.count == 2 && fixture.model.inventoryAvailability.count == 4)
            #expect(!fixture.model.inventoryDataIsStale && !fixture.model.setupLocked)
            #expect(await fixture.vault.calls.isEmpty && fixture.page.calls.isEmpty)
            #expect(!fixture.model.hasSavedProfile && !fixture.model.profileOpen && !fixture.model.coordinator.isArmed)
            #expect(fixture.model.rehearsal.state == .idle)
            #expect(fixture.alerts.installs == 1)
            #expect(fixture.attention.requests == 0 && fixture.alerts.payloads.isEmpty)
            #expect(fixture.preferences.saved.inventoryLocationQuery == "Synthetic City")
        }
    }

    @Test func ownedLaunchStartupSurvivesCallerCancellationAndStartsOnlyOnce() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.feed.suspend()
            let windowTask = Task {
                fixture.model.observeInventoryOnLaunch()
                try? await Task.sleep(for: .seconds(10))
                return Task.isCancelled
            }
            defer { windowTask.cancel() }
            try await inventoryModelEventually { await fixture.feed.isWaiting }
            windowTask.cancel()
            #expect(await windowTask.value)
            fixture.model.observeInventoryOnLaunch()
            await fixture.feed.release()
            try await inventoryModelEventually {
                fixture.model.inventoryMonitor.isRunning && !fixture.model.busy
            }
            fixture.model.observeInventoryOnLaunch()
            await Task.yield()
            #expect(await fixture.catalog.calls == 1)
            #expect(await fixture.feed.calls.count == 1)
            #expect(fixture.model.inventoryAvailability.count == 2 && fixture.model.inventoryMonitor.checkCount == 1)
            #expect(await fixture.vault.calls.isEmpty && fixture.page.calls.isEmpty)
        }
    }

    @Test func failedDiscoverySeedsAutomaticBackoffWithoutImmediateDuplicateRequest() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.feed.setFailure(.httpStatus(503))
            await fixture.model.startup()
            #expect(fixture.model.inventoryMonitor.isRunning)
            #expect(fixture.model.inventoryMonitor.lastError?.contains("503") == true)
            #expect(fixture.model.inventoryMonitor.checkCount == 1 && fixture.model.inventoryMonitor.snapshot == nil)
            #expect(fixture.model.inventoryMonitor.nextCheck != nil)
            #expect(fixture.model.inventoryDataIsStale && fixture.model.inventoryAvailability.isEmpty)
            #expect(await fixture.feed.calls.count == 1)
            await fixture.model.refreshInventory()
            #expect(await fixture.feed.calls.count == 1)
            #expect(fixture.model.inventoryMonitor.checkCount == 1)
            #expect(fixture.model.inventoryAlerts.unreadCount == 0 && fixture.alerts.payloads.isEmpty)
            #expect(await fixture.vault.calls.isEmpty && fixture.page.calls.isEmpty)
        }
    }

    @Test func inventoryOnlyBlocksEveryPublicCheckoutEntryPoint() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            fixture.model.hasSavedProfile = true
            fixture.model.consentToOrder = true
            await fixture.model.arm()
            fixture.model.requestArmingReview()
            await fixture.model.confirmArmingReview(id: UUID())
            await fixture.model.testCheckout()
            await fixture.model.openProfile()
            await fixture.model.saveProfile()
            await fixture.model.restoreSavedCheckoutProfile()
            await fixture.model.deleteProfile()
            await fixture.model.clearSession()
            await fixture.model.saveResolvedAppleSession()
            await fixture.model.returnToAppleBag()
            await fixture.model.showSafariCheckout()
            await fixture.model.resetLock()
            await fixture.model.reconcileVisibleConfirmation()
            #expect(await fixture.vault.calls.isEmpty)
            #expect(fixture.page.calls.isEmpty)
            #expect(fixture.model.pendingArmingReview == nil && !fixture.model.coordinator.isArmed)
            #expect(fixture.model.rehearsal.state == .idle && !fixture.model.startingCheckoutTest)
            #expect(!fixture.model.profileOpen && !fixture.model.canRestoreSavedProfile && !fixture.model.canSaveResolvedAppleSession)
            #expect(fixture.model.error?.contains("temporarily disabled") == true)
        }
    }

    @Test func refreshKeepsAutomaticObservationAndIncludesAllNearbyStores() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            let third = RetailStore(id: "STORE-THREE", name: "Store Three", latitude: 43.75, longitude: -79.45, countryCode: "CA")
            let response = inventoryModelSnapshot(stores: inventoryModelStores + [third], state: .available)
            await fixture.feed.setResponse(response)
            await fixture.model.refreshInventory()
            #expect(Set(fixture.model.inventoryStores.map(\.id)) == Set(response.stores.map(\.id)))
            #expect(fixture.model.inventoryAvailability.count == 3)
            #expect(fixture.model.preferences.selectedStoreIDs == [inventoryModelStores[0].id])
            #expect(fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryMonitor.checkCount == 2)
            #expect(fixture.model.inventoryAlerts.unreadCount == 3)
            try await inventoryModelEventually { fixture.alerts.payloads.count == 1 }
            #expect(fixture.attention.requests == 1)
            #expect(await fixture.vault.calls.isEmpty && fixture.page.calls.isEmpty)
        }
    }

    @Test func changingSelectedVariantsAutomaticallyReconfiguresObservation() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            fixture.model.toggleVariant(inventoryModelSecondProduct.id)
            try await inventoryModelEventually {
                let calls = await fixture.feed.calls
                return calls.count >= 2 && Set(calls.last?.products.map(\.id) ?? []) == [inventoryModelProduct.id, inventoryModelSecondProduct.id]
                    && fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryAvailability.count == 4
            }
            fixture.model.toggleVariant(inventoryModelProduct.id)
            try await inventoryModelEventually {
                let calls = await fixture.feed.calls
                return calls.last?.products.map(\.id) == [inventoryModelSecondProduct.id]
                    && fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryAvailability.count == 2
            }
            #expect(await fixture.feed.maximumConcurrentRequests == 1)
            #expect(fixture.model.error == nil && !fixture.model.setupLocked)
            #expect(await fixture.vault.calls.isEmpty && fixture.page.calls.isEmpty)
        }
    }

    @Test func selectingNoProductsQuietlyStopsAndSelectingAgainAutomaticallyResumes() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            fixture.model.toggleVariant(inventoryModelProduct.id)
            try await inventoryModelEventually { !fixture.model.inventoryMonitor.isRunning }
            #expect(fixture.model.preferences.selectedVariantIDs.isEmpty)
            #expect(fixture.model.inventoryAvailability.isEmpty)
            #expect(fixture.model.error == nil)
            fixture.model.toggleVariant(inventoryModelSecondProduct.id)
            try await inventoryModelEventually {
                let calls = await fixture.feed.calls
                return fixture.model.inventoryMonitor.isRunning && calls.last?.products.map(\.id) == [inventoryModelSecondProduct.id]
                    && fixture.model.inventoryAvailability.count == 2
            }
            #expect(fixture.model.error == nil)
        }
    }

    @Test func manualLocationEditPausesOldScopeAndFindAutomaticallyResumes() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            fixture.model.enterLocationQuery("Another Synthetic City")
            #expect(!fixture.model.inventoryMonitor.isRunning)
            #expect(fixture.model.inventoryStores.isEmpty && fixture.model.inventoryAvailability.isEmpty)
            #expect(fixture.model.inventoryDataIsStale)
            let beforeFind = await fixture.feed.calls.count
            await Task.yield()
            #expect(await fixture.feed.calls.count == beforeFind)
            #expect(fixture.preferences.saved.inventoryLocationQuery == "Another Synthetic City")
            await fixture.model.discover()
            try await inventoryModelEventually { fixture.model.inventoryMonitor.isRunning && !fixture.model.inventoryDataIsStale }
            let latest = try #require(await fixture.feed.calls.last)
            #expect(latest.location == "Another Synthetic City")
            #expect(latest.products.map(\.id) == [inventoryModelProduct.id])
            #expect(await fixture.vault.calls.isEmpty)
        }
    }

    @Test func failedRefreshRetainsVerifiedRowsAsStaleAndKeepsRetryingWithoutFalseAlerts() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            let discoveredStores = fixture.model.inventoryStores
            let discoveredAvailability = fixture.model.inventoryAvailability
            await fixture.feed.setFailure(.httpStatus(503))
            await fixture.model.refreshInventory()
            #expect(fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryMonitor.lastError != nil)
            #expect(fixture.model.inventoryStores == discoveredStores)
            #expect(fixture.model.inventoryAvailability == discoveredAvailability && fixture.model.inventoryDataIsStale)
            #expect(fixture.model.inventoryMonitor.changes.isEmpty && fixture.model.inventoryAlerts.unreadCount == 0)
            #expect(fixture.alerts.payloads.isEmpty && fixture.attention.requests == 0)
            #expect(await fixture.vault.calls.isEmpty && fixture.page.calls.isEmpty)
        }
    }

    @Test func configurationChangesDiscardLateDiscoveryResponse() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.feed.suspend()
            let startup = Task { await fixture.model.startup() }
            try await inventoryModelEventually { await fixture.feed.isWaiting }
            fixture.model.enterLocationQuery("New Synthetic City")
            await fixture.feed.release()
            await startup.value
            #expect(fixture.model.locationQuery == "New Synthetic City")
            #expect(fixture.model.inventoryStores.isEmpty && fixture.model.inventoryAvailability.isEmpty)
            #expect(!fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryDataIsStale)
            #expect(fixture.travel.queries.isEmpty)
            #expect(await fixture.vault.calls.isEmpty)
        }
    }

    @Test func automaticReconfigurationWaitsForOldRequestAndDiscardsItsLateStock() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            await fixture.feed.setResponse(inventoryModelSnapshot(state: .available))
            await fixture.feed.suspend()
            let refresh = Task { await fixture.model.refreshInventory() }
            try await inventoryModelEventually { await fixture.feed.isWaiting }
            fixture.model.toggleVariant(inventoryModelSecondProduct.id)
            for _ in 0..<20 { await Task.yield() }
            #expect(await fixture.feed.calls.count == 2)
            #expect(fixture.model.inventoryAvailability.isEmpty)
            await fixture.feed.setResponse(inventoryModelSnapshot(variants: [inventoryModelProduct, inventoryModelSecondProduct]))
            await fixture.feed.release()
            await refresh.value
            try await inventoryModelEventually {
                fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryAvailability.count == 4
            }
            #expect(await fixture.feed.maximumConcurrentRequests == 1)
            #expect(fixture.model.inventoryAlerts.unreadCount == 0 && fixture.alerts.payloads.isEmpty)
        }
    }

    @Test func countryChangeRequiresNewCatalogAndSelectionBeforeAutomaticObservation() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            fixture.model.selectMarket(.uk)
            #expect(fixture.model.preferences.market == .uk)
            #expect(fixture.model.preferences.selectedVariantIDs.isEmpty && !fixture.model.inventoryMonitor.isRunning)
            await fixture.model.discover()
            #expect(!fixture.model.inventoryMonitor.isRunning && !fixture.model.variants.isEmpty)
            fixture.model.toggleVariant(inventoryModelSecondProduct.id)
            try await inventoryModelEventually {
                let latest = await fixture.feed.calls.last
                return fixture.model.inventoryMonitor.isRunning && latest?.market == .uk
                    && latest?.products.map(\.id) == [inventoryModelSecondProduct.id]
            }
            #expect(fixture.model.variants.allSatisfy { $0.productURL.path.hasPrefix(Market.uk.productBaseURL.path + "/") })
            #expect(fixture.model.error == nil)
        }
    }

    @Test func savedAdapterCatalogMigratesBeforeDiscoveryWithoutLosingPhoneSelectionOrLocation() async throws {
        try await withInventoryModelFixture(configure: {
            $0.catalogProduct = .usbCHeadphoneAdapter
            $0.selectedVariantIDs = [CatalogProduct.adapterSKU, inventoryModelProduct.id, inventoryModelSecondProduct.id]
        }) { fixture in
            let phoneIDs = [inventoryModelProduct.id, inventoryModelSecondProduct.id]
            #expect(fixture.model.preferences.catalogProduct == .iPhoneDuo)
            #expect(fixture.model.preferences.selectedVariantIDs == phoneIDs)
            #expect(fixture.preferences.saved.catalogProduct == .iPhoneDuo)
            #expect(fixture.preferences.saved.selectedVariantIDs == phoneIDs)
            #expect(fixture.preferences.saved.inventoryLocationQuery == "Synthetic City")
            #expect(fixture.preferences.saved.selectedStoreIDs == [inventoryModelStores[0].id])
            await fixture.model.startup()
            #expect(await fixture.catalog.requestedProducts == [.iPhoneDuo])
            #expect(await fixture.feed.calls.allSatisfy { !$0.products.contains(where: { $0.id == CatalogProduct.adapterSKU }) })
            #expect(fixture.model.inventoryMonitor.isRunning && fixture.model.inventoryAvailability.count == 4)
            #expect(!fixture.model.variants.contains(where: { $0.id == CatalogProduct.adapterSKU }))
            #expect(await fixture.vault.calls.isEmpty && fixture.page.calls.isEmpty)
        }
    }

    @Test func adapterOnlySavedSelectionMigratesToQuietUnselectedPhoneCatalog() async throws {
        try await withInventoryModelFixture(configure: {
            $0.catalogProduct = .usbCHeadphoneAdapter
            $0.selectedVariantIDs = [CatalogProduct.adapterSKU]
        }) { fixture in
            await fixture.model.startup()
            #expect(fixture.model.preferences.catalogProduct == .iPhoneDuo)
            #expect(fixture.model.preferences.selectedVariantIDs.isEmpty)
            #expect(!fixture.model.inventoryMonitor.isRunning && fixture.model.error == nil)
            #expect(await fixture.catalog.requestedProducts == [.iPhoneDuo])
            #expect(await fixture.feed.calls.allSatisfy { !$0.products.contains(where: { $0.id == CatalogProduct.adapterSKU }) })
            #expect(fixture.preferences.saved.selectedVariantIDs.isEmpty)
            #expect(fixture.preferences.saved.inventoryLocationQuery == "Synthetic City")
        }
    }

    @Test func inventoryModeIgnoresAdapterCatalogSelectionAndCannotSelectItsSKU() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            let initialSelection = fixture.model.preferences.selectedVariantIDs
            let saves = fixture.preferences.saveCount
            fixture.model.selectCatalogProduct(.usbCHeadphoneAdapter)
            #expect(fixture.model.preferences.catalogProduct == .iPhoneDuo)
            #expect(fixture.model.preferences.selectedVariantIDs == initialSelection)
            #expect(fixture.model.inventoryMonitor.isRunning && fixture.model.error == nil)
            #expect(fixture.preferences.saveCount == saves)
            fixture.model.toggleVariant(CatalogProduct.adapterSKU)
            await Task.yield()
            #expect(fixture.model.preferences.selectedVariantIDs == initialSelection)
            #expect(fixture.preferences.saveCount == saves)
            #expect(await fixture.catalog.requestedProducts == [.iPhoneDuo])
            #expect(await fixture.feed.calls.count == 1)
        }
    }

    @Test func atomicConfigurationSelectionRetainsTwoAndThreeItemsWithOneCheckPerChange() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            let threeIDs = [inventoryModelProduct.id, inventoryModelSecondProduct.id, inventoryModelThirdProduct.id]
            let firstSaves = fixture.preferences.saveCount
            fixture.model.setInventoryVariantSelection(threeIDs)
            #expect(fixture.model.preferences.selectedVariantIDs == threeIDs)
            #expect(fixture.preferences.saved.selectedVariantIDs == threeIDs)
            #expect(fixture.preferences.saveCount == firstSaves + 1)
            try await inventoryModelEventually {
                let latest = await fixture.feed.calls.last
                return fixture.model.inventoryMonitor.isRunning && latest?.products.map(\.id) == threeIDs
                    && fixture.model.inventoryAvailability.count == 6
            }
            #expect(await fixture.feed.calls.count == 2)
            let secondSaves = fixture.preferences.saveCount
            fixture.model.setInventoryVariantSelection(Array(threeIDs.prefix(2)))
            try await inventoryModelEventually {
                let latest = await fixture.feed.calls.last
                return fixture.model.inventoryMonitor.isRunning && latest?.products.map(\.id) == Array(threeIDs.prefix(2))
                    && fixture.model.inventoryAvailability.count == 4
            }
            #expect(fixture.model.preferences.selectedVariantIDs == Array(threeIDs.prefix(2)))
            #expect(fixture.preferences.saveCount == secondSaves + 1)
            #expect(await fixture.feed.calls.count == 3)
            #expect(await fixture.feed.maximumConcurrentRequests == 1)
            #expect(fixture.model.error == nil)
        }
    }

    @Test func rapidAtomicSelectionChangesObserveOnlyFinalConfigurationSet() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.model.startup()
            fixture.model.setInventoryVariantSelection([inventoryModelProduct.id, inventoryModelSecondProduct.id, inventoryModelThirdProduct.id])
            fixture.model.setInventoryVariantSelection([inventoryModelSecondProduct.id, inventoryModelThirdProduct.id])
            fixture.model.setInventoryVariantSelection([inventoryModelThirdProduct.id])
            try await inventoryModelEventually {
                let latest = await fixture.feed.calls.last
                return fixture.model.inventoryMonitor.isRunning && latest?.products.map(\.id) == [inventoryModelThirdProduct.id]
                    && fixture.model.inventoryAvailability.count == 2
            }
            #expect(await fixture.feed.calls.count == 2)
            #expect(await fixture.feed.maximumConcurrentRequests == 1)
            #expect(fixture.model.preferences.selectedVariantIDs == [inventoryModelThirdProduct.id])
            #expect(fixture.preferences.saved.selectedVariantIDs == [inventoryModelThirdProduct.id])
            #expect(fixture.model.error == nil)
        }
    }

    @Test func atomicSelectionRejectsInvalidBatchesWithoutPartialChangesAndAllowsBulkClear() async throws {
        try await withInventoryModelFixture { fixture in
            await fixture.catalog.setVariantCount(21)
            await fixture.model.startup()
            let allIDs = fixture.model.variants.map(\.id)
            #expect(allIDs.count == 21)
            let twentyIDs = Array(allIDs.prefix(20))
            fixture.model.setInventoryVariantSelection(twentyIDs)
            try await inventoryModelEventually {
                let latest = await fixture.feed.calls.last
                return latest?.products.map(\.id) == twentyIDs && fixture.model.inventoryAvailability.count == 40
            }
            let saves = fixture.preferences.saveCount
            for invalidIDs in [allIDs, [inventoryModelSecondProduct.id, "UNKNOWN/A"],
                               [inventoryModelSecondProduct.id, inventoryModelSecondProduct.id],
                               [inventoryModelSecondProduct.id, CatalogProduct.adapterSKU]] {
                fixture.model.setInventoryVariantSelection(invalidIDs)
                #expect(fixture.model.preferences.selectedVariantIDs == twentyIDs)
                #expect(fixture.preferences.saved.selectedVariantIDs == twentyIDs)
                #expect(fixture.preferences.saveCount == saves)
                #expect(fixture.model.inventoryMonitor.isRunning)
                #expect(fixture.model.error != nil)
            }
            var foreignVariant = inventoryModelThirdProduct
            foreignVariant.id = "SYNTHETIC-FOREIGN/A"
            foreignVariant.productURL = Market.uk.productBaseURL.appendingPathComponent("synthetic-foreign")
            for invalidCatalogEntry in [inventoryModelProduct, foreignVariant] {
                fixture.model.variants.append(invalidCatalogEntry)
                fixture.model.setInventoryVariantSelection([inventoryModelSecondProduct.id, invalidCatalogEntry.id])
                #expect(fixture.model.preferences.selectedVariantIDs == twentyIDs)
                #expect(fixture.preferences.saved.selectedVariantIDs == twentyIDs)
                #expect(fixture.preferences.saveCount == saves)
                #expect(fixture.model.error != nil)
                fixture.model.variants.removeLast()
            }
            await Task.yield()
            #expect(await fixture.feed.calls.count == 2)
            fixture.model.setInventoryVariantSelection([])
            #expect(fixture.model.preferences.selectedVariantIDs.isEmpty && fixture.preferences.saved.selectedVariantIDs.isEmpty)
            #expect(!fixture.model.inventoryMonitor.isRunning)
            #expect(fixture.preferences.saveCount == saves + 1)
            #expect(fixture.model.error == nil)
            #expect(await fixture.feed.calls.count == 2)
        }
    }

    @Test func observationBeginsBeforeSlowTravelEstimatesFinish() async throws {
        try await withInventoryModelFixture { fixture in
            fixture.travel.suspendOrigin = true
            let startup = Task { await fixture.model.startup() }
            try await inventoryModelEventually { fixture.travel.isWaiting }
            #expect(fixture.model.inventoryMonitor.isRunning)
            #expect(fixture.model.inventoryAvailability.count == 2)
            fixture.travel.release()
            await startup.value
        }
    }

    @Test func startupAndObservationDoNotWaitForNotificationPermission() async throws {
        try await withInventoryModelFixture { fixture in
            fixture.alerts.authorization = .notDetermined
            fixture.alerts.suspendPermission = true
            await fixture.feed.setResponse(inventoryModelSnapshot(state: .available))
            await fixture.model.startup()
            try await inventoryModelEventually { fixture.alerts.isWaiting }
            #expect(fixture.model.inventoryMonitor.isRunning)
            #expect(fixture.model.inventoryAvailability.count == 2)
            try await inventoryModelEventually { fixture.model.inventoryAlerts.unreadCount == 2 }
            #expect(fixture.alerts.payloads.isEmpty)
            await fixture.model.refreshInventory()
            #expect(fixture.model.inventoryMonitor.checkCount == 2)
            fixture.alerts.authorization = .authorized
            fixture.alerts.release()
            try await inventoryModelEventually { fixture.alerts.payloads.count == 1 }
            #expect(fixture.model.inventoryAlerts.unreadCount == 2)
            #expect(fixture.alerts.permissionRequests == 1)
        }
    }

    @Test func previewNeverAutomaticallyStartsObservationOrRequestsNotificationPermission() async throws {
        try await withInventoryModelFixture(smoke: true) { fixture in
            await fixture.model.startup()
            if let variant = fixture.model.variants.first { fixture.model.toggleVariant(variant.id) }
            await Task.yield()
            #expect(!fixture.model.inventoryMonitor.isRunning)
            #expect(await fixture.feed.calls.isEmpty)
            #expect(await fixture.catalog.calls == 0)
            #expect(fixture.alerts.permissionRequests == 0 && fixture.alerts.installs == 0)
            #expect(await fixture.vault.calls.isEmpty)
        }
    }

    @Test func refreshDefaultsToOneSecondAndModelPersistsClampedWholeSeconds() {
        let fixture = InventoryModelFixture()
        #expect(fixture.model.preferences.inventoryRefreshInterval == 1 && fixture.model.inventoryMonitor.refreshInterval == 1)
        for (input, expected) in [(0.0, 1.0), (1.0, 1.0), (3.7, 4.0), (4000.0, 3600.0), (Double.infinity, 1.0), (Double.nan, 1.0)] {
            fixture.model.setInventoryRefreshInterval(input)
            #expect(fixture.model.preferences.inventoryRefreshInterval == expected)
            #expect(fixture.model.inventoryMonitor.refreshInterval == expected)
            #expect(fixture.preferences.saved.inventoryRefreshInterval == expected)
        }
        let invalidSaved = InventoryModelFixture { $0.inventoryRefreshInterval = -5 }
        #expect(invalidSaved.model.preferences.inventoryRefreshInterval == 1 && invalidSaved.model.inventoryMonitor.refreshInterval == 1)
    }
}
