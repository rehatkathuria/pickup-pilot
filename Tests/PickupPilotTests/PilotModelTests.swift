import Foundation
import PilotCore
import Synchronization
import Testing
import WebKit
@testable import PickupPilot

private enum ModelSyntheticError: Error, LocalizedError {
    case expected
    var errorDescription: String? { "Synthetic storage failure" }
}

private final class ModelPreferencesStore: PreferencesStore {
    struct State {
        var preferences = PilotPreferences()
        var saves = 0
        var failLoad = false
        var failSave = false
    }
    let state = Mutex(State())
    func load() throws -> PilotPreferences {
        try state.withLock {
            if $0.failLoad { throw ModelSyntheticError.expected }
            return $0.preferences
        }
    }
    func save(_ preferences: PilotPreferences) throws {
        try state.withLock {
            if $0.failSave { throw ModelSyntheticError.expected }
            $0.preferences = preferences
            $0.saves += 1
        }
    }
}

private actor ModelSecureVault: SecureVault {
    var profile: SecureProfile?
    var session: Data?
    var orderState: Data?
    var failingOperation: String?
    var suspendProfileLoad = false
    var profileLoads = 0
    var pendingProfileLoad: CheckedContinuation<SecureProfile?, Error>?
    func fail(_ operation: String?) { failingOperation = operation }
    func suspendLoad() { suspendProfileLoad = true }
    func resolveLoad() { let continuation = pendingProfileLoad; pendingProfileLoad = nil; continuation?.resume(returning: profile) }
    private func check(_ operation: String) throws {
        if operation == failingOperation { throw ModelSyntheticError.expected }
    }
    func saveProfile(_ profile: SecureProfile) throws { try check("saveProfile"); self.profile = profile }
    func loadProfile() async throws -> SecureProfile? {
        profileLoads += 1
        try check("loadProfile")
        if suspendProfileLoad { return try await withCheckedThrowingContinuation { pendingProfileLoad = $0 } }
        return profile
    }
    func deleteProfile() throws { try check("deleteProfile"); profile = nil }
    func saveSession(_ data: Data) throws { try check("saveSession"); session = data }
    func loadSession() -> Data? { session }
    func deleteSession() throws { try check("deleteSession"); session = nil }
    func saveOrderState(_ data: Data) throws { try check("saveOrderState"); orderState = data }
    func loadOrderState() throws -> Data? { try check("loadOrderState"); return orderState }
    func deleteOrderState() { orderState = nil }
    func clear() { profile = nil; session = nil; orderState = nil }
}

private func modelSyntheticProfile() -> SecureProfile {
    SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid",
                  phone: "+14165550100", cardholder: "Synthetic Tester", cardNumber: "4111111111111111",
                  expiryMonth: "12", expiryYear: "2035", cvv: "123", billingLine1: "1 Synthetic Street",
                  billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
}

@MainActor private final class ModelLocation: LocationDetecting {
    var status = "Synthetic location unavailable. Enter a location manually."
    var requesting = false
    var calls = 0
    var suspended = false
    var pending: CheckedContinuation<DetectedLocation, Error>?
    var result: Result<DetectedLocation, Error> = .failure(LocationFailure.denied)
    func locate() async throws -> DetectedLocation {
        calls += 1; requesting = true
        defer { requesting = false }
        if suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
        return try result.get()
    }
    func resolve() { let continuation = pending; pending = nil; continuation?.resume(with: result) }
}

@MainActor private final class ModelTravel: StoreTravelProviding {
    func origin(for query: String, market: Market) async throws -> Coordinate {
        throw ModelSyntheticError.expected
    }
    func drivingRoute(from origin: Coordinate, to destination: Coordinate) async throws -> DrivingRoute {
        DrivingRoute(distanceKilometers: 6, expectedTravelSeconds: 900)
    }
}

private actor ModelCatalog: ProductCatalogFetching {
    var products: [ProductVariant]
    var failure = false
    var suspended = false
    var calls: [Market] = []
    var requestedProducts: [CatalogProduct] = []
    var pending: CheckedContinuation<[ProductVariant], Error>?
    init(_ products: [ProductVariant]) { self.products = products }
    func configure(failure: Bool = false, suspended: Bool = false) { self.failure = failure; self.suspended = suspended }
    func variants(market: Market) async throws -> [ProductVariant] {
        calls.append(market)
        if failure { throw ModelSyntheticError.expected }
        if suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
        return products
    }
    func variants(market: Market, product: CatalogProduct) async throws -> [ProductVariant] {
        requestedProducts.append(product)
        return try await variants(market: market)
    }
    func resolve() { let continuation = pending; pending = nil; continuation?.resume(returning: products) }
}

private actor ModelInventory: InventoryFetching {
    struct Call: Sendable { let market: Market; let location: String; let variants: [ProductVariant] }
    var snapshot: InventorySnapshot
    var failure = false
    var suspended = false
    var calls: [Call] = []
    var pending: CheckedContinuation<InventorySnapshot, Error>?
    init(_ snapshot: InventorySnapshot = InventorySnapshot(stores: [], availability: [])) { self.snapshot = snapshot }
    func configure(failure: Bool = false, suspended: Bool = false) { self.failure = failure; self.suspended = suspended }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        calls.append(Call(market: market, location: location, variants: variants))
        if failure { throw ModelSyntheticError.expected }
        if suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
        return snapshot
    }
    func resolve() { let continuation = pending; pending = nil; continuation?.resume(returning: snapshot) }
}

@MainActor private final class ModelCheckoutPage: AppleCheckoutPage {
    var current: CheckoutSnapshot
    var afterPlace: CheckoutSnapshot
    var places = 0
    var failRestore = false
    var loads: [URL] = []
    var advances = 0
    var recoveryMarkets: [Market] = []
    var recoveryError: (any Error)?
    var suspendRecovery = false
    var pendingRecovery: CheckedContinuation<Void, Error>?
    var currentSession = Data()
    init(current: CheckoutSnapshot, afterPlace: CheckoutSnapshot) { self.current = current; self.afterPlace = afterPlace }
    func load(_ url: URL) { loads.append(url) }
    func snapshot() -> CheckoutSnapshot { current }
    func advance(request: CheckoutRequest, profile: SecureProfile) -> Bool { advances += 1; return false }
    func placeOrder(expected: CheckoutSnapshot) -> Bool { places += 1; current = afterPlace; return true }
    func restoreSession(_ data: Data?) throws { if failRestore { throw ModelSyntheticError.expected } }
    func sessionData() -> Data { currentSession }
    func acknowledgeManualRecovery(market: Market) async throws {
        recoveryMarkets.append(market)
        if let recoveryError { throw recoveryError }
        guard let url = URL(string: current.sourceURL), CheckoutPagePolicy.isStorefront(url, market: market),
              [.product, .bag, .fulfillment, .contact, .payment, .review].contains(current.phase) else { throw CheckoutError.storefrontBlocked }
        if suspendRecovery { try await withCheckedThrowingContinuation { pendingRecovery = $0 } }
    }
    func resolveRecovery() { let continuation = pendingRecovery; pendingRecovery = nil; continuation?.resume(returning: ()) }
    func cancel() {}
    func clearPage() {}
}

