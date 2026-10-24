import Foundation
import PilotCore
import Testing
import UserNotifications
@testable import PickupPilot

private enum AlertFixtureFailure: Error { case unavailable }

@MainActor private final class AlertCenterFixture: InventoryAlertCenter {
    var currentSettings = InventoryAlertSettings(authorization: .authorized, alerts: .enabled, sounds: .enabled,
                                                badges: .enabled, timeSensitive: .enabled)
    var permissionGranted = true
    var authorizationError = false
    var deliveryError = false
    var badgeError = false
    var suspendSettings = false
    var suspendAdd = false
    var suspendAuthorization = false
    private(set) var authorizationOptions: [UNAuthorizationOptions] = []
    private(set) var settingsReads = 0
    private(set) var installedDelegates = 0
    private(set) var delegate: (any UNUserNotificationCenterDelegate)?
    private(set) var payloads: [InventoryAlertPayload] = []
    private(set) var badgeCounts: [Int] = []
    private(set) var removals: [[String]] = []
    private var settingsContinuation: CheckedContinuation<InventoryAlertSettings, Never>?
    private var addContinuation: CheckedContinuation<Void, Error>?
    private var authorizationContinuation: CheckedContinuation<Bool, Error>?

    func install(delegate: any UNUserNotificationCenterDelegate) {
        installedDelegates += 1
        self.delegate = delegate
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationOptions.append(options)
        if authorizationError { throw AlertFixtureFailure.unavailable }
        if suspendAuthorization { return try await withCheckedThrowingContinuation { authorizationContinuation = $0 } }
        return permissionGranted
    }
    func settings() async -> InventoryAlertSettings {
        settingsReads += 1
        if suspendSettings { return await withCheckedContinuation { settingsContinuation = $0 } }
        return currentSettings
    }
    func add(_ payload: InventoryAlertPayload) async throws {
        payloads.append(payload)
        if deliveryError { throw AlertFixtureFailure.unavailable }
        if suspendAdd { try await withCheckedThrowingContinuation { addContinuation = $0 } }
    }
    func setBadgeCount(_ count: Int) async throws {
        badgeCounts.append(count)
        if badgeError { throw AlertFixtureFailure.unavailable }
    }
    func removeDelivered(identifiers: [String]) { removals.append(identifiers) }
    func finishSettings() { let pending = settingsContinuation; settingsContinuation = nil; pending?.resume(returning: currentSettings) }
    func finishAdd() { let pending = addContinuation; addContinuation = nil; pending?.resume() }
    func finishAuthorization() { let pending = authorizationContinuation; authorizationContinuation = nil; pending?.resume(returning: permissionGranted) }
}

@MainActor private final class AlertAttentionFixture: InventoryAlertAttention {
    private(set) var badges: [String?] = []
    private(set) var requests = 0
    private(set) var cancellations: [Int] = []
    func setBadgeLabel(_ label: String?) { badges.append(label) }
    func requestAttention() -> Int { requests += 1; return requests }
    func cancelAttention(_ identifier: Int) { cancellations.append(identifier) }
}

@Suite(.serialized) @MainActor struct InventoryAlertServiceTests {
    private func change(store: String = "Store One", product: String = "Synthetic accessory",
                        state: AvailabilityState = .available, message: String = "Pickup today") -> InventoryChange {
        InventoryChange(storeID: "R001", storeName: store, variantID: "SYNTHETIC/A", productName: product,
                        oldState: .unavailable, newState: state, oldMessage: "Unavailable", newMessage: message)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AlertFixtureFailure.unavailable
    }

    @Test func constructingAndInstallingDoNotRequestPermissionOrReadSettings() {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        let service = InventoryAlertService(center: center, attention: attention)
        #expect(center.installedDelegates == 0)
        #expect(center.authorizationOptions.isEmpty)
        #expect(center.settingsReads == 0)
        #expect(attention.badges.isEmpty && attention.requests == 0)
        service.installNotificationDelegate()
        service.installNotificationDelegate()
        #expect(center.installedDelegates == 1)
        #expect(center.authorizationOptions.isEmpty)
        #expect(center.settingsReads == 0)
    }

    @Test func authorizationRequestsAlertSoundBadgeAndReadsActualSettings() async {
        let center = AlertCenterFixture()
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        await service.requestAuthorization()
        #expect(center.authorizationOptions == [[.alert, .sound, .badge]])
        #expect(center.installedDelegates == 1)
        #expect(center.settingsReads == 1)
        #expect(service.notificationsEnabled)
        #expect(service.authorizationSummary.contains("alerts, sounds and badges"))
        #expect(!service.requestingAuthorization)
        #expect(service.lastError == nil)
    }

