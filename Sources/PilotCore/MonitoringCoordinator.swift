import Foundation
import Observation

public typealias InventoryProviding = InventoryFetching

public enum MonitoringClock {
    public static func monotonicNow() -> ContinuousClock.Instant { .now }
    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
    public static func sleep(_ seconds: TimeInterval) async throws {
        guard seconds.isFinite, seconds >= 0 else { throw CancellationError() }
        var remaining = seconds
        repeat {
            let interval = min(remaining, 3600)
            try await Task.sleep(for: .seconds(interval))
            remaining -= interval
        } while remaining > 0
    }
}

public enum PilotStatus: Equatable, Sendable {
    case stopped, checking, monitoring, waiting, preparing, authenticationRequired, manualInputRequired, submitting, confirmed, uncertain, failed
    public var title: String {
        switch self {
        case .stopped: "Disarmed"; case .checking: "Checking availability"; case .monitoring: "Monitoring"
        case .waiting: "Waiting for attempt window"; case .preparing: "Preparing checkout"
        case .authenticationRequired: "Guest checkout unavailable"; case .submitting: "Submitting one order"
        case .manualInputRequired: "Checkout input needed"
        case .confirmed: "Order confirmed"; case .uncertain: "Order needs reconciliation"; case .failed: "Needs attention"
        }
    }
}
public struct PilotEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let message: String
    public init(date: Date, message: String) { self.id = UUID(); self.date = date; self.message = message }
}

