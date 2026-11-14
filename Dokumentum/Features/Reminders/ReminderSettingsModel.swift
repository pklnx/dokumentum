import DokumentumKit
import Foundation
import Observation

/// This device's reminder settings (#12, part 3; plan §7; maintainer decisions Q3, Q4): on or off, the lead time and the
/// time of day, in the launch's settings suite (`ReminderEnvironment`), never synced. Each change calls `changed`: the
/// app reconciles, recounts the Deadlines (Q7: the count follows this device's lead time), and asks for permission when
/// the switch is turned on (`ReminderAuthorization`).
@MainActor
@Observable
final class ReminderSettingsModel {
    nonisolated static let isOnKey = "reminders.isOn"
    nonisolated static let leadDaysKey = "reminders.leadDays"
    nonisolated static let minuteOfDayKey = "reminders.minuteOfDay"

    private(set) var settings: ReminderSettings

    /// What changed, for `changed`.
    enum Change: Equatable {
        case turnedOn
        case turnedOff
        case leadDays
        case time
    }

    @ObservationIgnored let suite: String?
    @ObservationIgnored var changed: @MainActor (Change) -> Void

    init(suite: String?, changed: @escaping @MainActor (Change) -> Void = { _ in }) {
        self.suite = suite
        self.changed = changed
        settings = Self.read(suite: suite)
    }

    /// The settings as stored in `suite`, from any thread (the reconciler reads them at each reconcile). Missing values
    /// are the defaults: on, 3 days, 09:00.
    nonisolated static func read(suite: String?) -> ReminderSettings {
        let defaults = defaults(suite)
        return ReminderSettings(
            isOn: defaults.object(forKey: isOnKey) as? Bool ?? true,
            leadDays: defaults.object(forKey: leadDaysKey) as? Int ?? ReminderSettings.defaultLeadDays,
            minuteOfDay: defaults.object(forKey: minuteOfDayKey) as? Int ?? ReminderSettings.defaultMinuteOfDay)
    }

    nonisolated private static func defaults(_ suite: String?) -> UserDefaults {
        suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func setOn(_ isOn: Bool) {
        guard isOn != settings.isOn else { return }
        Self.defaults(suite).set(isOn, forKey: Self.isOnKey)
        settings.isOn = isOn
        changed(isOn ? .turnedOn : .turnedOff)
    }

    func setLeadDays(_ leadDays: Int) {
        guard ReminderSettings.leadDayChoices.contains(leadDays), leadDays != settings.leadDays else { return }
        Self.defaults(suite).set(leadDays, forKey: Self.leadDaysKey)
        settings.leadDays = leadDays
        changed(.leadDays)
    }

    func setMinuteOfDay(_ minuteOfDay: Int) {
        guard (0..<(24 * 60)).contains(minuteOfDay), minuteOfDay != settings.minuteOfDay else { return }
        Self.defaults(suite).set(minuteOfDay, forKey: Self.minuteOfDayKey)
        settings.minuteOfDay = minuteOfDay
        changed(.time)
    }
}
