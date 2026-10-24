import AppKit
import Foundation
import Observation
import PilotCore

@MainActor
@Observable
final class PilotModel {
    var preferences: PilotPreferences
    var locationQuery = ""
    var locationDescription = "Shopping country is a preference until your physical location is detected."
    var variants: [ProductVariant] = []
    var stores: [RetailStore] = []
    var availability: [StoreAvailability] = []
    private(set) var travelEstimates: [String: StoreTravelEstimate] = [:]
    private(set) var resolvingTravel = false
    private(set) var travelStatus = ""
    var profile = SecureProfile()
    var hasSavedProfile = false
    private(set) var profileAccessStatus = ""
    private(set) var restoringSavedProfile = false
    var busy = false
    var message = ""
    var error: String?
    var profileOpen = false
    var consentToOrder = false
    var selectedPage: AppPage = .overview
    let locationService: any LocationDetecting
    let vault: any SecureVault
    let checkout: AppleCheckoutDriver
    let rehearsal: CheckoutRehearsal
    let coordinator: MonitoringCoordinator
    let inventoryOnly: Bool
    let inventoryMonitor: InventoryMonitor
    let inventoryAlerts: InventoryAlertService
    private(set) var startingCheckoutTest = false
    private(set) var armingAutomaticCheckout = false
    private(set) var pendingArmingReview: ArmingReview?
    private(set) var appleSessionRecoveryDetail = ""
    private var keychainActionInFlight = false
    private var loadingSavedProfile = false
    var canRestoreSavedProfile: Bool {
        !inventoryOnly && !smoke && !hasSavedProfile && !setupLocked && !busy && !locationService.requesting &&
        !keychainActionInFlight && !loadingSavedProfile && !profileOpen
    }
    private var configurationLocked: Bool { armingAutomaticCheckout || coordinator.isArmed || pendingArmingReview != nil }
    var setupLocked: Bool { configurationLocked || startingCheckoutTest || rehearsal.isActive }
    var canSaveResolvedAppleSession: Bool {
        !inventoryOnly && !smoke && !configurationLocked && !keychainActionInFlight && !startingCheckoutTest &&
        !rehearsal.isActive && !coordinator.journal.blocksPurchase
    }
    private let preferencesStore: any PreferencesStore
    private let catalog: any ProductCatalogFetching
    private let inventory: any InventoryFetching
    private let travelService: any StoreTravelProviding
    private var coordinate: Coordinate?
    private var physicalOrigin = false
    private var travelTask: Task<Void, Never>?
    private var routeCache: [Coordinate: (route: DrivingRoute, date: Date)] = [:]
    private let smoke: Bool
    private let isApplicationActive: @MainActor () -> Bool
    private var initialized = false
    private var locationGeneration = 0
    private var checkoutTestGeneration = 0
    private struct InventoryScope: Equatable {
        let market: Market
        let location: String
        let variants: [String]
    }
    private var monitoredScope: InventoryScope?
    private var discoveredScope: InventoryScope?
    private var inventoryActionGeneration = 0
    private var automaticallyObservesInventory = false
    private var requestedInventoryAlerts = false
    private(set) var inventorySetupError: String?
    @ObservationIgnored private var inventoryReconfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryDiscoveryRetryTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryAuthorizationTask: Task<Void, Never>?
    @ObservationIgnored private var inventoryStartupTask: Task<Void, Never>?
    private var inventoryDiscoveryFailures = 0
    private var currentInventoryScope: InventoryScope {
        InventoryScope(market: preferences.market,
                       location: locationQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                       variants: preferences.selectedVariantIDs.sorted())
    }
    private var monitorMatchesConfiguration: Bool { monitoredScope == currentInventoryScope }

    var inventoryOriginCoordinate: Coordinate? { coordinate }
    var inventoryStores: [RetailStore] {
        let scope = currentInventoryScope
        let discoveryMatches = discoveredScope?.market == scope.market && discoveredScope?.location == scope.location
        var result = discoveryMatches || smoke ? stores : []
        if monitorMatchesConfiguration, let snapshot = inventoryMonitor.snapshot {
            for store in snapshot.stores {
                if let index = result.firstIndex(where: { $0.id == store.id }) { result[index] = store }
                else { result.append(store) }
            }
        }
        return LocationResolver.rank(result, near: coordinate)
    }
    var inventoryAvailability: [StoreAvailability] {
        if monitorMatchesConfiguration, let snapshot = inventoryMonitor.snapshot { return snapshot.availability }
        return discoveredScope == currentInventoryScope || smoke ? availability : []
    }
    var inventoryDataIsStale: Bool {
        if monitorMatchesConfiguration, inventoryMonitor.lastError != nil { return true }
        if monitorMatchesConfiguration, inventoryMonitor.snapshot != nil {
            return false
        }
        return !smoke && discoveredScope != currentInventoryScope
    }

    func stopInventoryMonitoring() {
        automaticallyObservesInventory = false
        inventoryStartupTask?.cancel(); inventoryStartupTask = nil
        interruptInventoryObservation()
        inventoryAuthorizationTask?.cancel()
        inventoryAuthorizationTask = nil
    }

    /// Window visibility must not own the observer's startup lifetime.
    func observeInventoryOnLaunch() {
        guard inventoryOnly, !smoke, !initialized, inventoryStartupTask == nil else { return }
        inventoryStartupTask = Task { [weak self] in
            await self?.startup()
            self?.inventoryStartupTask = nil
        }
    }

    func refreshInventory() async {
        guard inventoryOnly, !busy, !locationService.requesting else { return }
        if inventoryMonitor.isRunning { await inventoryMonitor.performRefresh(); return }
        await discover()
    }

