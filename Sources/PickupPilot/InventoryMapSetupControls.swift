import PilotCore
import SwiftUI

struct InventoryMapSetupControls: View {
    @Bindable var model: PilotModel
    @State private var query = ""
    @State private var showingConfigurations = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Country", selection: Binding(get: { model.preferences.market }, set: model.selectMarket)) {
                    ForEach(Market.allCases) { market in Text(market.displayName).tag(market) }
                }.frame(maxWidth: 180)
                TextField("Postal code or city", text: $query).textFieldStyle(.roundedBorder)
                    .onSubmit(findStores).frame(maxWidth: 230)
                Button("Find stores", systemImage: "magnifyingglass", action: findStores)
                Button("Use my location", systemImage: "location") { Task { await model.detectLocation() } }
                    .disabled(model.locationService.requesting)
                Spacer(minLength: 10)
                Button("Configurations (\(model.preferences.selectedVariantIDs.count))", systemImage: "checklist") {
                    showingConfigurations.toggle()
                }.fixedSize()
                    .accessibilityIdentifier("inventory-configurations")
                    .popover(isPresented: $showingConfigurations, arrowEdge: .bottom) {
                        InventoryConfigurationPicker(model: model)
                    }
            }.disabled(model.setupLocked || model.busy)
            if model.busy {
                Label("Loading products and nearby stores…", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            .onChange(of: model.locationQuery, initial: true) { _, location in if query != location { query = location } }
    }

    private func findStores() {
        model.enterLocationQuery(query)
        Task { await model.discover() }
    }
}
