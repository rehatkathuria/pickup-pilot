import AppKit
import Vision
import Foundation
import SwiftUI
import Testing
import PilotCore
@testable import PickupPilot

private actor InteractionVault: SecureVault {
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
private struct InteractionPreferences: PreferencesStore {
    func load() -> PilotPreferences { PilotPreferences() }
    func save(_ preferences: PilotPreferences) {}
}

@Suite(.serialized) @MainActor struct NativePreviewExportTests {
    private func host<V: View>(_ view: V, width: CGFloat = 960, height: CGFloat = 740) async throws -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view.environment(\.colorScheme, .light).background(Color(nsColor: .windowBackgroundColor)))
        window.orderFront(nil)
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        return window
    }
    @Test func exportSyntheticScreensWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["PICKUP_PILOT_RENDER_PREVIEWS"] == "1" else { return }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("outputs/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = PilotModel(vault: InteractionVault(), preferencesStore: InteractionPreferences(), smoke: true)
        for page in AppPage.allCases {
            model.selectedPage = page
            let window = try await host(MainView(model: model))
            let view = try #require(window.contentView)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
            #expect(recognition.results?.contains { observation in
                observation.boundingBox.midX < 0.25 && observation.topCandidates(1).first?.string == page.rawValue
            } == true, "The selected sidebar label must remain legible in the rendered native view.")
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(page.id.replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-").lowercased() + ".png"))
            window.close()
        }
    }
}
