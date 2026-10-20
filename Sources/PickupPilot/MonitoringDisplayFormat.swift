import Foundation
import PilotCore

enum MonitoringDisplayFormat {
    static func date(_ date: Date, timeZone identifier: String) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .standard)
        style.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }

    static func hours(_ hours: DailyWindow) -> String {
        guard hours.isValid else { return "Invalid daily hours" }
        if hours.startMinute == 0 && hours.endMinute == 1439 { return "All day" }
        let start = String(format: "%02d:%02d", hours.startMinute / 60, hours.startMinute % 60)
        let end = String(format: "%02d:%02d", hours.endMinute / 60, hours.endMinute % 60)
        return "\(start)–\(end)\(hours.startMinute > hours.endMinute ? " (overnight)" : "")"
    }

    static func cadence(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "Invalid check interval" }
        return "Every \(interval.formatted(.number.precision(.fractionLength(0...1)))) \(interval == 1 ? "second" : "seconds") when healthy"
    }
}