private func modelProduct(_ id: String = "synthetic-a", market: Market = .ca) -> ProductVariant {
    ProductVariant(id: id, name: "Synthetic iPhone", storage: "256GB", color: "Night", productURL: market.productBaseURL.appendingPathComponent("synthetic-" + id))
}

private func modelStoreSnapshot() -> InventorySnapshot {
    let stores = [RetailStore(id: "FAR", name: "Farther", latitude: 44.0, longitude: -79.0),
                  RetailStore(id: "NEAR", name: "Nearby", latitude: 43.65, longitude: -79.38)]
    return InventorySnapshot(stores: stores, availability: stores.map {
        StoreAvailability(storeID: $0.id, variantID: "synthetic-a", state: .disabled, message: "Synthetic pickup disabled")
    })
}

@MainActor private final class ModelRehearsalDriver: CheckoutRehearsalPreparing {
    var requests: [CheckoutRequest] = []
    var profiles: [SecureProfile] = []
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        requests.append(request); profiles.append(profile)
        throw CheckoutError.manualInputRequired
    }
    func cancel() {}
}

@Suite(.serialized) @MainActor struct PilotModelTests {
    private func armingFixture(savedProfile: Bool = true) async throws -> (model: PilotModel, vault: ModelSecureVault, inventory: ModelInventory, catalog: ModelCatalog) {
        let vault = ModelSecureVault()
        if savedProfile { try await vault.saveProfile(modelSyntheticProfile()) }
        let inventory = ModelInventory(modelStoreSnapshot())
        let products = [modelProduct(), modelProduct("synthetic-b")]
        let catalog = ModelCatalog(products)
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), catalog: catalog, inventory: inventory,
                               locationService: ModelLocation(), travelService: ModelTravel())
        model.variants = products; model.stores = modelStoreSnapshot().stores
        model.preferences.selectedVariantIDs = ["synthetic-b", "synthetic-a"]
        model.preferences.selectedStoreIDs = ["NEAR", "FAR"]
        model.locationQuery = "Synthetic public location"
        model.hasSavedProfile = savedProfile; model.consentToOrder = true
        return (model, vault, inventory, catalog)
    }

    @Test func armingRequiresAnExplicitOrderedScopeReviewAndCancelRevokesItsCapability() async throws {
        let fixture = try await armingFixture(), model = fixture.model
        await model.arm()
        let review = try #require(model.pendingArmingReview)
        #expect(!model.coordinator.isArmed && model.setupLocked && review.profileSaved)
        #expect(review.plan.variants.map(\.id) == ["synthetic-b", "synthetic-a"])
        #expect(review.plan.stores.map(\.id) == ["NEAR", "FAR"])
        #expect(review.plan.configuration == model.preferences && review.plan.location == model.locationQuery)
        #expect(await fixture.vault.profileLoads == 0)
        #expect(await fixture.inventory.calls.isEmpty)
        let text = String(reflecting: review)
        #expect(!text.contains("4111111111111111") && !text.contains("synthetic@example.invalid") && !text.contains("Synthetic Tester"))
        model.toggleVariant("synthetic-a"); model.toggleStore("NEAR")
        model.selectCatalogProduct(.usbCHeadphoneAdapter)
        #expect(model.preferences == review.plan.configuration)
        model.cancelArmingReview()
        #expect(model.pendingArmingReview == nil && !model.setupLocked && !model.coordinator.isArmed)
        await model.confirmArmingReview(id: review.id)
        #expect(!model.coordinator.isArmed && model.error?.contains("Review") == true)
        model.requestArmingReview()
        let fresh = try #require(model.pendingArmingReview)
        #expect(fresh.id != review.id)
        await model.confirmArmingReview(id: fresh.id)
        #expect(model.coordinator.isArmed && model.pendingArmingReview == nil)
        #expect(model.coordinator.monitoringPlan == fresh.plan)
        model.cancelArmingReview() // Sheet dismissal after success must not disarm the approved run.
        #expect(model.coordinator.isArmed)
        await model.coordinator.stopAndWait()
    }

    @Test func incompleteOrStaleSetupProducesVisibleReviewErrorsWithoutArming() async throws {
        for kind in ["missingVariant", "missingStore", "noSelection", "foreignStore", "duplicateLoadedVariant", "blankLocation", "expiredAttempts", "noConsent", "noProfile"] {
            let fixture = try await armingFixture(), model = fixture.model
            switch kind {
            case "missingVariant": model.preferences.selectedVariantIDs.append("missing")
            case "missingStore": model.preferences.selectedStoreIDs.append("missing")
            case "noSelection": model.preferences.selectedVariantIDs = []
            case "foreignStore": model.stores[1].countryCode = "US"
            case "duplicateLoadedVariant": model.variants.append(model.variants[0])
            case "blankLocation": model.locationQuery = " \n "
            case "expiredAttempts": model.preferences.attemptWindow = DateWindow(start: Date().addingTimeInterval(-100), end: Date().addingTimeInterval(-1))
            case "noConsent": model.consentToOrder = false
            default: model.hasSavedProfile = false
            }
            model.requestArmingReview()
            #expect(model.pendingArmingReview == nil && !model.coordinator.isArmed && model.error?.isEmpty == false)
            #expect(await fixture.vault.profileLoads == 0)
            #expect(await fixture.inventory.calls.isEmpty)
        }
    }

    @Test func pendingDiscoveryMustFinishBeforeTheArmingReviewCanOpen() async throws {
        let fixture = try await armingFixture(), model = fixture.model
        await fixture.catalog.configure(suspended: true)
        let discovery = Task { await model.discover() }
        try await waitUntil { await fixture.catalog.pending != nil }
        model.requestArmingReview()
        #expect(model.pendingArmingReview == nil && model.error?.contains("loading") == true && !model.coordinator.isArmed)
        await fixture.catalog.resolve(); await discovery.value
        #expect(!model.busy)
        model.requestArmingReview()
        #expect(model.pendingArmingReview != nil && !model.coordinator.isArmed)
        model.cancelArmingReview()
    }

    @Test func missingStoredProfileCannotArmEvenWhenMetadataWasPreviouslySaved() async throws {
        let fixture = try await armingFixture(savedProfile: false), model = fixture.model
        model.hasSavedProfile = true
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        await model.confirmArmingReview(id: review.id)
        #expect(!model.coordinator.isArmed && model.pendingArmingReview == nil && model.error != nil)
        #expect(model.coordinator.monitoringPlan == nil)
        #expect(await fixture.inventory.calls.isEmpty)
    }

    @Test(arguments: ["budget", "productObject", "storeObject", "priority", "location", "consent"])
    func changedScopeRequiresAnotherReviewBeforeAnyStorageOrMonitoring(_ kind: String) async throws {
        let fixture = try await armingFixture(), model = fixture.model
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        switch kind {
        case "budget": model.preferences.maximumTotal += 1
        case "productObject": model.variants[1].name = "Changed product description"
        case "storeObject": model.stores[1].address = "Changed store address"
        case "priority": model.preferences.selectedVariantIDs.reverse()
        case "location": model.locationQuery = "Changed location"
        default: model.consentToOrder = false
        }
        await model.confirmArmingReview(id: review.id)
        #expect(!model.coordinator.isArmed && model.pendingArmingReview == nil && model.error?.contains("changed") == true)
        #expect(await fixture.vault.profileLoads == 0)
        #expect(await fixture.inventory.calls.isEmpty)
    }

    @Test(arguments: ["cancel", "budget", "consent"])
    func storageSuspensionCannotOutliveTheReviewedAuthorization(_ kind: String) async throws {
        let fixture = try await armingFixture(), model = fixture.model
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        await fixture.vault.suspendLoad()
        let confirmation = Task { await model.confirmArmingReview(id: review.id) }
        try await waitUntil { await fixture.vault.pendingProfileLoad != nil }
        #expect(model.armingAutomaticCheckout && !model.coordinator.isArmed)
        if kind == "cancel" { model.cancelArmingReview() }
        else if kind == "budget" { model.preferences.maximumTotal += 1 }
        else { model.consentToOrder = false }
        await fixture.vault.resolveLoad(); await confirmation.value
        #expect(!model.coordinator.isArmed && !model.armingAutomaticCheckout && model.pendingArmingReview == nil)
        #expect(model.coordinator.monitoringPlan == nil && model.coordinator.checkCount == 0)
        #expect(await fixture.inventory.calls.isEmpty)
        if kind != "cancel" { #expect(model.error?.contains("changed") == true) }
    }

    @Test func duplicateConfirmationAndConsumedReviewCannotArmTwice() async throws {
        let fixture = try await armingFixture(), model = fixture.model
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        await fixture.vault.suspendLoad()
        let confirmation = Task { await model.confirmArmingReview(id: review.id) }
        try await waitUntil { await fixture.vault.pendingProfileLoad != nil }
        await model.confirmArmingReview(id: review.id)
        #expect(await fixture.vault.profileLoads == 1)
        await fixture.vault.resolveLoad(); await confirmation.value
        #expect(model.coordinator.isArmed && model.coordinator.monitoringPlan == review.plan)
        let loads = await fixture.vault.profileLoads
        await model.confirmArmingReview(id: review.id)
        #expect(await fixture.vault.profileLoads == loads)
        #expect(model.coordinator.isArmed && model.coordinator.monitoringPlan == review.plan)
        await model.coordinator.stopAndWait()
    }

    @Test func changingCatalogClearsPhoneSelectionBudgetAndConsentWithoutTouchingTheProfile() {
        let store = ModelPreferencesStore()
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: store, locationService: ModelLocation(), travelService: ModelTravel())
        model.variants = [modelProduct()]; model.stores = modelStoreSnapshot().stores
        model.preferences.selectedVariantIDs = ["synthetic-a"]; model.preferences.selectedStoreIDs = ["NEAR"]
        model.preferences.maximumTotal = 4000; model.consentToOrder = true
        model.profile = modelSyntheticProfile()
        model.selectCatalogProduct(.usbCHeadphoneAdapter)
        #expect(model.preferences.catalogProduct == .usbCHeadphoneAdapter)
        #expect(model.preferences.selectedVariantIDs.isEmpty && model.variants.isEmpty && model.availability.isEmpty)
        #expect(model.preferences.maximumTotal == 0 && !model.consentToOrder && !model.coordinator.isArmed)
        #expect(model.preferences.selectedStoreIDs == ["NEAR"] && model.profile == modelSyntheticProfile())
        #expect(store.state.withLock { $0.preferences.catalogProduct } == .usbCHeadphoneAdapter)
        model.preferences.market = .uk; model.changedMarket()
        #expect(model.preferences.catalogProduct == .iPhoneDuo && model.preferences.selectedStoreIDs.isEmpty)
        model.selectCatalogProduct(.usbCHeadphoneAdapter)
        #expect(model.preferences.catalogProduct == .iPhoneDuo)
    }

    @Test func adapterDiscoveryAndReviewTestUseOnlyTheSelectedAccessory() async throws {
        let adapter = ProductVariant(id: CatalogProduct.adapterSKU, name: "USB-C to 3.5mm Headphone Jack Adapter · CA$10.00", storage: "", color: "", productURL: CatalogProduct.adapterURL)
        let catalog = ModelCatalog([adapter]); let inventory = ModelInventory(modelStoreSnapshot())
        let driver = ModelRehearsalDriver(); let rehearsal = CheckoutRehearsal(driver: driver, webView: WKWebView())
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: catalog, inventory: inventory, locationService: ModelLocation(), travelService: ModelTravel(), rehearsal: rehearsal)
        model.selectCatalogProduct(.usbCHeadphoneAdapter); model.locationQuery = "Toronto"
        await model.discover()
        #expect(await catalog.requestedProducts == [.usbCHeadphoneAdapter])
        #expect(model.variants == [adapter])
        #expect(await inventory.calls.first?.variants == [adapter])
        model.toggleVariant(adapter.id); model.toggleStore("NEAR"); model.preferences.maximumTotal = 12
        await model.testCheckout()
        #expect(driver.requests.count == 1 && driver.requests.first?.variant == adapter)
        #expect(rehearsal.state == .manualInputRequired && !model.coordinator.isArmed)
        model.selectCatalogProduct(.iPhoneDuo)
        #expect(model.preferences.catalogProduct == .usbCHeadphoneAdapter, "An active checkout test keeps its original product selected.")
        let original = model.preferences
        model.selectMarket(.uk); model.enterLocationQuery("London"); model.toggleVariant(adapter.id); model.toggleStore("NEAR")
        await model.discover()
        #expect(model.preferences == original && model.locationQuery == "Toronto")
        #expect(await catalog.requestedProducts == [.usbCHeadphoneAdapter])
        model.cancelCheckoutTest()
    }

    @Test func changingProductDiscardsAnInFlightPhoneCatalogResponse() async throws {
        let catalog = ModelCatalog([modelProduct()]); await catalog.configure(suspended: true)
        let inventory = ModelInventory(modelStoreSnapshot())
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: catalog, inventory: inventory, locationService: ModelLocation(), travelService: ModelTravel())
        model.locationQuery = "Toronto"
        let discovery = Task { await model.discover() }
        try await waitUntil { await catalog.pending != nil }
        model.selectCatalogProduct(.usbCHeadphoneAdapter)
        await catalog.resolve(); await discovery.value
        #expect(model.preferences.catalogProduct == .usbCHeadphoneAdapter && model.variants.isEmpty && !model.busy)
        #expect(await inventory.calls.isEmpty)
    }

    @Test func pendingAutomaticArmingPreventsReviewTestUntilStorageValidationFinishes() async throws {
        let vault = ModelSecureVault()
        try await vault.saveProfile(modelSyntheticProfile())
        try await vault.saveSession(Data([7]))
        let driver = ModelRehearsalDriver()
        let rehearsal = CheckoutRehearsal(driver: driver, webView: WKWebView())
        let catalog = ModelCatalog([modelProduct("different-catalog-product")])
        let inventory = ModelInventory(modelStoreSnapshot())
        let location = ModelLocation()
        let healthy = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/bag", phase: .bag, bagIsEmpty: true)
        let page = ModelCheckoutPage(current: healthy, afterPlace: healthy)
        let checkout = AppleCheckoutDriver(vault: vault, page: page)
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), catalog: catalog, inventory: inventory,
                               locationService: location, travelService: ModelTravel(), checkout: checkout, rehearsal: rehearsal)
        model.variants = [modelProduct()]; model.stores = modelStoreSnapshot().stores
        model.preferences.selectedVariantIDs = ["synthetic-a"]; model.preferences.selectedStoreIDs = ["NEAR"]
        model.locationQuery = "Synthetic arming location"; model.consentToOrder = true
        model.hasSavedProfile = true
        let configuration = model.preferences
        let description = model.locationDescription
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        await vault.suspendLoad()
        let arming = Task { await model.confirmArmingReview(id: review.id) }
        try await waitUntil { await vault.pendingProfileLoad != nil }
        #expect(model.armingAutomaticCheckout && !model.coordinator.isArmed)
        await model.testCheckout()
        await model.arm()
        await model.discover(); await model.detectLocation()
        model.toggleStore("FAR"); model.toggleVariant("different-catalog-product")
        model.changedMarket(); model.changedLocationManually()
        await model.openProfile(); await model.saveProfile(); await model.deleteProfile(); await model.clearSession()
        await model.saveResolvedAppleSession()
        #expect(driver.requests.isEmpty && !model.startingCheckoutTest && !rehearsal.isActive)
        #expect(model.preferences == configuration && model.consentToOrder)
        #expect(model.variants == [modelProduct()] && model.stores == modelStoreSnapshot().stores)
        #expect(model.locationDescription == description && model.locationQuery == "Synthetic arming location")
        #expect(location.calls == 0 && !model.profileOpen && model.profile.isEmpty)
        #expect(await catalog.calls.isEmpty)
        #expect(await inventory.calls.isEmpty)
        #expect(await vault.profile == modelSyntheticProfile())
        #expect(await vault.session == Data([7]))
        #expect(page.recoveryMarkets.isEmpty)
        await vault.resolveLoad(); await arming.value
        #expect(!model.armingAutomaticCheckout && model.coordinator.isArmed)
        await model.discover(); await model.detectLocation()
        model.toggleStore("FAR"); model.toggleVariant("different-catalog-product")
        model.changedMarket(); model.changedLocationManually()
        await model.openProfile(); await model.saveProfile(); await model.deleteProfile(); await model.clearSession()
        await model.saveResolvedAppleSession()
        #expect(model.preferences == configuration && model.consentToOrder && location.calls == 0)
        #expect(await vault.profile == modelSyntheticProfile())
        #expect(await vault.session == Data([7]))
        #expect(page.recoveryMarkets.isEmpty)
        await model.coordinator.stopAndWait()
    }

    @Test func resolvedSessionSavesCurrentCookiesWithoutPreparingOrderingOrChangingLimits() async throws {
        let vault = ModelSecureVault()
        try await vault.saveProfile(modelSyntheticProfile())
        try await vault.saveSession(Data("previous-session".utf8))
        let preferences = ModelPreferencesStore()
        let healthy = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/bag", phase: .bag, bagIsEmpty: true)
        let page = ModelCheckoutPage(current: healthy, afterPlace: healthy)
        page.currentSession = Data("synthetic-current-browser-cookies".utf8)
        let checkout = AppleCheckoutDriver(vault: vault, page: page)
        let model = PilotModel(vault: vault, preferencesStore: preferences, travelService: ModelTravel(), checkout: checkout)
        model.consentToOrder = true
        let limits = model.preferences
        #expect(model.canSaveResolvedAppleSession)
        await model.saveResolvedAppleSession()
        #expect(await vault.session == page.currentSession)
        #expect(await vault.profile == modelSyntheticProfile())
        #expect(await vault.orderState == nil)
        #expect(page.recoveryMarkets == [.ca] && page.loads.isEmpty && page.advances == 0 && page.places == 0)
        #expect(model.preferences == limits && model.consentToOrder && preferences.state.withLock { $0.saves } == 0)
        #expect(!model.coordinator.isArmed && model.coordinator.journal.phase == .idle && !checkout.requiresPaymentConfirmation)
        #expect(model.error == nil && model.message.contains("session saved") && model.message.contains("Review your limits"))
        #expect(model.appleSessionRecoveryDetail == model.message && model.message.contains("Saving never arms"))
    }

    @Test func returningToBagIsExplicitAndCannotLoadProfileAddItemsOrArm() async throws {
        let vault = ModelSecureVault()
        let previous = Data("synthetic-previous-session".utf8)
        try await vault.saveSession(previous)
        let missing = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/404", phase: .pageNotFound)
        let page = ModelCheckoutPage(current: missing, afterPlace: missing)
        let checkout = AppleCheckoutDriver(vault: vault, page: page)
        let preferences = ModelPreferencesStore()
        let model = PilotModel(vault: vault, preferencesStore: preferences, travelService: ModelTravel(), checkout: checkout)
        let limits = model.preferences
        await model.returnToAppleBag()
        #expect(page.loads.map(\.absoluteString) == ["https://www.apple.com/ca/shop/bag"])
        #expect(page.advances == 0 && page.places == 0 && page.recoveryMarkets.isEmpty)
        #expect(await vault.profileLoads == 0)
        #expect(await vault.session == previous)
        #expect(model.preferences == limits && preferences.state.withLock { $0.saves } == 0)
        #expect(!model.coordinator.isArmed && model.coordinator.journal.phase == .idle && model.pendingArmingReview == nil)
        #expect(model.error == nil && model.appleSessionRecoveryDetail.contains("does not arm"))
    }

    @Test func unavailablePageCannotSaveSessionAndDoesNotInventABlock() async throws {
        let vault = ModelSecureVault(); let previous = Data("synthetic-previous-session".utf8)
        try await vault.saveSession(previous)
        let missing = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/404", phase: .pageNotFound)
        let page = ModelCheckoutPage(current: missing, afterPlace: missing)
        page.recoveryError = CheckoutError.sessionRecoveryNotReady
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel(), checkout: AppleCheckoutDriver(vault: vault, page: page))
        await model.saveResolvedAppleSession()
        #expect(model.error?.contains("verified checkout page") == true && model.error?.contains("blocked") == false)
        #expect(model.appleSessionRecoveryDetail == model.error)
        #expect(await vault.session == previous)
        #expect(await vault.profileLoads == 0)
        #expect(page.loads.isEmpty && page.advances == 0 && page.places == 0 && !model.coordinator.isArmed)
    }

    @Test(arguments: [false, true])
    func resolvedSessionFailuresAreSanitizedAndPreservePreviousCookies(storageFailure: Bool) async throws {
        let vault = ModelSecureVault()
        let previous = Data("previous-session".utf8)
        try await vault.saveSession(previous)
        let healthy = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/bag", phase: .bag, bagIsEmpty: true)
        let page = ModelCheckoutPage(current: healthy, afterPlace: healthy)
        page.currentSession = Data("uncommitted-current-cookies".utf8)
        if storageFailure { await vault.fail("saveSession") }
        else { page.recoveryError = ModelSyntheticError.expected }
        let checkout = AppleCheckoutDriver(vault: vault, page: page)
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel(), checkout: checkout)
        await model.saveResolvedAppleSession()
        #expect(model.error?.contains("could not be verified") == true)
        #expect(model.error?.contains("Synthetic storage failure") == false)
        #expect(model.error?.contains("uncommitted-current-cookies") == false)
        #expect(model.appleSessionRecoveryDetail == model.error)
        #expect(await vault.session == previous)
        #expect(await vault.orderState == nil)
        #expect(page.loads.isEmpty && page.advances == 0 && page.places == 0 && !model.coordinator.isArmed)
    }

    @Test func resolvedSessionGatesOverlapAndRehearsalAndRemainsExplicitlyDisarmed() async throws {
        let vault = ModelSecureVault()
        let healthy = CheckoutSnapshot(sourceURL: "https://www.apple.com/ca/shop/bag", phase: .bag, bagIsEmpty: true)
        let page = ModelCheckoutPage(current: healthy, afterPlace: healthy)
        page.suspendRecovery = true; page.currentSession = Data("synthetic-current-cookies".utf8)
        let checkout = AppleCheckoutDriver(vault: vault, page: page)
        let rehearsalDriver = ModelRehearsalDriver()
        let rehearsal = CheckoutRehearsal(driver: rehearsalDriver, webView: WKWebView())
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel(), checkout: checkout, rehearsal: rehearsal)
        model.consentToOrder = true
        let recovery = Task { await model.saveResolvedAppleSession() }
        try await waitUntil { page.pendingRecovery != nil }
        #expect(!model.canSaveResolvedAppleSession)
        await model.saveResolvedAppleSession(); await model.arm(); await model.testCheckout()
        await model.openProfile(); await model.saveProfile(); await model.deleteProfile(); await model.clearSession()
        #expect(page.recoveryMarkets == [.ca] && !model.coordinator.isArmed && rehearsalDriver.requests.isEmpty)
        page.resolveRecovery(); await recovery.value
        #expect(model.error == nil && model.canSaveResolvedAppleSession)
        #expect(page.loads.isEmpty && page.advances == 0 && page.places == 0)
        #expect(await vault.orderState == nil)
        let request = CheckoutRequest(variant: modelProduct(), store: modelStoreSnapshot().stores[0], market: .ca, maximumTotal: 4000)
        await rehearsal.start(request: request, profile: modelSyntheticProfile())
        #expect(rehearsal.isActive && !model.canSaveResolvedAppleSession)
        await model.saveResolvedAppleSession()
        #expect(page.recoveryMarkets == [.ca])
        model.cancelCheckoutTest()
    }

    @Test func pendingProfileActionPreventsArmingUntilItsReadFinishes() async throws {
        let vault = ModelSecureVault()
        try await vault.saveProfile(modelSyntheticProfile())
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel())
        model.consentToOrder = true
        await vault.suspendLoad()
        let edit = Task { await model.openProfile() }
        try await waitUntil { await vault.pendingProfileLoad != nil }
        await model.arm()
        #expect(!model.coordinator.isArmed && !model.armingAutomaticCheckout)
        #expect(model.error?.contains("Wait for checkout details") == true)
        await vault.resolveLoad(); await edit.value
        #expect(model.profileOpen && model.profile == modelSyntheticProfile())
        model.closeProfile()
        #expect(!model.profileOpen && model.profile.isEmpty)
    }

    @Test func reviewOnlyTestUsesFirstSelectedConfigurationAndCannotArmWhileActive() async throws {
        let vault = ModelSecureVault()
        try await vault.saveProfile(modelSyntheticProfile())
        let driver = ModelRehearsalDriver()
        let rehearsal = CheckoutRehearsal(driver: driver, webView: WKWebView())
        let preferences = ModelPreferencesStore()
        let model = PilotModel(vault: vault, preferencesStore: preferences, travelService: ModelTravel(), rehearsal: rehearsal)
        model.variants = [modelProduct(), modelProduct("synthetic-b")]
        model.stores = modelStoreSnapshot().stores
        model.preferences.selectedVariantIDs = ["synthetic-b", "synthetic-a"]
        model.preferences.selectedStoreIDs = ["NEAR", "FAR"]
        model.locationQuery = "Synthetic review-only location"
        await model.testCheckout()
        #expect(driver.requests.count == 1 && driver.requests[0].variant.id == "synthetic-b" && driver.requests[0].store.id == "NEAR")
        #expect(driver.profiles.first?.searchLocation == model.locationQuery)
        #expect(rehearsal.state == .manualInputRequired && !model.startingCheckoutTest)
        #expect(!model.coordinator.isArmed && !model.coordinator.journal.blocksPurchase && model.profile.isEmpty)
        #expect(preferences.state.withLock { $0.saves } == 0)
        model.consentToOrder = true
        await model.arm()
        #expect(model.error?.contains("Close the checkout test") == true && !model.coordinator.isArmed)
        model.cancelCheckoutTest()
        #expect(!rehearsal.isActive)
        #expect(try await vault.loadProfile() == modelSyntheticProfile())
        #expect(await vault.orderState == nil)
    }

    @Test func reviewOnlyTestRejectsIncompleteSetupAndPreviewWithoutStartingABrowserFlow() async {
        let driver = ModelRehearsalDriver()
        let rehearsal = CheckoutRehearsal(driver: driver, webView: WKWebView())
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), travelService: ModelTravel(), rehearsal: rehearsal)
        await model.testCheckout()
        #expect(model.error?.contains("Choose a local store") == true && driver.requests.isEmpty)
        let preview = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), smoke: true, travelService: ModelTravel(), rehearsal: rehearsal)
        await preview.testCheckout()
        #expect(preview.error?.contains("Preview mode") == true && driver.requests.isEmpty)
    }

    @Test func cancelDuringReviewProfileLoadNeverStartsCheckoutAndVaultFailureRemainsRecoverable() async throws {
        let vault = ModelSecureVault()
        try await vault.saveProfile(modelSyntheticProfile())
        let driver = ModelRehearsalDriver()
        let rehearsal = CheckoutRehearsal(driver: driver, webView: WKWebView())
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel(), rehearsal: rehearsal)
        model.variants = [modelProduct()]; model.stores = modelStoreSnapshot().stores
        model.preferences.selectedVariantIDs = ["synthetic-a"]; model.preferences.selectedStoreIDs = ["NEAR"]
        model.locationQuery = "Synthetic review-only location"
        await vault.suspendLoad()
        let start = Task { await model.testCheckout() }
        try await waitUntil { await vault.pendingProfileLoad != nil }
        #expect(model.startingCheckoutTest)
        await model.testCheckout()
        model.cancelCheckoutTest()
        await vault.resolveLoad(); await start.value
        #expect(!model.startingCheckoutTest && driver.requests.isEmpty && !rehearsal.isActive)
        await vault.fail("loadProfile")
        await model.testCheckout()
        #expect(model.error?.contains("could not be read") == true && driver.requests.isEmpty)
        #expect(!model.coordinator.isArmed && !model.startingCheckoutTest)
    }
    @Test func togglesPreservePreferenceSelectionOrderAndRevokeConsent() {
        let store = ModelPreferencesStore()
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: store, travelService: ModelTravel())
        model.consentToOrder = true
        model.toggleVariant("synthetic-a")
        #expect(!model.consentToOrder)
        model.toggleVariant("synthetic-b")
        #expect(model.preferences.selectedVariantIDs == ["synthetic-a", "synthetic-b"])
        #expect(model.variantCount == 2)
        model.toggleVariant("synthetic-a")
        #expect(model.preferences.selectedVariantIDs == ["synthetic-b"])
        model.consentToOrder = true
        model.toggleStore("R121")
        #expect(!model.consentToOrder)
        model.toggleStore("R120")
        #expect(model.preferences.selectedStoreIDs == ["R121", "R120"])
        #expect(model.storeCount == 2)
        model.toggleStore("R121")
        #expect(model.preferences.selectedStoreIDs == ["R120"])
        #expect(store.state.withLock { $0.saves } == 6)
        let recreated = PilotModel(vault: ModelSecureVault(), preferencesStore: store, travelService: ModelTravel())
        #expect(recreated.preferences.selectedStoreIDs == ["R120"])
        #expect(recreated.preferences.selectedVariantIDs == ["synthetic-b"])
    }

    @Test func defaultPreferencesFactoryPersistsLocallyAndLocaleNeverClaimsPhysicalDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PickupPilotModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preferences.json")
        let first = PilotModel(vault: ModelSecureVault(), locationService: ModelLocation(), travelService: ModelTravel(), preferencesURL: url, locale: Locale(identifier: "en_US"))
        #expect(first.preferences.market == .us)
        #expect(first.locationDescription.contains("preference until"))
        first.preferences.selectedStoreIDs = ["SYNTHETIC"]
        first.savePreferences()
        let recreated = PilotModel(vault: ModelSecureVault(), locationService: ModelLocation(), travelService: ModelTravel(), preferencesURL: url, locale: Locale(identifier: "en_GB"))
        #expect(recreated.preferences.market == .us)
        #expect(recreated.preferences.selectedStoreIDs == ["SYNTHETIC"])
        for identifier in ["en", "xx_XX"] {
            let missing = directory.appendingPathComponent(identifier + ".json")
            let manual = PilotModel(vault: ModelSecureVault(), locationService: ModelLocation(), travelService: ModelTravel(), preferencesURL: missing, locale: Locale(identifier: identifier))
            #expect(manual.preferences.market == .ca)
            #expect(manual.locationQuery.isEmpty)
        }
    }

    @Test func marketChangesInvalidateRegionalSelectionBudgetAndConsent() {
        let store = ModelPreferencesStore()
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: store, travelService: ModelTravel())
        model.variants = [ProductVariant(id: "synthetic", name: "Synthetic", storage: "256GB", color: "Night", productURL: Market.ca.productBaseURL)]
        model.stores = [RetailStore(id: "R121", name: "Synthetic")]
        model.availability = [StoreAvailability(storeID: "R121", variantID: "synthetic", state: .disabled, message: "Synthetic")]
        model.preferences.selectedStoreIDs = ["R121"]
        model.preferences.selectedVariantIDs = ["synthetic"]
        model.consentToOrder = true
        model.preferences.market = .uk
        model.changedMarket()
        #expect(model.preferences.selectedStoreIDs.isEmpty)
        #expect(model.preferences.selectedVariantIDs.isEmpty)
        #expect(model.variants.isEmpty && model.stores.isEmpty && model.availability.isEmpty)
        #expect(model.preferences.maximumTotal == 0)
        #expect(!model.consentToOrder)
        #expect(model.locationDescription.contains("Manual shopping country"))
        #expect(store.state.withLock { $0.preferences.market } == .uk)
        model.changedLocationManually()
        #expect(model.locationDescription.contains("Manual location"))
        #expect(model.distance(to: RetailStore(id: "R", name: "Synthetic")) == nil)
    }

    @Test func profileEditingSavesOnlyToVaultAndClearsTransientCopies() async throws {
        let vault = ModelSecureVault()
        let preferences = ModelPreferencesStore()
        let model = PilotModel(vault: vault, preferencesStore: preferences, travelService: ModelTravel())
        await model.openProfile()
        #expect(model.profileOpen && model.profile.isEmpty)
        model.profile = modelSyntheticProfile()
        model.locationQuery = "Synthetic postal location"
        await model.saveProfile()
        #expect(model.hasSavedProfile && !model.profileOpen && model.profile.isEmpty)
        var expected = modelSyntheticProfile()
        expected.searchLocation = model.locationQuery
        #expect(try await vault.loadProfile() == expected)
        #expect(preferences.state.withLock { $0.saves } == 0)
        let ordinaryData = try JSONEncoder().encode(preferences.state.withLock { $0.preferences })
        let ordinaryText = String(decoding: ordinaryData, as: UTF8.self)
        for value in [expected.cardNumber, expected.cvv, expected.billingLine1, expected.email, expected.searchLocation] {
            #expect(!ordinaryText.contains(value))
        }
        await model.openProfile()
        #expect(model.profileOpen && model.profile == expected)
        model.profile.cvv = "456"
        model.closeProfile()
        #expect(!model.profileOpen && model.profile.isEmpty)
        #expect(try await vault.loadProfile() == expected)
        model.consentToOrder = true
        await model.deleteProfile()
        #expect(!model.hasSavedProfile && model.profile.isEmpty && !model.consentToOrder)
        #expect(try await vault.loadProfile() == nil)
    }

    @Test func profileErrorsRemainRecoverableAndDoNotClaimSuccess() async {
        let vault = ModelSecureVault()
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel())
        await vault.fail("loadProfile")
        await model.openProfile()
        #expect(!model.profileOpen && model.error == "Synthetic storage failure")
        await vault.fail(nil)
        await model.openProfile()
        model.profile = modelSyntheticProfile()
        await vault.fail("saveProfile")
        await model.saveProfile()
        #expect(!model.hasSavedProfile && model.profileOpen && !model.profile.isEmpty)
        await vault.fail(nil)
        await model.saveProfile()
        #expect(model.hasSavedProfile && model.profile.isEmpty)
        await vault.fail("deleteProfile")
        await model.deleteProfile()
        #expect(model.hasSavedProfile)
        #expect(model.error == "Synthetic storage failure")
    }

    @Test func savedSessionCanBeDeletedWithoutDeletingProfileOrOrderJournal() async throws {
        let vault = ModelSecureVault()
        try await vault.saveProfile(modelSyntheticProfile())
        try await vault.saveSession(Data("synthetic-session".utf8))
        try await vault.saveOrderState(Data("synthetic-journal".utf8))
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel())
        await model.clearSession()
        #expect(await vault.loadSession() == nil)
        #expect(try await vault.loadProfile() == modelSyntheticProfile())
        #expect(try await vault.loadOrderState() == Data("synthetic-journal".utf8))
        #expect(model.message.contains("Safari checkout window was reset"))
        #expect(model.checkout.browserKind == .safari && !model.checkout.hasEmbeddedBrowser)
        await vault.fail("deleteSession")
        await model.clearSession()
        #expect(model.error == "Synthetic storage failure")
    }

    @Test func preferenceFailuresAreVisibleAndPreviewCannotArmOrPersist() async {
        let preferences = ModelPreferencesStore()
        preferences.state.withLock { $0.failLoad = true; $0.failSave = true }
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: preferences, travelService: ModelTravel())
        model.savePreferences()
        #expect(model.error?.contains("Preferences could not be saved") == true)
        await model.arm()
        #expect(model.error == "Confirm the one-order authorization before arming.")
        model.consentToOrder = true
        await model.arm()
        #expect(!model.coordinator.isArmed && model.error != nil)
        let previewStore = ModelPreferencesStore()
        let preview = PilotModel(vault: ModelSecureVault(), preferencesStore: previewStore, smoke: true, travelService: ModelTravel())
        #expect(preview.variantCount == 1 && preview.storeCount == 2)
        #expect(preview.variants.count == 2 && preview.stores.count == 3)
        preview.savePreferences()
        preview.consentToOrder = true
        await preview.arm()
        #expect(preview.error == "Preview mode cannot place orders.")
        #expect(!preview.coordinator.isArmed)
        #expect(previewStore.state.withLock { $0.saves } == 0)
        await preview.startup()
        await preview.startup()
        await preview.resetLock()
        #expect(!preview.consentToOrder)
    }

    @Test func appPagesHaveStableIdentifiersAndSymbols() {
        for page in AppPage.allCases {
            #expect(page.id == page.rawValue)
            #expect(!page.icon.isEmpty)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ModelSyntheticError.expected
    }

    @Test func startupRestoresSavedPresenceAndManualFallbackOnceWithoutRetainingCardFields() async throws {
        let vault = ModelSecureVault()
        var profile = modelSyntheticProfile(); profile.searchLocation = "Synthetic saved location"
        try await vault.saveProfile(profile)
        let location = ModelLocation()
        let catalog = ModelCatalog([modelProduct()])
        let inventory = ModelInventory(modelStoreSnapshot())
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), catalog: catalog,
                               inventory: inventory, locationService: location, travelService: ModelTravel())
        await model.startup()
        await model.startup()
        #expect(location.calls == 1)
        #expect(model.hasSavedProfile && model.profile.isEmpty && !model.profileOpen)
        #expect(model.locationQuery == "Synthetic saved location")
        #expect(model.locationDescription == location.status)
        #expect(await inventory.calls.count == 1)
        #expect(model.stores.map(\.id) == ["FAR", "NEAR"])
        #expect(!model.busy && !model.coordinator.isArmed)
        let emptyVault = ModelSecureVault(); await emptyVault.fail("loadProfile")
        let noLocation = ModelLocation()
        let noProducts = ModelCatalog([])
        let failed = PilotModel(vault: emptyVault, preferencesStore: ModelPreferencesStore(), catalog: noProducts,
                                inventory: ModelInventory(), locationService: noLocation, travelService: ModelTravel())
        await failed.startup()
        #expect(!failed.hasSavedProfile && failed.error != nil)
        #expect(await noProducts.calls.isEmpty)
        let noProfile = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: noProducts,
                                   inventory: ModelInventory(), locationService: ModelLocation(), travelService: ModelTravel())
        await noProfile.startup()
        #expect(!noProfile.hasSavedProfile)
    }

    @Test func physicalCountryChangeClearsRegionalChoicesAndRanksStoresByActualCoordinates() async {
        let location = ModelLocation()
        location.result = .success(DetectedLocation(countryCode: "US", query: "Synthetic US location", latitude: 43.65, longitude: -79.38))
        let catalog = ModelCatalog([modelProduct(market: .us)])
        let inventory = ModelInventory(modelStoreSnapshot())
        let preferences = ModelPreferencesStore()
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: preferences, catalog: catalog,
                               inventory: inventory, locationService: location, travelService: ModelTravel())
        model.preferences.market = .ca
        model.preferences.selectedStoreIDs = ["OLD-CA"]
        model.preferences.selectedVariantIDs = ["OLD-CA/A"]
        model.consentToOrder = true
        await model.detectLocation()
        #expect(model.preferences.market == .us && model.preferences.maximumTotal == 0)
        #expect(model.preferences.selectedStoreIDs.isEmpty && model.preferences.selectedVariantIDs.isEmpty)
        #expect(!model.consentToOrder)
        #expect(model.locationDescription.contains("Physical location detected"))
        #expect(model.stores.map(\.id) == ["NEAR", "FAR"])
        #expect(model.distance(to: model.stores[0]) == "0.0 km")
        #expect(model.travelTime(to: model.stores[0]) == "~15 min drive")
        #expect(model.distance(to: RetailStore(id: "NOCOORD", name: "No coordinates")) == nil)
        #expect(await inventory.calls.first?.market == .us)
        #expect(await inventory.calls.first?.location == "Synthetic US location")
        #expect(preferences.state.withLock { $0.preferences.market } == .us)
        model.changedLocationManually()
        #expect(model.distance(to: model.stores[0]) == nil)
    }

    @Test func sameCountryPreservesBudgetAndPrunesStaleCatalogAndStoreIDs() async {
        let location = ModelLocation()
        location.result = .success(DetectedLocation(countryCode: "CA", query: "Synthetic location", latitude: 43.65, longitude: -79.38))
        let products = [modelProduct(), modelProduct("synthetic-b")]
        let inventory = ModelInventory(modelStoreSnapshot())
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: ModelCatalog(products),
                               inventory: inventory, locationService: location, travelService: ModelTravel())
        model.preferences.market = .ca
        model.preferences.maximumTotal = 3210
        model.preferences.selectedVariantIDs = ["synthetic-b", "obsolete", "synthetic-a"]
        model.preferences.selectedStoreIDs = ["NEAR", "OLD"]
        await model.detectLocation()
        #expect(model.preferences.maximumTotal == 3210)
        #expect(model.preferences.selectedVariantIDs == ["synthetic-b", "synthetic-a"])
        #expect(model.preferences.selectedStoreIDs == ["NEAR"])
        #expect(await inventory.calls.first?.variants.map(\.id) == ["synthetic-a", "synthetic-b"])
        let unsupported = ModelLocation()
        unsupported.result = .success(DetectedLocation(countryCode: "AQ", query: "Synthetic", latitude: -80, longitude: 0))
        let unused = ModelCatalog([])
        let manual = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: unused,
                                inventory: ModelInventory(), locationService: unsupported, travelService: ModelTravel())
        let country = manual.preferences.market
        await manual.detectLocation()
        #expect(manual.preferences.market == country && manual.locationDescription.contains("not have a supported"))
        #expect(await unused.calls.isEmpty)
    }

    @Test func catalogOnlyAndFailureDiscoveryPathsFinishBusyStateHonestly() async {
        let catalog = ModelCatalog([modelProduct()])
        let inventory = ModelInventory()
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: catalog,
                               inventory: inventory, locationService: ModelLocation(), travelService: ModelTravel())
        model.locationQuery = " \n"
        await model.discover()
        #expect(model.variants.count == 1 && model.message.contains("Regional catalog loaded"))
        #expect(await inventory.calls.isEmpty)
        #expect(!model.busy)
        await catalog.configure(failure: true)
        await model.discover()
        #expect(model.error == "Synthetic storage failure" && model.message.contains("could not be verified"))
        #expect(!model.busy)
        await catalog.configure()
        await inventory.configure(failure: true)
        model.locationQuery = "Synthetic location"
        await model.discover()
        #expect(model.error == "Synthetic storage failure" && !model.busy)
    }

    @Test func inFlightCountryAndQueryChangesDiscardStaleDiscoveryResponses() async throws {
        let catalog = ModelCatalog([modelProduct()]); await catalog.configure(suspended: true)
        let inventory = ModelInventory(modelStoreSnapshot())
        let model = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: catalog,
                               inventory: inventory, locationService: ModelLocation(), travelService: ModelTravel())
        model.locationQuery = "Original"
        let first = Task { await model.discover() }
        try await waitUntil { await catalog.pending != nil }
        await model.discover()
        #expect(await catalog.calls.count == 1)
        model.preferences.market = .us
        model.changedMarket()
        await catalog.resolve()
        await first.value
        #expect(model.variants.isEmpty && model.stores.isEmpty && !model.busy)
        let nextCatalog = ModelCatalog([modelProduct()])
        let nextInventory = ModelInventory(modelStoreSnapshot()); await nextInventory.configure(suspended: true)
        let next = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: nextCatalog,
                              inventory: nextInventory, locationService: ModelLocation(), travelService: ModelTravel())
        next.locationQuery = "Original"
        let second = Task { await next.discover() }
        try await waitUntil { await nextInventory.pending != nil }
        next.locationQuery = "Changed"
        next.changedLocationManually()
        await nextInventory.resolve()
        await second.value
        #expect(next.stores.isEmpty && next.availability.isEmpty && !next.busy)
    }

    @Test func manualCountryAndLocationOverridesWinOverDelayedPhysicalLocation() async throws {
        for success in [true, false] {
            let location = ModelLocation(); location.suspended = true
            if success { location.result = .success(DetectedLocation(countryCode: "US", query: "Old automatic fix", latitude: 43.65, longitude: -79.38)) }
            let catalog = ModelCatalog([modelProduct()])
            let model = PilotModel(vault: ModelSecureVault(), preferencesStore: ModelPreferencesStore(), catalog: catalog,
                                   inventory: ModelInventory(), locationService: location, travelService: ModelTravel())
            let detection = Task { await model.detectLocation() }
            try await waitUntil { location.pending != nil }
            await model.detectLocation()
            #expect(location.calls == 1)
            model.preferences.market = .uk
            model.changedMarket()
            model.locationQuery = "Manual UK location"
            model.changedLocationManually()
            location.resolve()
            await detection.value
            #expect(model.preferences.market == .uk && model.locationQuery == "Manual UK location")
            #expect(model.locationDescription.contains("Manual location"))
            #expect(await catalog.calls.isEmpty)
            #expect(model.error == nil)
        }
    }

    @Test func manualInputDuringStartupWinsOverSavedLocationAndAutomaticDetection() async throws {
        let vault = ModelSecureVault()
        var saved = modelSyntheticProfile(); saved.searchLocation = "Old saved location"
        try await vault.saveProfile(saved)
        await vault.suspendLoad()
        let location = ModelLocation()
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), catalog: ModelCatalog([]),
                               inventory: ModelInventory(), locationService: location, travelService: ModelTravel())
        let startup = Task { await model.startup() }
        try await waitUntil { await vault.pendingProfileLoad != nil }
        model.locationQuery = "Fresh manual location"
        model.changedLocationManually()
        await vault.resolveLoad()
        await startup.value
        #expect(model.hasSavedProfile && model.profile.isEmpty)
        #expect(model.locationQuery == "Fresh manual location" && location.calls == 0)
    }

    @Test func armingWithSyntheticInventoryLocksSetupAndResetErrorsRemainVisible() async throws {
        let vault = ModelSecureVault(); try await vault.saveProfile(modelSyntheticProfile())
        let inventory = ModelInventory(modelStoreSnapshot())
        let location = ModelLocation()
        let catalog = ModelCatalog([modelProduct()])
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), catalog: catalog,
                               inventory: inventory, locationService: location, travelService: ModelTravel())
        model.preferences.selectedStoreIDs = ["NEAR"]
        model.preferences.selectedVariantIDs = ["synthetic-a"]
        model.variants = [modelProduct()]
        model.stores = modelStoreSnapshot().stores
        model.locationQuery = "Synthetic location"
        model.consentToOrder = true
        model.hasSavedProfile = true
        await model.arm()
        let review = try #require(model.pendingArmingReview)
        #expect(!model.coordinator.isArmed)
        await model.confirmArmingReview(id: review.id)
        #expect(model.error == nil)
        let armed = model.coordinator.isArmed
        #expect(armed)
        await model.detectLocation()
        await model.discover()
        model.changedMarket()
        #expect(location.calls == 0)
        #expect(await catalog.calls.isEmpty)
        #expect(model.preferences.selectedStoreIDs == ["NEAR"])
        await model.coordinator.stopAndWait()
        await vault.fail("saveOrderState")
        await model.resetLock()
        #expect(model.error == "Synthetic storage failure")
        await vault.fail(nil)
        await model.resetLock()
        #expect(!model.consentToOrder)
    }

    @Test func visibleConfirmationReconcilesJournalWithoutSubmittingAgain() async throws {
        let vault = ModelSecureVault()
        let now = Date(timeIntervalSince1970: 1_792_166_400)
        let variant = modelProduct("TEST-CA/A")
        let request = CheckoutRequest(variant: variant, store: RetailStore(id: "R121", name: "Synthetic"), market: .ca, maximumTotal: 4000)
        let review = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout", phase: .review,
                                      productIDs: [variant.id], storeIDs: ["R121"], quantities: [1], totalText: "$3,388.87", currencyCode: "CAD",
                                      pickupStartISO: "2026-10-24T14:00:00Z", pickupEndISO: "2026-10-24T14:15:00Z", pickupSlot: "10:00–10:15",
                                      finalActionCount: 1, pickupOnly: true, documentID: "00000000-0000-4000-8000-000000000001", reviewStateID: "00000000-0000-4000-8000-000000000002")
        var auth = review; auth.phase = .authentication
        let page = ModelCheckoutPage(current: review, afterPlace: auth)
        let checkout = AppleCheckoutDriver(vault: vault, page: page, now: { now }, sleep: {})
        let model = PilotModel(vault: vault, preferencesStore: ModelPreferencesStore(), travelService: ModelTravel(), checkout: checkout)
        await model.reconcileVisibleConfirmation()
        #expect(model.error != nil && page.places == 0)
        model.error = nil
        await #expect(throws: CheckoutError.manualInputRequired) { try await checkout.prepare(request: request, profile: modelSyntheticProfile()) }
        let prepared = try await checkout.prepare(request: request, profile: modelSyntheticProfile())
        #expect(try await checkout.submit(review: prepared) == .requiresAuthentication)
        let pending = PurchaseJournal(phase: .uncertain, attemptID: UUID(), variantID: variant.id, storeID: "R121")
        try await vault.saveOrderState(JSONEncoder().encode(pending))
        await model.reconcileVisibleConfirmation()
        #expect(model.message.contains("No verified order confirmation"))
        var confirmed = review; confirmed.phase = .confirmation; confirmed.orderID = "W1234567890"
        page.current = confirmed
        await model.reconcileVisibleConfirmation()
        #expect(model.coordinator.journal.phase == .confirmed && model.coordinator.journal.orderID == "W1234567890")
        #expect(model.coordinator.journal.blocksPurchase && page.places == 1)
        #expect(model.message.contains("one-purchase lock remains active"))
    }
}
