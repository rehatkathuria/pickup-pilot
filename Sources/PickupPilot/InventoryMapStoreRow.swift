import SwiftUI

struct InventoryMapStoreRow: View {
    let store: InventoryMapPresentation.Store
    let selected: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Text(store.retailer.name).font(.headline).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if selected { Image(systemName: "mappin.circle.fill").foregroundStyle(.tint).accessibilityHidden(true) }
                    }
                    InventoryMapBadge(store: store, selected: selected)
                    if let distance = store.distance {
                        Text([distance, store.travelTime].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let time = store.travelTime {
                        Text(time).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityLabel("Show \(store.retailer.name) on map")
            if store.coordinate == nil {
                Label("Map location unavailable", systemImage: "mappin.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if selected {
                if !store.retailer.address.isEmpty { Text(store.retailer.address).font(.caption).foregroundStyle(.secondary) }
                ForEach(store.configurations) { configuration in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(configuration.name).font(.callout.weight(.medium))
                        Label(configuration.title, systemImage: configuration.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(configuration.state == .available && !store.isStale ? Color.green : .secondary)
                        Text(configuration.message).font(.caption).foregroundStyle(.secondary)
                        Text(configuration.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(14)
            .background(selected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08)) }
            .accessibilityElement(children: .contain)
    }
}
