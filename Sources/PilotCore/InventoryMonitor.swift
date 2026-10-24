import Foundation
import Observation

/// A verified change for one product at one store. A nil old state means the
/// product was already available when this monitoring session first observed it.
public struct InventoryChange: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let storeID: String
    public let storeName: String
    public let variantID: String
    public let productName: String
    public let oldState: AvailabilityState?
    public let newState: AvailabilityState
    public let oldMessage: String?
    public let newMessage: String

    public init(id: UUID = UUID(), date: Date = Date(), storeID: String, storeName: String,
                variantID: String, productName: String, oldState: AvailabilityState? = nil,
                newState: AvailabilityState, oldMessage: String? = nil, newMessage: String) {
        self.id = id; self.date = date; self.storeID = storeID; self.storeName = storeName
        self.variantID = variantID; self.productName = productName; self.oldState = oldState
        self.newState = newState; self.oldMessage = oldMessage; self.newMessage = newMessage
    }
}

public enum InventoryMonitorError: LocalizedError {
    case alreadyRunning, invalidConfiguration
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Stop monitoring and let the current check finish before starting again."
        case .invalidConfiguration: "Choose a location and one to twenty unique products from the selected Apple storefront."
        }
    }
}

/// Inventory-only observation. This type has no checkout, payment, profile or
/// order-journal dependency. Main-actor isolation keeps observed UI state and
/// refresh admission consistent while the Sendable inventory service does I/O.
@MainActor
@Observable
public final class InventoryMonitor {
    public static let minimumRefreshInterval: TimeInterval = 1
    public static let maximumRefreshInterval: TimeInterval = 3600
    public private(set) var isRunning = false
    public private(set) var isRefreshing = false
    public private(set) var snapshot: InventorySnapshot?
    public private(set) var lastCheck: Date?
    public private(set) var lastError: String?
    public private(set) var nextCheck: Date?
    public private(set) var checkCount = 0
    public private(set) var refreshInterval: TimeInterval = 1
    public private(set) var changes: [InventoryChange] = []
    public private(set) var unverifiedPairCount = 0
    @ObservationIgnored public var onChanges: (@MainActor ([InventoryChange]) async -> Void)?

    @ObservationIgnored private let inventory: any InventoryFetching
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var market: Market = .ca
    private var location = ""
    private var variants: [ProductVariant] = []
    private var generation = 0
    private var loopGeneration = 0
    private var runsContinuously = false
    private var failures = 0
    private var lastRequestStart: ContinuousClock.Instant?
    private var retryDeadline: ContinuousClock.Instant?
    private var baseline: [Pair: StoreAvailability] = [:]
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private struct Pair: Hashable { let storeID: String; let variantID: String }

    public init(inventory: any InventoryFetching,
                now: @escaping @Sendable () -> Date = { Date() },
                monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = MonitoringClock.monotonicNow,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = MonitoringClock.sleep) {
        self.inventory = inventory; self.now = now; self.monotonicNow = monotonicNow; self.sleep = sleep
    }

    /// A caller may hand over a just-fetched snapshot for this exact request
    /// scope, or its failed request. Reuse the observation or backoff rather
    /// than immediately duplicating the discovery request.
    public func start(market: Market, location: String, variants: [ProductVariant], runContinuously: Bool = true,
                      initialSnapshot: InventorySnapshot? = nil, initialFailure: AppleServiceError? = nil) throws {
        guard !isRunning, refreshTask == nil else { throw InventoryMonitorError.alreadyRunning }
        guard initialSnapshot == nil || initialFailure == nil else { throw InventoryMonitorError.invalidConfiguration }
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty, !variants.isEmpty, variants.count <= 20,
              Set(variants.map(\.id)).count == variants.count,
              variants.allSatisfy({ !$0.id.isEmpty && $0.productURL.scheme == "https" &&
                  $0.productURL.host == "www.apple.com" && $0.productURL.path.hasPrefix(market.storefrontPath + "/shop/") }) else {
            throw InventoryMonitorError.invalidConfiguration
        }
        generation += 1
        self.market = market; self.location = location; self.variants = variants
        snapshot = nil; lastCheck = nil; lastError = nil; nextCheck = nil; checkCount = 0
        changes = []; baseline = [:]; unverifiedPairCount = 0
        failures = 0; lastRequestStart = nil; retryDeadline = nil
        isRunning = true; runsContinuously = runContinuously
        if let initialSnapshot {
            let result = verified(initialSnapshot)
            let date = now()
            let deltas = compare(result, at: date)
            snapshot = result; lastCheck = date; lastRequestStart = monotonicNow(); checkCount = 1
            record(deltas)
            updateNextCheck()
            if !deltas.isEmpty { deliverInitialChanges(deltas, generation: generation) }
        } else if let initialFailure {
            lastRequestStart = monotonicNow(); checkCount = 1; failures = 1
            lastError = safeError(initialFailure)
            let delay = RetryPolicy(base: refreshInterval).delay(failures: failures, retryAfter: initialFailure.retryDelay)
            retryDeadline = monotonicNow().advanced(by: .seconds(delay))
            updateNextCheck()
        }
        if runContinuously { beginLoop() }
    }

