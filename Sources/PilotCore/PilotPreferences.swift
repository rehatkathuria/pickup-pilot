import Foundation

public struct PilotPreferences: Codable, Equatable, Sendable {
    public static let minimumPollInterval: TimeInterval = 1
    public static let maximumPollInterval: TimeInterval = 3600
    public static let defaultPollInterval: TimeInterval = 5
    public var market: Market = .ca
    public var catalogProduct: CatalogProduct = .iPhoneDuo
    public var selectedStoreIDs: [String] = []
    public var selectedVariantIDs: [String] = []
    public var pollInterval: TimeInterval = Self.defaultPollInterval
    public var maximumTotal: Decimal = 4000
    public var attemptWindow = DateWindow(start: Date(), end: Date().addingTimeInterval(7 * 86400))
    public var attemptHours = DailyWindow()
    public var pickupWindow = DateWindow(start: Date(), end: Date().addingTimeInterval(14 * 86400))
    public var pickupHours = DailyWindow()
    public var timeZoneIdentifier = TimeZone.current.identifier
    public var maximumPreparationFailures = 3
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case market, catalogProduct, selectedStoreIDs, selectedVariantIDs, pollInterval, maximumTotal,
             attemptWindow, attemptHours, pickupWindow, pickupHours, timeZoneIdentifier, maximumPreparationFailures
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        market = try values.decode(Market.self, forKey: .market)
        catalogProduct = try values.decodeIfPresent(CatalogProduct.self, forKey: .catalogProduct) ?? .iPhoneDuo
        selectedStoreIDs = try values.decode([String].self, forKey: .selectedStoreIDs)
        selectedVariantIDs = try values.decode([String].self, forKey: .selectedVariantIDs)
        pollInterval = try values.decode(TimeInterval.self, forKey: .pollInterval)
        maximumTotal = try values.decode(Decimal.self, forKey: .maximumTotal)
        attemptWindow = try values.decode(DateWindow.self, forKey: .attemptWindow)
        attemptHours = try values.decode(DailyWindow.self, forKey: .attemptHours)
        pickupWindow = try values.decode(DateWindow.self, forKey: .pickupWindow)
        pickupHours = try values.decode(DailyWindow.self, forKey: .pickupHours)
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        maximumPreparationFailures = try values.decode(Int.self, forKey: .maximumPreparationFailures)
    }

    public var validationIssues: [String] {
        var issues: [String] = []
        if selectedStoreIDs.isEmpty { issues.append("Select at least one pickup store.") }
        if selectedVariantIDs.isEmpty { issues.append("Select at least one product configuration.") }
        if !catalogProduct.supports(market: market) { issues.append("The headphone adapter option is available only for Canada.") }
        if Set(selectedStoreIDs).count != selectedStoreIDs.count || Set(selectedVariantIDs).count != selectedVariantIDs.count { issues.append("Remove duplicate stores or configurations.") }
        if maximumTotal.isNaN || maximumTotal <= 0 { issues.append("Set a maximum total greater than zero.") }
        if !(Self.minimumPollInterval...Self.maximumPollInterval).contains(pollInterval) { issues.append("Check interval must be between 1 and 3,600 seconds.") }
        if !attemptWindow.isValid { issues.append("Attempt end must follow its start.") }
        if catalogProduct == .iPhoneDuo && !pickupWindow.isValid { issues.append("Pickup end must follow its start.") }
        if !attemptHours.isValid || catalogProduct == .iPhoneDuo && !pickupHours.isValid { issues.append("Daily hours must be valid times.") }
        if TimeZone(identifier: timeZoneIdentifier) == nil { issues.append("Choose a valid time zone.") }
        if !(1...10).contains(maximumPreparationFailures) { issues.append("Preparation retry limit must be between one and ten.") }
        return issues
    }
    public func permitsAttempt(at date: Date) -> Bool {
        attemptWindow.contains(date) && attemptHours.contains(date, timeZone: timeZoneIdentifier)
    }
    public func permitsPickup(at date: Date) -> Bool {
        pickupWindow.contains(date) && pickupHours.contains(date, timeZone: timeZoneIdentifier)
    }
}

public struct DateWindow: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var isValid: Bool { start <= end }
    public func contains(_ date: Date) -> Bool { isValid && date >= start && date <= end }
}

public struct DailyWindow: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public init(startMinute: Int = 0, endMinute: Int = 1439) { self.startMinute = startMinute; self.endMinute = endMinute }
    public var isValid: Bool { (0...1439).contains(startMinute) && (0...1439).contains(endMinute) }
    public func contains(start: Date, end: Date, timeZone identifier: String) -> Bool {
        guard start <= end, contains(start, timeZone: identifier), contains(end, timeZone: identifier),
              let zone = TimeZone(identifier: identifier) else { return false }
        if startMinute == 0 && endMinute == 1439 { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = calendar.startOfDay(for: start)
        let startTime = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        let endDay: Date
        if startMinute <= endMinute || startTime <= endMinute { endDay = day }
        else { guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return false }; endDay = tomorrow }
        guard let endBoundary = calendar.date(bySettingHour: endMinute / 60, minute: endMinute % 60, second: 59, of: endDay) else { return false }
        return end <= endBoundary
    }
    public func contains(_ date: Date, timeZone identifier: String) -> Bool {
        guard isValid, let timeZone = TimeZone(identifier: identifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return startMinute <= endMinute ? (startMinute...endMinute).contains(minute) : minute >= startMinute || minute <= endMinute
    }
}
