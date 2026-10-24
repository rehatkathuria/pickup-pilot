import AppKit
import Foundation
import Observation
import PilotCore
import UserNotifications

enum InventoryAlertAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, unavailable
}

enum InventoryAlertSetting: Equatable, Sendable {
    case enabled, disabled, notSupported

    var label: String {
        switch self {
        case .enabled: "on"
        case .disabled: "off"
        case .notSupported: "unavailable"
        }
    }
}

struct InventoryAlertSettings: Equatable, Sendable {
    var authorization: InventoryAlertAuthorization
    var alerts: InventoryAlertSetting
    var sounds: InventoryAlertSetting
    var badges: InventoryAlertSetting
    var timeSensitive: InventoryAlertSetting

    static let unknown = Self(authorization: .notDetermined, alerts: .notSupported, sounds: .notSupported,
                              badges: .notSupported, timeSensitive: .notSupported)
    static let unavailable = Self(authorization: .unavailable, alerts: .notSupported, sounds: .notSupported,
                                  badges: .notSupported, timeSensitive: .notSupported)
}

/// Only immutable values cross the notification center's callback queue.
struct InventoryAlertPayload: Equatable, Sendable {
    var identifier: String
    var title: String
    var subtitle: String
    var body: String
    var badge: Int
    var timeSensitive: Bool
}

@MainActor protocol InventoryAlertCenter: AnyObject {
    func install(delegate: any UNUserNotificationCenterDelegate)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func settings() async -> InventoryAlertSettings
    func add(_ payload: InventoryAlertPayload) async throws
    func setBadgeCount(_ count: Int) async throws
    func removeDelivered(identifiers: [String])
}

@MainActor protocol InventoryAlertAttention: AnyObject {
    func setBadgeLabel(_ label: String?)
    func requestAttention() -> Int
    func cancelAttention(_ identifier: Int)
}

@MainActor private final class NativeInventoryAlertAttention: InventoryAlertAttention {
    private var isBundledApplication: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    func setBadgeLabel(_ label: String?) {
        guard isBundledApplication else { return }
        NSApp?.dockTile.badgeLabel = label
    }
    func requestAttention() -> Int {
        guard isBundledApplication else { return 0 }
        return NSApp?.requestUserAttention(.criticalRequest) ?? 0
    }
    func cancelAttention(_ identifier: Int) {
        guard isBundledApplication else { return }
        NSApp?.cancelUserAttentionRequest(identifier)
    }
}

private struct InventoryAlertCenterFailure: Error, Sendable {
    let code: Int
}

/// Native notification APIs are resolved lazily. Constructing a model or rendering
/// a standalone SwiftPM test must never open the system notification service.
@MainActor private final class NativeInventoryAlertCenter: InventoryAlertCenter {
    private var center: UNUserNotificationCenter?

    private func availableCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        if let center { return center }
        let center = UNUserNotificationCenter.current()
        self.center = center
        return center
    }

    func install(delegate: any UNUserNotificationCenterDelegate) { availableCenter()?.delegate = delegate }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        guard let center = availableCenter() else { throw InventoryAlertCenterFailure(code: -1) }
        return try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: options) { granted, error in
                if let error { continuation.resume(throwing: InventoryAlertCenterFailure(code: (error as NSError).code)) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func settings() async -> InventoryAlertSettings {
        guard let center = availableCenter() else { return .unavailable }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let authorization: InventoryAlertAuthorization
                switch settings.authorizationStatus {
                case .notDetermined: authorization = .notDetermined
                case .denied: authorization = .denied
                case .authorized: authorization = .authorized
                case .provisional: authorization = .provisional
                @unknown default: authorization = .unavailable
                }
                continuation.resume(returning: InventoryAlertSettings(
                    authorization: authorization, alerts: Self.setting(settings.alertSetting),
                    sounds: Self.setting(settings.soundSetting), badges: Self.setting(settings.badgeSetting),
                    timeSensitive: Self.setting(settings.timeSensitiveSetting)))
            }
        }
    }

    private nonisolated static func setting(_ value: UNNotificationSetting) -> InventoryAlertSetting {
        switch value {
        case .enabled: .enabled
        case .disabled: .disabled
        case .notSupported: .notSupported
        @unknown default: .notSupported
        }
    }

    func add(_ payload: InventoryAlertPayload) async throws {
        guard let center = availableCenter() else { throw InventoryAlertCenterFailure(code: -1) }
        let content = Self.content(for: payload)
        let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: InventoryAlertCenterFailure(code: (error as NSError).code)) }
                else { continuation.resume() }
            }
        }
    }

    nonisolated static func content(for payload: InventoryAlertPayload) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.badge = NSNumber(value: payload.badge)
        content.sound = .default
        content.categoryIdentifier = InventoryAlertService.categoryIdentifier
        content.threadIdentifier = "pickup-pilot-inventory"
        content.targetContentIdentifier = "inventory-map"
        content.userInfo = ["destination": "inventory-map"]
        // Time Sensitive is used only when macOS reports it enabled for this app.
        // This app does not request or simulate entitlement-only critical alerts.
        content.interruptionLevel = payload.timeSensitive ? .timeSensitive : .active
        content.relevanceScore = 1
        return content
    }

    func setBadgeCount(_ count: Int) async throws {
        guard let center = availableCenter() else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.setBadgeCount(count) { error in
                if let error { continuation.resume(throwing: InventoryAlertCenterFailure(code: (error as NSError).code)) }
                else { continuation.resume() }
            }
        }
    }

    func removeDelivered(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        availableCenter()?.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// The delegate has immutable Sendable callbacks. It copies the only needed
/// response fields before hopping to the main actor; no framework object escapes.
@MainActor final class InventoryNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated let onOpen: @MainActor @Sendable () async -> Void

    init(onOpen: @escaping @MainActor @Sendable () async -> Void) { self.onOpen = onOpen }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Self.presentationOptions(categoryIdentifier: notification.request.content.categoryIdentifier)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await receiveResponse(categoryIdentifier: response.notification.request.content.categoryIdentifier,
                              actionIdentifier: response.actionIdentifier)
    }

    nonisolated static func presentationOptions(categoryIdentifier: String) -> UNNotificationPresentationOptions {
        categoryIdentifier == InventoryAlertService.categoryIdentifier ? [.banner, .list, .sound, .badge] : []
    }

    nonisolated func receiveResponse(categoryIdentifier: String, actionIdentifier: String) async {
        guard categoryIdentifier == InventoryAlertService.categoryIdentifier,
              actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await onOpen()
    }
}

