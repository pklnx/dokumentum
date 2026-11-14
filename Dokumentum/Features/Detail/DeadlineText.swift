import DokumentumKit
import Foundation

/// The words and symbols of a deadline (#12, part 2a), shared by the Deadlines list's rows, the detail's deadline bar
/// and VoiceOver: "Due 16 Nov 2026", the label, and the status. Overdue is never shown by colour alone: it has its own
/// symbol and the word "Overdue".
enum DeadlineText {
    /// "Overdue", "Due today", "Due in 2 days", or "Completed" for a done deadline.
    static func status(_ status: DeadlineStatus) -> String {
        switch status {
        case .overdue:
            String(localized: "Overdue", comment: "A deadline's status: its day has passed and it is not done.")
        case .today: String(localized: "Due today", comment: "A deadline's status: it is due today.")
        case .upcoming(let days):
            String(localized: "Due in \(days) days", comment: "A deadline's status: how many days until it is due.")
        case .done: String(localized: "Completed", comment: "A deadline's status: it was marked done.")
        }
    }

    /// "Due 16 Nov 2026" (`long`: "Due 16 November 2026", for VoiceOver).
    static func due(_ day: DeadlineDay, long: Bool = false) -> String {
        let formatted = date(of: day).formatted(date: long ? .long : .abbreviated, time: .omitted)
        return String(localized: "Due \(formatted)", comment: "A deadline's day, e.g. “Due 16 Nov 2026”.")
    }

    /// The parts of the line: the day, the label (when there is one) and the status, in that order.
    static func parts(_ deadline: DocumentDeadline, status: DeadlineStatus, long: Bool = false) -> [String] {
        let label = deadline.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return [due(deadline.day, long: long), label, Self.status(status)].filter { !$0.isEmpty }
    }

    /// The line as shown: "Due 16 Nov 2026 · Pay · Overdue".
    static func line(_ deadline: DocumentDeadline, status: DeadlineStatus) -> String {
        parts(deadline, status: status).joined(separator: " · ")
    }

    /// What VoiceOver reads: "Due 16 November 2026, Pay, Overdue".
    static func spoken(_ deadline: DocumentDeadline, status: DeadlineStatus) -> String {
        parts(deadline, status: status, long: true).joined(separator: ", ")
    }

    // MARK: The suggestion (#12, part 2b)

    /// The name of a due date's kind: the label "Add Deadline" gives a suggested deadline ("Payment").
    static func kindName(_ kind: DueDateKind) -> String {
        switch kind {
        case .payment:
            String(
                localized: "Payment",
                comment: "A deadline's label when it is added from a payment date found in the text (“zahlbar bis”).")
        case .cancellation:
            String(
                localized: "Cancellation",
                comment:
                    "A deadline's label when it is added from a cancellation date found in the text (“kündbar bis”).")
        case .expiry:
            String(
                localized: "Expiry",
                comment: "A deadline's label when it is added from an expiry date found in the text (“gültig bis”).")
        case .deadline:
            String(
                localized: "Deadline",
                comment:
                    "Info panel: the section of the document's deadline; also the label of a deadline added from a date found in the text with “Frist” or “spätestens”."
            )
        }
    }

    /// "Found in the text: Payment due 28 Nov 2026" (`long`: "… 28 November 2026", for VoiceOver).
    static func suggestion(_ candidate: DueDateCandidate, long: Bool = false) -> String {
        let date = date(of: candidate.day).formatted(date: long ? .long : .abbreviated, time: .omitted)
        let found: String =
            switch candidate.kind {
            case .payment:
                String(
                    localized: "Payment due \(date)",
                    comment: "The due-date suggestion: a payment date found in the text. %@ is the date.")
            case .cancellation:
                String(
                    localized: "Cancel by \(date)",
                    comment: "The due-date suggestion: the last day to cancel, found in the text. %@ is the date.")
            case .expiry:
                String(
                    localized: "Expires \(date)",
                    comment: "The due-date suggestion: an expiry date found in the text. %@ is the date.")
            case .deadline:
                String(
                    localized: "Deadline \(date)",
                    comment: "The due-date suggestion: a deadline found in the text. %@ is the date.")
            }
        return String(
            localized: "Found in the text: \(found)",
            comment: "The detail's due-date suggestion, e.g. “Found in the text: Payment due 28 Nov 2026”.")
    }

    /// A warning triangle for an overdue deadline, a calendar for every other.
    static func symbol(_ status: DeadlineStatus) -> String {
        status.isOverdue ? "exclamationmark.triangle.fill" : "calendar"
    }

    /// Noon of `day` in the current time zone, for the date pickers and the formatters: noon is the same day in the
    /// zone whatever its daylight saving rules (no zone skips or repeats noon).
    static func date(of day: DeadlineDay, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// The day a date picker's date names in the current time zone; `nil` outside the years 1000–9999.
    static func day(of date: Date, timeZone: TimeZone = .current) -> DeadlineDay? {
        DeadlineDay.today(in: timeZone, now: date)
    }

    /// The range of a deadline's date picker: four-digit years only, so the stored day is always ten characters (review
    /// N8 of #12's plan).
    static var pickerRange: ClosedRange<Date> {
        let first = DeadlineDay(year: DeadlineDay.years.lowerBound, month: 1, day: 1)!
        let last = DeadlineDay(year: DeadlineDay.years.upperBound, month: 12, day: 31)!
        return date(of: first)...date(of: last)
    }
}
