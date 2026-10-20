import SwiftUI
import PilotCore

struct StoreSetupView: View {
    @Bindable var model: PilotModel
    var body: some View {
        PageTitle(title: "Stores & products", subtitle: "Choose a product, acceptable configurations and preferred stores. The first matching configuration and store in your selection order wins.")
        GroupBox("Product") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Shop for", selection: Binding(get: { model.preferences.catalogProduct }, set: { model.selectCatalogProduct($0) })) {
                    ForEach(CatalogProduct.allCases) { product in
                        Text(product.displayName).tag(product).disabled(!product.supports(market: model.preferences.market))
                    }
                }.accessibilityIdentifier("catalog-product")
                if model.preferences.catalogProduct == .usbCHeadphoneAdapter {
                    Text("A low-cost real item for testing Pickup Pilot's automatic checkout. Apple’s current Canadian price is loaded below. Pickup is when Apple confirms it is ready, with no reserved time. Arming can place a real order using your saved checkout profile.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The low-cost adapter is available in the Canada storefront. Changing product clears selected configurations, your budget and purchase authorization.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10)
        }.disabled(model.busy || model.setupLocked)
        GroupBox("Find nearby Apple stores") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Shopping country", selection: Binding(get: { model.preferences.market }, set: { model.selectMarket($0) })) {
                        ForEach(Market.allCases) { Text($0.displayName).tag($0) }
                    }
                    Button("Use my location", systemImage: "location") { Task { await model.detectLocation() } }.disabled(model.busy || model.locationService.requesting)
                }
                HStack {
                    TextField("Postal code or city", text: Binding(get: { model.locationQuery }, set: { model.enterLocationQuery($0) }))
                        .textFieldStyle(.roundedBorder)
                    Button("Find stores") { Task { await model.discover() } }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Loading Apple stores") }
                }
                Text(model.locationDescription).font(.caption).foregroundStyle(.secondary)
                Text("Country changes clear regional store and product selections. Catalogs and pickup support are verified with Apple; some markets or products may be unavailable.").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }.disabled(model.setupLocked)
        GroupBox("Product configurations · \(model.preferences.market.currencyCode)") {
            VStack(alignment: .leading, spacing: 0) {
                if model.variants.isEmpty { ContentUnavailableView("Load the selected product", systemImage: "shippingbox", description: Text("Choose a shopping country and find stores to load the selected product from Apple.")) }
                ForEach(model.variants) { variant in
                    HStack {
                        Toggle(variant.name, isOn: Binding(get: { model.preferences.selectedVariantIDs.contains(variant.id) }, set: { value in
                            if value != model.preferences.selectedVariantIDs.contains(variant.id) { model.toggleVariant(variant.id) }
                        }))
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("variant-\(variant.id)")
                        Text(variant.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(10)
                    if variant.id != model.variants.last?.id { Divider() }
                }
            }.padding(4)
        }.disabled(model.setupLocked)
        GroupBox("Preferred pickup stores") {
            VStack(alignment: .leading, spacing: 0) {
                if model.stores.isEmpty { ContentUnavailableView("No stores loaded", systemImage: "storefront", description: Text("Use your current location or enter a nearby postal code.")) }
                ForEach(model.stores) { store in
                    HStack(alignment: .top) {
                        Toggle(store.name, isOn: Binding(get: { model.preferences.selectedStoreIDs.contains(store.id) }, set: { value in
                            if value != model.preferences.selectedStoreIDs.contains(store.id) { model.toggleStore(store.id) }
                        }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("store-\(store.id)")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if let estimate = model.travelEstimate(to: store) {
                                HStack(spacing: 12) {
                                    Label(estimate.distanceLabel, systemImage: "location")
                                    Label(model.travelTime(to: store), systemImage: "car")
                                }
                                .font(.caption)
                                .monospacedDigit()
                                .accessibilityElement(children: .combine)
                            } else {
                                Text("Distance & drive time unavailable").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(store.address).font(.caption).foregroundStyle(.secondary)
                            let quotes = Set(model.availability.filter { $0.storeID == store.id }.map(\.message))
                            ForEach(quotes.sorted(), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(10)
                    if store.id != model.stores.last?.id { Divider() }
                }
                if !model.travelStatus.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        if model.resolvingTravel { ProgressView().controlSize(.small).accessibilityLabel("Estimating store travel") }
                        Text(model.travelStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(10)
                }
            }.padding(4)
        }.disabled(model.setupLocked)
    }
}
