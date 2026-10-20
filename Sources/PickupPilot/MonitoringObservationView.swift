import SwiftUI
import PilotCore

struct MonitoringObservationView: View {
    let coordinator: MonitoringCoordinator

    var body: some View {
        GroupBox("Live observation") {
            VStack(alignment: .leading, spacing: 12) {
                if let plan = coordinator.monitoringPlan {
                    Label(coordinator.isArmed ? "Observing the confirmed monitoring plan" : "Disarmed · last armed monitoring plan", systemImage: coordinator.isArmed ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.headline)
                    Text("\(plan.configuration.market.displayName) · \(plan.variants.count) configurations × \(plan.stores.count) selected stores · one item maximum")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("\(MonitoringDisplayFormat.cadence(plan.configuration.pollInterval)) · times in \(plan.configuration.timeZoneIdentifier)")
                        .font(.caption).foregroundStyle(.secondary)
                    if !coordinator.isArmed {
                        Text("Monitoring is stopped. These are retained results from the last armed plan.").font(.callout)
                    }
                    if coordinator.isCheckingInventory {
                        Label("Checking Apple now · check \(coordinator.checkCount)", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        Text("Rows below remain from the previous successful check until this request finishes.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Checks started: \(coordinator.checkCount)").monospacedDigit()
                    }
                    if let started = coordinator.lastCheckStarted {
                        Text("Latest check started: \(MonitoringDisplayFormat.date(started, timeZone: plan.configuration.timeZoneIdentifier))").font(.caption).monospacedDigit()
                    }
                    if let finished = coordinator.lastCheckFinished {
                        Text("Latest check finished: \(MonitoringDisplayFormat.date(finished, timeZone: plan.configuration.timeZoneIdentifier))").font(.caption).monospacedDigit()
                    }
                    if let error = coordinator.lastCheckError {
                        Label("\(coordinator.isCheckingInventory ? "Previous check did not succeed; retry in progress" : "Latest check did not succeed"): \(error)", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                        if coordinator.snapshot != nil { Text("Previous results · not a fresh availability response").font(.callout.bold()) }
                    }
                    if let checked = coordinator.lastCheck {
                        Text("Last successful check: \(MonitoringDisplayFormat.date(checked, timeZone: plan.configuration.timeZoneIdentifier)) · \(plan.configuration.timeZoneIdentifier)")
                            .font(.caption).monospacedDigit()
                    } else {
                        Text("No successful monitoring response yet. Discovery results are separate from armed checks.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let next = coordinator.nextCheck {
                        Text("Next check: \(MonitoringDisplayFormat.date(next, timeZone: plan.configuration.timeZoneIdentifier))").font(.caption).monospacedDigit()
                    }
                    ForEach(Array(plan.variants.enumerated()), id: \.offset) { index, variant in
                        Divider()
                        Text("\(index + 1). \(variant.name)").font(.headline)
                        Text("SKU: \(variant.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        ForEach(Array(plan.stores.enumerated()), id: \.offset) { storeIndex, store in
                            ObservedStoreRow(store: store, priority: storeIndex + 1,
                                responses: coordinator.snapshot?.availability.filter { $0.storeID == store.id && $0.variantID == variant.id } ?? [],
                                hasResponse: coordinator.snapshot != nil)
                        }
                    }
                    Text("Apple reports pickup eligibility, not a unit count. Missing or ambiguous rows are unverified.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No armed monitoring plan yet. Review your selections and confirm arming to start observing Apple.")
                        .foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