/// All observable state and AppKit attention effects belong to the main actor.
/// No permission request occurs until the user's Start / Enable Alerts action.
@MainActor @Observable final class InventoryAlertService {
    nonisolated static let categoryIdentifier = "PICKUP_PILOT_INVENTORY_CHANGE"
    nonisolated static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]

    private let center: any InventoryAlertCenter
    private let attention: any InventoryAlertAttention
    private var delegate: InventoryNotificationDelegate?
    private var attentionRequest: Int?
    private var deliveredIdentifiers: Set<String> = []
    private var acknowledgementGeneration = 0
    private struct ProductStore: Hashable { let storeID: String; let variantID: String }
    private var waitingForAuthorization: [ProductStore: InventoryChange] = [:]
    private(set) var authorization: InventoryAlertSettings = .unknown
    private(set) var unreadCount = 0
    private(set) var lastError: String?
    private(set) var requestingAuthorization = false
    private var pendingMapOpen = false
    var onOpenMap: (@MainActor () -> Void)? {
        didSet {
            if pendingMapOpen, let onOpenMap {
                pendingMapOpen = false
                onOpenMap()
            }
        }
    }

    init(center: (any InventoryAlertCenter)? = nil, attention: (any InventoryAlertAttention)? = nil) {
        self.center = center ?? NativeInventoryAlertCenter()
        self.attention = attention ?? NativeInventoryAlertAttention()
    }

    isolated deinit {
        if let attentionRequest { attention.cancelAttention(attentionRequest) }
    }

    nonisolated static func notificationContent(for payload: InventoryAlertPayload) -> UNMutableNotificationContent {
        NativeInventoryAlertCenter.content(for: payload)
    }

    var notificationsEnabled: Bool { authorization.authorization == .authorized || authorization.authorization == .provisional }
    var pendingChangeCount: Int { unreadCount }

    var authorizationSummary: String {
        switch authorization.authorization {
        case .notDetermined: "Enable inventory alerts"
        case .denied: "Notifications are denied in macOS Settings"
        case .authorized where authorization.alerts == .enabled && authorization.sounds == .enabled && authorization.badges == .enabled:
            "Inventory alerts, sounds and badges are enabled"
        case .authorized: "Some notification alerts are turned off"
        case .provisional: "Notifications are delivered quietly"
        case .unavailable: "Notifications require the installed app"
        }
    }

    var deliveryDetails: String {
        "Alerts \(authorization.alerts.label) · Sounds \(authorization.sounds.label) · Badges \(authorization.badges.label) · Time Sensitive \(authorization.timeSensitive.label). macOS notification settings and Focus can limit delivery."
    }

    func installNotificationDelegate() {
        guard delegate == nil else { return }
        let delegate = InventoryNotificationDelegate { [weak self] in
            guard let self else { return }
            await self.acknowledge()
            if let onOpenMap = self.onOpenMap { onOpenMap() }
            else { self.pendingMapOpen = true }
        }
        self.delegate = delegate
        center.install(delegate: delegate)
    }

    func requestAuthorization() async {
        guard !requestingAuthorization else { return }
        requestingAuthorization = true
        installNotificationDelegate()
        lastError = nil
        do { _ = try await center.requestAuthorization(options: Self.authorizationOptions) }
        catch { lastError = "macOS could not enable notifications. Check Pickup Pilot in System Settings → Notifications." }
        await refreshAuthorization()
        requestingAuthorization = false
        await deliverWaitingChanges()
    }

    func refreshAuthorization() async { authorization = await center.settings() }
    func enableAlerts() async { await requestAuthorization() }

    func notify(changes: [InventoryChange]) async {
        guard !changes.isEmpty, !Task.isCancelled else { return }
        let generation = acknowledgementGeneration
        unreadCount = unreadCount.addingReportingOverflow(changes.count).overflow ? Int.max : unreadCount + changes.count
        attention.setBadgeLabel(String(unreadCount))
        if let attentionRequest { attention.cancelAttention(attentionRequest) }
        attentionRequest = attention.requestAttention()
        lastError = nil
        await refreshAuthorization()
        guard generation == acknowledgementGeneration, !Task.isCancelled else { return }
        if requestingAuthorization || authorization.authorization == .notDetermined {
            for change in changes {
                waitingForAuthorization[ProductStore(storeID: change.storeID, variantID: change.variantID)] = change
            }
            return
        }
        guard notificationsEnabled else { return }
        await deliver(changes: changes, generation: generation)
    }

    private func deliverWaitingChanges() async {
        guard notificationsEnabled else {
            if authorization.authorization != .notDetermined { waitingForAuthorization.removeAll() }
            return
        }
        guard !Task.isCancelled, !waitingForAuthorization.isEmpty else { return }
        let changes = waitingForAuthorization.values.sorted {
            if $0.storeID == $1.storeID { return $0.variantID < $1.variantID }
            return $0.storeID < $1.storeID
        }
        waitingForAuthorization.removeAll()
        await deliver(changes: changes, generation: acknowledgementGeneration)
    }

    private func deliver(changes: [InventoryChange], generation: Int) async {
        guard !changes.isEmpty, generation == acknowledgementGeneration, !Task.isCancelled else { return }
        let identifier = "inventory-change-\(UUID().uuidString)"
        let payload = Self.payload(changes: changes, identifier: identifier, badge: unreadCount,
                                   timeSensitive: authorization.timeSensitive == .enabled)
        deliveredIdentifiers.insert(identifier)
        do {
            try await center.add(payload)
            if generation != acknowledgementGeneration || Task.isCancelled {
                center.removeDelivered(identifiers: [identifier])
                deliveredIdentifiers.remove(identifier)
                try? await center.setBadgeCount(unreadCount)
            }
        } catch {
            deliveredIdentifiers.remove(identifier)
            if generation == acknowledgementGeneration, !Task.isCancelled {
                lastError = "macOS could not deliver the inventory notification. The map and Dock badge still show the change."
            }
        }
    }

    /// Stops deferred work when monitoring stops; unread, already observed changes
    /// remain visible until the user acknowledges them.
    func cancelPendingDelivery() {
        acknowledgementGeneration &+= 1
        waitingForAuthorization.removeAll()
    }

    func acknowledge() async {
        cancelPendingDelivery()
        unreadCount = 0
        attention.setBadgeLabel(nil)
        if let attentionRequest { attention.cancelAttention(attentionRequest) }
        attentionRequest = nil
        let identifiers = Array(deliveredIdentifiers)
        deliveredIdentifiers.removeAll()
        center.removeDelivered(identifiers: identifiers)
        do { try await center.setBadgeCount(0) }
        catch { lastError = "macOS could not clear the notification badge. The inventory changes are acknowledged in Pickup Pilot." }
    }

    func acknowledgeAll() async { await acknowledge() }

    nonisolated static func payload(changes: [InventoryChange], identifier: String, badge: Int,
                                    timeSensitive: Bool) -> InventoryAlertPayload {
        let first = changes[0]
        let title: String
        if changes.count == 1 {
            title = first.newState == .available ? "Stock available at \(first.storeName)" : "Inventory changed at \(first.storeName)"
        } else { title = "\(changes.count) inventory changes nearby" }
        let lines = changes.prefix(5).map { change in
            let state: String
            switch change.newState {
            case .available: state = "Available"
            case .unavailable: state = "Unavailable"
            case .disabled: state = "Pickup unavailable"
            }
            let quote = change.newMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(change.productName) · \(change.storeName): \(state)\(quote.isEmpty ? "" : " — \(quote)")"
        }
        let extra = changes.count > 5 ? "\nAnd \(changes.count - 5) more. Open the map to review." : ""
        return InventoryAlertPayload(identifier: identifier, title: title, subtitle: "Pickup Pilot · Nearby Apple inventory",
                                     body: lines.joined(separator: "\n") + extra, badge: badge, timeSensitive: timeSensitive)
    }
}
