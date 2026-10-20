import AppKit
import SwiftUI
import PilotCore

struct MainView: View {
    @Bindable var model: PilotModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: $model.selectedPage) { page in
                Label(page.rawValue, systemImage: page.icon)
                    .foregroundStyle(model.selectedPage == page ? Color.white : Color.primary)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.coordinator.status.title, systemImage: model.coordinator.isArmed ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.headline)
                    Text("One item. Pickup only.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch model.selectedPage {
                    case .overview: OverviewView(model: model)
                    case .stores: StoreSetupView(model: model)
                    case .schedule: ScheduleView(model: model)
                    case .security: SecurityView(model: model)
                    case .activity: ActivityView(model: model)
                    }
                    if !model.message.isEmpty { Label(model.message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(28).frame(maxWidth: 860, alignment: .leading)
            }.frame(minWidth: 600, minHeight: 620)
        }
        .navigationTitle("Pickup Pilot")
        .onChange(of: model.coordinator.status) { _, status in
            if status == .preparing || status == .manualInputRequired || status == .uncertain {
                openWindow(id: "checkout")
                NSApp.activate()
            }
        }
        .toolbar {
            ToolbarItem {
                if model.coordinator.isArmed { Button("Disarm", systemImage: "stop.circle") { model.coordinator.stop() } }
                else { Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.discover() } }.disabled(model.busy) }
            }
        }
        .sheet(isPresented: $model.profileOpen, onDismiss: model.closeProfile) { ProfileView(model: model) }
        .sheet(item: Binding(get: { model.pendingArmingReview }, set: { if $0 == nil { model.cancelArmingReview() } })) { review in
            ArmingReviewView(model: model, review: review)
        }
        .alert("Pickup Pilot", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OverviewView: View {
    @Bindable var model: PilotModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        PageTitle(title: model.preferences.catalogProduct == .iPhoneDuo ? "Your next iPhone, nearby." : "Test a low-cost pickup order.", subtitle: "Watch your preferred Apple stores and attempt one pickup order within your chosen limits.")
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(model.coordinator.status.title, systemImage: statusIcon).font(.title2.bold())
                Text(model.coordinator.detail).textSelection(.enabled)
                if let next = model.coordinator.nextCheck { Text("Next check: \(next.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                if model.coordinator.status == .manualInputRequired {
                    Button("Open checkout", systemImage: "rectangle.and.pencil.and.ellipsis") { openWindow(id: "checkout") }
                    Button(model.checkout.requiresPaymentConfirmation ? "Confirm payment and allow order" : "Continue checkout") {
                        model.coordinator.resumeAuthentication()
                    }
                    if model.coordinator.isArmed && model.checkout.requiresPaymentConfirmation {
                        Text("This confirmation permits one authorized order within your armed limits. Check the payment method on Apple’s final review first.")
                            .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        if model.coordinator.isArmed { MonitoringObservationView(coordinator: model.coordinator) }
        HStack(spacing: 16) {
            MetricCard(title: "Pickup stores", value: "\(displayPlan.configuration.selectedStoreIDs.count)", icon: "storefront")
            MetricCard(title: "Configurations", value: "\(displayPlan.configuration.selectedVariantIDs.count)", icon: "shippingbox")
            MetricCard(title: "Maximum total", value: displayPlan.configuration.maximumTotal.formatted(.currency(code: displayPlan.configuration.market.currencyCode)), icon: "creditcard")
        }
        GroupBox(model.coordinator.isArmed ? "Automatic checkout controls" : "Before you arm") {
            VStack(alignment: .leading, spacing: 12) {
                setupRow("Select a product, configurations and pickup stores", ready: model.storeCount > 0 && model.variantCount > 0, page: .stores)
                setupRow(model.preferences.catalogProduct == .iPhoneDuo ? "Set attempt dates, pickup times and a budget" : "Set attempt dates and a budget; pickup is when ready", ready: model.preferences.validationIssues.isEmpty, page: .schedule)
                setupRow("Save contact, billing and card details in Keychain", ready: model.hasSavedProfile, page: .security)
                Divider()
                Toggle("Authorize one automatic pickup order up to \(model.preferences.maximumTotal.formatted(.currency(code: model.preferences.market.currencyCode))), including tax and fees.", isOn: $model.consentToOrder)
                    .disabled(model.setupLocked || model.coordinator.journal.blocksPurchase)
                Text("Checkout uses Safari and Apple's guest option, then pauses at final review for payment confirmation. If guest checkout is unavailable or a security challenge is required, the attempt stops. Keep this Mac awake with Pickup Pilot open. Arming lasts for this app session only.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.coordinator.isArmed ? "Disarm" : "Review and arm…", systemImage: model.coordinator.isArmed ? "stop.circle.fill" : "bolt.shield") {
                        if model.coordinator.isArmed { model.coordinator.stop() }
                        else { model.requestArmingReview() }
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.armingAutomaticCheckout || (!model.coordinator.isArmed && (model.setupLocked || model.busy || !model.consentToOrder || model.coordinator.journal.blocksPurchase)))
                    Button("View checkout", systemImage: "globe") { openWindow(id: "checkout") }
                }
            }.padding(12)
        }
        SelectionSummaryView(plan: displayPlan, profileSaved: model.hasSavedProfile,
                             title: model.coordinator.isArmed ? "Armed selections and limits" : "Selected items and limits")
        if !model.coordinator.isArmed { MonitoringObservationView(coordinator: model.coordinator) }
        GroupBox("Test checkout without ordering") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Test your first selected product and store through Apple's final review. Place Order is disabled in the test window. To make a real purchase with your saved profile, use Review and arm above, then confirm the monitoring plan.")
                Button("Test to final review", systemImage: "checkmark.shield") {
                    openWindow(id: "checkout-test")
                    Task { await model.testCheckout() }
                }.disabled(model.setupLocked)
            }.padding(12)
        }
    }
    private var displayPlan: MonitoringPlan {
        if model.coordinator.isArmed, let plan = model.coordinator.monitoringPlan { return plan }
        return MonitoringPlan(configuration: model.preferences,
                              variants: model.preferences.selectedVariantIDs.compactMap { id in model.variants.first { $0.id == id } },
                              stores: model.preferences.selectedStoreIDs.compactMap { id in model.stores.first { $0.id == id } },
                              location: model.locationQuery)
    }
    private var statusIcon: String {
        switch model.coordinator.status {
        case .confirmed: "checkmark.seal"; case .uncertain, .failed: "exclamationmark.triangle"
        case .authenticationRequired: "exclamationmark.triangle"
        case .manualInputRequired: "rectangle.and.pencil.and.ellipsis"
        default: model.coordinator.isArmed ? "dot.radiowaves.left.and.right" : "pause.circle"
        }
    }
    private func setupRow(_ title: String, ready: Bool, page: AppPage) -> some View {
        HStack {
            Label(title, systemImage: ready ? "checkmark.circle" : "circle").foregroundStyle(ready ? .primary : .secondary)
            Spacer()
            Button("Set up") { model.selectedPage = page }.buttonStyle(.link)
        }
    }
}
struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.bold()).minimumScaleFactor(0.75).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}
