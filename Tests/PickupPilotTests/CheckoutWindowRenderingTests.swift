import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
import WebKit
import Vision
@testable import PickupPilot

private struct CheckoutWindowPreferences: PreferencesStore {
    func load() -> PilotPreferences { PilotPreferences() }
    func save(_ preferences: PilotPreferences) { Issue.record("Checkout rendering must not save production preferences.") }
}
private actor CheckoutWindowVault: SecureVault {
    private let orderState: Data?
    init(journal: PurchaseJournal? = nil) throws {
        orderState = try journal.map { try JSONEncoder().encode($0) }
    }
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? {
        SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid", phone: "+14165550100",
                      cardholder: "Synthetic Tester", cardNumber: "4111111111111111", expiryMonth: "12", expiryYear: "2035", cvv: "123",
                      billingLine1: "1 Synthetic Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
    }
    func deleteProfile() {}
    func saveSession(_ data: Data) {}
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { orderState }
    func deleteOrderState() {}
    func clear() {}
}
private actor CheckoutWindowInventory: InventoryProviding {
    func fetch(market: Market, location: String, variants: [ProductVariant]) -> InventorySnapshot {
        InventorySnapshot(stores: [RetailStore(id: "R121", name: "Synthetic store", countryCode: "CA")],
                          availability: variants.map { StoreAvailability(storeID: "R121", variantID: $0.id, state: .available, message: "Synthetic stock") })
    }
}
@MainActor private final class CheckoutWindowAuthDriver: CheckoutDriver {
    private(set) var preparations = 0
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        preparations += 1
        throw CheckoutError.authenticationRequired
    }
    func submit(review: CheckoutReview) -> CheckoutOutcome {
        Issue.record("Synthetic auth-window rendering must never submit an order.")
        return .indeterminate(reason: "Rendering fixture")
    }
    func cancel() {}
}

