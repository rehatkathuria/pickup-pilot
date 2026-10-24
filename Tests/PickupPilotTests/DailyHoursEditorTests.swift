import Foundation
import SwiftUI
import Testing
import PilotCore
@testable import PickupPilot

@MainActor @Test func nativeTimeFieldAcceptsExactMinutesAndOvernightTimes() {
    var value = DailyWindow(startMinute: 0, endMinute: 1439)
    let editor = DailyHoursEditor(window: Binding(get: { value }, set: { value = $0 }))
    // Regression: fifteen-minute stepping from 23:59 could never select 17:00.
    editor.timeBinding(for: \.endMinute).wrappedValue = Date(timeIntervalSince1970: 17 * 3600)
    #expect(value.endMinute == 1020)
    editor.timeBinding(for: \.startMinute).wrappedValue = Date(timeIntervalSince1970: 23 * 3600 + 7 * 60)
    #expect(value.startMinute == 1387)
    #expect(editor.timeBinding(for: \.startMinute).wrappedValue == Date(timeIntervalSince1970: 23 * 3600 + 7 * 60))
    editor.timeBinding(for: \.endMinute).wrappedValue = Date(timeIntervalSince1970: 2 * 3600 + 3 * 60)
    #expect(value.endMinute == 123 && value.startMinute > value.endMinute)
}
