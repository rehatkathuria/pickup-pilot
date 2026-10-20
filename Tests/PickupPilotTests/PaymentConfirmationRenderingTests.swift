import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
import Vision
import WebKit
@testable import PickupPilot

private struct PaymentConfirmationPreferences: PreferencesStore {
    func load() -> PilotPreferences { PilotPreferences() }
    func save(_ preferences: PilotPreferences) { Issue.record("Rendering must not save preferences.") }
}

private actor PaymentConfirmationVault: SecureVault {
    private(set) var submissionIntents = 0
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? {
        SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid", phone: "+14165550100",
                      cardholder: "Synthetic Tester", cardNumber: "4111111111111111", expiryMonth: "12", expiryYear: "2099", cvv: "123",
                      billingLine1: "1 Synthetic Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
    }
    func deleteProfile() {}
    func saveSession(_ data: Data) {}
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) { submissionIntents += 1; Issue.record("Rendering must stop before submission intent.") }
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() {}
}

private actor PaymentConfirmationInventory: InventoryFetching {
    func fetch(market: Market, location: String, variants: [ProductVariant]) -> InventorySnapshot {
        InventorySnapshot(stores: [RetailStore(id: "R121", name: "Synthetic store", countryCode: "CA")],
                          availability: variants.map { StoreAvailability(storeID: "R121", variantID: $0.id, state: .available, message: "Synthetic stock") })
    }
}

@MainActor private final class PaymentConfirmationPage: AppleCheckoutPage {
    let webView: WKWebView
    let evidence: CheckoutSnapshot
    private(set) var placeCalls = 0
    init(finalReview: Bool, now: Date) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let formatter = ISO8601DateFormatter()
        evidence = CheckoutSnapshot(sourceURL: "https://secure6.store.apple.com/ca/shop/checkout",
                                    phase: finalReview ? .review : .payment, productIDs: ["SYNTHETIC/A"], storeIDs: ["R121"], quantities: [1],
                                    totalText: "CA$3,388.87", currencyCode: "CAD",
                                    pickupStartISO: formatter.string(from: now.addingTimeInterval(86400)),
                                    pickupEndISO: formatter.string(from: now.addingTimeInterval(87300)),
                                    pickupSlot: "Synthetic 15 minute slot", finalActionCount: finalReview ? 1 : 0,
                                    hasErrors: !finalReview, pickupOnly: true,
                                    documentID: "00000000-0000-4000-8000-000000000001", reviewStateID: "00000000-0000-4000-8000-000000000002")
    }
    func load(_ url: URL) {} // Preparation is real; the browser boundary never requests the network.
    func snapshot() -> CheckoutSnapshot { evidence }
    func advance(request: CheckoutRequest, profile: SecureProfile) -> Bool { false }
    func placeOrder(expected: CheckoutSnapshot) -> Bool {
        placeCalls += 1; Issue.record("The native rendering fixture must never submit."); return false
    }
    func restoreSession(_ data: Data?) {}
    func sessionData() -> Data { Data("[]".utf8) }
    func cancel() {}
}

@MainActor private enum PaymentConfirmationClock {
    static func pause() async throws {}
}

@Suite(.serialized) @MainActor struct PaymentConfirmationRenderingTests {
    private struct Fixture {
        let model: PilotModel
        let driver: AppleCheckoutDriver
        let coordinator: MonitoringCoordinator
        let page: PaymentConfirmationPage
        let vault: PaymentConfirmationVault
        let request: CheckoutRequest
    }
    private struct Surface { let window: NSWindow; let controller: NSHostingController<AnyView>; let size: NSSize }

