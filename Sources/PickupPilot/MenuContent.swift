import AppKit
import SwiftUI

struct MenuContent: View {
    @Bindable var model: PilotModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
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
