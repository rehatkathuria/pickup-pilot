import AppKit
import SwiftUI
import PilotCore

@main
struct PickupPilotApp: App {
    @NSApplicationDelegateAdaptor(PilotAppDelegate.self) private var delegate
    @State private var model: PilotModel

    init() {
        let preview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
        let model = PilotModel(smoke: preview, inventoryOnly: true)
        // Install before launch completes so notification responses can open the
        // map even when macOS launched the app from a delivered notification.
        if !preview { model.inventoryAlerts.installNotificationDelegate() }
        _model = State(initialValue: model)
    }
    var body: some Scene {
        Window("Apple Store inventory", id: "main") {
            PilotMainWindow(model: model, delegate: delegate)
        }
        .defaultSize(width: 1100, height: 780)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label("Pickup Pilot", systemImage: model.inventoryMonitor.isRunning ? "dot.radiowaves.left.and.right" : "storefront")
        }
    }
}

private struct PilotMainWindow: View {
    @Bindable var model: PilotModel
    let delegate: PilotAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainView(model: model)
            .onAppear {
                delegate.openMainWindow = { openWindow(id: "main") }
                model.inventoryAlerts.onOpenMap = { openWindow(id: "main"); NSApp.activate() }
                model.inventoryAlerts.installNotificationDelegate()
            }
            .task {
                delegate.isArmedCheck = { model.inventoryMonitor.isRunning }
                model.observeInventoryOnLaunch()
            }
    }
}

@MainActor
final class PilotAppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: SingleInstanceLock?
    var isArmedCheck: () -> Bool = { true }
    var openMainWindow: () -> Void = {}
    var activateApplication: () -> Void = { NSApp.activate() }
    var setActivationPolicy: (NSApplication.ActivationPolicy) -> Void = { _ = NSApp.setActivationPolicy($0) }
    var focusExistingApplication: () -> Bool = {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard applications.count == 1 else { return false }
        return applications[0].activate(options: [.activateAllWindows])
    }
    var showLaunchError: (String, String) -> Void = { title, detail in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
    var terminateApplication: () -> Void = { NSApp.terminate(nil) }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The main window must be discoverable through the Dock, app switcher and accessibility.
        // Keeping MenuBarExtra does not require an accessory-only application policy.
        setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-preview") else {
            activateApplication()
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
                    let visibleMain = NSApp.windows.contains { $0.title == "Apple Store inventory" && $0.isVisible }
                    print("PICKUP_PILOT_PREVIEW_LAUNCH mainWindow=\(visibleMain) armed=\(self.isArmedCheck())")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pickup Pilot", isDirectory: true)
        do { instanceLock = try SingleInstanceLock(url: directory.appendingPathComponent("instance.lock")) }
        catch {
            handleInstanceLockFailure(error)
            return
        }
        activateApplication()
    }

    func handleInstanceLockFailure(_ error: Error) {
        if case SingleInstanceLock.InstanceError.alreadyRunning = error {
            if !focusExistingApplication() {
                showLaunchError("Pickup Pilot is already open.", "Only one app instance may monitor inventory. Open the running copy from the Dock or menu bar.")
            }
        } else {
            showLaunchError("Pickup Pilot could not open its local lock.", "Check that Pickup Pilot can access its Application Support folder, then try again. Checkout has not been started by this copy.")
        }
        terminateApplication()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        activateApplication()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
