import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
import Vision
@testable import PickupPilot

private struct InventoryMapRenderingPreferences: PreferencesStore {
    func load() -> PilotPreferences { PilotPreferences() }
    func save(_ preferences: PilotPreferences) { Issue.record("A rendering fixture must not save preferences.") }
}

/// Captures actual native SwiftUI controls with synthetic inventory; map tiles and network are disabled.
@Suite(.serialized) @MainActor struct InventoryMapRenderingTests {
    private func fixture(stale: Bool = false) -> InventoryMapContent {
        let stores = [RetailStore(id: "RENDER-A", name: "Synthetic Eaton", latitude: 43.65, longitude: -79.38),
                      RetailStore(id: "RENDER-B", name: "Synthetic Yorkdale", latitude: 43.72, longitude: -79.45),
                      RetailStore(id: "RENDER-C", name: "Synthetic No Coordinates")]
        let variant = ProductVariant(id: "SYNTHETIC-MAP/A", name: "Synthetic iPhone Night Sky", storage: "256GB", color: "Night Sky", productURL: Market.ca.productBaseURL)
        let presentation = InventoryMapPresentation(stores: stores, variants: [variant], selectedVariantIDs: [variant.id],
                                                    availability: [StoreAvailability(storeID: stores[0].id, variantID: variant.id, state: .available, message: "Today"),
                                                                   StoreAvailability(storeID: stores[1].id, variantID: variant.id, state: .unavailable, message: "Unavailable")],
                                                    isStale: stale, distance: { $0.coordinate == nil ? nil : "3.1 km" },
                                                    travelTime: { $0.coordinate == nil ? nil : "~12 min drive" })
        return InventoryMapContent(presentation: presentation, locationTitle: "Synthetic city", origin: nil,
                                   isRunning: true, isRefreshing: false, lastCheck: Date(timeIntervalSince1970: 1_792_535_460),
                                   lastError: stale ? "Synthetic network failure" : nil,
                                   nextCheck: nil, checkCount: 42, refreshInterval: 1,
                                   alertSummary: "Alerts, sounds and badges enabled", notificationsEnabled: true,
                                   deliveryDetails: "Inventory changes notify immediately. Focus settings can silence alerts.",
                                   unreadCount: 3, notificationError: nil,
                                   refresh: {}, setRefreshInterval: { _ in }, enableAlerts: {}, acknowledge: {},
                                   rendersMap: ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_MAP_TILES"] == "1")
    }

    private func render(stale: Bool, filename: String) async throws -> String {
        try await render(fixture(stale: stale), filename: filename)
    }

    private func render<V: View>(_ view: V, filename: String, size: NSSize = NSSize(width: 1100, height: 780)) async throws -> String {
        _ = NSApplication.shared
        let root = view.environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_CA"))
            .background(Color(nsColor: .windowBackgroundColor)).transaction { $0.animation = nil }
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.frame = NSRect(origin: .zero, size: size); window.setContentSize(size)
        defer { window.close() }
        if ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_MAP_TILES"] == "1" {
            // A real, offscreen window lets MapKit realize annotation hosting views and native controls.
            window.orderFront(nil)
        }
        for _ in 0..<4 {
            window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        if ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_MAP_TILES"] == "1" {
            // Optional visual QA uses real MapKit tiles with only synthetic store and inventory data.
            try await Task.sleep(for: .milliseconds(1500))
            window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
        }
        let fit = controller.sizeThatFits(in: size)
        #expect(fit.width <= size.width + 1 && fit.height <= size.height + 1)
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 3_000)
        if ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_PREVIEWS"] == "1" {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("outputs/previews", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(filename))
            if ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_MAP_TILES"] == "1" {
                func describe(_ view: NSView) -> [[String: String]] {
                    [["type": NSStringFromClass(type(of: view)), "frame": NSStringFromRect(view.frame),
                      "bounds": NSStringFromRect(view.bounds), "hidden": String(view.isHiddenOrHasHiddenAncestor),
                      "alpha": String(describing: view.alphaValue), "layer": view.layer.map { NSStringFromClass(type(of: $0)) } ?? "none"]]
                    + view.subviews.flatMap(describe)
                }
                let tree = try JSONSerialization.data(withJSONObject: describe(controller.view), options: [.prettyPrinted, .sortedKeys])
                try tree.write(to: directory.appendingPathComponent(filename + ".views.json"))
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let annotations = descendants(controller.view).filter { NSStringFromClass(type(of: $0)).contains("SwiftUIAnnotationView") }
                for (index, annotation) in annotations.enumerated() {
                    guard let bitmap = annotation.bitmapImageRepForCachingDisplay(in: annotation.bounds) else { continue }
                    annotation.cacheDisplay(in: annotation.bounds, to: bitmap)
                    if let image = bitmap.representation(using: .png, properties: [:]) {
                        try image.write(to: directory.appendingPathComponent(filename + ".annotation-\(index).png"))
                    }
                }
            }
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false; request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.006
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
    }

    @Test func inventoryWindowShowsRefreshControlsObservedSKUAndEveryStoreState() async throws {
        let text = try await render(stale: false, filename: "inventory-map-synthetic.png")
        #expect(text.contains("nearby apple inventory") && text.contains("watching automatically") && text.contains("refresh now"))
        #expect(text.contains("refresh every") && text.contains("second") && text.contains("42 checks"))
        #expect(text.contains("synthetic iphone night sky") && text.contains("synthetic-map/a"))
        #expect(text.contains("synthetic eaton") && text.contains("synthetic yorkdale") && text.contains("synthetic no coordinates"))
        #expect(text.contains("1 available") && text.contains("no pickup") && text.contains("unverified"))
        #expect(text.contains("map location unavailable") && text.contains("3.1 km"))
        #expect(text.contains("enable alerts") && text.contains("acknowledge 3") && text.contains("focus"))
        #expect(!text.contains("place order") && !text.contains("arm checkout"))
        #expect(!text.contains("start watching") && !text.contains("stop watching"))
    }

    @Test func staleWindowKeepsPreviousResultsVisibleAndExplainsFailedRefresh() async throws {
        let text = try await render(stale: true, filename: "inventory-map-stale-synthetic.png")
        #expect(text.contains("latest check failed") && text.contains("synthetic network failure"))
        #expect(text.contains("previous results") && text.contains("0 stores with pickup"))
        #expect(!text.contains("1 available"))
    }

    @Test func productionMainSurfaceExposesInventoryAndNoCheckoutActions() async throws {
        let model = PilotModel(preferencesStore: InventoryMapRenderingPreferences(), smoke: true, inventoryOnly: true)
        let rendersMap = ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_MAP_TILES"] == "1"
        let text = try await render(MainView(model: model, rendersInventoryMap: rendersMap), filename: "inventory-main-synthetic.png")
        #expect(text.contains("nearby apple inventory") && text.contains("refresh now") && text.contains("configurations"))
        #expect(text.contains("refresh every") && text.contains("second") && text.contains("configuration"))
        #expect(text.contains("alerts") && text.contains("enable alerts"))
        #expect(!text.contains("start watching") && !text.contains("stop watching") && !text.contains("open inventory map"))
        #expect(!text.contains("review and arm") && !text.contains("save to keychain") && !text.contains("test to final review"))
        #expect(!text.contains("headphone") && !text.contains("adapter") && !text.contains("shop for"))
        #expect(!model.coordinator.isArmed && !model.inventoryMonitor.isRunning && !model.profileOpen)
    }

    @Test func configurationPickerRendersMultipleCheckedRowsAndNoAdapter() async throws {
        let model = PilotModel(preferencesStore: InventoryMapRenderingPreferences(), smoke: true, inventoryOnly: true)
        let phoneA = ProductVariant(id: "SYNTHETIC-NIGHT/A", name: "Synthetic iPhone Duo 256GB Night Sky", storage: "256GB", color: "Night Sky", productURL: Market.ca.productBaseURL.appendingPathComponent("night"))
        let phoneB = ProductVariant(id: "SYNTHETIC-WHITE/A", name: "Synthetic iPhone Duo 512GB Star White", storage: "512GB", color: "Star White", productURL: Market.ca.productBaseURL.appendingPathComponent("white"))
        let phoneC = ProductVariant(id: "SYNTHETIC-BLUE/A", name: "Synthetic iPhone Duo 1TB Blue", storage: "1TB", color: "Blue", productURL: Market.ca.productBaseURL.appendingPathComponent("blue"))
        let adapter = ProductVariant(id: CatalogProduct.adapterSKU, name: CatalogProduct.usbCHeadphoneAdapter.displayName, storage: "", color: "", productURL: CatalogProduct.adapterURL)
        model.variants = [phoneA, phoneB, phoneC, adapter]
        model.preferences.selectedVariantIDs = [phoneA.id, phoneB.id]
        let text = try await render(InventoryConfigurationPicker(model: model), filename: "inventory-configurations-synthetic.png", size: NSSize(width: 480, height: 390))
        #expect(text.contains("2 selected") && text.contains("every checked configuration automatically"))
        #expect(text.contains("256gb night sky") && text.contains("512gb star white") && text.contains("1tb blue"))
        #expect(text.contains("synthetic-night/a") && text.contains("synthetic-white/a"))
        #expect(text.contains("select all") && text.contains("clear selection"))
        #expect(!text.contains("headphone") && !text.contains("adapter") && !text.contains(CatalogProduct.adapterSKU.lowercased()))
        #expect(model.preferences.selectedVariantIDs == [phoneA.id, phoneB.id])
    }
}