/// UI-observed orchestration is main-actor confined; network/storage are Sendable services.
@MainActor
@Observable
public final class MonitoringCoordinator {
    public private(set) var status: PilotStatus = .stopped
    public private(set) var isArmed = false
    public private(set) var detail = "Set up your stores, configurations, schedule and secure checkout profile."
    public private(set) var events: [PilotEvent] = []
    public private(set) var snapshot: InventorySnapshot?
    public private(set) var journal = PurchaseJournal()
    public private(set) var nextCheck: Date?
    public private(set) var lastCheck: Date?
    public private(set) var monitoringPlan: MonitoringPlan?
    public private(set) var checkCount = 0
    public private(set) var lastCheckStarted: Date?
    public private(set) var lastCheckFinished: Date?
    public private(set) var lastCheckError: String?
    public private(set) var isCheckingInventory = false
    private let inventory: any InventoryProviding
    private let driver: any CheckoutDriver
    private let vault: any SecureVault
    private let journalStore: any PurchaseJournalStore
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var configuration = PilotPreferences()
    private var variants: [ProductVariant] = []
    private var stores: [RetailStore] = []
    private var location = ""
    private var inventoryFailures = 0
    private var preparationFailures = 0
    private var cycleInFlight = false
    private var armInFlight = false
    private var reconciliationInFlight = false
    private var generation = 0
    private struct PausedPreparation {
        let request: CheckoutRequest
        let profile: SecureProfile
    }
    private var pausedPreparation: PausedPreparation?
    private var resumeRequested = false
    private var usesRetryDelay = false
    private var loopGeneration = 0
    private var delay: TimeInterval = PilotPreferences.defaultPollInterval
    public init(inventory: any InventoryProviding, driver: any CheckoutDriver, vault: any SecureVault, journalStore: any PurchaseJournalStore, now: @escaping @Sendable () -> Date = { Date() }, monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = MonitoringClock.monotonicNow, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = MonitoringClock.sleep) {
        self.inventory = inventory; self.driver = driver; self.vault = vault; self.journalStore = journalStore
        self.now = now; self.monotonicNow = monotonicNow; self.sleep = sleep
    }
    public func restoreJournal() async {
        do {
            journal = try await journalStore.load()
            if journal.blocksPurchase {
                status = journal.phase == .confirmed ? .confirmed : .uncertain
                detail = journal.phase == .confirmed ? "One purchase is recorded. Automatic ordering is locked." : "A previous submission may have reached Apple. Check your Apple orders before resetting."
            }
        } catch { fail("The secure order journal could not be read. Ordering stays locked until storage is available.") }
    }
    public func arm(configuration: PilotPreferences, variants: [ProductVariant], stores: [RetailStore], location: String, runContinuously: Bool = true,
                    authorizationCheck: (@MainActor () -> Bool)? = nil) async throws {
        guard !isArmed, !cycleInFlight, !armInFlight, !reconciliationInFlight else { throw CoordinatorError.alreadyRunning }
        armInFlight = true
        generation += 1
        let armGeneration = generation
        defer { armInFlight = false }
        let issues = configuration.validationIssues
        guard issues.isEmpty else { throw CoordinatorError.invalidConfiguration(issues.joined(separator: " ")) }
        guard !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoordinatorError.invalidConfiguration("Enter a postal code or city, or detect your location.") }
        guard configuration.attemptWindow.end > now() else { throw CoordinatorError.invalidConfiguration("The attempt window has ended.") }
        let selectedVariants = configuration.selectedVariantIDs.compactMap { id in variants.first { $0.id == id } }
        let selectedStores = configuration.selectedStoreIDs.compactMap { id in stores.first { $0.id == id } }
        guard selectedVariants.count == configuration.selectedVariantIDs.count,
              selectedStores.count == configuration.selectedStoreIDs.count,
              selectedStores.allSatisfy({ $0.countryCode == nil || $0.countryCode?.uppercased() == configuration.market.countryCode }),
              selectedVariants.allSatisfy({ configuration.catalogProduct.permits(variant: $0, market: configuration.market) }) else { throw CoordinatorError.invalidConfiguration("Reload this country's selected product and stores, then select again.") }
        let persistedJournal = try await journalStore.load()
        guard generation == armGeneration, !Task.isCancelled, authorizationCheck?() != false else { throw CancellationError() }
        journal = persistedJournal
        guard !journal.blocksPurchase else { throw CoordinatorError.purchaseLocked }
        let profile = try await vault.loadProfile()
        guard generation == armGeneration, !Task.isCancelled, authorizationCheck?() != false else { throw CancellationError() }
        guard let profile, profile.validationIssues.isEmpty else { throw CoordinatorError.profileIncomplete }
        guard authorizationCheck?() != false else { throw CancellationError() }
        self.configuration = configuration; self.variants = selectedVariants; self.stores = selectedStores; self.location = location
        monitoringPlan = MonitoringPlan(configuration: configuration, variants: selectedVariants, stores: selectedStores, location: location)
        snapshot = nil; lastCheck = nil; nextCheck = nil
        checkCount = 0; lastCheckStarted = nil; lastCheckFinished = nil; lastCheckError = nil; isCheckingInventory = false
        inventoryFailures = 0; preparationFailures = 0; delay = configuration.pollInterval
        pausedPreparation = nil; resumeRequested = false
        isArmed = true; status = .monitoring
        detail = "Armed for \(selectedVariants.count) selected configuration\(selectedVariants.count == 1 ? "" : "s") at \(selectedStores.count) pickup store\(selectedStores.count == 1 ? "" : "s"). Waiting for the first availability check."
        record("Armed for one pickup order, up to \(configuration.maximumTotal) \(configuration.market.currencyCode).")
        if runContinuously { beginLoop() }
    }
    public func stop() {
        if isCheckingInventory {
            lastCheckFinished = now()
            lastCheckError = "Availability check was cancelled."
        }
        isCheckingInventory = false
        generation += 1; loopGeneration += 1; isArmed = false; task?.cancel(); task = nil; nextCheck = nil; driver.cancel()
        pausedPreparation = nil; resumeRequested = false
        if status != .confirmed && status != .uncertain {
            status = .stopped; detail = "Disarmed. No further checkout attempts will start."
        }
        record("Disarmed.")
    }
    /// Graceful shutdown waits for the canceled monitoring task to finish its cleanup.
    public func stopAndWait() async {
        let activeTask = task
        stop()
        await activeTask?.value
    }
    public func resumeAuthentication() {
        guard isArmed, status == .manualInputRequired, !cycleInFlight,
              pausedPreparation != nil, !journal.blocksPurchase else { return }
        resumeRequested = true
        status = .monitoring
        record("Continuing after user checkout input.")
        beginLoop()
    }
    /// Records a verified browser confirmation after post-submission authentication, without submitting again.
    public func reconcileConfirmation(orderID: String) async throws {
        guard !isArmed, !cycleInFlight, !armInFlight, !reconciliationInFlight else { throw CoordinatorError.alreadyRunning }
        let orderID = orderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orderID.isEmpty else { throw CoordinatorError.invalidConfirmation }
        reconciliationInFlight = true
        defer { reconciliationInFlight = false }
        var pending = try await journalStore.load()
        guard pending.phase == .uncertain || pending.phase == .submitting else { throw CoordinatorError.invalidConfirmation }
        pending.phase = .confirmed; pending.orderID = orderID; pending.updatedAt = now()
        // Keep the existing durable lock and UI state if the confirmation cannot be saved.
        try await journalStore.save(pending)
        journal = pending; status = .confirmed
        detail = "Apple's order confirmation was reconciled. One-purchase lock is active."
        record(detail)
    }
    public func resetPurchaseLock() async throws {
        guard !isArmed, !cycleInFlight, !armInFlight, !reconciliationInFlight else { throw CoordinatorError.alreadyRunning }
        let fresh = PurchaseJournal(updatedAt: now())
        try await journalStore.save(fresh)
        journal = fresh; status = .stopped; detail = "Purchase lock reset. Review configuration before arming again."
        record("User reset the purchase lock after reconciling Apple orders.")
    }
    public func performCycle() async {
        guard isArmed, !cycleInFlight, status != .authenticationRequired, status != .manualInputRequired else { return }
        cycleInFlight = true
        let cycleGeneration = generation
        defer {
            cycleInFlight = false
            if generation == cycleGeneration { isCheckingInventory = false }
        }
        usesRetryDelay = false
        delay = configuration.pollInterval
        let date = now()
        guard date <= configuration.attemptWindow.end else {
            pausedPreparation = nil; resumeRequested = false; driver.cancel()
            isArmed = false; status = .stopped; detail = "The attempt window has ended."; record(detail); return
        }
        guard configuration.permitsAttempt(at: date) else {
            // A confirmation clicked outside the schedule must not carry into a later window.
            if pausedPreparation != nil { driver.cancel() }
            pausedPreparation = nil; resumeRequested = false
            status = .waiting; detail = "Your attempt schedule is closed. The app will check again while it remains open."; return
        }
        let resuming = resumeRequested ? pausedPreparation : nil
        resumeRequested = false
        pausedPreparation = nil
        do {
            try Task.checkCancellation()
            let preparation: PausedPreparation
            if let resuming {
                // Preserve the original stock choice/profile and same browser, but refresh the durable lock.
                let persisted = try await journalStore.load()
                try Task.checkCancellation()
                guard isArmed, generation == cycleGeneration, configuration.permitsAttempt(at: now()) else { driver.cancel(); return }
                journal = persisted
                guard !journal.blocksPurchase else {
                    driver.cancel(); isArmed = false
                    status = journal.phase == .confirmed ? .confirmed : .uncertain
                    detail = "A purchase is recorded or uncertain. Automatic ordering remains locked."
                    record(detail); return
                }
                preparation = resuming
            } else {
                status = .checking
                checkCount += 1; lastCheckStarted = now(); lastCheckFinished = nil; isCheckingInventory = true
                let result: InventorySnapshot
                do {
                    result = try await inventory.fetch(market: configuration.market, location: location, variants: variants)
                    try Task.checkCancellation()
                } catch {
                    guard isArmed, generation == cycleGeneration else { return }
                    isCheckingInventory = false; lastCheckFinished = now()
                    lastCheckError = error is CancellationError ? "Availability check was cancelled." : safeError(error)
                    throw error
                }
                guard isArmed, generation == cycleGeneration else { return }
                isCheckingInventory = false; lastCheckFinished = now(); lastCheckError = nil
                snapshot = result; lastCheck = lastCheckFinished; inventoryFailures = 0; delay = configuration.pollInterval
                let available = result.availability.filter { $0.state == .available }
                guard let choice = variants.lazy.compactMap({ variant -> (ProductVariant, RetailStore)? in
                    guard let store = self.stores.first(where: { store in available.contains { $0.variantID == variant.id && $0.storeID == store.id } }) else { return nil }
                    return (variant, store)
                }).first else {
                    status = .monitoring; detail = "No selected configuration is available for pickup at your selected stores."; return
                }
                guard var profile = try await vault.loadProfile(), profile.validationIssues.isEmpty else { throw CoordinatorError.profileIncomplete }
                guard isArmed, generation == cycleGeneration, !Task.isCancelled, configuration.permitsAttempt(at: now()) else { return }
                profile.searchLocation = location
                let request = CheckoutRequest(variant: choice.0, store: choice.1, market: configuration.market, maximumTotal: configuration.maximumTotal, pickupWindow: configuration.pickupWindow, pickupHours: configuration.pickupHours, timeZoneIdentifier: configuration.timeZoneIdentifier, attemptWindow: configuration.attemptWindow, attemptHours: configuration.attemptHours)
                preparation = PausedPreparation(request: request, profile: profile)
                record("Pickup available: \(choice.0.name) [\(choice.0.id)] at \(choice.1.name). Preparing a single-item checkout.")
            }
            status = .preparing
            detail = "Verifying the selected checkout and pickup time."
            await prepareCheckout(preparation)
        } catch is CancellationError {
            pausedPreparation = nil
            driver.cancel()
            if isArmed, generation == cycleGeneration, status == .checking {
                status = .monitoring; detail = "Availability check was cancelled."
            }
        } catch {
            guard isArmed, generation == cycleGeneration else { return }
            if resuming != nil { driver.cancel() }
            inventoryFailures += 1
            usesRetryDelay = true
            var retryAfter: TimeInterval?
            if let service = error as? AppleServiceError { retryAfter = service.retryDelay }
            delay = RetryPolicy(base: configuration.pollInterval).delay(failures: inventoryFailures, retryAfter: retryAfter)
            status = .monitoring
            detail = "Availability check failed: \(safeError(error)). Next retry in \(String(format: "%.0f", delay)) seconds."
            record(detail)
        }
    }
    private func prepareCheckout(_ preparation: PausedPreparation) async {
        let request = preparation.request
        let profile = preparation.profile
        pausedPreparation = preparation
        do {
            let review = try await driver.prepare(request: request, profile: profile)
            try Task.checkCancellation()
            guard isArmed, configuration.permitsAttempt(at: now()) else { pausedPreparation = nil; driver.cancel(); return }
            pausedPreparation = nil
            try review.validate(for: request, at: now())
            // A durable write must succeed before a single final-submit call is allowed.
            let intent = PurchaseJournal(phase: .submitting, attemptID: UUID(), variantID: request.variant.id, storeID: request.store.id, receipt: PurchaseReceipt(request: request, review: review), updatedAt: now())
            try await journalStore.save(intent)
            journal = intent
            guard isArmed, !Task.isCancelled, configuration.permitsAttempt(at: now()) else { await markUncertain(); return }
            journal = intent; status = .submitting; detail = "Submitting one order. An uncertain response will lock further attempts."
            let outcome: CheckoutOutcome
            do { outcome = try await driver.submit(review: review) }
            catch { await markUncertain(); return }
            switch outcome {
            case .confirmed(let orderID):
                guard !orderID.isEmpty else { await markUncertain(); return }
                var confirmed = intent; confirmed.phase = .confirmed; confirmed.orderID = orderID; confirmed.updatedAt = now()
                do { try await journalStore.save(confirmed); journal = confirmed; status = .confirmed; detail = "Apple returned an order confirmation. One-purchase lock is active."; record(detail) }
                catch { await markUncertain() }
                isArmed = false
            case .requiresAuthentication, .unavailable, .indeterminate:
                await markUncertain()
            }
        } catch let error as CheckoutError where error.isSafariFailure {
            pausedPreparation = nil
            guard isArmed else { return }
            if journal.blocksPurchase { await markUncertain(); return }
            isArmed = false
            driver.cancel()
            fail(error.localizedDescription)
        } catch CheckoutError.authenticationRequired, CheckoutError.guestCheckoutUnavailable {
            pausedPreparation = nil
            guard isArmed else { return }
            if journal.blocksPurchase { await markUncertain(); return }
            isArmed = false
            driver.cancel()
            fail(CheckoutError.guestCheckoutUnavailable.localizedDescription)
        } catch CheckoutError.manualInputRequired {
            guard isArmed else { return }
            status = .manualInputRequired; detail = "Complete required checkout fields and confirm the payment method on Apple’s final review, then choose Continue."
            record("Checkout needs user input. Automatic attempts are paused.")
        } catch CheckoutError.guestCheckoutRefused {
            pausedPreparation = nil
            guard isArmed else { return }
            if journal.blocksPurchase { await markUncertain(); return }
            isArmed = false
            driver.cancel()
            fail(CheckoutError.guestCheckoutRefused.localizedDescription)
        } catch CheckoutError.storefrontBlocked {
            pausedPreparation = nil
            guard isArmed else { return }
            isArmed = false
            driver.cancel()
            fail("The last checkout attempt stopped after an Apple access or rate-limit response. The visible page may be an error redirect. Review the response details in the checkout window before trying again.")
        } catch CheckoutError.pageNotFound {
            pausedPreparation = nil
            guard isArmed else { return }
            isArmed = false
            driver.cancel()
            fail("The last checkout attempt reached Apple's Page Not Found. Automatic retries have stopped. Return to the bag to inspect the checkout before starting a new attempt.")
        } catch is CancellationError {
            pausedPreparation = nil
            driver.cancel()
        } catch {
            pausedPreparation = nil
            guard isArmed else { return }
            preparationFailures += 1
            usesRetryDelay = true
            delay = RetryPolicy(base: configuration.pollInterval).delay(failures: preparationFailures)
            driver.cancel()
            if preparationFailures >= configuration.maximumPreparationFailures {
                isArmed = false; fail("Checkout preparation stopped after \(preparationFailures) failures. Inspect the checkout window before arming again.")
            } else {
                status = .monitoring; detail = "Checkout could not be safely prepared. Retrying within your schedule (\(preparationFailures)/\(configuration.maximumPreparationFailures))."
                record(detail)
            }
        }
    }
    private func beginLoop() {
        task?.cancel()
        loopGeneration += 1
        let expectedGeneration = loopGeneration
        task = Task { [weak self] in await self?.runLoop(generation: expectedGeneration) }
    }
    private func runLoop(generation expectedGeneration: Int) async {
        while isArmed && !Task.isCancelled && loopGeneration == expectedGeneration {
            let started = monotonicNow()
            await performCycle()
            guard isArmed, status != .authenticationRequired, status != .manualInputRequired,
                  !Task.isCancelled, loopGeneration == expectedGeneration else { break }
            // Healthy cadence measures start-to-start. Errors keep their full delay after completion.
            let elapsed = MonitoringClock.seconds(started.duration(to: monotonicNow()))
            let wait = usesRetryDelay ? delay : max(0, delay - elapsed)
            nextCheck = min(.distantFuture, now().addingTimeInterval(wait))
            do { try await sleep(wait) } catch { break }
        }
        if loopGeneration == expectedGeneration { nextCheck = nil }
    }
    private func markUncertain() async {
        isArmed = false; status = .uncertain
        detail = "Submission may have reached Apple. Check your Apple orders. No automatic retry is permitted."
        journal.phase = .uncertain; journal.updatedAt = now()
        // The pre-submit .submitting record remains a lock even if this write fails.
        try? await journalStore.save(journal)
        record(detail)
    }
    private func record(_ message: String) {
        events.insert(PilotEvent(date: now(), message: message), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
    }
    private func fail(_ message: String) { status = .failed; detail = message; record(message) }
    private func safeError(_ error: Error) -> String {
        if error is CoordinatorError { return "secure profile or order storage is unavailable" }
        if let service = error as? AppleServiceError {
            switch service {
            case .invalidInput: return "availability request configuration is invalid"
            case .authenticationRequired: return "guest availability access is unavailable (HTTP 401)"
            case .blocked(let code): return "Apple blocked the request (HTTP \(code))"
            case .rateLimited: return "Apple requested fewer requests"
            case .httpStatus(let code): return "Apple returned HTTP \(code)"
            case .invalidResponse: return "Apple's availability response could not be safely verified"
            case .unsupportedMarket: return "the selected storefront is unsupported"
            case .productUnavailable: return "the selected product is unavailable in this storefront"
            }
        }
        return "network or response error"
    }
}

public enum CoordinatorError: LocalizedError {
    case alreadyRunning, invalidConfiguration(String), profileIncomplete, purchaseLocked, invalidConfirmation
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "An attempt is already active. Disarm before changing it."
        case .invalidConfiguration(let reason): reason
        case .profileIncomplete: "Save a complete checkout profile in Keychain first."
        case .purchaseLocked: "A purchase is recorded or uncertain. Reconcile your Apple orders before resetting the purchase lock."
        case .invalidConfirmation: "A verified order number and a pending or uncertain submission are required to reconcile confirmation."
        }
    }
}
