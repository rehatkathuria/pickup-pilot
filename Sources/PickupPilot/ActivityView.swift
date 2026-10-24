import SwiftUI
import PilotCore

struct ActivityView: View {
    @Bindable var model: PilotModel
    @Environment(\.openWindow) private var openWindow
    @State private var resetting = false
    var body: some View {
        PageTitle(title: "Activity & order", subtitle: "A confirmed or uncertain submission locks further purchasing, including after restarting the app.")
        GroupBox("Purchase journal · Keychain") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.coordinator.journal.phase == .idle ? "No submission recorded" : model.coordinator.status.title).font(.title2.bold())
                if let orderID = model.coordinator.journal.orderID {
                    SecureOrderNumber(orderID: orderID)
                }
                if let sku = model.coordinator.journal.variantID { Text("Configuration: \(sku)") }
                if let store = model.coordinator.journal.storeID { Text("Store: \(store)") }
                if let receipt = model.coordinator.journal.receipt {
                    Text(receipt.variantName)
                    Text("Pickup: \(receipt.storeName)")
                    Text(receipt.total, format: .currency(code: receipt.currencyCode))
                    if receipt.pickupIsUnscheduled == true {
                        Text("Pickup when Apple confirms ready; no reserved time")
                    } else if let start = receipt.pickupStart, let end = receipt.pickupEnd {
                        Text("\(start.formatted()) – \(end.formatted())")
                    } else {
                        Text("Pickup time unavailable. Verify with Apple.")
                    }
                    Text(receipt.pickupSlot).font(.caption).foregroundStyle(.secondary)
                }
                Text("Verify order details and pickup instructions directly with Apple.").font(.callout).foregroundStyle(.secondary)
                Link("View Apple orders", destination: URL(string: "https://www.apple.com\((model.coordinator.journal.receipt?.market ?? model.preferences.market).storefrontPath)/shop/order/list")!)
                if model.coordinator.status == .uncertain {
                    Button("Open checkout to inspect outcome") { openWindow(id: "checkout") }
                    Button("Check visible confirmation") { Task { await model.reconcileVisibleConfirmation() } }
                }
                if model.coordinator.journal.blocksPurchase {
                    Button("Reset purchase lock…", role: .destructive) { resetting = true }.disabled(model.coordinator.isArmed)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("This session") {
            VStack(alignment: .leading, spacing: 12) {
                if model.coordinator.events.isEmpty { Text("No activity yet. The app starts disarmed.").foregroundStyle(.secondary) }
                ForEach(model.coordinator.events) { event in
                    HStack(alignment: .top, spacing: 14) {
                        Text(event.date, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(event.message).font(.callout).textSelection(.enabled)
                    }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Have you reconciled your Apple orders?", isPresented: $resetting) {
            Button("I checked Apple orders. Reset lock.", role: .destructive) { Task { await model.resetLock() } }
        } message: { Text("Resetting allows another purchase. An uncertain submission may already have created an order. Check Apple's order history first to avoid buying twice.") }
    }
}
struct SecureOrderNumber: View {
    let orderID: String
    @State private var revealed = false
    var body: some View {
        HStack {
            Text(revealed ? "Order: \(orderID)" : "Order: ••••••••••").textSelection(.enabled)
            Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
        }
    }
}