    private func fixture(finalReview: Bool) async throws -> Fixture {
        let now = Date(), vault = PaymentConfirmationVault()
        let page = PaymentConfirmationPage(finalReview: finalReview, now: now)
        let driver = AppleCheckoutDriver(vault: vault, page: page, webView: page.webView, now: { now }, sleep: PaymentConfirmationClock.pause)
        let inventory = PaymentConfirmationInventory()
        let coordinator = MonitoringCoordinator(inventory: inventory, driver: driver, vault: vault, journalStore: KeychainJournalStore(vault: vault), now: { now })
        let variant = ProductVariant(id: "SYNTHETIC/A", name: "Synthetic Duo", storage: "256GB", color: "Night Sky",
                                     productURL: URL(string: "https://www.apple.com/ca/shop/buy-iphone/iphone-duo/synthetic")!)
        let store = RetailStore(id: "R121", name: "Synthetic store", countryCode: "CA")
        var preferences = PilotPreferences()
        preferences.selectedVariantIDs = [variant.id]; preferences.selectedStoreIDs = [store.id]
        preferences.attemptWindow = DateWindow(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600))
        preferences.pickupWindow = DateWindow(start: now, end: now.addingTimeInterval(172800))
        preferences.timeZoneIdentifier = "UTC"
        try await coordinator.arm(configuration: preferences, variants: [variant], stores: [store], location: "Synthetic location", runContinuously: false)
        let model = PilotModel(vault: vault, preferencesStore: PaymentConfirmationPreferences(), smoke: true, inventory: inventory, checkout: driver, coordinator: coordinator)
        let request = CheckoutRequest(variant: variant, store: store, market: .ca, maximumTotal: preferences.maximumTotal,
                                      pickupWindow: preferences.pickupWindow, timeZoneIdentifier: "UTC",
                                      attemptWindow: preferences.attemptWindow)
        return Fixture(model: model, driver: driver, coordinator: coordinator, page: page, vault: vault, request: request)
    }
    private func host<V: View>(_ view: V, size: NSSize) async throws -> Surface {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: AnyView(view.environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_CA")).background(Color(nsColor: .windowBackgroundColor))
            .transaction { $0.animation = nil }))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false
        window.contentViewController = controller; controller.view.frame = NSRect(origin: .zero, size: size)
        try await settle(controller.view)
        return Surface(window: window, controller: controller, size: size)
    }
    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 {
            view.window?.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func visibleText(_ surface: Surface) throws -> String {
        let view = surface.controller.view, fit = surface.controller.sizeThatFits(in: surface.size)
        #expect(fit.width.isFinite && fit.height.isFinite && fit.width <= surface.size.width + 1 && fit.height <= surface.size.height + 1)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect((bitmap.representation(using: .png, properties: [:])?.count ?? 0) > 3000)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]; request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
    }

    @Test(arguments: [false, true]) func nativeHandoffDistinguishesRequiredFieldsFromPaymentAuthorization(finalReview: Bool) async throws {
        let fixture = try await fixture(finalReview: finalReview)
        let checkout = try await host(CheckoutWindow(model: fixture.model), size: NSSize(width: 960, height: 740))
        let overview = try await host(ScrollView { VStack(alignment: .leading, spacing: 22) { OverviewView(model: fixture.model) }.padding(28) },
                                      size: NSSize(width: 960, height: 1100))
        defer { fixture.coordinator.stop(); checkout.window.close(); overview.window.close() }
        #expect(!fixture.driver.requiresPaymentConfirmation)
        for surface in [checkout, overview] {
            let text = try visibleText(surface)
            #expect(!text.contains("confirm payment and allow order"))
        }
        #expect(try !visibleText(checkout).contains("save resolved apple session"))
        await fixture.coordinator.performCycle()
        #expect(fixture.coordinator.status == .manualInputRequired && fixture.coordinator.isArmed)
        #expect(fixture.driver.requiresPaymentConfirmation == finalReview)
        for surface in [checkout, overview] {
            // Keep the same hosting controllers: coordinator observation must update the actual native view.
            try await settle(surface.controller.view)
            let text = try visibleText(surface)
            #expect(text.contains("complete required checkout fields") && text.contains("confirm the payment method"))
            if finalReview {
                #expect(text.components(separatedBy: "confirm payment and allow order").count - 1 == 1)
                #expect(!text.contains("continue checkout"))
                #expect(text.contains("this confirmation permits one authorized order"))
            } else {
                #expect(text.components(separatedBy: "continue checkout").count - 1 == 1)
                #expect(!text.contains("confirm payment and allow order"))
                #expect(!text.contains("this confirmation permits one authorized order"))
            }
        }
        #expect(fixture.page.placeCalls == 0 && fixture.coordinator.journal.phase == .idle)
        #expect(await fixture.vault.submissionIntents == 0)
        fixture.coordinator.stop()
        #expect(!fixture.driver.requiresPaymentConfirmation)
        for surface in [checkout, overview] {
            try await settle(surface.controller.view)
            let text = try visibleText(surface)
            #expect(!text.contains("confirm payment and allow order"))
        }
        let recoveryText = try visibleText(checkout)
        #expect(recoveryText.contains("save resolved apple session"))
        #expect(recoveryText.contains("this same checkout window") && recoveryText.contains("before starting a new attempt"))
        #expect(recoveryText.contains("saving never arms checkout or places an order"))
    }

    @Test func securityRendersExplicitSessionRecoveryWithoutChangingCheckoutState() async throws {
        let fixture = try await fixture(finalReview: false)
        fixture.coordinator.stop()
        let security = try await host(ScrollView { VStack(alignment: .leading, spacing: 22) { SecurityView(model: fixture.model) }.padding(28) },
                                      size: NSSize(width: 960, height: 1100))
        defer { security.window.close() }
        let text = try visibleText(security)
        #expect(text.contains("open apple checkout") && text.contains("verify safari session"))
        #expect(text.contains("working page") && text.contains("safari window"))
        #expect(text.contains("never asks you to sign in") && text.contains("the attempt stops"))
        #expect(text.contains("verification never arms checkout or places an order"))
        #expect(text.contains("reset safari checkout window") && text.contains("never exports safari cookies"))
        #expect(!text.contains("confirm payment and allow order"))
        #expect(!fixture.coordinator.isArmed && fixture.coordinator.journal.phase == .idle && fixture.page.placeCalls == 0)
        #expect(await fixture.vault.submissionIntents == 0)
    }

    @Test func driverPaymentConfirmationFlagClearsAfterConfirmationAndCancellation() async throws {
        let fixture = try await fixture(finalReview: true)
        defer { fixture.coordinator.stop() }
        #expect(!fixture.driver.requiresPaymentConfirmation)
        await fixture.coordinator.performCycle()
        #expect(fixture.driver.requiresPaymentConfirmation)
        _ = try await fixture.driver.prepare(request: fixture.request, profile: SecureProfile())
        #expect(!fixture.driver.requiresPaymentConfirmation)
        fixture.driver.cancel()
        await #expect(throws: CheckoutError.manualInputRequired) { try await fixture.driver.prepare(request: fixture.request, profile: SecureProfile()) }
        #expect(fixture.driver.requiresPaymentConfirmation)
        fixture.driver.cancel()
        #expect(!fixture.driver.requiresPaymentConfirmation && fixture.page.placeCalls == 0)
        #expect(await fixture.vault.submissionIntents == 0)
    }
}
