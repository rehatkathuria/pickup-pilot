import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
import Vision
@testable import PickupPilot

private let monitorRenderNow = Date(timeIntervalSince1970: 2_076_851_720) // 2035-10-24, within the synthetic attempt window.
private func monitorRenderProfile() -> SecureProfile {
    SecureProfile(givenName: "Synthetic", familyName: "Render", email: "rendering@example.invalid", phone: "+14165550100",
                  cardholder: "Synthetic Render", cardNumber: "4111111111111111", expiryMonth: "12", expiryYear: "2040", cvv: "719",
                  billingLine1: "1 Synthetic Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
}
private actor MonitorRenderVault: SecureVault {
    private var profileLoads = 0
    func loadCount() -> Int { profileLoads }
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { profileLoads += 1; return monitorRenderProfile() }
    func deleteProfile() {}
    func saveSession(_ data: Data) {}
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() {}
}
private struct MonitorRenderPreferences: PreferencesStore {
    let value: PilotPreferences
    func load() -> PilotPreferences { value }
    func save(_ preferences: PilotPreferences) { Issue.record("A rendering fixture must not save preferences.") }
}
private actor MonitorRenderCatalog: ProductCatalogFetching {
    func variants(market: Market) -> [ProductVariant] {
        Issue.record("A rendering fixture must not request a catalog."); return []
    }
}
private actor MonitorRenderInventory: InventoryFetching {
    var result: InventorySnapshot
    var fail = false
    var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ result: InventorySnapshot) { self.result = result }
    func configure(fail: Bool = false, suspend: Bool = false) { self.fail = fail; self.suspend = suspend }
    func isSuspended() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil; suspend = false }
    func fetch(market: Market, location: String, variants: [ProductVariant]) async throws -> InventorySnapshot {
        if suspend { await withCheckedContinuation { continuation = $0 } }
        if fail { throw AppleServiceError.httpStatus(503) }
        return result
    }
}
@MainActor private final class MonitorRenderLocation: LocationDetecting {
    let status = "Synthetic location"
    let requesting = false
    func locate() throws -> DetectedLocation {
        Issue.record("Rendering must not request physical location."); throw CheckoutError.cancelled
    }
}
@MainActor private final class MonitorRenderTravel: StoreTravelProviding {
    func origin(for query: String, market: Market) throws -> Coordinate {
        Issue.record("Rendering must not geocode a location."); throw CheckoutError.cancelled
    }
    func drivingRoute(from origin: Coordinate, to destination: Coordinate) throws -> DrivingRoute {
        Issue.record("Rendering must not request a driving route."); throw CheckoutError.cancelled
    }
}
@MainActor private final class MonitorRenderDriver: CheckoutDriver {
    private(set) var preparations = 0
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        preparations += 1
        throw CheckoutError.authenticationRequired
    }
    func submit(review: CheckoutReview) -> CheckoutOutcome {
        Issue.record("A rendering fixture must never submit an order.")
        return .indeterminate(reason: "Synthetic rendering only")
    }
    func cancel() {}
}

