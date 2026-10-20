import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
import Vision
import WebKit
@testable import PickupPilot

private struct StateRenderingPreferences: PreferencesStore {
    func load() -> PilotPreferences { PilotPreferences() }
    func save(_ preferences: PilotPreferences) { Issue.record("Rendering fixtures must not save production preferences.") }
}
private func stateRenderingProfile() -> SecureProfile {
    SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid", phone: "+14165550100",
                  cardholder: "Synthetic Tester", cardNumber: "4111111111111111", expiryMonth: "12", expiryYear: "2035", cvv: "123",
                  billingLine1: "1 Synthetic Street", billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
}
private actor StateRenderingVault: SecureVault {
    var journal: Data?
    init(_ journal: PurchaseJournal? = nil) throws { self.journal = try journal.map { try JSONEncoder().encode($0) } }
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { stateRenderingProfile() }
    func deleteProfile() {}
    func saveSession(_ data: Data) {}
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) { journal = data }
    func loadOrderState() -> Data? { journal }
    func deleteOrderState() { journal = nil }
    func clear() { journal = nil }
}
private let stateVariant = ProductVariant(id: "SYNTHETIC/A", name: "Synthetic Duo 256GB Night Sky", storage: "256GB", color: "Night Sky",
                                          productURL: Market.ca.productBaseURL.appendingPathComponent("synthetic"))
private let stateStores = [RetailStore(id: "R121", name: "Synthetic Eaton Store", latitude: 43.65, longitude: -79.38, address: "Toronto, Ontario", countryCode: "CA"),
                           RetailStore(id: "R120", name: "Synthetic Yorkdale Store", latitude: 43.72, longitude: -79.45, address: "Toronto, Ontario", countryCode: "CA")]