@Suite(.serialized) @MainActor struct CheckoutWindowRenderingTests {
    private struct Surface { let controller: NSHostingController<AnyView>; let window: NSWindow }
    private func host(_ model: PilotModel) -> Surface {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: AnyView(CheckoutWindow(model: model).environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor))))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 860, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 650)
        window.appearance = NSAppearance(named: .aqua)
        controller.view.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 860, height: 650))
        if model.checkout.browserKind == .embeddedFixture { window.orderFront(nil) }
        return Surface(controller: controller, window: window)
    }
    private func settle(_ view: NSView) async throws {
        for _ in 0..<5 {
            view.window?.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func headerControls(in view: NSView) -> [NSView] {
        descendants(view).filter {
            let frame = $0.convert($0.bounds, to: view)
            return $0.canBecomeKeyView && frame.midY < 60 && frame.width > 30 && frame.height > 10
        }.sorted { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX }
    }
    private func verifyContent(_ controller: NSHostingController<AnyView>, model: PilotModel) throws {
        let view = controller.view
        #expect(view.bounds.width >= 760 && view.bounds.height >= 600)
        let fitting = controller.sizeThatFits(in: NSSize(width: 860, height: 650))
        #expect(fitting.width.isFinite && fitting.height.isFinite && fitting.width <= 860 && fitting.height <= 650)
        let webViews = descendants(view).compactMap { $0 as? WKWebView }
        #expect(webViews.count == 1 && webViews[0] === model.checkout.webView)
        #expect(webViews[0].bounds.width > 700 && webViews[0].bounds.height > 400)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect((bitmap.representation(using: .png, properties: [:])?.count ?? 0) > 3000)
        #expect(!model.checkout.webView.configuration.websiteDataStore.isPersistent)
    }
    private func embeddedFixtureDriver(vault: any SecureVault) -> AppleCheckoutDriver {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        return AppleCheckoutDriver(vault: vault, page: page, webView: page.webView)
    }
    private func authenticationFixture() async throws -> (PilotModel, CheckoutWindowAuthDriver, MonitoringCoordinator, Surface) {
        let vault = try CheckoutWindowVault()
        let driver = CheckoutWindowAuthDriver()
        let coordinator = MonitoringCoordinator(inventory: CheckoutWindowInventory(), driver: driver, vault: vault, journalStore: KeychainJournalStore(vault: vault))
        let model = PilotModel(vault: vault, preferencesStore: CheckoutWindowPreferences(), smoke: true, checkout: embeddedFixtureDriver(vault: vault), coordinator: coordinator)
        let variant = ProductVariant(id: "SYNTHETIC/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky",
                                     productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!)
        var configuration = PilotPreferences()
        configuration.selectedVariantIDs = [variant.id]; configuration.selectedStoreIDs = ["R121"]
        try await coordinator.arm(configuration: configuration, variants: [variant], stores: [RetailStore(id: "R121", name: "Synthetic store", countryCode: "CA")], location: "Synthetic location", runContinuously: false)
        await coordinator.performCycle()
        #expect(coordinator.status == .failed && !coordinator.isArmed && driver.preparations == 1)
        return (model, driver, coordinator, host(model))
    }
    @Test func nativePrivateCheckoutWindowRendersAndUpdatesSameWebView() async throws {
        let vault = try CheckoutWindowVault()
        let model = PilotModel(vault: vault, preferencesStore: CheckoutWindowPreferences(), smoke: true, checkout: embeddedFixtureDriver(vault: vault))
        let surface = host(model)
        let controller = surface.controller
        defer { surface.window.close() }
        try await settle(controller.view)
        try verifyContent(controller, model: model)
        controller.rootView = AnyView(CheckoutWindow(model: model).environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        try await settle(controller.view)
        try verifyContent(controller, model: model)
        #expect(!model.coordinator.isArmed && model.coordinator.status == .stopped)
        #expect(model.profile.isEmpty)
    }
    @Test func productionSafariWindowRendersStatusWithoutConstructingOrEmbeddingWebKit() async throws {
        let vault = try CheckoutWindowVault()
        let model = PilotModel(vault: vault, preferencesStore: CheckoutWindowPreferences(), smoke: true)
        #expect(model.checkout.browserKind == .safari && !model.checkout.hasEmbeddedBrowser)
        let surface = host(model)
        defer { surface.window.close() }
        try await settle(surface.controller.view)
        let view = surface.controller.view
        #expect(descendants(view).compactMap { $0 as? WKWebView }.isEmpty)
        #expect(!model.checkout.hasEmbeddedBrowser)
        let fitting = surface.controller.sizeThatFits(in: NSSize(width: 860, height: 650))
        #expect(fitting.width <= 860 && fitting.height <= 650)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 3000)
        if ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_PREVIEWS"] == "1" { try png.write(to: URL(fileURLWithPath: "/private/tmp/pickup-pilot-safari-window.png")) }
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        recognition.minimumTextHeight = 0.006
        try VNImageRequestHandler(data: png).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        #expect(text.contains("safari"))
        #expect(text.contains("guest"))
        #expect(!model.coordinator.isArmed && !model.checkout.hasEmbeddedBrowser)
    }
    @Test func guestOnlyFailureRendersRecoveryControlsWithoutAuthentication() async throws {
        let (model, driver, coordinator, surface) = try await authenticationFixture()
        defer { coordinator.stop(); surface.window.close() }
        try await settle(surface.controller.view)
        try verifyContent(surface.controller, model: model)
        // This fixture is a disarmed preview: the recovery controls are rendered
        // but disabled, so there must be no keyboard-actionable header button.
        #expect(!model.canSaveResolvedAppleSession)
        #expect(headerControls(in: surface.controller.view).isEmpty)
        #expect(coordinator.status == .failed && !coordinator.isArmed && driver.preparations == 1)
    }
    @Test func uncertainOrderRendersReconciliationActionWithoutResubmission() async throws {
        let vault = try CheckoutWindowVault(journal: PurchaseJournal(phase: .uncertain))
        let driver = CheckoutWindowAuthDriver()
        let coordinator = MonitoringCoordinator(inventory: CheckoutWindowInventory(), driver: driver, vault: vault, journalStore: KeychainJournalStore(vault: vault))
        await coordinator.restoreJournal()
        #expect(coordinator.status == .uncertain && coordinator.journal.blocksPurchase)
        let model = PilotModel(vault: vault, preferencesStore: CheckoutWindowPreferences(), smoke: true, checkout: embeddedFixtureDriver(vault: vault), coordinator: coordinator)
        let surface = host(model)
        defer { surface.window.close() }
        try await settle(surface.controller.view)
        try verifyContent(surface.controller, model: model)
        #expect(headerControls(in: surface.controller.view).count == 1)
        #expect(model.error == nil)
        #expect(coordinator.status == .uncertain && coordinator.journal.blocksPurchase && !coordinator.isArmed)
        #expect(driver.preparations == 0)
    }
}