    @Test func authorizationFailureIsVisibleWithoutInventingGrant() async {
        let center = AlertCenterFixture()
        center.authorizationError = true
        center.currentSettings.authorization = .denied
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        await service.requestAuthorization()
        #expect(!service.notificationsEnabled)
        #expect(service.authorizationSummary.contains("denied"))
        #expect(service.lastError?.contains("could not enable") == true)
    }

    @Test func permissionRequestsDoNotOverlap() async throws {
        let center = AlertCenterFixture()
        center.suspendAuthorization = true
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        let request = Task { await service.requestAuthorization() }
        try await waitUntil { service.requestingAuthorization && center.authorizationOptions.count == 1 }
        await service.requestAuthorization()
        #expect(center.authorizationOptions.count == 1)
        center.finishAuthorization()
        await request.value
        #expect(!service.requestingAuthorization)
    }

    @Test func changesDuringPermissionPromptAreDeliveredAfterGrantWithoutDoubleCounting() async throws {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        center.suspendAuthorization = true
        center.currentSettings.authorization = .notDetermined
        let service = InventoryAlertService(center: center, attention: attention)
        let permission = Task { await service.requestAuthorization() }
        try await waitUntil { center.authorizationOptions.count == 1 }
        await service.notify(changes: [change()])
        #expect(center.payloads.isEmpty && service.unreadCount == 1)
        #expect(attention.requests == 1)
        center.currentSettings.authorization = .authorized
        center.finishAuthorization()
        await permission.value
        #expect(center.payloads.count == 1)
        #expect(center.payloads.first?.badge == 1)
        #expect(service.unreadCount == 1 && attention.requests == 1)
    }

    @Test func deferredPermissionAlertUsesLatestObservedStateForEachProductStore() async throws {
        let center = AlertCenterFixture()
        center.suspendAuthorization = true
        center.currentSettings.authorization = .notDetermined
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        let permission = Task { await service.requestAuthorization() }
        try await waitUntil { center.authorizationOptions.count == 1 }
        await service.notify(changes: [change()])
        await service.notify(changes: [change(state: .unavailable, message: "No longer available")])
        center.currentSettings.authorization = .authorized
        center.finishAuthorization()
        await permission.value
        #expect(center.payloads.count == 1)
        #expect(center.payloads.first?.title == "Inventory changed at Store One")
        #expect(center.payloads.first?.body.contains("No longer available") == true)
        #expect(center.payloads.first?.badge == 2 && service.unreadCount == 2)
    }

    @Test func acknowledgementOrStoppedMonitoringDiscardsDeferredPermissionDelivery() async throws {
        for acknowledge in [true, false] {
            let center = AlertCenterFixture()
            center.suspendAuthorization = true
            center.currentSettings.authorization = .notDetermined
            let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
            let permission = Task { await service.requestAuthorization() }
            try await waitUntil { center.authorizationOptions.count == 1 }
            await service.notify(changes: [change()])
            if acknowledge { await service.acknowledge() }
            else { service.cancelPendingDelivery() }
            center.currentSettings.authorization = .authorized
            center.finishAuthorization()
            await permission.value
            #expect(center.payloads.isEmpty)
            #expect(service.unreadCount == (acknowledge ? 0 : 1))
        }
    }

    @Test func deniedPermissionDoesNotReplayDeferredChangesAfterLaterEnable() async throws {
        let center = AlertCenterFixture()
        center.suspendAuthorization = true
        center.currentSettings.authorization = .notDetermined
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        let permission = Task { await service.requestAuthorization() }
        try await waitUntil { center.authorizationOptions.count == 1 }
        await service.notify(changes: [change()])
        center.currentSettings.authorization = .denied
        center.finishAuthorization()
        await permission.value
        center.suspendAuthorization = false
        center.currentSettings.authorization = .authorized
        await service.requestAuthorization()
        #expect(center.payloads.isEmpty && service.unreadCount == 1)
    }