/// Native offscreen rendering and OCR only. Services, profiles, inventory and dates
/// are synthetic; no button is invoked and no production storage is consulted.
@Suite(.serialized) @MainActor struct MonitoringReviewRenderingTests {
    private struct Surface {
        let window: NSWindow
        let controller: NSHostingController<AnyView>
        let size: NSSize
    }
    private struct Reading {
        let text: String
        let lines: [(text: String, bounds: CGRect)]
    }
    private func variants(count: Int = 2) -> [ProductVariant] {
        (1...count).map { index in
            ProductVariant(id: "SYNTH-\(index)/A", name: "Synthetic Duo \(index) · \(index == 1 ? "Night Sky 256GB" : "Cloud White 512GB")",
                           storage: index == 1 ? "256GB" : "512GB", color: index == 1 ? "Night Sky" : "Cloud White",
                           productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic-\(index)"))
        }
    }
    private func stores(count: Int = 2) -> [RetailStore] {
        (1...count).map { index in
            RetailStore(id: "R\(100 + index)", name: index == 1 ? "Synthetic Harbour Store" : "Synthetic Garden Store \(index)",
                        address: "\(index) Synthetic Avenue, Toronto", countryCode: "CA")
        }
    }
    private func configuration(variants: [ProductVariant], stores: [RetailStore], adapter: Bool = false) throws -> PilotPreferences {
        var value = PilotPreferences()
        value.catalogProduct = adapter ? .usbCHeadphoneAdapter : .iPhoneDuo
        value.selectedVariantIDs = variants.reversed().map(\.id)
        value.selectedStoreIDs = stores.reversed().map(\.id)
        value.maximumTotal = adapter ? Decimal(string: "12.00")! : Decimal(string: "3456.78")!
        value.pollInterval = 5
        value.timeZoneIdentifier = "America/Vancouver"
        value.attemptWindow = DateWindow(start: try #require(CheckoutPagePolicy.instant("2035-10-24T15:15:20Z")),
                                        end: try #require(CheckoutPagePolicy.instant("2035-10-25T17:11:15Z")))
        value.pickupWindow = DateWindow(start: try #require(CheckoutPagePolicy.instant("2035-10-26T16:00:00Z")),
                                       end: try #require(CheckoutPagePolicy.instant("2035-10-28T20:00:00Z")))
        value.pickupHours = DailyWindow(startMinute: 550, endMinute: 1125)
        value.maximumPreparationFailures = 4
        return value
    }
    private func model(configuration: PilotPreferences, variants: [ProductVariant], stores: [RetailStore],
                       vault: MonitorRenderVault = MonitorRenderVault(), coordinator: MonitoringCoordinator? = nil) -> PilotModel {
        let inventory = MonitorRenderInventory(InventorySnapshot(stores: stores, availability: []))
        let model = PilotModel(vault: vault, preferencesStore: MonitorRenderPreferences(value: configuration),
                               catalog: MonitorRenderCatalog(), inventory: inventory,
                               locationService: MonitorRenderLocation(), travelService: MonitorRenderTravel(), coordinator: coordinator)
        model.variants = variants; model.stores = stores
        model.locationQuery = "Synthetic public search location"
        model.hasSavedProfile = true; model.consentToOrder = true
        return model
    }
    private func render<V: View>(_ view: V, size: NSSize = NSSize(width: 960, height: 1100)) async throws -> Surface {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: AnyView(view.environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_CA"))
            .background(Color(nsColor: .windowBackgroundColor)).transaction { $0.animation = nil }))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false
        window.contentViewController = controller; controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.frame = NSRect(origin: .zero, size: size); window.setContentSize(size)
        let surface = Surface(window: window, controller: controller, size: size)
        try await settle(surface)
        let fit = controller.sizeThatFits(in: size)
        #expect(fit.width.isFinite && fit.height.isFinite && fit.width > 0 && fit.height > 0)
        #expect(fit.width <= size.width + 1 && fit.height <= size.height + 1)
        return surface
    }
    private func settle(_ surface: Surface) async throws {
        for _ in 0..<4 {
            surface.window.layoutIfNeeded(); surface.controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func bitmap(_ surface: Surface) throws -> NSBitmapImageRep {
        let view = surface.controller.view
        #expect(view.bounds.size == surface.size)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(surface.size.width) && bitmap.pixelsHigh >= Int(surface.size.height))
        #expect((bitmap.representation(using: .png, properties: [:])?.count ?? 0) > 3000)
        return bitmap
    }
    private func read(_ surface: Surface) throws -> Reading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]; request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: try #require(bitmap(surface).cgImage)).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (text: String, bounds: CGRect)? in
            guard let value = observation.topCandidates(1).first?.string else { return nil }
            return (value.lowercased().replacingOccurrences(of: "’", with: "'"), observation.boundingBox)
        }
        let text = lines.map(\.text).joined(separator: " ")
        #expect(text.count > 20, "The actual native bitmap must contain readable content.")
        #expect(!text.contains("rendering@example.invalid") && !text.contains("4111111111111111"))
        return Reading(text: text, lines: lines)
    }
    private func scroll(_ surface: Surface, toBottom: Bool) async throws {
        let scrolls = descendants(surface.controller.view).compactMap { $0 as? NSScrollView }
        #expect(!scrolls.isEmpty)
        for scroll in scrolls {
            guard let document = scroll.documentView else { continue }
            let low = document.bounds.minY, high = max(low, document.bounds.maxY - scroll.contentView.bounds.height)
            let y = toBottom == document.isFlipped ? high : low
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await settle(surface)
    }
    private func export(_ surface: Surface, name: String) throws {
        guard ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_PREVIEWS"] == "1" else { return }
        let data = try #require(bitmap(surface).representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("outputs/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }
    private func order(_ text: String, _ first: String, before second: String) {
        let left = text.range(of: first), right = text.range(of: second)
        #expect(left != nil && right != nil)
        if let left, let right { #expect(left.lowerBound < right.lowerBound) }
    }

    @Test func phoneReviewRendersExactPrioritiesTotalsAndConfiguredTimeZoneWithoutReadingProfile() async throws {
        let variants = variants(), stores = stores(), vault = MonitorRenderVault()
        var preferences = try configuration(variants: variants, stores: stores)
        preferences.attemptHours = DailyWindow(startMinute: 1350, endMinute: 135)
        let model = model(configuration: preferences, variants: variants, stores: stores, vault: vault)
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        defer { model.cancelArmingReview() }
        let summary = try await render(SelectionSummaryView(plan: review.plan, profileSaved: review.profileSaved).padding(24))
        defer { summary.window.close() }
        let text = try read(summary).text
        #expect(text.contains("configuration priority") && text.contains("pickup store priority"))
        order(text, "synthetic duo 2", before: "synthetic duo 1")
        order(text, "synthetic garden store 2", before: "synthetic harbour store")
        #expect(text.contains("synth-2/a") && text.contains("synth-1/a"))
        #expect(text.contains("r102") && text.contains("r101") && text.contains("cad"))
        #expect(text.contains("3,456.78") || text.contains("3456.78"))
        #expect(text.contains("includes tax and fees") && text.contains("every 5 seconds when healthy"))
        #expect(text.contains("america/vancouver") && text.contains("overnight"))
        #expect(text.contains("8:15:20") && text.contains("10:11:15"), "Attempts must render Vancouver times, including seconds, rather than the host's time zone.")
        #expect(text.contains("22:30") && text.contains("02:15") && text.contains("09:10") && text.contains("18:45"))
        #expect(text.contains("daily pickup hours") && !text.contains("no reserved date or time"))
        #expect(text.contains("checkout profile saved in keychain"))
        #expect(!model.coordinator.isArmed && model.profile.isEmpty && review.profileSaved)
        #expect(await vault.loadCount() == 0)
        try export(summary, name: "arming-plan-phone.png")
    }

    @Test func adapterReviewUsesWhenReadySemanticsAndKeepsTheArmingActionsVisible() async throws {
        let variants = [ProductVariant(id: CatalogProduct.adapterSKU, name: "Synthetic Headphone Adapter", storage: "", color: "", productURL: CatalogProduct.adapterURL)]
        let stores = stores(count: 1), preferences = try configuration(variants: variants, stores: stores, adapter: true)
        let model = model(configuration: preferences, variants: variants, stores: stores)
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        defer { model.cancelArmingReview() }
        let surface = try await render(ArmingReviewView(model: model, review: review), size: NSSize(width: 660, height: 640))
        defer { surface.window.close() }
        let top = try read(surface).text
        #expect(top.contains("review before arming") && top.contains("confirm and arm") && top.contains("cancel"))
        #expect(top.contains("confirming permits one pickup order") && top.contains("payment confirmation"))
        try await scroll(surface, toBottom: true)
        let bottom = try read(surface).text
        #expect(bottom.contains("pickup when apple confirms ready") && bottom.contains("no reserved date or time"))
        #expect(!bottom.contains("daily pickup hours") && !bottom.contains("earliest pickup"))
        #expect(bottom.contains("confirm and arm") && bottom.contains("cancel"))
        #expect(!model.coordinator.isArmed && model.pendingArmingReview?.id == review.id)
        try export(surface, name: "arming-plan-adapter.png")
    }

    @Test func longReviewScrollsAtMinimumHeightWhileConfirmationAndCancelRemainReachable() async throws {
        let variants = variants(count: 8), stores = stores(count: 8)
        let model = model(configuration: try configuration(variants: variants, stores: stores), variants: variants, stores: stores)
        model.requestArmingReview()
        let review = try #require(model.pendingArmingReview)
        defer { model.cancelArmingReview() }
        let surface = try await render(ArmingReviewView(model: model, review: review), size: NSSize(width: 560, height: 480))
        defer { surface.window.close() }
        let scrolls = descendants(surface.controller.view).compactMap { $0 as? NSScrollView }
        #expect(scrolls.contains { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 100 })
        for bottom in [false, true] {
            try await scroll(surface, toBottom: bottom)
            let reading = try read(surface)
            #expect(reading.text.contains("confirm and arm") && reading.text.contains("cancel"))
            #expect(reading.lines.contains { $0.text.contains("confirm and arm") && $0.bounds.maxY < 0.3 })
            #expect(reading.lines.contains { $0.text == "cancel" && $0.bounds.maxY < 0.3 })
            if bottom {
                #expect(reading.text.contains("checkout profile saved in keychain") && reading.text.contains("preparation failure limit"))
            } else {
                #expect(reading.text.contains("synthetic duo 8"))
            }
        }
        #expect(!model.coordinator.isArmed)
        try export(surface, name: "arming-review-minimum.png")
    }

    @Test func observationRendersActualCheckLifecycleMissingRowsAndStaleFailure() async throws {
        let variants = variants(), stores = stores(), vault = MonitorRenderVault(), driver = MonitorRenderDriver()
        let preferences = try configuration(variants: variants, stores: stores)
        let responses = [StoreAvailability(storeID: stores[1].id, variantID: variants[1].id, state: .disabled, message: "Synthetic pickup disabled quote"),
                         StoreAvailability(storeID: stores[0].id, variantID: variants[1].id, state: .unavailable, message: "Synthetic unavailable quote"),
                         StoreAvailability(storeID: stores[1].id, variantID: variants[0].id, state: .disabled, message: "Synthetic duplicate one"),
                         StoreAvailability(storeID: stores[1].id, variantID: variants[0].id, state: .unavailable, message: "Synthetic duplicate two")]
        let inventory = MonitorRenderInventory(InventorySnapshot(stores: stores, availability: responses))
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: driver, vault: vault,
                                                journalStore: KeychainJournalStore(vault: vault), now: { monitorRenderNow })
        let surface = try await render(ScrollView { MonitoringObservationView(coordinator: coordinator).padding(24) }, size: NSSize(width: 960, height: 1260))
        defer { coordinator.stop(); surface.window.close() }
        #expect(try read(surface).text.contains("no armed monitoring plan yet"))
        try await coordinator.arm(configuration: preferences, variants: variants, stores: stores, location: "Synthetic location", runContinuously: false)
        try await settle(surface)
        let waiting = try read(surface).text
        #expect(waiting.contains("observing the confirmed monitoring plan") && waiting.contains("checks started: 0"))
        #expect(waiting.contains("no successful monitoring response yet") && waiting.contains("not checked yet"))
        await inventory.configure(suspend: true)
        let cycle = Task { await coordinator.performCycle() }
        for _ in 0..<1000 { if await inventory.isSuspended() { break }; await Task.yield() }
        try #require(await inventory.isSuspended())
        try await settle(surface)
        let checking = try read(surface).text
        #expect(checking.contains("checking apple now") && checking.contains("check 1"))
        #expect(checking.contains("previous successful check") && checking.contains("latest check started"))
        #expect(coordinator.isCheckingInventory && coordinator.checkCount == 1)
        await inventory.release(); await cycle.value
        try await settle(surface)
        let success = try read(surface).text
        #expect(success.contains("checks started: 1") && success.contains("last successful check"))
        #expect(success.contains("pickup disabled") && success.contains("unavailable") && success.contains("unverified"))
        #expect(success.contains("did not return this selected") && success.contains("more than one response"))
        #expect(success.contains("synthetic pickup disabled quote") && success.contains("synthetic unavailable quote"))
        order(success, "synthetic duo 2", before: "synthetic duo 1")
        #expect(coordinator.snapshot?.availability == responses && !coordinator.isCheckingInventory && driver.preparations == 0)
        try export(surface, name: "monitoring-observation.png")
        await inventory.configure(fail: true)
        await coordinator.performCycle(); try await settle(surface)
        let failure = try read(surface).text
        #expect(failure.contains("checks started: 2") && failure.contains("latest check did not succeed"))
        #expect(failure.contains("http 503") && failure.contains("previous results") && failure.contains("not a fresh availability response"))
        #expect(failure.contains("last successful check") && failure.contains("synthetic unavailable quote"))
        #expect(coordinator.snapshot?.availability == responses && coordinator.lastCheckError != nil)
        coordinator.stop(); try await settle(surface)
        let stopped = try read(surface).text
        #expect(stopped.contains("disarmed") && stopped.contains("monitoring is stopped") && stopped.contains("retained results"))
        #expect(!stopped.contains("checking apple now") && !coordinator.isArmed)
        try export(surface, name: "monitoring-observation-stale.png")
    }

    @Test func availableObservationIsAnEligibilityQuoteAndCannotSubmitFromRendering() async throws {
        let variants = variants(count: 1), stores = stores(count: 1), vault = MonitorRenderVault(), driver = MonitorRenderDriver()
        let preferences = try configuration(variants: variants, stores: stores)
        let inventory = MonitorRenderInventory(InventorySnapshot(stores: stores, availability: [
            StoreAvailability(storeID: stores[0].id, variantID: variants[0].id, state: .available, message: "Synthetic ready-for-pickup eligibility")
        ]))
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: driver, vault: vault,
                                                journalStore: KeychainJournalStore(vault: vault), now: { monitorRenderNow })
        defer { coordinator.stop() }
        try await coordinator.arm(configuration: preferences, variants: variants, stores: stores, location: "Synthetic location", runContinuously: false)
        await coordinator.performCycle()
        let surface = try await render(ScrollView { MonitoringObservationView(coordinator: coordinator).padding(24) }, size: NSSize(width: 960, height: 740))
        defer { surface.window.close() }
        let text = try read(surface).text
        #expect(text.contains("pickup available") && text.contains("synthetic ready-for-pickup eligibility"))
        #expect(text.contains("not a unit count") && text.contains("one item maximum"))
        #expect(driver.preparations == 1 && coordinator.status == .failed && !coordinator.isArmed && coordinator.journal.phase == .idle)
    }
}
