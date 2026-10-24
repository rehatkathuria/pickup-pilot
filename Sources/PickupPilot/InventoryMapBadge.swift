import SwiftUI

struct InventoryMapBadge: View {
    let store: InventoryMapPresentation.Store
    var selected = false

    private var tint: Color {
        if store.isStale || store.configurations.isEmpty || store.unverifiedCount == store.configurations.count { return .secondary }
        if store.availableCount > 0 { return .green }
        if store.unverifiedCount > 0 { return .orange }
        return .secondary
    }
    private var symbol: String {
        if store.isStale { return "clock.arrow.circlepath" }
        if store.availableCount > 0 { return "checkmark.circle.fill" }
        if store.unverifiedCount > 0 || store.configurations.isEmpty { return "questionmark.circle" }
        return "minus.circle"
    }

    var body: some View {
        VStack(spacing: 4) {
            Label(store.badgeTitle, systemImage: symbol)
                .font(.caption.weight(.semibold))
            if store.configurations.count > 1 {
                HStack(spacing: 7) {
                    Label("\(store.availableCount)", systemImage: "checkmark.circle")
                    Label("\(store.unavailableCount)", systemImage: "minus.circle")
                    Label("\(store.disabledCount)", systemImage: "nosign")
                    Label("\(store.unverifiedCount)", systemImage: "questionmark.circle")
                }.font(.caption2).monospacedDigit().accessibilityHidden(true)
            }
        }
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(tint.opacity(0.10), in: .capsule)
            .overlay { Capsule().strokeBorder(selected ? Color.accentColor : tint.opacity(0.25), lineWidth: selected ? 2 : 1) }
            .accessibilityLabel(store.accessibilitySummary)
            .help(store.accessibilitySummary)
    }
}