    @Test func localNotificationBatchCountsEveryChangeAndRequestsAttentionImmediately() async {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        let service = InventoryAlertService(center: center, attention: attention)
        await service.notify(changes: [change(), change(store: "Store Two", state: .unavailable)])
        #expect(service.unreadCount == 2)
        #expect(attention.badges == ["2"])
        #expect(attention.requests == 1)
        #expect(center.authorizationOptions.isEmpty)
        #expect(center.payloads.count == 1)
        #expect(center.payloads.first?.badge == 2)
        #expect(center.payloads.first?.title == "2 inventory changes nearby")
        #expect(center.payloads.first?.body.contains("Store One: Available") == true)
        #expect(center.payloads.first?.body.contains("Store Two: Unavailable") == true)
        #expect(center.payloads.first?.timeSensitive == true)
        await service.notify(changes: [change(state: .disabled, message: "Pickup cannot be selected")])
        #expect(service.unreadCount == 3)
        #expect(attention.requests == 2)
        #expect(attention.cancellations == [1])
        #expect(center.payloads.last?.badge == 3)
        #expect(center.payloads.last?.body.contains("Pickup unavailable") == true)
    }

    @Test func emptyChangeBatchHasNoOSOrAttentionSideEffects() async {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        let service = InventoryAlertService(center: center, attention: attention)
        await service.notify(changes: [])
        #expect(service.unreadCount == 0)
        #expect(center.payloads.isEmpty && center.settingsReads == 0)
        #expect(attention.requests == 0 && attention.badges.isEmpty)
    }

    @Test func deniedNotificationsStillGetDockAttentionAndTruthfulStatus() async {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        center.currentSettings.authorization = .denied
        center.currentSettings.alerts = .disabled
        center.currentSettings.sounds = .disabled
        center.currentSettings.badges = .disabled
        let service = InventoryAlertService(center: center, attention: attention)
        await service.notify(changes: [change()])
        #expect(center.payloads.isEmpty)
        #expect(center.authorizationOptions.isEmpty)
        #expect(service.unreadCount == 1 && attention.requests == 1)
        #expect(!service.notificationsEnabled)
        #expect(service.authorizationSummary.contains("denied"))
        #expect(service.deliveryDetails.contains("Alerts off · Sounds off · Badges off"))
        #expect(service.deliveryDetails.contains("Focus"))
    }

    @Test func authorizedQuietSettingsRemainVisibleAndUseNormalInterruption() async {
        let center = AlertCenterFixture()
        center.currentSettings.sounds = .disabled
        center.currentSettings.timeSensitive = .notSupported
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        await service.notify(changes: [change()])
        #expect(service.authorizationSummary.contains("turned off"))
        #expect(service.deliveryDetails.contains("Sounds off"))
        #expect(service.deliveryDetails.contains("Time Sensitive unavailable"))
        #expect(center.payloads.first?.timeSensitive == false)
        center.currentSettings.authorization = .provisional
        await service.refreshAuthorization()
        #expect(service.authorizationSummary.contains("quietly"))
        #expect(service.notificationsEnabled)
    }

    @Test func deliveryFailureKeepsUnreadChangesAndShowsError() async {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        center.deliveryError = true
        let service = InventoryAlertService(center: center, attention: attention)
        await service.notify(changes: [change()])
        #expect(service.unreadCount == 1)
        #expect(attention.badges == ["1"])
        #expect(service.lastError?.contains("could not deliver") == true)
    }

    @Test func acknowledgementClearsOwnNotificationsBadgeAndNativeAttention() async throws {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        let service = InventoryAlertService(center: center, attention: attention)
        await service.notify(changes: [change()])
        let identifier = try #require(center.payloads.first?.identifier)
        await service.acknowledge()
        #expect(service.unreadCount == 0)
        #expect(attention.badges == ["1", nil])
        #expect(attention.cancellations == [1])
        #expect(center.badgeCounts == [0])
        #expect(center.removals == [[identifier]])
    }

    @Test func acknowledgementDuringSettingsReadPreventsStaleAlert() async throws {
        let center = AlertCenterFixture(), attention = AlertAttentionFixture()
        center.suspendSettings = true
        let service = InventoryAlertService(center: center, attention: attention)
        let notification = Task { await service.notify(changes: [change()]) }
        try await waitUntil { center.settingsReads == 1 }
        #expect(attention.requests == 1)
        await service.acknowledge()
        center.finishSettings()
        await notification.value
        #expect(service.unreadCount == 0)
        #expect(center.payloads.isEmpty)
        #expect(center.badgeCounts == [0])
    }

