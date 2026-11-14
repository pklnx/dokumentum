import Foundation

// Reminders of deadlines (#12, part 3; plan §3, §4, §7). Kit holds the rule and its plain values; the app keeps the
// settings in this device's defaults and talks to the system's notification center.

/// This device's reminder settings (maintainer decisions Q3 and Q4): per device, never synced. On by default, three
/// days before the due day, at 09:00.
public struct ReminderSettings: Hashable, Sendable {
    /// Whether this device reminds of deadlines at all.
    public var isOn: Bool
    /// How many days before its day a deadline reminds: one of `leadDayChoices`.
    public var leadDays: Int
    /// The time of day of a reminder, in minutes after midnight (0–1439), on the device's clock wherever it is.
    public var minuteOfDay: Int

    /// The lead times the settings offer: on the day, 1, 2, 3, 7 or 14 days before.
    public static let leadDayChoices = [0, 1, 2, 3, 7, 14]
    /// Three days (Q3); the Deadlines count's default too (`LibraryCounts.defaultDeadlineLeadDays`).
    public static let defaultLeadDays = 3
    /// 09:00 (Q3).
    public static let defaultMinuteOfDay = 9 * 60

    /// A lead time that is not one of the choices reads as the default, and so does a minute outside the day: a value
    /// written by a later build never breaks the rule.
    public init(isOn: Bool = true, leadDays: Int = defaultLeadDays, minuteOfDay: Int = defaultMinuteOfDay) {
        self.isOn = isOn
        self.leadDays = Self.leadDayChoices.contains(leadDays) ? leadDays : Self.defaultLeadDays
        self.minuteOfDay = (0..<(24 * 60)).contains(minuteOfDay) ? minuteOfDay : Self.defaultMinuteOfDay
    }

    public var hour: Int { minuteOfDay / 60 }
    public var minute: Int { minuteOfDay % 60 }
}

/// Whether this device may show notifications, as the system answers it. Only `.authorized`, `.provisional` and
/// `.ephemeral` let the rule plan anything (plan §3, rule 1).
public enum ReminderAuthorizationStatus: String, Sendable, CaseIterable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    /// Whether reminders can be shown.
    public var allowsReminders: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        }
    }
}

/// The rule's fixed numbers.
public enum ReminderLimits {
    /// At most this many reminders are pending at once, the earliest first (T5). The system holds 64; the rest is
    /// left to the app's other notifications.
    public static let pending = 60
    /// A catch-up is planned at the start of the minute after `now` + this (plan §3, rule 5).
    public static let catchUpDelay: TimeInterval = 60
    /// An entry of the scheduled set goes once its day is more than this many days before today (R2): the day of grace
    /// keeps a westward time-zone change from bringing back a day just pruned.
    public static let pruneGraceDays = 1
    /// Every reminder's thread, so reminders due together are grouped.
    public static let threadIdentifier = "deadlines"
}

/// A reminder's identifier, `deadline.<instanceID>.<yyyy-MM-dd>` (T4): deterministic, so adding it again replaces it,
/// and a new day is a new identifier. The reconciler touches only requests with the `deadline.` prefix, never another
/// notification of the app.
public enum ReminderIdentifier {
    public static let prefix = "deadline."

    public static func make(instanceID: UUID, day: DeadlineDay) -> String {
        "\(prefix)\(instanceID.uuidString).\(day.storedValue)"
    }

    /// Whether `identifier` is a reminder's (has the prefix).
    public static func isReminder(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix)
    }

    /// The document and the day an identifier names; `nil` for anything else.
    public static func parse(_ identifier: String) -> (instanceID: UUID, day: DeadlineDay)? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let rest = identifier.dropFirst(prefix.count)
        guard let dot = rest.lastIndex(of: "."), let instanceID = UUID(uuidString: String(rest[..<dot])) else {
            return nil
        }
        let dayText = String(rest[rest.index(after: dot)...])
        guard dayText.count == 10, let day = DeadlineDay(storedValue: dayText) else { return nil }
        return (instanceID, day)
    }
}

/// A moment as the trigger holds it: floating calendar components (year, month, day, hour, minute) with no time zone,
/// so 09:00 is 09:00 wherever the device is (plan §3). Gregorian.
public struct ReminderMoment: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    /// The components of `date` in `calendar` (its time zone); seconds are dropped.
    public init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        self.init(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0, hour: parts.hour ?? 0,
            minute: parts.minute ?? 0)
    }

    /// The instant these components name in `calendar`'s time zone now, as the system resolves a floating trigger.
    public func date(in calendar: Calendar) -> Date? {
        calendar.date(from: components)
    }

    /// The components, without a calendar or a time zone: floating.
    public var components: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    }

    /// The calendar day of the moment.
    public var calendarDay: DeadlineDay? {
        DeadlineDay(year: year, month: month, day: day)
    }

    public static func < (lhs: ReminderMoment, rhs: ReminderMoment) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute) < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute)
    }

    public var description: String {
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return "\(year)-\(two(month))-\(two(day)) \(two(hour)):\(two(minute))"
    }
}
