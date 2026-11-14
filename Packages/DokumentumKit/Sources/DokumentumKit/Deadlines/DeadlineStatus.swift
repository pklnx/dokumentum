import Foundation

/// Where a deadline stands on a day (#12, part 2a): what the Deadlines list's rows and the detail's bar show next to
/// the day. Computed from "today" as a calendar day (`AppDay` in the app), never from an instant, so it changes exactly
/// at local midnight and a daylight saving change cannot shift it.
public enum DeadlineStatus: Hashable, Sendable {
    /// Marked done.
    case done
    /// Open, and its day is before today: overdue by `days` (at least 1).
    case overdue(days: Int)
    /// Open and due today.
    case today
    /// Open and due in `days` days (at least 1).
    case upcoming(days: Int)

    public init(_ deadline: DocumentDeadline, today: DeadlineDay) {
        if deadline.isDone {
            self = .done
            return
        }
        let days = today.days(until: deadline.day)
        if days < 0 {
            self = .overdue(days: -days)
        } else if days == 0 {
            self = .today
        } else {
            self = .upcoming(days: days)
        }
    }

    public var isOverdue: Bool {
        if case .overdue = self { return true }
        return false
    }
}
