import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import PickupPilot

private actor RenderingSecureVault: SecureVault {
    func saveProfile(_ profile: SecureProfile) {}
    func loadProfile() -> SecureProfile? { nil }
    func deleteProfile() {}
    func saveSession(_ data: Data) {}
    func loadSession() -> Data? { nil }
    func deleteSession() {}
    func saveOrderState(_ data: Data) {}
    func loadOrderState() -> Data? { nil }
    func deleteOrderState() {}
    func clear() {}
}

private struct RenderingPreferences: PreferencesStore {
    func load() -> PilotPreferences { PilotPreferences() }
    func save(_ preferences: PilotPreferences) { Issue.record("Preview rendering must never persist production preferences.") }
}

@Suite(.serialized) @MainActor struct ViewRenderingTests {
    private let mainSize = NSSize(width: 960, height: 740)
    private struct Surface {
        let window: NSWindow
        let view: NSView
        let proposedFit: () -> NSSize
    }

    private func model() -> PilotModel {
        PilotModel(vault: RenderingSecureVault(), preferencesStore: RenderingPreferences(), smoke: true)
    }

    private func host<V: View>(_ view: V, size: NSSize) -> Surface {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: view
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor))
            .transaction { $0.animation = nil })
        controller.sizingOptions = []
        let hosting = controller.view
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        return Surface(window: window, view: hosting, proposedFit: { controller.sizeThatFits(in: size) })
    }

    private func layout(_ host: NSView) async throws {
        // SwiftUI commits native controls on subsequent main-run-loop turns.
        for _ in 0..<4 {
            host.window?.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func verifyBitmap(_ surface: Surface, size: NSSize) throws {
        let host = surface.view
        #expect(host.bounds.width == size.width)
        #expect(host.bounds.height == size.height)
        // Frame-based native hosts may have a zero Auto Layout fittingSize. SwiftUI's
        // proposed fitting size is the relevant geometry constraint for this hierarchy.
        let nativeFitting = host.fittingSize
        #expect(nativeFitting.width.isFinite && nativeFitting.height.isFinite)
        #expect(nativeFitting.width >= 0 && nativeFitting.height >= 0)
        let fitting = surface.proposedFit()
        #expect(fitting.width.isFinite && fitting.height.isFinite)
        #expect(fitting.width > 0 && fitting.height > 0)
        #expect(fitting.width <= size.width + 1)
        #expect(fitting.height <= size.height + 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 2_000)
        var colors = Set<UInt32>()
        var opaqueSamples = 0
        var samples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 50)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 50)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = UInt32((max(0, min(1, color.redComponent)) * 255).rounded())
                let green = UInt32((max(0, min(1, color.greenComponent)) * 255).rounded())
                let blue = UInt32((max(0, min(1, color.blueComponent)) * 255).rounded())
                colors.insert((red << 16) | (green << 8) | blue)
                if color.alphaComponent > 0.9 { opaqueSamples += 1 }
                samples += 1
            }
        }
        #expect(samples > 2_000)
        #expect(opaqueSamples > samples / 2)
        #expect(colors.count > 12, "A real rendered page must contain more than a flat background.")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test(arguments: AppPage.allCases)
    func everyPageRendersNativeContentAtMinimumWindowSize(_ page: AppPage) async throws {
        let model = model()
        model.selectedPage = page
        if page == .schedule { model.preferences.pollInterval = 1 }
        let surface = host(MainView(model: model), size: mainSize)
        defer { surface.window.close() }
        try await layout(surface.view)
        try verifyBitmap(surface, size: mainSize)
        #expect(!model.coordinator.isArmed)
        #expect(model.profile.isEmpty)
        #expect(!model.hasSavedProfile)
        #expect(model.error == nil)
    }

    @Test func profileSheetRendersNativeVisibleEditableControlsAndScrollableForm() async throws {
        let model = model()
        model.profile = SecureProfile(givenName: "Synthetic", familyName: "Tester", email: "synthetic@example.invalid",
                                      phone: "+15555550100", cardholder: "Synthetic Tester", cardNumber: "4111111111111111",
                                      expiryMonth: "12", expiryYear: "2035", cvv: "123", billingLine1: "1 Synthetic Street",
                                      billingCity: "Toronto", billingRegion: "ON", billingPostalCode: "M5V 3L9", billingCountry: "CA")
        let parent = host(MainView(model: model), size: mainSize).window
        let size = NSSize(width: 640, height: 720)
        let surface = host(ProfileView(model: model), size: size)
        let sheet = surface.window
        let hosting = surface.view
        parent.beginSheet(sheet, completionHandler: nil)
        defer { parent.endSheet(sheet); sheet.close(); parent.close(); model.closeProfile() }
        try await layout(hosting)
        #expect(sheet.sheetParent === parent)
        #expect(parent.attachedSheet === sheet)
        try verifyBitmap(surface, size: size)
        let views = descendants(of: hosting)
        let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        #expect(fields.count == 15, "All contact, card and billing inputs must remain directly editable.")
        #expect(views.allSatisfy { !($0 is NSSecureTextField) }, "Profile entries must be visible while editing.")
        #expect(views.contains { $0 is NSScrollView }, "The profile must remain scrollable at its fixed sheet size.")
        for field in fields {
            #expect(!(field.cell is NSSecureTextFieldCell))
            #expect(field.isEditable && field.isEnabled)
            #expect(field.bounds.width > 40 && field.bounds.height > 10)
        }
        let visibleValues = Set(fields.map(\.stringValue))
        #expect(visibleValues.contains("synthetic@example.invalid"))
        #expect(visibleValues.contains("4111111111111111") && visibleValues.contains("123"))
        #expect(!model.coordinator.isArmed)
    }

    @Test func securitySetupAndMenuRenderWithoutSecretsOrSideEffects() async throws {
        let model = model()
        let surface = host(ScrollView {
            VStack(alignment: .leading, spacing: 22) { SecurityView(model: model) }.padding(28)
        }, size: mainSize)
        defer { surface.window.close() }
        try await layout(surface.view)
        try verifyBitmap(surface, size: mainSize)
        let hosting = surface.view
        #expect(descendants(of: hosting).compactMap { $0 as? NSTextField }.allSatisfy { !$0.isEditable })
        let menuSize = NSSize(width: 400, height: 300)
        let menuSurface = host(VStack(alignment: .leading) { MenuContent(model: model) }.padding(), size: menuSize)
        defer { menuSurface.window.close() }
        try await layout(menuSurface.view)
        try verifyBitmap(menuSurface, size: menuSize)
        #expect(model.profile.isEmpty && !model.hasSavedProfile && !model.coordinator.isArmed)
    }
}