    /// Reconfiguration cancels and drains the previous request before the new
    /// selected set can make a request. Old results can never publish afterward.
    @discardableResult private func interruptInventoryObservation() -> Int {
        guard inventoryOnly else { return inventoryActionGeneration }
        inventoryActionGeneration += 1
        inventoryReconfigurationTask?.cancel(); inventoryReconfigurationTask = nil
        inventoryDiscoveryRetryTask?.cancel(); inventoryDiscoveryRetryTask = nil
        inventoryAlerts.cancelPendingDelivery()
        inventoryMonitor.stop()
        monitoredScope = nil
        inventorySetupError = nil
        return inventoryActionGeneration
    }

    @discardableResult private func resumeAutomaticInventoryObservation(initialSnapshot: InventorySnapshot? = nil,
                                                                       initialFailure: AppleServiceError? = nil) -> Task<Void, Never>? {
        let generation = interruptInventoryObservation()
        guard inventoryOnly, automaticallyObservesInventory, !smoke else { return nil }
        guard let selected = try? inventorySelection() else {
            message = "Choose a location and up to twenty product configurations. Observation starts automatically."
            if preferences.selectedVariantIDs.count > 20 { error = "Select at most twenty configurations to observe." }
            return nil
        }
        let scope = currentInventoryScope
        let task = Task { [weak self] in
            guard let self else { return }
            guard self.automaticallyObservesInventory, generation == self.inventoryActionGeneration,
                  scope == self.currentInventoryScope, !Task.isCancelled else { return }
            await self.inventoryMonitor.stopAndWait()
            guard self.automaticallyObservesInventory, generation == self.inventoryActionGeneration,
                  scope == self.currentInventoryScope, !Task.isCancelled else { return }
            do {
                self.inventoryMonitor.setRefreshInterval(self.preferences.inventoryRefreshInterval)
                try self.inventoryMonitor.start(market: scope.market, location: scope.location, variants: selected,
                                                initialSnapshot: initialSnapshot, initialFailure: initialFailure)
                self.monitoredScope = scope
                self.error = nil
                self.message = "Automatically observing all selected items at nearby Apple stores."
                if !self.requestedInventoryAlerts {
                    self.requestedInventoryAlerts = true
                    self.inventoryAuthorizationTask = Task { [weak self] in await self?.inventoryAlerts.requestAuthorization() }
                }
            } catch { self.error = error.localizedDescription }
            if generation == self.inventoryActionGeneration { self.inventoryReconfigurationTask = nil }
        }
        inventoryReconfigurationTask = task
        return task
    }

