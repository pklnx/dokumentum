import Foundation

/// One deadline as the reminders read it (plan §3, inputs): the document, its deadline, whether the document is in
/// the trash, and its title as stored (the app's texts give an empty one its fallback).
public struct ReminderDeadline: Hashable, Sendable {
    public var instanceID: UUID
    public var deadline: DocumentDeadline
    public var title: String
    public var isTrashed: Bool

    public init(instanceID: UUID, deadline: DocumentDeadline, title: String, isTrashed: Bool = false) {
        self.instanceID = instanceID
        self.deadline = deadline
        self.title = title
        self.isTrashed = isTrashed
    }

    /// `deadline.<instanceID>.<day>`.
    public var identifier: String { ReminderIdentifier.make(instanceID: instanceID, day: deadline.day) }

    /// Not done and not in the trash: the only deadlines that remind.
    public var isOpen: Bool { !deadline.isDone && !isTrashed }
}

/// A reminder the rule wants pending (plan §3): when, and for which deadline.
public struct PlannedReminder: Hashable, Sendable {
    public var deadline: ReminderDeadline
    /// The trigger's floating components.
    public var moment: ReminderMoment
    /// The instant the components name now, in the reconcile's calendar: what the order and the cap go by.
    public var instant: Date
    /// Planned by the catch-up (rule 5), not at the due moment.
    public var isCatchUp: Bool

    public var identifier: String { deadline.identifier }
}

/// The scheduling rule (plan §3, Revision 2: R1, R2, N1; maintainer decision Q6). Pure: everything it reads is passed
/// in, and nothing reads the clock.
///
/// For each identifier, at a reconcile:
/// 1. Nothing is planned unless reminders are on, the status allows them, the deadline is open and its document not in
///    the trash.
/// 2. A **fired** identifier is never planned again on this device. Fired means: in delivered, **or in the scheduled set
///    `S` and no longer pending** (R1). An `S` entry leaves only with this device's own withdrawal or by pruning, so an
///    entry that is no longer pending was delivered by the system. No time is compared, so a time-zone change in either
///    direction changes nothing, and so does the clock set back while the identifier's entry is still in `S`. **The
///    limit (review A N1 of #222):** an entry is pruned once a reconcile runs more than a day after its day (the day of
///    grace); if its banner is gone too (tapped or cleared) and the clock is then set back to before the due day, the
///    deadline is caught up once more. The plan accepts that grace.
/// 3. **The due moment `E`.** `L` is the day − `leadDays` at `minuteOfDay`, `U` the day at `minuteOfDay`. `E = L` if `L`
///    is after `setAt` (or `setAt` is `nil`), else `E = U` if `U` is after `setAt`, else nothing: the deadline was set
///    on its due day after the time. So a deadline set inside the lead window reminds on its due day, on both devices,
///    from the synced `setAt`.
/// 4. If `E` is after `now`, it is planned at `E`.
/// 5. **Catch-up (Q6).** If `E` is at or before `now` and the due day is today or later, it is planned at `C`, the start
///    of the minute after `now` + 60 s. A pending moment `P` with `now < P ≤ C` is kept (N1): a catch-up never moves a
///    pending request later, so frequent saves cannot keep pushing it back.
/// 6. The 60 earliest planned moments are kept, tie-broken by identifier (`ReminderLimits.pending`).
///
/// **Times.** A moment is resolved in the calendar's time zone: in the spring-forward gap the time moves on
/// (`.nextTimePreservingSmallerComponents`, 02:30 → 03:30), in the repeated hour the first occurrence counts, and the
/// trigger gets the resolved components.
public enum ReminderPlanner {
    /// What a reconcile knows.
    public struct Input: Sendable {
        public var deadlines: [ReminderDeadline]
        public var settings: ReminderSettings
        public var status: ReminderAuthorizationStatus
        public var now: Date
        /// Gregorian, in the device's current time zone.
        public var calendar: Calendar
        /// The pending reminders with their trigger's components.
        public var pending: [String: ReminderMoment]
        /// The delivered reminders' identifiers.
        public var delivered: Set<String>
        /// The scheduled set `S`.
        public var scheduled: Set<String>

        public init(
            deadlines: [ReminderDeadline], settings: ReminderSettings, status: ReminderAuthorizationStatus, now: Date,
            calendar: Calendar, pending: [String: ReminderMoment] = [:], delivered: Set<String> = [],
            scheduled: Set<String> = []
        ) {
            self.deadlines = deadlines
            self.settings = settings
            self.status = status
            self.now = now
            self.calendar = calendar
            self.pending = pending
            self.delivered = delivered
            self.scheduled = scheduled
        }
    }

    /// Whether reminders can be planned at all (rule 1, the device's half).
    public static func isEnabled(_ settings: ReminderSettings, status: ReminderAuthorizationStatus) -> Bool {
        settings.isOn && status.allowsReminders
    }

    /// Rule 2: in delivered, or in `S` and no longer pending.
    public static func isFired(
        _ identifier: String, pending: Set<String>, delivered: Set<String>, scheduled: Set<String>
    ) -> Bool {
        delivered.contains(identifier) || (scheduled.contains(identifier) && !pending.contains(identifier))
    }