    @Test func acknowledgementDuringDeliveryRemovesLateArrivingAlert() async throws {
        let center = AlertCenterFixture()
        center.suspendAdd = true
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        let notification = Task { await service.notify(changes: [change()]) }
        try await waitUntil { center.payloads.count == 1 }
        let identifier = try #require(center.payloads.first?.identifier)
        await service.acknowledge()
        center.finishAdd()
        await notification.value
        #expect(service.unreadCount == 0)
        #expect(center.removals == [[identifier], [identifier]])
        #expect(center.badgeCounts == [0, 0])
    }

    @Test func canceledMonitorCannotDeliverAfterSettingsReadReturns() async throws {
        let center = AlertCenterFixture()
        center.suspendSettings = true
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        let notification = Task { await service.notify(changes: [change()]) }
        try await waitUntil { center.settingsReads == 1 }
        notification.cancel()
        center.finishSettings()
        await notification.value
        #expect(center.payloads.isEmpty)
        #expect(service.unreadCount == 1)
    }

    @Test func foregroundPresentationIncludesAllRequestedChannelsOnlyForInventory() {
        #expect(InventoryNotificationDelegate.presentationOptions(categoryIdentifier: InventoryAlertService.categoryIdentifier)
                == [.banner, .list, .sound, .badge])
        #expect(InventoryNotificationDelegate.presentationOptions(categoryIdentifier: "unrelated").isEmpty)
    }

    @Test func notificationClickAcknowledgesThenOpensMapButIgnoresOtherActions() async throws {
        let center = AlertCenterFixture()
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        var mapOpened = false
        var countWhenOpened: Int?
        service.onOpenMap = { mapOpened = true; countWhenOpened = service.unreadCount }
        service.installNotificationDelegate()
        await service.notify(changes: [change()])
        let delegate = try #require(center.delegate as? InventoryNotificationDelegate)
        await delegate.receiveResponse(categoryIdentifier: "unrelated", actionIdentifier: UNNotificationDefaultActionIdentifier)
        await delegate.receiveResponse(categoryIdentifier: InventoryAlertService.categoryIdentifier,
                                       actionIdentifier: UNNotificationDismissActionIdentifier)
        #expect(!mapOpened && service.unreadCount == 1)
        await delegate.receiveResponse(categoryIdentifier: InventoryAlertService.categoryIdentifier,
                                       actionIdentifier: UNNotificationDefaultActionIdentifier)
        #expect(mapOpened && countWhenOpened == 0)
        service.onOpenMap = {}
    }

    @Test func coldLaunchNotificationWaitsForMapWindowHandler() async throws {
        let center = AlertCenterFixture()
        let service = InventoryAlertService(center: center, attention: AlertAttentionFixture())
        service.installNotificationDelegate()
        let delegate = try #require(center.delegate as? InventoryNotificationDelegate)
        await delegate.receiveResponse(categoryIdentifier: InventoryAlertService.categoryIdentifier,
                                       actionIdentifier: UNNotificationDefaultActionIdentifier)
        var opens = 0
        service.onOpenMap = { opens += 1 }
        #expect(opens == 1)
        service.onOpenMap = { opens += 1 }
        #expect(opens == 1)
        service.onOpenMap = nil
    }

    @Test func nativeContentHasDefaultSoundBadgeMapDestinationAndSupportedInterruption() {
        let payload = InventoryAlertService.payload(changes: [change()], identifier: "inventory-change-synthetic", badge: 4,
                                                    timeSensitive: true)
        let content = InventoryAlertService.notificationContent(for: payload)
        #expect(content.title == "Stock available at Store One")
        #expect(content.sound != nil)
        #expect(content.badge == 4)
        #expect(content.categoryIdentifier == InventoryAlertService.categoryIdentifier)
        #expect(content.targetContentIdentifier == "inventory-map")
        #expect(content.userInfo["destination"] as? String == "inventory-map")
        #expect(content.interruptionLevel == .timeSensitive)
        var ordinary = payload; ordinary.timeSensitive = false
        #expect(InventoryAlertService.notificationContent(for: ordinary).interruptionLevel == .active)
    }

    @Test func longBatchStaysReadableAndReportsUndisplayedChanges() {
        let changes = (1...7).map { change(store: "Store \($0)") }
        let payload = InventoryAlertService.payload(changes: changes, identifier: "synthetic", badge: 7, timeSensitive: false)
        #expect(payload.body.contains("Store 5"))
        #expect(!payload.body.contains("Store 6"))
        #expect(payload.body.contains("And 2 more"))
    }
}
