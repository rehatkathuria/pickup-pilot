import SwiftUI

/// Safari owns the visible website window and session; this panel only controls Pickup Pilot.
struct SafariCheckoutStatusView: View {
    let reviewOnly: Bool
    let showBrowser: @MainActor () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Checkout in Safari", systemImage: "safari")
                .font(.title2.bold())
            Text("Apple checkout opens in a separate Safari window. Safari manages its website cookies and session; Pickup Pilot does not import or export Safari cookies.")
                .fixedSize(horizontal: false, vertical: true)
            if reviewOnly {
                Text("Pickup Pilot will stop at review and will not submit an order. Safari’s own order button may remain available: do not place the order during this test.")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Show Safari checkout", systemImage: "arrow.up.forward.app", action: openBrowser)
                .buttonStyle(.borderedProminent)
            Text("If prompted, allow Pickup Pilot to control Safari in System Settings → Privacy & Security → Automation. Enable Safari Settings → Developer → Automation → Allow JavaScript from Apple Events. Enable web developer features in Settings → Advanced if Developer settings are hidden.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openBrowser() { Task { await showBrowser() } }
}