    /// The reminders the rule wants pending, the earliest first (by instant, then identifier), at most
    /// `ReminderLimits.pending`.
    public static func plan(_ input: Input) -> [PlannedReminder] {
        guard isEnabled(input.settings, status: input.status) else { return [] }
        let calendar = input.calendar
        let pendingIDs = Set(input.pending.keys)
        let today = DeadlineDay.today(in: calendar.timeZone, now: input.now)
        var planned: [String: PlannedReminder] = [:]
        for deadline in input.deadlines where deadline.isOpen {
            let identifier = deadline.identifier
            guard planned[identifier] == nil,
                !isFired(identifier, pending: pendingIDs, delivered: input.delivered, scheduled: input.scheduled),
                let due = dueMoment(
                    of: deadline.deadline.day, settings: input.settings, setAt: deadline.deadline.setAt,
                    calendar: calendar)
            else { continue }
            if due > input.now {
                planned[identifier] = PlannedReminder(
                    deadline: deadline, moment: ReminderMoment(due, in: calendar), instant: due, isCatchUp: false)
                continue
            }
            guard let today, today <= deadline.deadline.day else { continue }
            let catchUp = catchUp(after: input.now)
            if let pending = input.pending[identifier], let kept = pending.date(in: calendar), input.now < kept,
                kept <= catchUp
            {
                planned[identifier] = PlannedReminder(
                    deadline: deadline, moment: pending, instant: kept, isCatchUp: true)
            } else {
                planned[identifier] = PlannedReminder(
                    deadline: deadline, moment: ReminderMoment(catchUp, in: calendar), instant: catchUp,
                    isCatchUp: true)
            }
        }
        let ordered = planned.values.sorted { lhs, rhs in
            lhs.instant != rhs.instant ? lhs.instant < rhs.instant : lhs.identifier < rhs.identifier
        }
        return Array(ordered.prefix(ReminderLimits.pending))
    }

    /// Rule 3: `E`, or `nil` when the deadline was set on its due day after the time (or a day cannot be resolved).
    public static func dueMoment(
        of day: DeadlineDay, settings: ReminderSettings, setAt: Date?, calendar: Calendar
    ) -> Date? {
        guard let leadDay = day.adding(days: -settings.leadDays),
            let lead = instant(of: leadDay, minuteOfDay: settings.minuteOfDay, in: calendar),
            let onTheDay = instant(of: day, minuteOfDay: settings.minuteOfDay, in: calendar)
        else { return nil }
        guard let setAt else { return lead }
        if lead > setAt { return lead }
        if onTheDay > setAt { return onTheDay }
        return nil
    }

    /// The instant of `day` at `minuteOfDay` in `calendar`'s time zone: in the spring-forward gap the next time that
    /// exists keeping the minutes (02:30 → 03:30), in the repeated hour the first occurrence.
    public static func instant(of day: DeadlineDay, minuteOfDay: Int, in calendar: Calendar) -> Date? {
        guard
            let noon = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
        else { return nil }
        let start = calendar.startOfDay(for: noon)
        guard minuteOfDay > 0 else { return start }
        let wanted = DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0)
        guard
            let found = calendar.nextDate(
                after: start, matching: wanted, matchingPolicy: .nextTimePreservingSmallerComponents,
                repeatedTimePolicy: .first, direction: .forward),
            DeadlineDay.today(in: calendar.timeZone, now: found) == day
        else { return nil }
        return found
    }

    /// Rule 5's `C`: the start of the minute after `now` + 60 s (`now` itself when that is already a minute's start).
    public static func catchUp(after now: Date) -> Date {
        let later = now.timeIntervalSince1970 + ReminderLimits.catchUpDelay
        return Date(timeIntervalSince1970: (later / 60).rounded(.up) * 60)
    }
}

/// The scheduled set `S` (plan §3, R1, R2): the identifiers this device has added to its center. Per device, never
/// synced, never in a backup.
/// - An identifier is inserted only after its `add` succeeded, and removed together with every withdrawal of a request
///   that is still pending.
/// - **Pruning is by the identifier's day only** (R2): an entry goes when its day is before today − 1. An identifier
///   whose deadline was removed or moved keeps its entry until then, so removing and adding the same day again does not
///   remind again, and a read that finds no deadlines (an empty fallback store) never erases what has fired.
public enum ScheduledSet {
    /// `scheduled` without the entries whose day is before `today` − 1, and without anything that is no reminder's
    /// identifier.
    public static func pruned(_ scheduled: Set<String>, today: DeadlineDay) -> Set<String> {
        guard let oldest = today.adding(days: -ReminderLimits.pruneGraceDays) else { return scheduled }
        return scheduled.filter { identifier in
            guard let parsed = ReminderIdentifier.parse(identifier) else { return false }
            return parsed.day >= oldest
        }
    }
}

/// Where `S` is kept: a file excluded from backup in the app (`ScheduledSetFile`, Core), memory in tests and in every
/// launch on the in-memory center.
public protocol ScheduledSetStoring: Sendable {
    /// The set as saved; empty when nothing was saved yet. Throws when it cannot be read, and the reconcile then
    /// changes nothing.
    func load() throws -> Set<String>
    func save(_ scheduled: Set<String>) throws
}

/// `S` in memory: empty at each launch that uses it.
public final class InMemoryScheduledSet: ScheduledSetStoring, @unchecked Sendable {
    // Guarded by `lock`.
    private var stored: Set<String>
    private let lock = NSLock()

    public init(_ stored: Set<String> = []) {
        self.stored = stored
    }

    public func load() throws -> Set<String> {
        lock.withLock { stored }
    }

    public func save(_ scheduled: Set<String>) throws {
        lock.withLock { stored = scheduled }
    }

    /// What is saved now.
    public var identifiers: Set<String> { lock.withLock { stored } }
}
