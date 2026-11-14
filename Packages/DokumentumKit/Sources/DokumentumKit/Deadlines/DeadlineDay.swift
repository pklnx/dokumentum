import Foundation

// A document's deadline (#12): the day it is due, as a calendar day, and the values stored with it. The model keeps
// the day as an ISO 8601 string (`Document.deadlineDay`, schema V3); these are its plain values.

/// A calendar day with no time and no time zone: a deadline is due on a day, wherever the device is. A `Date` at
/// Berlin midnight would read as the day before in London.
///
/// **The read rule** (frozen, like the synced enums): `init(storedValue:)` reads only the first ten characters, as
/// `yyyy-MM-dd`. So a later build may append to the string (a time, `2026-11-27T14:00`) without a schema change, and
/// this build still reads the day. A value that does not read as a day is "no day"; the caller never writes it back,
/// so the stored string stays as it is. `storedValue` writes exactly ten characters with a four-digit year, which is
/// why only the years 1000–9999 are days (review N8 of #12's plan).
public struct DeadlineDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// The years a day can have: four digits, so `storedValue` is always ten characters.
    public static let years = 1000...9999

    /// `nil` unless it is a day of the Gregorian calendar with a four-digit year (`2026-02-29` is not, `2028-02-29`
    /// is).
    public init?(year: Int, month: Int, day: Int) {
        guard Self.years.contains(year), (1...12).contains(month),
            (1...Self.numberOfDays(inMonth: month, of: year)).contains(day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Reads a stored value by the read rule: the first ten characters (Unicode scalars) must be `yyyy-MM-dd` in
    /// ASCII digits and name a day; whatever follows them is ignored. `""`, a shorter string, other digits, a sign
    /// or an impossible day (`2026-02-30`) read as `nil`.
    public init?(storedValue: String) {
        let scalars = Array(storedValue.unicodeScalars.prefix(10))
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-" else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for scalar in scalars[range] {
                guard ("0"..."9").contains(scalar) else { return nil }
                value = value * 10 + Int(scalar.value - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The day the suggestion names, if it is one (`SuggestedDate` holds any three numbers).
    public init?(_ date: SuggestedDate) {
        self.init(year: date.year, month: date.month, day: date.day)
    }

    /// The day in `timeZone` at the instant `now`, in the Gregorian calendar whatever the user's calendar is.
    /// `nil` only for an instant outside the years 1000–9999.
    public static func today(in timeZone: TimeZone, now: Date) -> DeadlineDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: now)
        guard parts.era == 1, let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return DeadlineDay(year: year, month: month, day: day)
    }

    /// The string to store: `yyyy-MM-dd`, always ten characters.
    public var storedValue: String {
        "\(year)-\(Self.twoDigits(month))-\(Self.twoDigits(day))"
    }

    public var suggestedDate: SuggestedDate { SuggestedDate(day: day, month: month, year: year) }

    public var description: String { storedValue }

    // MARK: Day arithmetic (#12, part 2a)

    /// Days since 1970-01-01 in the proleptic Gregorian calendar: plain integer arithmetic, with no `Calendar` and no
    /// time zone, so a day is always 1 apart from the next, across daylight saving changes too.
    public var dayNumber: Int {
        // Howard Hinnant's `days_from_civil`; the years here are positive.
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = shiftedYear / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The day with this `dayNumber`; `nil` outside the years 1000–9999.
    public init?(dayNumber: Int) {
        // Howard Hinnant's `civil_from_days`.
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex + (monthIndex < 10 ? 3 : -9)
        self.init(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// The day `days` later (earlier for a negative number); `nil` outside the years 1000–9999.
    public func adding(days: Int) -> DeadlineDay? {
        DeadlineDay(dayNumber: dayNumber + days)
    }

    /// How many days `other` lies after this day: 0 for the same day, negative when it lies before.
    public func days(until other: DeadlineDay) -> Int {
        other.dayNumber - dayNumber
    }

    public static func < (lhs: DeadlineDay, rhs: DeadlineDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static func numberOfDays(inMonth month: Int, of year: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// A document's deadline as the model reads it (`Document.deadline`): the day, the optional label ("Pay"), when a
/// user last set the day, and when it was marked done (`nil` while open).
public struct DocumentDeadline: Hashable, Sendable {
    public var day: DeadlineDay
    public var label: String
    public var setAt: Date?
    public var doneAt: Date?

    public init(day: DeadlineDay, label: String = "", setAt: Date? = nil, doneAt: Date? = nil) {
        self.day = day
        self.label = label
        self.setAt = setAt
        self.doneAt = doneAt
    }

    /// Marked done; undoing clears `doneAt`.
    public var isDone: Bool { doneAt != nil }
}
