import SwiftUI

struct CheckoutRehearsalWindow: View {
    @Bindable var model: PilotModel
    private var rehearsal: CheckoutRehearsal { model.rehearsal }
    private var readingProfile: Bool { model.startingCheckoutTest && !rehearsal.isActive }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(readingProfile ? "Checkout test · Starting" : rehearsal.state == .notStarted ? "Checkout test · Not started" : rehearsal.browserKind == .safari ? "Checkout test · App submission disabled" : "Checkout test · Orders disabled", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                if model.startingCheckoutTest || rehearsal.state == .preparing { ProgressView().controlSize(.small) }
                if rehearsal.state == .manualInputRequired {
                    Button("Continue to review") { Task { await rehearsal.resume() } }
                }
                if rehearsal.state == .blocked {
                    Button("Continue after resolving session") { Task { await rehearsal.resume() } }
                }
                Button("End test") { model.cancelCheckoutTest() }
            }.padding()
            VStack(alignment: .leading, spacing: 6) {
                Text(readingProfile ? "Reading the local checkout profile…" : rehearsal.detail)
                    .textSelection(.enabled)
                Text(rehearsal.browserKind == .safari
                     ? "This guest-only test runs in Safari. Pickup Pilot never submits the test order or requests sign-in. Enter ordinary checkout fields locally in Safari; keep card details out of chat."
                     : "This separate guest-only test browser cannot submit an order. Complete ordinary checkout fields here; sign-in and authentication are never requested by this app. Keep card details out of chat.")
                    .font(.caption).foregroundStyle(.secondary)
                if let review = rehearsal.review {
                    Text("Verified review: \(review.currencyCode) \(review.total.formatted()) · \(review.pickupSlot)")
                        .font(.callout.bold())
                }
                if rehearsal.state != .notStarted, let diagnostics = rehearsal.diagnostics {
                    CheckoutDiagnosticsView(diagnostics: diagnostics)
                }
            }.padding([.horizontal, .bottom]).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if readingProfile {
                ContentUnavailableView("Preparing checkout test", systemImage: "hourglass", description: Text("Waiting for local checkout profile access. Safari opens after the profile is ready."))
            } else if rehearsal.state == .notStarted {
                ContentUnavailableView("Checkout test not started", systemImage: "exclamationmark.triangle", description: Text("Resolve the message above, then return to Overview and choose Test to final review. No checkout browser was opened for this attempt."))
            } else if rehearsal.browserKind == .safari {
                SafariCheckoutStatusView(reviewOnly: true, showBrowser: rehearsal.showBrowser)
            } else {
                CheckoutWebView(webView: rehearsal.webView)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .onDisappear { model.cancelCheckoutTest() }
    }
}
