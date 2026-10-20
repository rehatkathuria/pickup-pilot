import SwiftUI
import PilotCore

struct ObservedStoreRow: View {
    let store: RetailStore
    let priority: Int
    let responses: [StoreAvailability]
    let hasResponse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(priority). \(store.name) · \(store.id)")
                Spacer(minLength: 12)
                if responses.count == 1, let response = responses.first {
                    Label(title(response.state), systemImage: icon(response.state)).font(.callout.bold())
                } else {
                    Label(hasResponse ? "Unverified" : "Not checked yet", systemImage: "questionmark.circle").font(.callout)
                }
            }
            if responses.count == 1, let response = responses.first {
                Text(response.message.isEmpty ? "Apple supplied no pickup quote." : response.message)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if hasResponse {
                Text(responses.isEmpty ? "Apple did not return this selected store/configuration pair." : "Apple returned more than one response for this pair.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
    private func title(_ state: AvailabilityState) -> String {
        switch state {
        case .available: "Pickup available"
        case .unavailable: "Unavailable"
        case .disabled: "Pickup disabled"
        }
    }
    private func icon(_ state: AvailabilityState) -> String {
        switch state {
        case .available: "checkmark.circle"
        case .unavailable: "minus.circle"
        case .disabled: "nosign"
        }
    }
}
