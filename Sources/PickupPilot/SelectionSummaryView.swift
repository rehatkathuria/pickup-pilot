import SwiftUI
import PilotCore

struct SelectionSummaryView: View {
    let plan: MonitoringPlan
    let profileSaved: Bool
    var title = "Selected items and limits"

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 14) {
                Text(plan.configuration.catalogProduct.displayName).font(.headline)
                LabeledContent("Storefront", value: "\(plan.configuration.market.displayName) · \(plan.configuration.market.currencyCode)")
                LabeledContent("Search location", value: plan.location.isEmpty ? "No location entered" : plan.location)
                Text("Configuration priority").font(.headline)
                if plan.configuration.selectedVariantIDs.isEmpty {
                    Text("No product configurations selected").foregroundStyle(.secondary)
                }
                ForEach(Array(plan.configuration.selectedVariantIDs.enumerated()), id: \.offset) { index, id in
                    VStack(alignment: .leading, spacing: 3) {
                        if let variant = plan.variants.first(where: { $0.id == id }) {
                            Text("\(index + 1). \(variant.name)")
                            Text("SKU: \(id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else {
                            Label("\(index + 1). Configuration not loaded · \(id)", systemImage: "exclamationmark.triangle")
                        }
                    }.textSelection(.enabled)
                }
                Text("Pickup store priority").font(.headline)
                if plan.configuration.selectedStoreIDs.isEmpty {
                    Text("No pickup stores selected").foregroundStyle(.secondary)
                }
                ForEach(Array(plan.configuration.selectedStoreIDs.enumerated()), id: \.offset) { index, id in
                    VStack(alignment: .leading, spacing: 3) {
                        if let store = plan.stores.first(where: { $0.id == id }) {
                            Text("\(index + 1). \(store.name) · \(id)")
                            if !store.address.isEmpty { Text(store.address).font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Label("\(index + 1). Store not loaded · \(id)", systemImage: "exclamationmark.triangle")
                        }
                    }.textSelection(.enabled)
                }
                Text("One item total. The first available configuration wins, then the first available store in your priority order.")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                LabeledContent("Maximum final total", value: plan.configuration.maximumTotal.formatted(.currency(code: plan.configuration.market.currencyCode)))
                Text("Includes tax and fees · paid in full · pickup only").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Stock checks", value: MonitoringDisplayFormat.cadence(plan.configuration.pollInterval))
                Text("Network failures and Apple rate limits delay retries. Requests never overlap.").font(.caption).foregroundStyle(.secondary)
                Text("Attempts: \(MonitoringDisplayFormat.date(plan.configuration.attemptWindow.start, timeZone: plan.configuration.timeZoneIdentifier)) – \(MonitoringDisplayFormat.date(plan.configuration.attemptWindow.end, timeZone: plan.configuration.timeZoneIdentifier))")
                LabeledContent("Daily attempt hours", value: MonitoringDisplayFormat.hours(plan.configuration.attemptHours))
                if plan.configuration.catalogProduct == .usbCHeadphoneAdapter {
                    Text("Pickup when Apple confirms ready · no reserved date or time")
                } else {
                    Text("Pickup: \(MonitoringDisplayFormat.date(plan.configuration.pickupWindow.start, timeZone: plan.configuration.timeZoneIdentifier)) – \(MonitoringDisplayFormat.date(plan.configuration.pickupWindow.end, timeZone: plan.configuration.timeZoneIdentifier))")
                    LabeledContent("Daily pickup hours", value: MonitoringDisplayFormat.hours(plan.configuration.pickupHours))
                }
                LabeledContent("Time zone for all times", value: plan.configuration.timeZoneIdentifier)
                LabeledContent("Preparation failure limit", value: "\(plan.configuration.maximumPreparationFailures)")
                Label(profileSaved ? "Checkout profile saved in Keychain" : "Checkout profile must be saved before arming", systemImage: profileSaved ? "checkmark.shield" : "exclamationmark.shield")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
