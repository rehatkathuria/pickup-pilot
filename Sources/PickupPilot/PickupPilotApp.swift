import AppKit
import SwiftUI
import PilotCore

@main
struct PickupPilotApp: App {
    @NSApplicationDelegateAdaptor(PilotAppDelegate.self) private var delegate
    @State private var model = PilotModel(smoke: ProcessInfo.processInfo.arguments.contains("--ui-preview"))
    var body: some Scene {
        Window("Pickup Pilot", id: "main") {
            MainView(model: model)
                .task {
                    let coordinator = model.coordinator
                    delegate.isArmedCheck = { coordinator.isArmed }
                    await model.startup()
                }
        }
        .defaultSize(width: 960, height: 740)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label("Pickup Pilot", systemImage: model.coordinator.isArmed ? "iphone.radiowaves.left.and.right" : "iphone")
        }
        Window("Apple Checkout · Pickup Pilot", id: "checkout") {
            CheckoutWindow(model: model)
        }.defaultSize(width: 1100, height: 820)
        Window("Checkout Test · Pickup Pilot", id: "checkout-test") {
            CheckoutRehearsalWindow(model: model)
        }.defaultSize(width: 1100, height: 820)
    }
}

@MainActor
final class PilotAppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: SingleInstanceLock?
    var isArmedCheck: () -> Bool = { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-preview") else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            if ProcessInfo.processInfo.arguments.contains("--validate-safari") {
                Task { @MainActor in
                    let result = await SafariValidation.run()
                    print("PICKUP_PILOT_SAFARI_VALIDATION result=\(result.rawValue) armed=\(self.isArmedCheck())")
                    NSApp.terminate(nil)
                }
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--validate-launch") {
                Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    let visibleMain = NSApp.windows.contains { $0.title == "Pickup Pilot" && $0.isVisible }
                    print("PICKUP_PILOT_PREVIEW_LAUNCH mainWindow=\(visibleMain) armed=\(self.isArmedCheck())")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pickup Pilot", isDirectory: true)
        do { instanceLock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Pickup Pilot is already open or its local lock is unavailable."
            alert.informativeText = "Only one app instance may monitor and order. Close the other copy before trying again."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
