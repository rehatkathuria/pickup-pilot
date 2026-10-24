import PilotCore
import SwiftUI

/// A persistent popover with independent checkboxes, rather than a single-choice product menu.
struct InventoryConfigurationPicker: View {
    @Bindable var model: PilotModel

    private var phoneVariants: [ProductVariant] {
        model.variants.filter { $0.id != CatalogProduct.adapterSKU && $0.productURL != CatalogProduct.adapterURL }
    }
    private var selectedCount: Int { model.preferences.selectedVariantIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("iPhone Duo configurations").font(.headline)
                Text("\(selectedCount) selected · Watching every checked configuration automatically")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            if phoneVariants.isEmpty {
                ContentUnavailableView("No configurations loaded", systemImage: "shippingbox",
                                       description: Text("Find nearby stores to load the iPhone Duo configurations for your country."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(phoneVariants) { variant in
                            Toggle(isOn: selection(for: variant)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(variant.name).font(.body).fixedSize(horizontal: false, vertical: true)
                                    Text(variant.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("inventory-configuration-\(variant.id)")
                            .disabled(model.busy || model.setupLocked || (!model.preferences.selectedVariantIDs.contains(variant.id) && selectedCount >= 20))
                            .padding(.vertical, 11)
                            Divider()
                        }
                    }.padding(.horizontal, 2)
                }.frame(maxHeight: 350)
            }
            HStack(spacing: 12) {
                Button(phoneVariants.count > 20 ? "Select first 20" : "Select all") {
                    model.setInventoryVariantSelection(Array(phoneVariants.prefix(20).map(\.id)))
                }.disabled(phoneVariants.isEmpty || model.busy || model.setupLocked)
                Button("Clear selection") { model.setInventoryVariantSelection([]) }
                    .disabled(selectedCount == 0 || model.busy || model.setupLocked)
                Spacer(minLength: 0)
                Text("Up to 20 configurations").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 480)
            .accessibilityElement(children: .contain)
    }

    private func selection(for variant: ProductVariant) -> Binding<Bool> {
        Binding(get: { model.preferences.selectedVariantIDs.contains(variant.id) }, set: { selected in
            if selected != model.preferences.selectedVariantIDs.contains(variant.id) { model.toggleVariant(variant.id) }
        })
    }
}
