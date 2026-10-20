import Foundation
import Observation
import PilotCore

enum CheckoutDiagnosticAction: String, Equatable, Sendable {
    case idle, openingBag, openingProduct, addingItem, openingCheckout, continuingAsGuest
    case selectingPickup, enteringContact, enteringPayment, awaitingReview, stopped
}

enum CheckoutDiagnosticRoute: String, Equatable, Sendable {
    case idle, product, bag, signIn, checkout, pageNotFound, securityError, otherApple, external

    static func classify(_ url: URL?) -> Self {
        guard let url, url.absoluteString != "about:blank" else { return .idle }
        guard CheckoutPagePolicy.isAppleHTTPS(url) else { return .external }
        let path = url.path.lowercased()
        if path.range(of: #"\A(?:/[a-z]{2})?/shop/(?:go/)?404/?\z"#, options: .regularExpression) != nil { return .pageNotFound }
        if path.range(of: #"\A(?:/[a-z]{2})?/shop/(?:go/)?(?:403|429|541|error)(?:/|$)"#, options: .regularExpression) != nil { return .securityError }
        if path.hasSuffix("/shop/bag") || path.hasSuffix("/shop/bag/") { return .bag }
        if path.hasSuffix("/shop/signin") || path.hasSuffix("/shop/signin/") { return .signIn }
        if path.hasSuffix("/shop/checkout") || path.hasSuffix("/shop/checkout/") { return .checkout }
        if path.contains("/shop/product/") || path.contains("/shop/buy-") { return .product }
        return .otherApple
    }
}

enum CheckoutDiagnosticSource: String, Equatable, Sendable { case mainFrame, fetch, xhr }

struct CheckoutDiagnosticEvent: Identifiable, Equatable, Sendable {
    let id: Int
    let action: CheckoutDiagnosticAction
    let route: CheckoutDiagnosticRoute
    let source: CheckoutDiagnosticSource?
    let status: Int?
    let phase: CheckoutSnapshot.Phase?
}

/// Only fixed classifications and numeric HTTP evidence are retained. Page URLs,
/// headers, content, profile values and session identifiers never enter this model.
@MainActor @Observable final class CheckoutPageDiagnostics {
    private(set) var action: CheckoutDiagnosticAction = .idle
    private(set) var currentRoute: CheckoutDiagnosticRoute = .idle
    private(set) var mainFrameStatus: Int?
    private(set) var phase: CheckoutSnapshot.Phase?
    private(set) var blockingStatus: Int?
    private(set) var blockingSource: CheckoutDiagnosticSource?
    private(set) var isBlocked = false
    private(set) var history: [CheckoutDiagnosticEvent] = []
    private var sequence = 0

    func reset() {
        action = .idle; currentRoute = .idle; mainFrameStatus = nil; phase = nil
        blockingStatus = nil; blockingSource = nil; isBlocked = false
        history = []; sequence = 0
    }
    func recordAction(_ action: CheckoutDiagnosticAction) {
        self.action = action
        append()
    }
    func recordNavigation(_ url: URL?, resetStatus: Bool = false) {
        currentRoute = .classify(url)
        if resetStatus { mainFrameStatus = nil; phase = nil }
        append()
    }
    func recordResponse(status: Int, source: CheckoutDiagnosticSource, route: CheckoutDiagnosticRoute) {
        guard (100...599).contains(status) else { return }
        if source == .mainFrame { currentRoute = route; mainFrameStatus = status }
        if route != .external { recordBlockingStatus(status, source: source) }
        append(source: source, status: status, route: route)
    }
    func recordBlockingStatus(_ status: Int, source: CheckoutDiagnosticSource) {
        guard [403, 429, 541].contains(status) else { return }
        if blockingStatus == nil { blockingStatus = status; blockingSource = source }
        isBlocked = true
    }
    func clearActiveBlock() { isBlocked = false }
    func recordSnapshot(_ snapshot: CheckoutSnapshot) {
        phase = snapshot.phase
        currentRoute = snapshot.phase == .pageNotFound ? .pageNotFound : .classify(URL(string: snapshot.sourceURL))
        append()
    }
    private func append(source: CheckoutDiagnosticSource? = nil, status: Int? = nil, route: CheckoutDiagnosticRoute? = nil) {
        let route = route ?? currentRoute
        if let previous = history.first, previous.action == action, previous.route == route,
           previous.source == source, previous.status == status, previous.phase == phase { return }
        sequence += 1
        history.insert(CheckoutDiagnosticEvent(id: sequence, action: action, route: route, source: source, status: status, phase: phase), at: 0)
        if history.count > 8 { history.removeLast(history.count - 8) }
    }
}