    private func retryInventoryDiscovery(after error: any Error) {
        guard automaticallyObservesInventory, !smoke else { return }
        inventoryDiscoveryFailures += 1
        let delay = RetryPolicy(base: preferences.inventoryRefreshInterval).delay(
            failures: inventoryDiscoveryFailures, retryAfter: (error as? AppleServiceError)?.retryDelay)
        let generation = inventoryActionGeneration, scope = currentInventoryScope
        inventoryDiscoveryRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.automaticallyObservesInventory, generation == self.inventoryActionGeneration,
                  scope == self.currentInventoryScope, !Task.isCancelled else { return }
            self.inventoryDiscoveryRetryTask = nil
            await self.discover()
        }
    }

    func setInventoryRefreshInterval(_ seconds: TimeInterval) {
        let safe = seconds.isFinite ? min(3600, max(1, seconds.rounded())) : 1
        preferences.inventoryRefreshInterval = safe
        inventoryMonitor.setRefreshInterval(safe)
        savePreferences()
    }

    private func inventorySelection() throws -> [ProductVariant] {
        let ids = preferences.selectedVariantIDs
        let selected = variants.filter { ids.contains($0.id) }
        guard !locationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ids.isEmpty, ids.count <= 20, Set(ids).count == ids.count,
              selected.count == ids.count,
              selected.allSatisfy({ preferences.catalogProduct.permits(variant: $0, market: preferences.market) }) else {
            throw InventoryMonitorError.invalidConfiguration
        }
        return selected
    }

    init(vault: any SecureVault = KeychainVault(mode: .localLoginKeychain), preferencesStore: (any PreferencesStore)? = nil, smoke: Bool = false,
         catalog: any ProductCatalogFetching = ProductCatalogClient(), inventory: any InventoryFetching = AppleInventoryClient(),
         locationService: any LocationDetecting = LocationService(), travelService: any StoreTravelProviding = StoreTravelService(), checkout: AppleCheckoutDriver? = nil, rehearsal: CheckoutRehearsal? = nil,
         coordinator: MonitoringCoordinator? = nil, preferencesURL: URL? = nil, locale: Locale = .current,
         isApplicationActive: @escaping @MainActor () -> Bool = { NSApp.isActive }, inventoryOnly: Bool = false,
         inventoryMonitor: InventoryMonitor? = nil, inventoryAlerts: InventoryAlertService? = nil) {
        self.vault = vault
        self.inventoryOnly = inventoryOnly
        self.inventoryMonitor = inventoryMonitor ?? InventoryMonitor(inventory: inventory)
        self.inventoryAlerts = inventoryAlerts ?? InventoryAlertService()
        self.smoke = smoke
        self.isApplicationActive = isApplicationActive
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pickup Pilot", isDirectory: true)
        let preferencesURL = preferencesURL ?? directory.appendingPathComponent("preferences.json")
        let store = preferencesStore ?? FilePreferencesStore(url: preferencesURL)
        self.preferencesStore = store
        var loadedPreferences = (try? store.load()) ?? PilotPreferences()
        let needsPhoneOnlyMigration = inventoryOnly && (loadedPreferences.catalogProduct != .iPhoneDuo ||
                                                       loadedPreferences.selectedVariantIDs.contains(CatalogProduct.adapterSKU))
        if needsPhoneOnlyMigration {
            loadedPreferences.catalogProduct = .iPhoneDuo
            loadedPreferences.selectedVariantIDs.removeAll { $0 == CatalogProduct.adapterSKU }
        }
        self.preferences = loadedPreferences
        self.catalog = catalog
        self.inventory = inventory
        self.locationService = locationService
        self.travelService = travelService
        let checkout = checkout ?? AppleCheckoutDriver.safari(vault: vault)
        self.checkout = checkout
        self.rehearsal = rehearsal ?? CheckoutRehearsal()
        self.coordinator = coordinator ?? MonitoringCoordinator(inventory: inventory, driver: checkout, vault: vault, journalStore: KeychainJournalStore(vault: vault))
        self.inventoryMonitor.setRefreshInterval(preferences.inventoryRefreshInterval)
        self.preferences.inventoryRefreshInterval = self.inventoryMonitor.refreshInterval
        self.inventoryMonitor.onChanges = { [weak self] changes in
            guard let self, self.inventoryOnly else { return }
            await self.inventoryAlerts.notify(changes: changes)
        }
        if preferencesStore == nil, let country = locale.region?.identifier, let market = Market(countryCode: country), !(FileManager.default.fileExists(atPath: preferencesURL.path)) { preferences.market = market }
        if needsPhoneOnlyMigration, !smoke {
            do { try store.save(preferences) }
            catch { self.error = "Updated product settings could not be saved: \(error.localizedDescription)" }
        }
        if smoke { seedPreview() }
    }
    func startup() async {
        guard !initialized else { return }
        initialized = true
        guard !smoke else { return }
        if inventoryOnly {
            automaticallyObservesInventory = true
            inventoryAlerts.installNotificationDelegate()
            await inventoryAlerts.refreshAuthorization()
            locationQuery = preferences.inventoryLocationQuery
            if locationQuery.isEmpty { await detectLocation() }
            else { await discover() }
            return
        }
        let startupGeneration = locationGeneration
        loadingSavedProfile = true
        profileAccessStatus = "Reading saved checkout profile from Keychain…"
        await coordinator.restoreJournal()
        do {
            if let saved = try await vault.loadProfile() {
                hasSavedProfile = true
                profileAccessStatus = "Saved checkout profile restored from Keychain."
                if startupGeneration == locationGeneration, !configurationLocked { locationQuery = saved.searchLocation }
            } else {
                profileAccessStatus = "No saved checkout profile was found in this app’s Keychain."
            }
        } catch {
            profileAccessStatus = profileReadFailure(error)
            self.error = profileAccessStatus
        }
        loadingSavedProfile = false
        guard startupGeneration == locationGeneration else { return }
        await detectLocation()
    }
    func detectLocation() async {
        guard !setupLocked, !busy, !locationService.requesting else { return }
        interruptInventoryObservation()
        locationGeneration += 1
        invalidateTravel()
        coordinate = nil
        physicalOrigin = false
        let generation = locationGeneration
        do {
            let found = try await locationService.locate()
            guard generation == locationGeneration, !configurationLocked else { return }
            guard let market = Market(countryCode: found.countryCode) else {
                locationDescription = "Your detected country (\(found.countryCode)) does not have a supported Apple storefront in this app. Choose another shopping country manually."
                return
            }
            if preferences.market != market { preferences.market = market; resetRegionalSelection(); preferences.maximumTotal = 0; consentToOrder = false; savePreferences() }
            coordinate = Coordinate(latitude: found.latitude, longitude: found.longitude)
            physicalOrigin = true
            locationQuery = found.query
            locationDescription = "Physical location detected in \(market.displayName). Stores are ranked by distance."
            await discover()
        } catch {
            guard generation == locationGeneration, !configurationLocked else { return }
            locationDescription = locationService.status
            self.error = error.localizedDescription
            if !locationQuery.isEmpty { await discover() }
        }
    }
    func changedMarket() {
        guard !setupLocked else { return }
        interruptInventoryObservation()
        locationGeneration += 1
        invalidateTravel()
        coordinate = nil
        physicalOrigin = false
        locationDescription = "Manual shopping country: \(preferences.market.displayName). Enter a location in this country."
        resetRegionalSelection()
        preferences.maximumTotal = 0
        consentToOrder = false
        savePreferences()
    }
    func changedLocationManually() {
        guard !setupLocked else { return }
        interruptInventoryObservation()
        locationGeneration += 1
        invalidateTravel()
        coordinate = nil
        physicalOrigin = false
        locationDescription = "Manual location. Apple suggests nearby stores for the entered postal code or city."
        if inventoryOnly {
            stores = []; availability = []; discoveredScope = nil
            savePreferences()
        }
    }
    func selectMarket(_ market: Market) {
        guard !setupLocked, market != preferences.market else { return }
        preferences.market = market
        changedMarket()
    }
    func enterLocationQuery(_ query: String) {
        guard !setupLocked else { return }
        locationQuery = query
        changedLocationManually()
    }
    private func resetRegionalSelection() {
        if !preferences.catalogProduct.supports(market: preferences.market) { preferences.catalogProduct = .iPhoneDuo }
        preferences.selectedStoreIDs = []; preferences.selectedVariantIDs = []
        variants = []; stores = []; availability = []
    }
    func selectCatalogProduct(_ product: CatalogProduct) {
        guard !inventoryOnly || product == .iPhoneDuo else { return }
        guard !configurationLocked, !startingCheckoutTest, !rehearsal.isActive,
              product != preferences.catalogProduct, product.supports(market: preferences.market) else { return }
        interruptInventoryObservation()
        locationGeneration += 1
        invalidateTravel()
        preferences.catalogProduct = product
        preferences.selectedVariantIDs = []
        preferences.maximumTotal = 0
        variants = []; availability = []
        consentToOrder = false
        message = inventoryOnly ? "Product changed. Find stores again and select the configurations to watch." : "Product changed. Find stores again, select the item, and set a new maximum total including tax."
        savePreferences()
    }
    func discover() async {
        guard !busy, !setupLocked else { return }
        interruptInventoryObservation()
        busy = true; error = nil
        defer { busy = false }
        let generation = locationGeneration
        let currentMarket = preferences.market
        let currentProduct = preferences.catalogProduct
        let currentQuery = locationQuery
        do {
            if inventoryOnly { await inventoryMonitor.stopAndWait() }
            guard discoveryIsCurrent(generation, market: currentMarket, query: currentQuery) else { return }
            let currentCoordinate = coordinate
            let products = try await catalog.variants(market: currentMarket, product: currentProduct)
            guard discoveryIsCurrent(generation, market: currentMarket, query: currentQuery), preferences.catalogProduct == currentProduct else { return }
            variants = products
            preferences.selectedVariantIDs.removeAll { id in !products.contains { $0.id == id } }
            guard !locationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                message = "Regional catalog loaded. Enter a postal code or city to find stores."; return
            }
            let selected = products.filter { preferences.selectedVariantIDs.contains($0.id) }
            let result = try await inventory.fetch(market: currentMarket, location: currentQuery, variants: selected.isEmpty ? Array(products.prefix(1)) : selected)
            guard discoveryIsCurrent(generation, market: currentMarket, query: currentQuery), preferences.catalogProduct == currentProduct else { return }
            stores = LocationResolver.rank(result.stores, near: currentCoordinate)
            availability = result.availability
            discoveredScope = InventoryScope(market: currentMarket, location: currentQuery.trimmingCharacters(in: .whitespacesAndNewlines), variants: selected.map(\.id).sorted())
            preferences.selectedStoreIDs.removeAll { id in !stores.contains { $0.id == id } }
            message = "Loaded \(products.count) regional configurations and \(stores.count) nearby stores."
            savePreferences()
            inventoryDiscoveryFailures = 0
            if inventoryOnly {
                let restart = resumeAutomaticInventoryObservation(initialSnapshot: result)
                await restart?.value
                guard discoveryIsCurrent(generation, market: currentMarket, query: currentQuery) else { return }
            }
            travelEstimates = [:]
            travelTask?.cancel()
            let task = Task { await self.loadStoreTravel(generation: generation, market: currentMarket, query: currentQuery) }
            travelTask = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if generation == locationGeneration { travelTask = nil }
        } catch {
            guard discoveryIsCurrent(generation, market: currentMarket, query: currentQuery) else { return }
            if inventoryOnly {
                if (try? inventorySelection()) != nil {
                    let failure = error as? AppleServiceError ?? .invalidResponse("Inventory request failed")
                    await resumeAutomaticInventoryObservation(initialFailure: failure)?.value
                } else {
                    inventorySetupError = "Apple's products or nearby stores could not be loaded. Retrying automatically."
                    retryInventoryDiscovery(after: error)
                }
                return
            }
            self.error = error.localizedDescription; message = "The latest inventory could not be verified."
        }
    }
    private func discoveryIsCurrent(_ generation: Int, market: Market, query: String) -> Bool {
        !configurationLocked && generation == locationGeneration && market == preferences.market && query == locationQuery && !Task.isCancelled
    }
    private func invalidateTravel() {
        travelTask?.cancel(); travelTask = nil
        travelEstimates = [:]; routeCache = [:]
        resolvingTravel = false; travelStatus = ""
    }
    private func loadStoreTravel(generation: Int, market: Market, query: String) async {
        guard !stores.isEmpty, discoveryIsCurrent(generation, market: market, query: query) else { return }
        resolvingTravel = true
        travelStatus = "Locating the postcode or city and estimating driving times…"
        defer { if generation == locationGeneration { resolvingTravel = false } }
        let origin: Coordinate
        if let coordinate { origin = coordinate }
        else {
            do {
                origin = try await travelService.origin(for: query, market: market)
                guard discoveryIsCurrent(generation, market: market, query: query) else { return }
                guard origin.isValid else {
                    travelStatus = "Distances and drive times are unavailable because the location could not be verified."
                    return
                }
                coordinate = origin
            } catch {
                guard discoveryIsCurrent(generation, market: market, query: query) else { return }
                travelStatus = "Couldn’t locate this postcode or city in \(market.displayName). Check the location and find stores again for distances and drive times."
                return
            }
        }
        guard origin.isValid else {
            travelStatus = "Distances and drive times are unavailable because the location could not be verified."
            return
        }
        stores = LocationResolver.rank(stores, near: origin)
        let originDescription = physicalOrigin ? "your detected location" : "the postcode or city centre"
        travelStatus = "Distances are straight-line from \(originDescription). Drive times are rough Apple Maps estimates, rounded up in steps of 5 minutes. Traffic, parking and your exact starting point can change them."
        // Keep requests sequential and cache successful routes for ten minutes; inventory polling never requests routes.
        for store in stores {
            guard discoveryIsCurrent(generation, market: market, query: query) else { return }
            guard let destination = store.coordinate else { continue }
            var route: DrivingRoute?
            if let cached = routeCache[destination], Date.now.timeIntervalSince(cached.date) < 600 {
                route = cached.route
            } else {
                route = try? await travelService.drivingRoute(from: origin, to: destination)
                guard discoveryIsCurrent(generation, market: market, query: query) else { return }
                if let route { routeCache[destination] = (route, .now) }
            }
            travelEstimates[store.id] = StoreTravelEstimate(straightLineKilometers: origin.distanceKilometers(to: destination), drivingRoute: route)
        }
    }
    func savePreferences() {
        guard !smoke else { return }
        if inventoryOnly { preferences.inventoryLocationQuery = locationQuery }
        do { try preferencesStore.save(preferences) }
        catch { self.error = "Preferences could not be saved: \(error.localizedDescription)" }
    }
    func toggleVariant(_ id: String) {
        guard !setupLocked else { return }
        if inventoryOnly {
            var selected = preferences.selectedVariantIDs
            if selected.contains(id) { selected.removeAll { $0 == id } }
            else { selected.append(id) }
            setInventoryVariantSelection(selected)
            return
        }
        if preferences.selectedVariantIDs.contains(id) { preferences.selectedVariantIDs.removeAll { $0 == id } }
        else { preferences.selectedVariantIDs.append(id) }
        consentToOrder = false; savePreferences()
    }

    func setInventoryVariantSelection(_ ids: [String]) {
        guard inventoryOnly, !setupLocked, !busy else { return }
        guard ids.count <= 20, Set(ids).count == ids.count,
              ids.allSatisfy({ id in
                  let matches = variants.filter { $0.id == id }
                  return matches.count == 1 && CatalogProduct.iPhoneDuo.permits(variant: matches[0], market: preferences.market)
              }) else {
            error = "Choose up to twenty different configurations from the current iPhone catalog."
            return
        }
        guard ids != preferences.selectedVariantIDs else { return }
        preferences.selectedVariantIDs = ids
        consentToOrder = false
        error = nil
        savePreferences()
        locationGeneration += 1
        if resolvingTravel { invalidateTravel() }
        resumeAutomaticInventoryObservation()
    }
    func toggleStore(_ id: String) {
        guard !setupLocked else { return }
        if preferences.selectedStoreIDs.contains(id) { preferences.selectedStoreIDs.removeAll { $0 == id } }
        else { preferences.selectedStoreIDs.append(id) }
        consentToOrder = false; savePreferences()
    }
    func restoreSavedCheckoutProfile() async {
        guard !inventoryOnly else { return }
        guard canRestoreSavedProfile else { return }
        guard isApplicationActive() else {
            profileAccessStatus = "Bring Pickup Pilot to the foreground before restoring saved checkout details."
            return
        }
        let generation = locationGeneration
        keychainActionInFlight = true
        restoringSavedProfile = true
        profileAccessStatus = "Restoring saved checkout profile. Approve any native Keychain prompt locally."
        defer {
            keychainActionInFlight = false
            restoringSavedProfile = false
            if Task.isCancelled { profileAccessStatus = "Saved checkout profile restore was canceled. No details were opened." }
        }
        do {
            let restored = try await vault.loadProfileForUserInitiatedRestore() != nil
            guard !Task.isCancelled, !setupLocked else { return }
            guard restored else {
                profileAccessStatus = "No saved checkout profile was found in this app’s Keychain."
                return
            }
            // A one-time authorization must not imply that later automatic reads can succeed.
            guard let saved = try await vault.loadProfile() else {
                profileAccessStatus = "The saved checkout profile is no longer available in Keychain. Restore it again before continuing."
                return
            }
            guard !Task.isCancelled, !setupLocked else { return }
            hasSavedProfile = true
            profileAccessStatus = "Saved checkout profile restored from Keychain without opening its details."
            error = nil
            if generation == locationGeneration {
                locationGeneration += 1
                invalidateTravel()
                coordinate = nil
                physicalOrigin = false
                locationQuery = saved.searchLocation
                locationDescription = "Saved search location restored. Apple suggests nearby stores for this location."
            }
            if !locationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await discover() }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else {
                profileAccessStatus = "Saved checkout profile restore was canceled. No details were opened."
                return
            }
            profileAccessStatus = profileReadFailure(error)
            self.error = profileAccessStatus
        }
    }
    private func profileReadFailure(_ error: any Error) -> String {
        if let vaultError = error as? SecureVaultError {
            return "Saved checkout profile could not be restored. \(vaultError.localizedDescription)"
        }
        return "Saved checkout profile could not be restored. Check Keychain access, then try Restore saved checkout profile."
    }
    func openProfile() async {
        guard !inventoryOnly else { return }
        guard !configurationLocked, !keychainActionInFlight else { return }
        keychainActionInFlight = true
        defer { keychainActionInFlight = false }
        do {
            let saved = try await vault.loadProfile()
            guard !configurationLocked else { return }
            profile = saved ?? SecureProfile()
            profileOpen = true
        } catch { self.error = error.localizedDescription }
    }
    func saveProfile() async {
        guard !inventoryOnly else { return }
        guard !configurationLocked, !keychainActionInFlight else { return }
        keychainActionInFlight = true
        defer { keychainActionInFlight = false }
        do {
            profile.searchLocation = locationQuery
            try await vault.saveProfile(profile)
            guard !configurationLocked else { return }
            hasSavedProfile = true; profileOpen = false; profile = SecureProfile()
            profileAccessStatus = "Checkout profile saved in Keychain."
            message = "Checkout details saved in this app's local Keychain items."
        } catch { self.error = error.localizedDescription }
    }
    func closeProfile() { profile = SecureProfile(); profileOpen = false }
    func deleteProfile() async {
        guard !inventoryOnly else { return }
        guard !configurationLocked, !keychainActionInFlight else { return }
        keychainActionInFlight = true
        defer { keychainActionInFlight = false }
        do {
            try await vault.deleteProfile()
            guard !configurationLocked else { return }
            hasSavedProfile = false; profile = SecureProfile(); consentToOrder = false
            profileAccessStatus = "Checkout profile deleted from Keychain."
            message = "Checkout profile deleted from Keychain."
        } catch { self.error = error.localizedDescription }
    }
    func clearSession() async {
        guard !inventoryOnly else { return }
        guard !configurationLocked, !keychainActionInFlight else { return }
        keychainActionInFlight = true
        defer { keychainActionInFlight = false }
        do {
            try await checkout.clearSession()
            guard !configurationLocked else { return }
            try await vault.deleteSession()
            guard !configurationLocked else { return }
            message = checkout.usesBrowserManagedSession
                ? "Pickup Pilot’s Safari checkout window was reset. Safari keeps its own website data."
                : "Saved Apple session deleted from Keychain."
        }
        catch { self.error = error.localizedDescription }
    }
    func saveResolvedAppleSession() async {
        guard !inventoryOnly else { return }
        guard canSaveResolvedAppleSession else { return }
        keychainActionInFlight = true
        defer { keychainActionInFlight = false }
        appleSessionRecoveryDetail = checkout.usesBrowserManagedSession ? "Verifying the Safari checkout page…" : "Saving the current Apple session…"
        do {
            try await checkout.recoverSessionAfterManualInput(market: preferences.market)
            error = nil
            message = checkout.usesBrowserManagedSession
                ? "Safari’s checkout page was verified. Review your limits, then arm a new attempt. Verification never arms checkout or places an order."
                : "Resolved Apple session saved. Review your limits, then arm a new attempt. Saving never arms checkout or places an order."
            appleSessionRecoveryDetail = message
        } catch {
            let detail: String
            if let checkoutError = error as? CheckoutError, checkoutError == .pageNotFound || checkoutError == .sessionRecoveryNotReady || checkoutError.isSafariFailure {
                detail = checkoutError.localizedDescription
            } else {
                detail = "The current Apple page could not be verified. Return to a working bag or product page in the checkout browser before trying again."
            }
            self.error = detail
            appleSessionRecoveryDetail = detail
        }
    }
    func returnToAppleBag() async {
        guard !inventoryOnly else { return }
        guard canSaveResolvedAppleSession else { return }
        keychainActionInFlight = true
        defer { keychainActionInFlight = false }
        do {
            try await checkout.returnToBag(market: preferences.market)
            error = nil
            appleSessionRecoveryDetail = "Opening Apple's bag. This does not arm checkout, add another item or submit an order. Review your selections before arming a new attempt."
        } catch {
            let detail = (error as? CheckoutError).flatMap { $0.isSafariFailure ? $0.localizedDescription : nil }
                ?? "The bag could not be opened while this checkout operation is active. Finish or cancel the operation before trying again."
            self.error = detail
            appleSessionRecoveryDetail = detail
        }
    }
    func showSafariCheckout() async {
        guard !inventoryOnly else { return }
        guard !smoke else { error = "Preview mode cannot open a live Safari checkout."; return }
        do { try await checkout.showBrowser() }
        catch {
            self.error = (error as? CheckoutError)?.localizedDescription
                ?? "Pickup Pilot’s Safari checkout window could not be shown."
        }
    }
    /// Compatibility entry point: requesting a review can never start monitoring.
    func arm() async { requestArmingReview() }

    func requestArmingReview() {
        guard !inventoryOnly else { error = "Automatic checkout is temporarily disabled. Use the inventory map to monitor stock."; return }
        guard !smoke else { error = "Preview mode cannot place orders."; return }
        guard !armingAutomaticCheckout, !coordinator.isArmed else { error = "Automatic checkout is already arming or armed."; return }
        guard pendingArmingReview == nil else { return }
        guard !busy, !locationService.requesting else { error = "Wait for product, store and location loading to finish before reviewing an order."; return }
        guard !keychainActionInFlight else { error = "Wait for checkout details or saved session changes to finish before reviewing an order."; return }
        guard !profileOpen else { error = "Finish editing checkout details before reviewing an order."; return }
        guard !startingCheckoutTest, !rehearsal.isActive else { error = "Close the checkout test before arming automatic checkout."; return }
        guard consentToOrder else { error = "Confirm the one-order authorization before arming."; return }
        guard hasSavedProfile else { error = "Save a complete checkout profile before reviewing automatic checkout."; return }
        guard !coordinator.journal.blocksPurchase else { error = CoordinatorError.purchaseLocked.localizedDescription; return }
        do {
            let plan = try currentArmingPlan()
            locationGeneration += 1
            travelTask?.cancel(); travelTask = nil; resolvingTravel = false
            pendingArmingReview = ArmingReview(plan: plan, profileSaved: hasSavedProfile)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func cancelArmingReview() {
        guard pendingArmingReview != nil else { return }
        pendingArmingReview = nil
        // Cancellation can occur while the coordinator awaits storage. Its authorization
        // callback also observes the revoked review before activating any monitoring.
        if armingAutomaticCheckout, coordinator.isArmed { coordinator.stop() }
        message = "Arming review canceled. No new monitoring was authorized."
    }

    func confirmArmingReview(id: UUID) async {
        guard !inventoryOnly else { return }
        guard !armingAutomaticCheckout else { return }
        guard let review = pendingArmingReview, review.id == id else {
            error = "Review the selected products, stores and limits before arming."; return
        }
        guard !coordinator.isArmed, armingReviewMatches(review) else {
            pendingArmingReview = nil
            error = "The products, stores, location or limits changed. Review them again before arming."; return
        }
        armingAutomaticCheckout = true
        locationGeneration += 1
        travelTask?.cancel(); travelTask = nil; resolvingTravel = false
        defer { armingAutomaticCheckout = false }
        do {
            savePreferences()
            try await coordinator.arm(configuration: review.plan.configuration, variants: review.plan.variants, stores: review.plan.stores,
                                      location: review.plan.location, authorizationCheck: { [weak self] in
                self?.armingReviewMatches(review) == true && !Task.isCancelled
            })
            guard armingReviewMatches(review), !Task.isCancelled else {
                coordinator.stop()
                throw CancellationError()
            }
            pendingArmingReview = nil
            error = nil
        } catch {
            let canceled = pendingArmingReview == nil || Task.isCancelled
            pendingArmingReview = nil
            if coordinator.isArmed { coordinator.stop() }
            if canceled { message = "Arming canceled. Automatic checkout remains disarmed." }
            else if error is CancellationError { self.error = "The reviewed order changed. Review the current products, stores and limits again before arming." }
            else { self.error = error.localizedDescription }
        }
    }

    private func currentArmingPlan() throws -> MonitoringPlan {
        let issues = preferences.validationIssues
        guard issues.isEmpty else { throw CoordinatorError.invalidConfiguration(issues.joined(separator: " ")) }
        guard preferences.attemptWindow.end > Date() else { throw CoordinatorError.invalidConfiguration("The checkout attempt window has ended.") }
        guard !locationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoordinatorError.invalidConfiguration("Enter a postal code or city before reviewing automatic checkout.")
        }
        let selectedVariants = try preferences.selectedVariantIDs.map { id -> ProductVariant in
            let matches = variants.filter { $0.id == id }
            guard matches.count == 1, let variant = matches.first,
                  preferences.catalogProduct.permits(variant: variant, market: preferences.market) else {
                throw CoordinatorError.invalidConfiguration("Reload the selected product and select every intended configuration again.")
            }
            return variant
        }
        let selectedStores = try preferences.selectedStoreIDs.map { id -> RetailStore in
            let matches = stores.filter { $0.id == id }
            guard matches.count == 1, let store = matches.first,
                  store.countryCode == nil || store.countryCode?.uppercased() == preferences.market.countryCode else {
                throw CoordinatorError.invalidConfiguration("Reload stores for this country and select every intended pickup store again.")
            }
            return store
        }
        return MonitoringPlan(configuration: preferences, variants: selectedVariants, stores: selectedStores, location: locationQuery)
    }

    private func armingReviewMatches(_ review: ArmingReview) -> Bool {
        pendingArmingReview?.id == review.id && consentToOrder && !smoke && !busy && !locationService.requesting &&
        !keychainActionInFlight && !profileOpen && !startingCheckoutTest && !rehearsal.isActive &&
        hasSavedProfile && review.profileSaved == hasSavedProfile && (try? currentArmingPlan()) == review.plan
    }
    func testCheckout() async {
        guard !inventoryOnly else { error = "Checkout is temporarily disabled. Inventory monitoring does not place orders."; return }
        guard !startingCheckoutTest, !rehearsal.isActive else {
            error = "A checkout test is already running or waiting for you. Use its test window to continue or end it."
            return
        }
        guard !rehearsal.hasPendingPreparation else {
            rejectCheckoutTestStartup("Wait for the previous checkout test to finish stopping before starting another test.")
            return
        }
        guard pendingArmingReview == nil, !armingAutomaticCheckout, !coordinator.isArmed else {
            rejectCheckoutTestStartup("Cancel the arming review or disarm automatic checkout before starting a review-only test.")
            return
        }
        guard !busy, !locationService.requesting else {
            rejectCheckoutTestStartup("Wait for product, store and location loading to finish before starting the checkout test.")
            return
        }
        guard !keychainActionInFlight, !profileOpen else {
            rejectCheckoutTestStartup("Finish editing or updating the local checkout profile before starting the checkout test.")
            return
        }
        guard !smoke else { rejectCheckoutTestStartup("Preview mode cannot open a live checkout test."); return }
        guard let variantID = preferences.selectedVariantIDs.first,
              let variant = variants.first(where: { $0.id == variantID }),
              let storeID = preferences.selectedStoreIDs.first,
              let store = stores.first(where: { $0.id == storeID }),
              preferences.catalogProduct.permits(variant: variant, market: preferences.market),
              store.countryCode == nil || store.countryCode?.uppercased() == preferences.market.countryCode,
              preferences.maximumTotal > 0, !preferences.maximumTotal.isNaN,
              preferences.catalogProduct == .usbCHeadphoneAdapter || (preferences.pickupWindow.isValid && preferences.pickupHours.isValid),
              TimeZone(identifier: preferences.timeZoneIdentifier) != nil,
              !locationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            rejectCheckoutTestStartup("Choose a local store, a product configuration, a location and a budget before testing checkout.")
            return
        }
        let request = CheckoutRequest(variant: variant, store: store, market: preferences.market, maximumTotal: preferences.maximumTotal,
                                      pickupWindow: preferences.pickupWindow, pickupHours: preferences.pickupHours,
                                      timeZoneIdentifier: preferences.timeZoneIdentifier)
        let query = locationQuery
        locationGeneration += 1
        travelTask?.cancel(); travelTask = nil; resolvingTravel = false
        checkoutTestGeneration += 1
        let generation = checkoutTestGeneration
        error = nil
        startingCheckoutTest = true
        defer { if generation == checkoutTestGeneration { startingCheckoutTest = false } }
        do {
            var saved = try await withTaskCancellationHandler {
                try await vault.loadProfile() ?? SecureProfile()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.checkoutTestGeneration == generation else { return }
                    self.cancelCheckoutTest()
                }
            }
            guard generation == checkoutTestGeneration else { return }
            guard !Task.isCancelled else { cancelCheckoutTest(); return }
            guard !coordinator.isArmed else {
                rejectCheckoutTestStartup("Disarm automatic checkout before starting a review-only test.")
                return
            }
            saved.searchLocation = query
            await rehearsal.start(request: request, profile: saved)
        } catch {
            guard generation == checkoutTestGeneration else { return }
            guard !Task.isCancelled, !(error is CancellationError) else { cancelCheckoutTest(); return }
            rejectCheckoutTestStartup("The checkout profile could not be read. Review Keychain access before testing.")
        }
    }
    private func rejectCheckoutTestStartup(_ reason: String) {
        error = reason
        rehearsal.rejectStartup(reason)
    }
    func cancelCheckoutTest() {
        checkoutTestGeneration += 1
        startingCheckoutTest = false
        rehearsal.cancel()
    }
    func resetLock() async {
        guard !inventoryOnly else { return }
        do { try await coordinator.resetPurchaseLock(); try await checkout.resetAfterReconciliation(); consentToOrder = false }
        catch { self.error = error.localizedDescription }
    }
    func reconcileVisibleConfirmation() async {
        guard !inventoryOnly else { return }
        do {
            if case .confirmed(let orderID) = try await checkout.recoverOutcome() {
                try await coordinator.reconcileConfirmation(orderID: orderID)
                message = "Apple's visible order confirmation was recorded. The one-purchase lock remains active."
            } else {
                message = "No verified order confirmation is visible. Check your Apple orders before resetting the purchase lock."
            }
        } catch { self.error = error.localizedDescription }
    }
    var storeCount: Int { preferences.selectedStoreIDs.count }
    var variantCount: Int { preferences.selectedVariantIDs.count }
    func distance(to store: RetailStore) -> String? {
        guard let coordinate, coordinate.isValid, let destination = store.coordinate else { return nil }
        return String(format: "%.1f km", coordinate.distanceKilometers(to: destination))
    }
    func travelEstimate(to store: RetailStore) -> StoreTravelEstimate? {
        guard let coordinate, coordinate.isValid, let destination = store.coordinate else { return nil }
        return travelEstimates[store.id] ?? StoreTravelEstimate(straightLineKilometers: coordinate.distanceKilometers(to: destination), drivingRoute: nil)
    }
    func travelTime(to store: RetailStore) -> String {
        if let estimate = travelEstimates[store.id] { return estimate.travelTimeLabel }
        return resolvingTravel && store.coordinate != nil ? "Estimating drive…" : "Drive time unavailable"
    }
    private func seedPreview() {
        preferences = PilotPreferences(); preferences.market = .ca
        locationQuery = "Toronto"
        locationDescription = "Preview data • no live monitoring or purchasing"
        variants = [ProductVariant(id: "PREVIEW-256-NIGHT", name: "iPhone Duo 256GB Night Sky", storage: "256GB", color: "Night Sky", productURL: Market.ca.productBaseURL), ProductVariant(id: "PREVIEW-256-WHITE", name: "iPhone Duo 256GB Star White", storage: "256GB", color: "Star White", productURL: Market.ca.productBaseURL)]
        stores = [RetailStore(id: "R121", name: "Eaton Centre", latitude: 43.6544, longitude: -79.3807, address: "Toronto, Ontario"), RetailStore(id: "R120", name: "Yorkdale", latitude: 43.7254, longitude: -79.4521, address: "Toronto, Ontario"), RetailStore(id: "R208", name: "Sherway Gardens", latitude: 43.6118, longitude: -79.5573, address: "Etobicoke, Ontario")]
        let previewOrigin = Coordinate(latitude: 43.6426, longitude: -79.3871)
        coordinate = previewOrigin
        travelStatus = "Preview distances and driving times are sample data from a Toronto origin. Live searches use the postcode or city centre and Apple Maps driving estimates."
        for (index, store) in stores.enumerated() {
            if let destination = store.coordinate {
                travelEstimates[store.id] = StoreTravelEstimate(straightLineKilometers: previewOrigin.distanceKilometers(to: destination), drivingRoute: DrivingRoute(distanceKilometers: [2.1, 14.5, 19.8][index], expectedTravelSeconds: [600, 1500, 1800][index]))
            }
        }
        availability = stores.map { StoreAvailability(storeID: $0.id, variantID: variants[0].id, state: .disabled, message: "Check back for availability on 10.24") }
        preferences.selectedVariantIDs = [variants[0].id]
        preferences.selectedStoreIDs = [stores[0].id, stores[1].id]
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case overview = "Overview", stores = "Stores & products", schedule = "Schedule & limits", security = "Secure checkout", activity = "Activity & order"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"; case .stores: "mappin.and.ellipse"; case .schedule: "calendar.badge.clock"; case .security: "lock.shield"; case .activity: "list.bullet.rectangle"
        }
    }
}
