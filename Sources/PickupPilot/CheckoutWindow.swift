import SwiftUI
import WebKit

struct CheckoutWindow: View {
    @Bindable var model: PilotModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(model.coordinator.status.title, systemImage: "lock.shield")
                Spacer()
                if model.coordinator.status == .manualInputRequired {
                    Button(model.checkout.requiresPaymentConfirmation ? "Confirm payment and allow order" : "Continue checkout") {
                        model.coordinator.resumeAuthentication()
                    }
                }
                if model.coordinator.status == .uncertain {
                    Button("Check visible confirmation") { Task { await model.reconcileVisibleConfirmation() } }
                }
                if !model.coordinator.isArmed && !model.coordinator.journal.blocksPurchase {
                    Button("Return to bag") { Task { await model.returnToAppleBag() } }
                        .disabled(!model.canSaveResolvedAppleSession)
                    Button(model.checkout.usesBrowserManagedSession ? "Verify Safari session" : "Save resolved Apple session") { Task { await model.saveResolvedAppleSession() } }
                        .disabled(!model.canSaveResolvedAppleSession)
                }
                if model.coordinator.isArmed { Button("Disarm") { model.coordinator.stop() } }
            }.padding()
            Text(model.coordinator.detail).textSelection(.enabled).padding([.horizontal, .bottom])
            if !model.coordinator.isArmed && !model.coordinator.journal.blocksPurchase {
                Text(model.checkout.usesBrowserManagedSession
                    ? "Checkout is disarmed. Return to a working bag or product page in Pickup Pilot’s Safari window before starting a new attempt. Verify that page before retrying; verification never arms checkout or places an order."
                    : "Checkout is disarmed. Return to a working bag or product page in this same checkout window before starting a new attempt. Save only a verified working page; saving never arms checkout or places an order.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true).padding([.horizontal, .bottom])
                if !model.appleSessionRecoveryDetail.isEmpty {
                    Text(model.appleSessionRecoveryDetail).font(.callout).textSelection(.enabled).padding([.horizontal, .bottom])
                }
            }
            if let diagnostics = model.checkout.diagnostics,
               diagnostics.action != .idle || diagnostics.currentRoute != .idle || diagnostics.mainFrameStatus != nil {
                CheckoutDiagnosticsView(diagnostics: diagnostics).padding([.horizontal, .bottom])
            }
            if model.coordinator.isArmed && model.checkout.requiresPaymentConfirmation {
                Text("This confirmation permits one authorized order within your armed limits. Check the payment method on Apple’s final review first.")
                    .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .bottom])
            }
            Text("Checkout uses Apple's guest option automatically. If guest checkout is unavailable or a security challenge is required, the attempt stops. Final submission still requires verified item, store, pickup and total details.")
                .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom])
            Divider()
            if model.checkout.browserKind == .safari {
                SafariCheckoutStatusView(reviewOnly: false, showBrowser: { await model.showSafariCheckout() })
            } else {
                CheckoutWebView(webView: model.checkout.webView)
            }
        }.frame(minWidth: 760, minHeight: 600)
    }
}
struct CheckoutWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
