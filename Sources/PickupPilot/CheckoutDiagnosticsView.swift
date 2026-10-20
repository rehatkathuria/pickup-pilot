import SwiftUI
import PilotCore

struct CheckoutDiagnosticsView: View {
    let diagnostics: CheckoutPageDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checkout response details").font(.callout.bold())
            Text("Step: \(actionTitle(diagnostics.action)) · Current page: \(routeTitle(diagnostics.currentRoute))\(diagnostics.mainFrameStatus.map { " · HTTP \($0)" } ?? "")")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if let status = diagnostics.blockingStatus, let source = diagnostics.blockingSource {
                Text("Observed access/rate-limit response: HTTP \(status) · \(sourceTitle(source))")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if diagnostics.currentRoute == .pageNotFound {
                Text("Page Not Found is separate from an access or rate-limit response. No such response was recorded for this attempt.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Recent response history") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(diagnostics.history.enumerated()), id: \.offset) { _, event in
                        Text(eventDescription(event)).font(.caption).textSelection(.enabled)
                    }
                    Text("Only checkout steps, page categories and HTTP codes are shown.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventDescription(_ event: CheckoutDiagnosticEvent) -> String {
        var text = actionTitle(event.action) + " · " + routeTitle(event.route)
        if let source = event.source { text += " · " + sourceTitle(source) }
        if let status = event.status { text += " · HTTP \(status)" }
        if let phase = event.phase { text += " · " + phase.rawValue }
        return text
    }
    private func actionTitle(_ action: CheckoutDiagnosticAction) -> String {
        switch action {
        case .idle: "No checkout action yet"
        case .openingBag: "Opening bag"
        case .openingProduct: "Opening selected product"
        case .addingItem: "Adding selected item"
        case .openingCheckout: "Opening checkout"
        case .continuingAsGuest: "Continuing as guest"
        case .selectingPickup: "Selecting pickup"
        case .enteringContact: "Entering pickup contact"
        case .enteringPayment: "Entering payment"
        case .awaitingReview: "Verifying final review"
        case .stopped: "Checkout stopped"
        }
    }
    private func routeTitle(_ route: CheckoutDiagnosticRoute) -> String {
        switch route {
        case .idle: "No page yet"
        case .product: "Product"
        case .bag: "Bag"
        case .signIn: "Sign-in"
        case .checkout: "Checkout"
        case .pageNotFound: "Page Not Found"
        case .securityError: "HTTP error page"
        case .otherApple: "Other Apple page"
        case .external: "External page"
        }
    }
    private func sourceTitle(_ source: CheckoutDiagnosticSource) -> String {
        switch source {
        case .mainFrame: "Page navigation"
        case .fetch: "Checkout fetch request"
        case .xhr: "Checkout XHR request"
        }
    }
}
