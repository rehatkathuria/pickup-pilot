import AppKit
import SwiftUI

struct MenuContent: View {
    @Bindable var model: PilotModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if model.inventoryOnly {
            inventoryMenu
        } else {
            legacyMenu
        }
    }
    private var inventoryMenu: some View {
        Group {
            Text("Pickup Pilot · \(model.inventoryMonitor.isRunning ? "Watching automatically" : "Waiting for products & location")")
            Text("\(model.inventoryStores.count) \(model.inventoryStores.count == 1 ? "store" : "stores") · \(model.variantCount) \(model.variantCount == 1 ? "configuration" : "configurations")")
            if model.inventoryAlerts.unreadCount > 0 { Text("\(model.inventoryAlerts.unreadCount) inventory changes") }
            Divider()
            Button("Open Apple Store inventory…", systemImage: "map") { openWindow(id: "main"); NSApp.activate() }.keyboardShortcut("o")
            Button("Refresh inventory now") { Task { await model.refreshInventory() } }
                .disabled(model.busy || model.locationService.requesting || model.inventoryMonitor.isRefreshing || model.preferences.selectedVariantIDs.isEmpty)
            if model.inventoryAlerts.unreadCount > 0 {
                Button("Acknowledge inventory changes") { Task { await model.inventoryAlerts.acknowledge() } }
            }
            Divider()
            Button("Quit Pickup Pilot") { model.stopInventoryMonitoring(); NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
    private var legacyMenu: some View {
        Group {
        Text("Pickup Pilot · \(model.coordinator.status.title)")
        Text("\(model.storeCount) stores · \(model.variantCount) configurations")
        Divider()
        Button("Open Pickup Pilot…") { openWindow(id: "main"); NSApp.activate() }.keyboardShortcut("o")
        Button("Open Apple checkout…") { openWindow(id: "checkout"); NSApp.activate() }
        if model.coordinator.isArmed { Button("Disarm automatic checkout") { model.coordinator.stop() } }
        else { Button("Refresh availability") { Task { await model.discover() } }.disabled(model.busy || model.armingAutomaticCheckout) }
        Divider()
        Button("Quit Pickup Pilot") { model.coordinator.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