    public func stop() {
        generation += 1; loopGeneration += 1
        isRunning = false; runsContinuously = false; isRefreshing = false; nextCheck = nil
        loopTask?.cancel(); loopTask = nil; refreshTask?.cancel()
    }

    /// A non-cooperating transport cannot publish after cancellation, and a new
    /// session cannot overlap its request while graceful shutdown is pending.
    public func stopAndWait() async {
        let activeLoop = loopTask, activeRefresh = refreshTask, activeID = refreshID
        stop()
        await activeRefresh?.value
        await activeLoop?.value
        if refreshID == activeID { refreshTask = nil; refreshID = nil }
    }

    public func setRefreshInterval(_ seconds: TimeInterval) {
        let safe = seconds.isFinite ? min(Self.maximumRefreshInterval, max(Self.minimumRefreshInterval, seconds)) : 1
        guard safe != refreshInterval else { return }
        refreshInterval = safe
        updateNextCheck()
        // Replace the sleeping loop, retaining the single admitted request.
        if isRunning, runsContinuously { beginLoop() }
    }

    public func performRefresh() async {
        guard isRunning, !Task.isCancelled else { return }
        if let refreshTask { await refreshTask.value; return }
        // Manual refreshes cannot bypass a server's backoff deadline.
        if let retryDeadline, monotonicNow() < retryDeadline { updateNextCheck(); return }
        let activeGeneration = generation, id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refresh(generation: activeGeneration)
        }
        refreshTask = task; refreshID = id
        await task.value
        if refreshID == id { refreshTask = nil; refreshID = nil }
    }

    private func refresh(generation expectedGeneration: Int) async {
        guard isRunning, generation == expectedGeneration, !Task.isCancelled else { return }
        isRefreshing = true; checkCount += 1; nextCheck = nil
        lastRequestStart = monotonicNow()
        defer {
            if generation == expectedGeneration {
                isRefreshing = false
                updateNextCheck()
            }
        }
        do {
            let response = try await inventory.fetch(market: market, location: location, variants: variants)
            guard isRunning, generation == expectedGeneration, !Task.isCancelled else { return }
            let result = verified(response)
            let date = now()
            let deltas = compare(result, at: date)
            snapshot = result; lastCheck = date; lastError = nil; failures = 0; retryDeadline = nil
            if !deltas.isEmpty {
                record(deltas)
                // Deliver during this cycle as soon as the response is verified.
                guard isRunning, generation == expectedGeneration, !Task.isCancelled else { return }
                await onChanges?(deltas)
            }
        } catch {
            guard isRunning, generation == expectedGeneration, !Task.isCancelled else { return }
            if error is CancellationError { return }
            failures += 1
            let delay = RetryPolicy(base: refreshInterval).delay(failures: failures, retryAfter: (error as? AppleServiceError)?.retryDelay)
            retryDeadline = monotonicNow().advanced(by: .seconds(delay))
            lastError = safeError(error)
        }
    }

    private func record(_ deltas: [InventoryChange]) {
        changes.insert(contentsOf: deltas, at: 0)
        if changes.count > 200 { changes.removeLast(changes.count - 200) }
    }

    private func deliverInitialChanges(_ deltas: [InventoryChange], generation expectedGeneration: Int) {
        let id = UUID()
        refreshID = id
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.refreshID == id { self.refreshTask = nil; self.refreshID = nil }
            }
            guard self.isRunning, self.generation == expectedGeneration, !Task.isCancelled else { return }
            await self.onChanges?(deltas)
        }
    }

    /// A missing or repeated row is unknown, never an unavailable result. Keep
    /// its previous comparison baseline so temporary omissions create no alert.
    private func verified(_ result: InventorySnapshot) -> InventorySnapshot {
        let groupedStores = Dictionary(grouping: result.stores, by: \.id)
        let stores = result.stores.filter { !$0.id.isEmpty && groupedStores[$0.id]?.count == 1 }
        let storeIDs = Set(stores.map(\.id)), variantIDs = Set(variants.map(\.id))
        let groupedRows = Dictionary(grouping: result.availability) { Pair(storeID: $0.storeID, variantID: $0.variantID) }
        let rows = result.availability.filter {
            storeIDs.contains($0.storeID) && variantIDs.contains($0.variantID) &&
            groupedRows[Pair(storeID: $0.storeID, variantID: $0.variantID)]?.count == 1
        }
        unverifiedPairCount = stores.count * variants.count - rows.count
        return InventorySnapshot(stores: stores, availability: rows)
    }

    private func compare(_ result: InventorySnapshot, at date: Date) -> [InventoryChange] {
        let stores = Dictionary(uniqueKeysWithValues: result.stores.map { ($0.id, $0) })
        let products = Dictionary(uniqueKeysWithValues: variants.map { ($0.id, $0) })
        return result.availability.compactMap { row in
            let key = Pair(storeID: row.storeID, variantID: row.variantID)
            let old = baseline.updateValue(row, forKey: key)
            let changed = old.map { $0.state != row.state || normalized($0.message) != normalized(row.message) } ?? (row.state == .available)
            guard changed else { return nil }
            return InventoryChange(date: date, storeID: row.storeID, storeName: stores[row.storeID]?.name ?? row.storeID,
                                   variantID: row.variantID, productName: products[row.variantID].map(displayName) ?? row.variantID,
                                   oldState: old?.state, newState: row.state, oldMessage: old?.message, newMessage: row.message)
        }
    }

    private func displayName(_ product: ProductVariant) -> String {
        var parts = [product.name]
        for detail in [product.storage, product.color] {
            let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else { continue }
            let compact = { (value: String) in
                value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .filter { !$0.isWhitespace }
            }
            if !compact(parts.joined(separator: " ")).contains(compact(detail)) { parts.append(detail) }
        }
        return parts.joined(separator: " · ")
    }

    private func normalized(_ message: String) -> String {
        message.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private func beginLoop() {
        loopTask?.cancel(); loopGeneration += 1
        let expectedLoop = loopGeneration, expectedSession = generation
        loopTask = Task { [weak self] in await self?.runLoop(session: expectedSession, loop: expectedLoop) }
    }

    private func runLoop(session: Int, loop: Int) async {
        while isRunning, generation == session, loopGeneration == loop, !Task.isCancelled {
            if lastRequestStart != nil {
                let wait = remainingDelay()
                nextCheck = now().addingTimeInterval(wait)
                do { try await sleep(wait) } catch { break }
            }
            guard isRunning, generation == session, loopGeneration == loop, !Task.isCancelled else { break }
            await performRefresh()
        }
        if loopGeneration == loop { nextCheck = nil }
    }

    private func remainingDelay() -> TimeInterval {
        let current = monotonicNow()
        if let retryDeadline { return max(0, MonitoringClock.seconds(current.duration(to: retryDeadline))) }
        guard let lastRequestStart else { return 0 }
        return max(0, refreshInterval - MonitoringClock.seconds(lastRequestStart.duration(to: current)))
    }

    private func updateNextCheck() {
        guard isRunning, lastRequestStart != nil else { nextCheck = nil; return }
        nextCheck = now().addingTimeInterval(remainingDelay())
    }

    private func safeError(_ error: Error) -> String {
        guard let service = error as? AppleServiceError else { return "The inventory request failed. Retrying with a longer delay." }
        switch service {
        case .invalidInput: return "The availability request configuration is invalid."
        case .authenticationRequired: return "Apple did not allow the availability request (HTTP 401)."
        case .blocked(let code): return "Apple restricted the request (HTTP \(code)). Monitoring is backing off."
        case .rateLimited: return "Apple requested fewer requests. Monitoring is backing off."
        case .httpStatus(let code): return "Apple returned HTTP \(code). Monitoring is backing off."
        case .invalidResponse: return "Apple's availability response could not be verified."
        case .unsupportedMarket: return "The selected Apple storefront is unsupported."
        case .productUnavailable: return "The selected product is unavailable in this storefront."
        }
    }
}
