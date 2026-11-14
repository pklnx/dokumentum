import Foundation

/// What one reconcile did: counts only (T11), for the log and for tests.
public struct ReminderReconcileReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// The center is in step with the rule.
        case reconciled
        /// The deadlines could not be read: nothing was changed (R2).
        case readFailed
        /// The scheduled set could not be read: nothing was changed.
        case scheduledSetUnreadable
    }

    public var outcome: Outcome
    public var added = 0
    public var replaced = 0
    public var withdrawn = 0
    public var failedAdds = 0
    public var removedDelivered = 0
    /// The reminders pending afterwards, by the rule.
    public var planned = 0
    /// Whether saving the scheduled set failed (it is written again at the next reconcile).
    public var scheduledSetSaveFailed = false

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

/// Keeps the notification center in step with the rule (plan §4; T4). One reconcile at a time: a request while one
/// runs is served by exactly one more run, however many arrive (`reconcile()` returns the report of a run that started
/// after the call).
///
/// A reconcile:
/// 1. reads the deadlines; **a read that throws ends the reconcile with no change** (R2);
/// 2. reads pending and delivered, **then** takes `now` (N5), the calendar, the status, the settings and `S`; every
///    pending or delivered reminder counts as scheduled (`S`), since only this device's adds put it there;
/// 3. plans by `ReminderPlanner`;
/// 4. diffs against the pending requests **with the `deadline.` prefix only**: withdraws what is not planned and removes
///    it from `S`; then reads delivered again and keeps in `S` every withdrawn identifier found there, since the system
///    delivered it meanwhile (re-review 2, N1); adds what is missing or changed (trigger, title, body) and inserts its
///    identifier into `S` once `add` returned; never adds an identifier that is in delivered;
/// 5. removes the delivered reminders of deadlines that are gone, done, trashed or moved, so a deadline done on the
///    iPhone clears the Mac's banner. **With reminders off or without authorization it leaves delivered notifications
///    alone** (re-review 2, N3) and withdraws every prefixed pending request;
/// 6. prunes `S` by day and saves it.
public actor ReminderReconciler {
    public typealias ReadDeadlines = @Sendable () async throws -> [ReminderDeadline]

    private let center: any NotificationScheduling
    private let scheduledSet: any ScheduledSetStoring
    private let readDeadlines: ReadDeadlines
    private let settings: @Sendable () async -> ReminderSettings
    private let text: ReminderText
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar

    private var isRunning = false
    private var waitingForNextRun: [CheckedContinuation<ReminderReconcileReport, Never>] = []
    /// How many reconciles ran. For tests.
    public private(set) var runs = 0
    /// How many calls wait for a run that has not started yet. For tests.
    public var queuedRequests: Int { isRunning ? waitingForNextRun.count : 0 }

    /// - Parameters:
    ///   - settings: this device's settings, read at each reconcile.
    ///   - now: the clock; tests pass fixed instants.
    ///   - calendar: Gregorian in the device's current time zone, read at each reconcile.
    public init(
        center: any NotificationScheduling, scheduledSet: any ScheduledSetStoring,
        readDeadlines: @escaping ReadDeadlines,
        settings: @escaping @Sendable () async -> ReminderSettings, text: ReminderText,
        now: @escaping @Sendable () -> Date, calendar: @escaping @Sendable () -> Calendar
    ) {
        self.center = center
        self.scheduledSet = scheduledSet
        self.readDeadlines = readDeadlines
        self.settings = settings
        self.text = text
        self.now = now
        self.calendar = calendar
    }

    /// Runs a reconcile, or waits for the one more run that follows the one going on; returns that run's report.
    public func reconcile() async -> ReminderReconcileReport {
        await withCheckedContinuation { continuation in
            waitingForNextRun.append(continuation)
            guard !isRunning else { return }
            isRunning = true
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while !waitingForNextRun.isEmpty {
            let waiting = waitingForNextRun
            waitingForNextRun = []
            let report = await runOnce()
            runs += 1
            for continuation in waiting { continuation.resume(returning: report) }
        }
        isRunning = false
    }

    private func runOnce() async -> ReminderReconcileReport {
        let deadlines: [ReminderDeadline]
        do {
            deadlines = try await readDeadlines()
        } catch {
            return ReminderReconcileReport(outcome: .readFailed)
        }
        let pending = await center.pending().filter { ReminderIdentifier.isReminder($0.identifier) }
        let delivered = Set(
            await center.delivered().map(\.identifier).filter(ReminderIdentifier.isReminder))
        let now = now()
        let calendar = calendar()
        let status = await center.authorizationStatus()
        let settings = await settings()
        var scheduled: Set<String>
        do {
            scheduled = try scheduledSet.load()
        } catch {
            return ReminderReconcileReport(outcome: .scheduledSetUnreadable)
        }
        let pendingByID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        scheduled.formUnion(pendingByID.keys)
        scheduled.formUnion(delivered)

        let enabled = ReminderPlanner.isEnabled(settings, status: status)
        let planned = ReminderPlanner.plan(
            ReminderPlanner.Input(
                deadlines: deadlines, settings: settings, status: status, now: now, calendar: calendar,
                pending: pendingByID.mapValues(\.moment), delivered: delivered, scheduled: scheduled))
        var report = ReminderReconcileReport(outcome: .reconciled)
        report.planned = planned.count
        let wanted = Set(planned.map(\.identifier))

        let withdrawn = pendingByID.keys.filter { !wanted.contains($0) }.sorted()
        if !withdrawn.isEmpty {
            await center.removePending(withdrawn)
            scheduled.subtract(withdrawn)
            report.withdrawn = withdrawn.count
        }
        // The system may have delivered a request between the reads and the withdrawal (re-review 2, N1): it has fired,
        // and its entry stays.
        let deliveredNow = Set(
            await center.delivered().map(\.identifier).filter(ReminderIdentifier.isReminder))
        scheduled.formUnion(deliveredNow)

        for reminder in planned where !deliveredNow.contains(reminder.identifier) {
            let request = self.request(for: reminder)
            let existing = pendingByID[reminder.identifier]
            guard existing != request else { continue }
            do {
                try await center.add(request)
                scheduled.insert(reminder.identifier)
                if existing == nil { report.added += 1 } else { report.replaced += 1 }
            } catch {
                report.failedAdds += 1
            }
        }

        if enabled {
            let current = Set(deadlines.filter(\.isOpen).map(\.identifier))
            let stale = deliveredNow.subtracting(current).sorted()
            if !stale.isEmpty {
                await center.removeDelivered(stale)
                report.removedDelivered = stale.count
            }
        }

        if let today = DeadlineDay.today(in: calendar.timeZone, now: now) {
            scheduled = ScheduledSet.pruned(scheduled, today: today)
        }
        do {
            try scheduledSet.save(scheduled)
        } catch {
            report.scheduledSetSaveFailed = true
        }
        return report
    }

    /// The request for a planned reminder: the texts from the app, relative to the moment's day (N6).
    private func request(for reminder: PlannedReminder) -> ReminderRequest {
        let deadline = reminder.deadline
        let content = ReminderContent(
            title: deadline.title, label: deadline.deadline.label, day: deadline.deadline.day,
            momentDay: reminder.moment.calendarDay ?? deadline.deadline.day)
        return ReminderRequest(
            identifier: reminder.identifier, moment: reminder.moment, title: text.title(content),
            body: text.body(content), instanceID: deadline.instanceID)
    }
}