private actor StateRenderingCatalog: ProductCatalogFetching {
    func variants(market: Market) -> [ProductVariant] { [stateVariant] }
}
private actor StateRenderingInventory: InventoryFetching {
    let state: AvailabilityState
    init(state: AvailabilityState = .disabled) { self.state = state }
    func fetch(market: Market, location: String, variants: [ProductVariant]) -> InventorySnapshot {
        InventorySnapshot(stores: stateStores, availability: stateStores.flatMap { store in
            variants.map { StoreAvailability(storeID: store.id, variantID: $0.id, state: state, message: "Synthetic pickup quote") }
        })
    }
}
@MainActor private final class StateRenderingLocation: LocationDetecting {
    let status = "Synthetic physical location"
    let requesting = false
    func locate() -> DetectedLocation { DetectedLocation(countryCode: "CA", query: "Toronto", latitude: 43.65, longitude: -79.38) }
}
private enum StateRenderingTravelFailure: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "Synthetic travel unavailable" }
}
@MainActor private final class StateRenderingTravel: StoreTravelProviding {
    func origin(for query: String, market: Market) async throws -> Coordinate {
        throw StateRenderingTravelFailure.unavailable
    }
    func drivingRoute(from origin: Coordinate, to destination: Coordinate) async throws -> DrivingRoute {
        DrivingRoute(distanceKilometers: 6, expectedTravelSeconds: 900)
    }
}
@MainActor private final class StateRenderingAuthDriver: CheckoutDriver {
    var preparations = 0
    var failure = CheckoutError.authenticationRequired
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        preparations += 1
        throw failure
    }
    func submit(review: CheckoutReview) -> CheckoutOutcome {
        Issue.record("A rendering fixture must never submit an order.")
        return .indeterminate(reason: "Rendering only")
    }
    func cancel() {}
}
private enum StateRenderingRehearsalMode { case manual, blocked, pageNotFound, review }
@MainActor private final class StateRenderingRehearsalDriver: CheckoutRehearsalPreparing {
    let mode: StateRenderingRehearsalMode
    let diagnostics: CheckoutPageDiagnostics?
    let browserKind: CheckoutBrowserKind
    private(set) var preparations = 0
    init(_ mode: StateRenderingRehearsalMode, diagnostics: CheckoutPageDiagnostics? = nil,
         browserKind: CheckoutBrowserKind = .embeddedFixture) {
        self.mode = mode; self.diagnostics = diagnostics; self.browserKind = browserKind
    }
    func prepare(request: CheckoutRequest, profile: SecureProfile) throws -> CheckoutReview {
        preparations += 1
        switch mode {
        case .manual: throw CheckoutError.manualInputRequired
        case .blocked: throw CheckoutError.storefrontBlocked
        case .pageNotFound: throw CheckoutError.pageNotFound
        case .review:
            let pickup = Date().addingTimeInterval(86_400)
            return CheckoutReview(variantID: request.variant.id, storeID: request.store.id, quantity: 1,
                                  total: Decimal(string: "3388.87")!, currencyCode: "CAD", pickupDate: pickup,
                                  pickupEndDate: pickup.addingTimeInterval(900), pickupSlot: "Synthetic 10:00 to 10:15",
                                  expiresAt: Date().addingTimeInterval(600))
        }
    }
    func cancel() {}
}
private enum StateRenderingClock {
    static func sleep(_ seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

@Suite(.serialized) @MainActor struct StateRenderingTests {
    private struct Surface {
        let window: NSWindow
        let controller: NSHostingController<AnyView>
        let size: NSSize
    }
    private func model(coordinator: MonitoringCoordinator? = nil, vault: (any SecureVault)? = nil,
                       rehearsal: CheckoutRehearsal? = nil, checkout: AppleCheckoutDriver? = nil) throws -> PilotModel {
        PilotModel(vault: try vault ?? StateRenderingVault(), preferencesStore: StateRenderingPreferences(), smoke: true,
                   catalog: StateRenderingCatalog(), inventory: StateRenderingInventory(), locationService: StateRenderingLocation(), travelService: StateRenderingTravel(),
                   checkout: checkout, rehearsal: rehearsal, coordinator: coordinator)
    }
    private func render<V: View>(_ view: V, size: NSSize = NSSize(width: 960, height: 980)) async throws -> Surface {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: AnyView(view.environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_CA"))
            .background(Color(nsColor: .windowBackgroundColor)).transaction { $0.animation = nil }))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        let surface = Surface(window: window, controller: controller, size: size)
        try await settle(controller.view)
        let fit = controller.sizeThatFits(in: size)
        #expect(fit.width.isFinite && fit.height.isFinite && fit.width > 0 && fit.height > 0)
        #expect(fit.width <= size.width + 1 && fit.height <= size.height + 1)
        return surface
    }
    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 {
            view.window?.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func visibleText(_ surface: Surface) throws -> String {
        let view = surface.controller.view
        #expect(view.bounds.size == surface.size)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(surface.size.width) && bitmap.pixelsHigh >= Int(surface.size.height))
        #expect((bitmap.representation(using: .png, properties: [:])?.count ?? 0) > 3_000)
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            .lowercased().replacingOccurrences(of: "’", with: "'")
        #expect(text.count > 20, "The native bitmap must contain readable content.")
        return text
    }
    private func failureComment(_ text: String) -> Comment {
        Comment(rawValue: "Synthetic native OCR text: \(text)")
    }
    private func exportPreviewIfRequested(_ surface: Surface, filename: String = "checkout-test.png") throws {
        guard ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_PREVIEWS"] == "1" else { return }
        let view = surface.controller.view
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("outputs/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(filename))
    }
    private func configuration() -> PilotPreferences {
        var configuration = PilotPreferences()
        configuration.selectedStoreIDs = ["R121"]; configuration.selectedVariantIDs = [stateVariant.id]
        return configuration
    }
    @Test func lowCostProductPickerAndUnscheduledPickupRenderInTheActualSetupPages() async throws {
        let model = try model()
        model.selectCatalogProduct(.usbCHeadphoneAdapter)
        model.variants = [ProductVariant(id: CatalogProduct.adapterSKU, name: "USB-C to 3.5mm Headphone Jack Adapter · CA$10.00", storage: "", color: "", productURL: CatalogProduct.adapterURL)]
        model.preferences.selectedVariantIDs = [CatalogProduct.adapterSKU]
        model.preferences.maximumTotal = 12
        let products = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { StoreSetupView(model: model) }.padding(28) }, size: NSSize(width: 960, height: 1200))
        defer { products.window.close() }
        let productText = try visibleText(products)
        #expect(productText.contains("headphone jack adapter") && productText.contains("10.00"))
        #expect(productText.contains("no reserved time") && productText.contains("saved checkout profile"))
        try exportPreviewIfRequested(products, filename: "low-cost-product.png")
        let schedule = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { ScheduleView(model: model) }.padding(28) }, size: NSSize(width: 960, height: 1100))
        defer { schedule.window.close() }
        let scheduleText = try visibleText(schedule)
        #expect(scheduleText.contains("pickup when ready") && scheduleText.contains("no reserved time"))
        #expect(!scheduleText.contains("earliest pickup") && !scheduleText.contains("latest pickup"))
        #expect(scheduleText.contains("begin attempting") && scheduleText.contains("maximum final total"))
        #expect(!model.coordinator.isArmed && model.preferences.maximumTotal == 12)
        try exportPreviewIfRequested(schedule, filename: "low-cost-schedule.png")
    }
    private func restored(_ phase: PurchaseJournal.Phase, receipt: Bool = false) async throws -> PilotModel {
        let start = Date().addingTimeInterval(8 * 86_400)
        let request = CheckoutRequest(variant: stateVariant, store: stateStores[0], market: .ca, maximumTotal: 4000)
        let review = CheckoutReview(variantID: stateVariant.id, storeID: "R121", quantity: 1, total: Decimal(string: "3388.87")!, currencyCode: "CAD",
                                    pickupDate: start, pickupEndDate: start.addingTimeInterval(900), pickupSlot: "10:00–10:15", expiresAt: start)
        let journal = PurchaseJournal(phase: phase, attemptID: UUID(), orderID: receipt ? "W1234567890" : nil,
                                      variantID: receipt ? stateVariant.id : nil, storeID: receipt ? "R121" : nil,
                                      receipt: receipt ? PurchaseReceipt(request: request, review: review) : nil)
        let vault = try StateRenderingVault(journal)
        let coordinator = MonitoringCoordinator(inventory: StateRenderingInventory(), driver: StateRenderingAuthDriver(), vault: vault,
                                                journalStore: KeychainJournalStore(vault: vault))
        await coordinator.restoreJournal()
        let model = try model(coordinator: coordinator, vault: vault)
        model.hasSavedProfile = true
        return model
    }

    @Test func confirmedReceiptAndUncertainJournalRenderActualOrderState() async throws {
        let confirmed = try await restored(.confirmed, receipt: true)
        let receipt = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { ActivityView(model: confirmed) }.padding(28) })
        defer { receipt.window.close() }
        let text = try visibleText(receipt)
        #expect(text.contains("order confirmed"))
        #expect(text.contains("synthetic duo") && text.contains("synthetic eaton store"))
        #expect(text.contains("3388.87") || text.contains("3,388.87"))
        #expect(text.contains("reveal") && text.contains("reset purchase lock"))
        #expect(!text.contains("w1234567890"))
        #expect(confirmed.coordinator.journal.blocksPurchase && !confirmed.coordinator.isArmed)
        let uncertain = try await restored(.uncertain)
        let locked = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { ActivityView(model: uncertain) }.padding(28) })
        defer { locked.window.close() }
        let lockText = try visibleText(locked)
        #expect(lockText.contains("order needs reconciliation"))
        #expect(lockText.contains("check visible confirmation") && lockText.contains("reset purchase lock"))
        #expect(uncertain.coordinator.journal.blocksPurchase && uncertain.error == nil)
    }

    @Test func overviewRendersGuestOnlyStopConfirmedUncertainAndReadiness() async throws {
        let vault = try StateRenderingVault()
        let driver = StateRenderingAuthDriver()
        let coordinator = MonitoringCoordinator(inventory: StateRenderingInventory(state: .available), driver: driver, vault: vault,
                                                journalStore: KeychainJournalStore(vault: vault))
        try await coordinator.arm(configuration: configuration(), variants: [stateVariant], stores: stateStores,
                                  location: "Synthetic location", runContinuously: false)
        await coordinator.performCycle()
        let authentication = try model(coordinator: coordinator, vault: vault)
        authentication.hasSavedProfile = true
        let auth = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { OverviewView(model: authentication) }.padding(28) })
        defer { coordinator.stop(); auth.window.close() }
        let authText = try visibleText(auth)
        #expect(authText.contains("guest checkout") && authText.contains("stopped"))
        #expect(!authText.contains("open apple authentication") && !authText.contains("continue after authentication"))
        #expect(driver.preparations == 1 && !coordinator.isArmed && coordinator.status == .failed)
        let checkout = try await render(CheckoutWindow(model: authentication), size: NSSize(width: 1100, height: 900))
        defer { checkout.window.close() }
        let checkoutText = try visibleText(checkout)
        #expect(checkoutText.contains("guest checkout") && checkoutText.contains("return to bag"))
        #expect(!checkoutText.contains("authentication needed") && !checkoutText.contains("continue after authentication"))
        for phase in [PurchaseJournal.Phase.confirmed, .uncertain] {
            let model = try await restored(phase)
            if phase == .uncertain {
                model.preferences.selectedStoreIDs = []; model.preferences.selectedVariantIDs = []
                model.preferences.maximumTotal = 0; model.hasSavedProfile = false
            }
            let surface = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { OverviewView(model: model) }.padding(28) })
            defer { surface.window.close() }
            let text = try visibleText(surface)
            #expect(text.contains(phase == .confirmed ? "order confirmed" : "order needs reconciliation"))
            #expect(text.contains("before you arm") && text.contains("authorize one automatic pickup order"))
            #expect(model.coordinator.journal.blocksPurchase && !model.coordinator.isArmed)
        }
    }

    @Test func scheduledMonitoringDisplaysNextCheckWithoutAnyCheckoutPreparation() async throws {
        let vault = try StateRenderingVault()
        let driver = StateRenderingAuthDriver()
        let coordinator = MonitoringCoordinator(inventory: StateRenderingInventory(), driver: driver, vault: vault,
                                                journalStore: KeychainJournalStore(vault: vault), sleep: StateRenderingClock.sleep)
        try await coordinator.arm(configuration: configuration(), variants: [stateVariant], stores: stateStores, location: "Synthetic location")
        defer { coordinator.stop() }
        for _ in 0..<100 {
            if coordinator.nextCheck != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(coordinator.nextCheck != nil && driver.preparations == 0)
        let model = try model(coordinator: coordinator, vault: vault)
        let surface = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { OverviewView(model: model) }.padding(28) })
        defer { surface.window.close() }
        #expect(try visibleText(surface).contains("next check"))
    }

    @Test func checkoutTestWindowRendersManualBlockedAndVerifiedReviewWithoutLiveCheckout() async throws {
        for mode in [StateRenderingRehearsalMode.manual, .blocked, .pageNotFound, .review] {
            let driver = StateRenderingRehearsalDriver(mode)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let browser = WKWebView(frame: .zero, configuration: configuration)
            browser.loadHTMLString("""
                <!doctype html><html lang="en"><head><meta charset="utf-8">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
                <style>body{font:20px -apple-system,sans-serif;background:#f6f8fa;color:#18202b;padding:48px}h1{font-size:30px}</style>
                </head><body><h1>Synthetic checkout preview</h1>
                <p>Local HTML fixture. No live Apple session, account, payment or order.</p>
                <p>Review rendering only. All checkout details shown above are synthetic.</p></body></html>
                """, baseURL: nil)
            let rehearsal = CheckoutRehearsal(driver: driver, webView: browser)
            let model = try model(rehearsal: rehearsal)
            let request = CheckoutRequest(variant: stateVariant, store: stateStores[0], market: .ca,
                                          maximumTotal: 4000, timeZoneIdentifier: "UTC")
            await rehearsal.start(request: request, profile: stateRenderingProfile())
            let surface = try await render(CheckoutRehearsalWindow(model: model), size: NSSize(width: 1100, height: 820))
            defer { surface.window.close(); model.cancelCheckoutTest() }
            surface.window.orderFront(nil)
            for _ in 0..<100 {
                if !browser.isLoading { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await settle(surface.controller.view)
            let text = try visibleText(surface)
            #expect(text.contains("orders disabled") && text.contains("end test"))
            #expect(text.contains("cannot submit an order"))
            #expect(!text.contains("4111111111111111") && !text.contains("synthetic@example.invalid"))
            #expect(driver.preparations == 1 && !model.coordinator.isArmed)
            switch mode {
            case .manual:
                #expect(rehearsal.state == .manualInputRequired)
                #expect(text.contains("continue to review") && text.contains("payment method") && text.contains("final review"))
            case .blocked:
                #expect(rehearsal.state == .blocked && rehearsal.isActive)
                #expect(text.contains("access or rate-limit response") && text.contains("may be an error redirect"))
                #expect(!text.contains("apple blocked this checkout session"))
                #expect(text.components(separatedBy: "continue after resolving session").count - 1 == 1)
                #expect(text.contains("check the apple page in this window") && text.contains("order control stays disabled"))
                #expect(!text.contains("continue to review"))
            case .pageNotFound:
                #expect(rehearsal.state == .failed && !rehearsal.isActive && rehearsal.review == nil)
                #expect(text.contains("page was not found") && text.contains("without placing an order"))
                #expect(!text.contains("access or rate-limit response") && !text.contains("apple blocked"))
                #expect(!text.contains("continue after resolving session") && !text.contains("continue to review"))
            case .review:
                #expect(rehearsal.state == .reviewReady)
                #expect(text.contains("verified review") && text.contains("cad"))
                #expect(text.contains("3388.87") || text.contains("3,388.87"))
                #expect(text.contains("synthetic 10:00 to 10:15"))
                #expect(!text.contains("continue to review"))
                try exportPreviewIfRequested(surface)
            }
        }
    }

    @Test func safariReviewOnlyWindowShowsExternalSessionAndManualOrderLimitsWithoutEmbeddedBrowser() async throws {
        let driver = StateRenderingRehearsalDriver(.review, browserKind: .safari)
        let rehearsal = CheckoutRehearsal(driver: driver)
        let model = try model(rehearsal: rehearsal)
        let request = CheckoutRequest(variant: stateVariant, store: stateStores[0], market: .ca,
                                      maximumTotal: 4000, timeZoneIdentifier: "UTC")
        await rehearsal.start(request: request, profile: stateRenderingProfile())
        let surface = try await render(CheckoutRehearsalWindow(model: model), size: NSSize(width: 1100, height: 900))
        defer { surface.window.close(); model.cancelCheckoutTest() }
        let text = try visibleText(surface)
        #expect(text.contains("checkout in safari") && text.contains("show safari checkout"))
        // Vision can recognize the headline's initial A as a Cyrillic lookalike;
        // the readable submission state and separate promise must both remain visible.
        #expect(text.contains("submission disabled") && text.contains("will not submit an order"), failureComment(text))
        #expect(text.contains("do not place the order") && text.contains("safari manages"))
        #expect(text.contains("automation") && text.contains("javascript from apple events"))
        #expect(!text.contains("cannot submit an order") && !text.contains("private browser"))
        #expect(!text.contains("4111111111111111") && !text.contains("synthetic@example.invalid"))
        #expect(rehearsal.embeddedWebView == nil && !descendants(surface.controller.view).contains { $0 is WKWebView })
        #expect(driver.preparations == 1 && !model.coordinator.isArmed && rehearsal.state == .reviewReady)
        try exportPreviewIfRequested(surface, filename: "checkout-safari-review-only.png")
    }

    @Test(arguments: [404, 403, 429, 541])
    func diagnosticRehearsalRenderingSeparatesPlain404FromEarlierAccessResponses(status: Int) async throws {
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        let optionalDiagnostics: CheckoutPageDiagnostics? = page.diagnostics
        let diagnostics = try #require(optionalDiagnostics)
        diagnostics.recordAction(.continuingAsGuest)
        if status != 404 {
            let access = try #require(HTTPURLResponse(url: URL(string: "https://secure7.store.apple.com/ca/shop/signIn?synthetic-token=never-display")!,
                                                    statusCode: status, httpVersion: nil, headerFields: nil))
            page.observeNavigationResponse(access, isForMainFrame: true)
        }
        let notFound = try #require(HTTPURLResponse(url: URL(string: "https://www.apple.com/ca/shop/go/404?synthetic-token=never-display")!,
                                                  statusCode: 404, httpVersion: nil, headerFields: nil))
        page.observeNavigationResponse(notFound, isForMainFrame: true)
        #expect(diagnostics.currentRoute == .pageNotFound && diagnostics.mainFrameStatus == 404)
        #expect(diagnostics.blockingStatus == (status == 404 ? nil : status))
        let driver = StateRenderingRehearsalDriver(status == 404 ? .pageNotFound : .blocked, diagnostics: diagnostics)
        let rehearsal = CheckoutRehearsal(driver: driver, webView: page.webView)
        let model = try model(rehearsal: rehearsal)
        let request = CheckoutRequest(variant: stateVariant, store: stateStores[0], market: .ca, maximumTotal: 4000)
        await rehearsal.start(request: request, profile: stateRenderingProfile())
        #expect(rehearsal.diagnostics === diagnostics)
        let surface = try await render(CheckoutRehearsalWindow(model: model), size: NSSize(width: 1100, height: 900))
        defer { surface.window.close(); model.cancelCheckoutTest() }
        let text = try visibleText(surface)
        #expect(text.contains("checkout response details") && text.contains("continuing as guest"))
        // Vision sometimes labels the identical HTTP T/P glyphs as Cyrillic U+0442/U+0440.
        // Numeric status and word boundaries remain exact.
        #expect(text.contains("page not found") && text.range(of: #"\bh[t\u0442][t\u0442][p\u0440]\s*404\b"#, options: .regularExpression) != nil, failureComment(text))
        #expect(text.contains("orders disabled") && text.contains("cannot submit an order"))
        #expect(!text.contains("synthetic-token") && !text.contains("never-display") && !text.contains("apple blocked this checkout session"))
        #expect(driver.preparations == 1 && !model.coordinator.isArmed)
        if status == 404 {
            #expect(rehearsal.state == .failed && !rehearsal.isActive)
            #expect(text.contains("page was not found") && text.contains("no such response was recorded"))
            #expect(!text.contains("observed access/rate-limit response") && !text.contains("earlier access/rate-limit response") && !text.contains("continue after resolving session"))
            #expect(!text.contains("continue to review"))
            try exportPreviewIfRequested(surface, filename: "checkout-page-not-found.png")
        } else {
            #expect(rehearsal.state == .blocked && rehearsal.isActive)
            #expect(text.contains("observed access/rate-limit response") && text.range(of: #"\bh[t\u0442][t\u0442][p\u0440]\s*"# + String(status) + #"\b"#, options: .regularExpression) != nil, failureComment(text))
            #expect(text.contains("page navigation") && text.contains("may be an error redirect"))
            #expect(text.contains("continue after resolving session") && !text.contains("no such response was recorded"))
            if status == 541 { try exportPreviewIfRequested(surface, filename: "checkout-access-response-redirect.png") }
        }
    }

    @Test func ordinary404InNormalCheckoutRendersNeutralDisarmedGuidanceWithoutAnAccessClaim() async throws {
        let vault = try StateRenderingVault()
        let page = WKAppleCheckoutPage(submissionAllowed: false)
        defer { page.clearPage() }
        page.observeNavigationResponse(try #require(HTTPURLResponse(url: URL(string: "https://www.apple.com/ca/shop/go/404?synthetic-token=never-display")!,
                                                                  statusCode: 404, httpVersion: nil, headerFields: nil)), isForMainFrame: true)
        let checkout = AppleCheckoutDriver(vault: vault, page: page, webView: page.webView)
        let failingDriver = StateRenderingAuthDriver(); failingDriver.failure = .pageNotFound
        let coordinator = MonitoringCoordinator(inventory: StateRenderingInventory(state: .available), driver: failingDriver,
                                                vault: vault, journalStore: KeychainJournalStore(vault: vault))
        try await coordinator.arm(configuration: configuration(), variants: [stateVariant], stores: stateStores,
                                  location: "Synthetic location", runContinuously: false)
        await coordinator.performCycle()
        #expect(!coordinator.isArmed && coordinator.status == .failed && !coordinator.journal.blocksPurchase)
        let model = try model(coordinator: coordinator, vault: vault, checkout: checkout)
        let surface = try await render(CheckoutWindow(model: model), size: NSSize(width: 1100, height: 900))
        defer { coordinator.stop(); surface.window.close() }
        let text = try visibleText(surface)
        #expect(text.contains("checkout is disarmed") && text.contains("return to bag") && text.contains("working bag or product page"))
        #expect(text.contains("page not found") && text.range(of: #"\bh[t\u0442][t\u0442][p\u0440]\s*404\b"#, options: .regularExpression) != nil && text.contains("no such response was recorded"))
        #expect(!text.contains("resolve apple's blocked session") && !text.contains("apple blocked the checkout session"))
        #expect(!text.contains("observed access/rate-limit response") && !text.contains("earlier access/rate-limit response") && !text.contains("continue after authentication"))
        #expect(!text.contains("synthetic-token") && !text.contains("never-display"))
        #expect(!model.coordinator.isArmed && failingDriver.preparations == 1)
        try exportPreviewIfRequested(surface, filename: "checkout-disarmed-not-found.png")
    }

    @Test func overviewRendersManualCheckoutInputAndItsContinuationActions() async throws {
        let vault = try StateRenderingVault()
        let driver = StateRenderingAuthDriver(); driver.failure = .manualInputRequired
        let coordinator = MonitoringCoordinator(inventory: StateRenderingInventory(state: .available), driver: driver, vault: vault,
                                                journalStore: KeychainJournalStore(vault: vault))
        try await coordinator.arm(configuration: configuration(), variants: [stateVariant], stores: stateStores,
                                  location: "Synthetic location", runContinuously: false)
        defer { coordinator.stop() }
        await coordinator.performCycle()
        let model = try model(coordinator: coordinator, vault: vault)
        let surface = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { OverviewView(model: model) }.padding(28) })
        defer { surface.window.close() }
        let text = try visibleText(surface)
        #expect(text.contains("checkout input needed"))
        #expect(text.contains("open checkout") && text.contains("continue checkout"))
        #expect(text.contains("complete required checkout fields") && text.contains("confirm the payment method"))
        #expect(coordinator.status == .manualInputRequired && coordinator.isArmed && driver.preparations == 1)
    }

    @Test func emptyAndBusyPhysicalStoreSetupRenderDistinctContentAndDistances() async throws {
        let empty = try model()
        empty.variants = []; empty.stores = []
        empty.preferences.selectedStoreIDs = []; empty.preferences.selectedVariantIDs = []
        let initial = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { StoreSetupView(model: empty) }.padding(28) })
        defer { initial.window.close() }
        let text = try visibleText(initial)
        #expect(text.contains("load the selected product") && text.contains("no stores loaded"))
        let physical = try model()
        await physical.detectLocation()
        physical.busy = true
        let loaded = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { StoreSetupView(model: physical) }.padding(28) })
        defer { loaded.window.close() }
        let loadedText = try visibleText(loaded)
        #expect(loadedText.contains("physical location detected") && loadedText.contains("0.0 km"))
        #expect(loadedText.contains("15 min drive"))
        #expect(physical.travelTime(to: stateStores[0]) == "~15 min drive")
        #expect(loadedText.contains("synthetic eaton store") && loadedText.contains("synthetic pickup quote"))
        #expect(physical.busy && physical.stores.count == 2 && !physical.coordinator.isArmed)
        #expect(descendants(loaded.controller.view).contains { $0 is NSProgressIndicator })
    }

    @Test func completeAndDraftProfilesRenderVisibleEditableValuesAndValidation() async throws {
        for complete in [true, false] {
            let model = try model()
            var synthetic = stateRenderingProfile()
            synthetic.cardNumber = "4242424242424242"
            synthetic.cvv = "737"
            model.profile = complete ? synthetic : SecureProfile()
            let surface = try await render(ProfileView(model: model), size: NSSize(width: 640, height: 720))
            defer { surface.window.close(); model.closeProfile() }
            let views = descendants(surface.controller.view)
            let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
            #expect(fields.count == 15 && fields.allSatisfy { $0.isEnabled && !($0.cell is NSSecureTextFieldCell) })
            #expect(views.allSatisfy { !($0 is NSSecureTextField) })
            let scrolls = views.compactMap { $0 as? NSScrollView }
            #expect(!scrolls.isEmpty)
            for scroll in scrolls {
                guard let document = scroll.documentView else { continue }
                let y = document.isFlipped ? document.bounds.minY : max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            try await settle(surface.controller.view)
            let text = try visibleText(surface)
            #expect(text.contains("secure checkout details") && text.contains("save to keychain"))
            let compactTop = text.filter { !$0.isWhitespace }
            if complete {
                try exportPreviewIfRequested(surface, filename: "profile-visible.png")
                #expect(compactTop.contains("synthetic@example.invalid"))
                #expect(compactTop.contains("4242424242424242") && compactTop.contains("737"))
                #expect(Set(fields.map(\.stringValue)).isSuperset(of: [synthetic.email, synthetic.cardNumber, synthetic.cvv]))
            } else {
                #expect(!compactTop.contains("synthetic@example.invalid") && !compactTop.contains("4242424242424242"))
                #expect(fields.allSatisfy { $0.stringValue.isEmpty })
            }
            for scroll in scrolls {
                guard let document = scroll.documentView else { continue }
                let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
            try await settle(surface.controller.view)
            let bottom = try visibleText(surface)
            if complete {
                #expect(model.profile.validationIssues.isEmpty && !bottom.contains("required before arming"))
                #expect(bottom.contains("toronto") && bottom.filter { !$0.isWhitespace }.contains("m5v3l9"))
            }
            else { #expect(bottom.contains("required before arming") && bottom.contains("given name is required")) }
        }
    }

    @Test func invalidScheduleRendersActionableValidationMessages() async throws {
        let model = try model()
        model.preferences.selectedStoreIDs = []; model.preferences.selectedVariantIDs = []
        model.preferences.maximumTotal = 0; model.preferences.timeZoneIdentifier = "Invalid/Zone"
        let surface = try await render(ScrollView { VStack(alignment: .leading, spacing: 22) { ScheduleView(model: model) }.padding(28) },
                                       size: NSSize(width: 960, height: 1400))
        defer { surface.window.close() }
        let text = try visibleText(surface)
        #expect(text.contains("select at least one pickup store"))
        #expect(text.contains("set a maximum total greater than zero"))
        #expect(text.contains("choose a valid time zone"))
        #expect(model.preferences.validationIssues.count >= 4 && !model.coordinator.isArmed)
    }
}
