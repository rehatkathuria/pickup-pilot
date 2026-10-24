import SwiftUI
import PilotCore

struct ScheduleView: View {
    @Bindable var model: PilotModel
    var body: some View {
        PageTitle(title: "Your timing. Your limits.", subtitle: model.preferences.catalogProduct == .iPhoneDuo ? "Every submitted order must match these dates, pickup hours and the final total, including taxes and fees." : "Set when checkout may run and the maximum final total. This accessory uses pickup when Apple confirms it is ready, without a reserved pickup time.")
        Form {
            Section("Checkout attempts") {
                DatePicker("Begin attempting", selection: $model.preferences.attemptWindow.start)
                DatePicker("Stop attempting", selection: $model.preferences.attemptWindow.end)
                DailyHoursEditor(window: $model.preferences.attemptHours)
                Stepper("Check every \(Int(model.preferences.pollInterval)) \(model.preferences.pollInterval == 1 ? "second" : "seconds")", value: $model.preferences.pollInterval, in: PilotPreferences.minimumPollInterval...PilotPreferences.maximumPollInterval, step: 1)
                Stepper("Stop after \(model.preferences.maximumPreparationFailures) checkout preparation failures", value: $model.preferences.maximumPreparationFailures, in: 1...10)
                Text("Healthy checks can run every second. Requests never overlap; network and rate-limit errors use increasing retry delays. A failed or uncertain final submission is never retried automatically.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Acceptable pickup") {
                if model.preferences.catalogProduct == .iPhoneDuo {
                    DatePicker("Earliest pickup", selection: $model.preferences.pickupWindow.start)
                    DatePicker("Latest pickup", selection: $model.preferences.pickupWindow.end)
                    DailyHoursEditor(window: $model.preferences.pickupHours)
                    Text("Both ends of the offered pickup slot must fit your limits.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Pickup when ready · no reserved time")
                    Text("The adapter does not reserve a pickup appointment. Wait for Apple's ready-for-pickup notice before visiting your selected store. Pickup date and daily-hour limits do not apply to this item.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Time zone for all daily hours", text: $model.preferences.timeZoneIdentifier)
                Text("Use an IANA time zone such as America/Toronto or Europe/London. Set the store's local zone if you are travelling.").font(.caption).foregroundStyle(.secondary)
            }
            Section("One-order budget") {
                TextField("Maximum final total (\(model.preferences.market.currencyCode))", value: $model.preferences.maximumTotal, format: .number)
                Text("One selected item, pickup only, paid in full. Carrier contracts, financing, trade-in and extras are outside this app's automatic checkout path.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            .disabled(model.setupLocked)
            .onChange(of: model.preferences) { _, _ in model.consentToOrder = false; model.savePreferences() }
        ForEach(model.preferences.validationIssues, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary) }
    }
}
struct DailyHoursEditor: View {
    @Binding var window: DailyWindow
    var body: some View {
        HStack {
            DatePicker("From", selection: timeBinding(for: \.startMinute), displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: timeBinding(for: \.endMinute), displayedComponents: .hourAndMinute)
        }
        // These values are wall-clock minutes, not instants. UTC is only the
        // picker's stable representation; the configured store zone is applied by policy.
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        Text("A start later than the end spans midnight.").font(.caption).foregroundStyle(.secondary)
    }
    func timeBinding(for keyPath: WritableKeyPath<DailyWindow, Int>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: Double(window[keyPath: keyPath]) * 60) }, set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            window[keyPath: keyPath] = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        })
    }
}
