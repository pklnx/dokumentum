import DokumentumKit
import Foundation
import Testing

/// The plan's §3 probe cases 1–12 (`final_rule_r2.py`) and probes A–F (`r2_tz_probe.py`) of #12, part 3, each through
/// the reconciler on an in-memory center that delivers by floating components in its current calendar. Unless a case
/// says otherwise: the deadline is due 2026-11-27, set 2026-11-01 10:00, lead 3 days, 09:00, in Berlin. The expected
/// moments are the probes' output, line for line.
struct ReminderRuleCaseTests {
    private let identifier = deadline().identifier

    // MARK: §3 cases 1–12

    @Test func case1TheLeadMoment() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 22, 10))
        #expect(await device.pendingMoment() == moment(2026, 11, 24, 9, 0))
    }

    /// The same day, the lead raised to 7: the new lead moment has passed, so it is caught up (B1 case 2).
    @Test func case2ALeadRaisedWhilePendingIsCaughtUp() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 22, 10))
        device.set(settings: ReminderSettings(leadDays: 7))
        await device.reconcile(at: at(2026, 11, 22, 10))
        #expect(await device.pendingMoment() == moment(2026, 11, 22, 10, 1))
    }

    /// 3a: the Mac is not authorized: nothing. 3b: authorized inside the window: caught up.
    @Test func case3TheMacAuthorizedInsideTheWindowCatchesUp() async {
        let mac = ReminderDevice(status: .notDetermined)
        await mac.reconcile(at: at(2026, 11, 23, 10))
        #expect(await mac.pendingMoment() == nil)
        await mac.center.setStatus(.authorized)
        await mac.reconcile(at: at(2026, 11, 25, 10))
        #expect(await mac.pendingMoment() == moment(2026, 11, 25, 10, 1))
    }

    /// The device first sees the deadline inside the window (the app had not run, or it arrived by sync): caught up
    /// once (Q6).
    @Test func case4ALateFirstSightIsCaughtUp() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 25, 10))
        #expect(await device.pendingMoment() == moment(2026, 11, 25, 10, 1))
    }

    /// 5a: set inside the window on this device → its due day; 5b: the same deadline synced to the other device → its
    /// due day too, never a reminder at entry time.
    @Test func case5ADeadlineSetInsideTheWindowRemindsOnItsDayOnBothDevices() async {
        let entered = [deadline(setAt: at(2026, 11, 25, 10))]
        let here = ReminderDevice(entered)
        let other = ReminderDevice(entered)
        await here.reconcile(at: at(2026, 11, 25, 10, 0, 1))
        await other.reconcile(at: at(2026, 11, 25, 10, 5))
        #expect(await here.pendingMoment() == moment(2026, 11, 27, 9, 0))
        #expect(await other.pendingMoment() == moment(2026, 11, 27, 9, 0))
    }

    /// 6a–6d: after it fired nothing plans it again, whatever changes: a reconcile, a new lead and time, a cleared
    /// Notification Center. Shown once through 11-30.
    @Test func case6AfterItFiredNothingRemindsAgain() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 22, 10))
        await device.deliver(upTo: at(2026, 11, 24, 9))
        await device.reconcile(at: at(2026, 11, 24, 12))
        #expect(await device.pendingMoment() == nil, "6a")
        device.set(settings: ReminderSettings(leadDays: 1, minuteOfDay: 18 * 60))
        await device.reconcile(at: at(2026, 11, 24, 12))
        #expect(await device.pendingMoment() == nil, "6b")
        await device.center.clearDelivered()
        await device.reconcile(at: at(2026, 11, 25, 12))
        #expect(await device.pendingMoment() == nil, "6c")
        await device.deliver(upTo: at(2026, 11, 30))
        #expect(await device.shown() == 1, "6d")
    }

    /// 7a: done before the moment: nothing. 7b: undone after it: caught up once. 7c: after that fired, done and undone
    /// again: nothing. 7d: shown once.
    @Test func case7DoneAndUndone() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 22, 10))
        device.set(deadlines: [deadline(done: true)])
        await device.reconcile(at: at(2026, 11, 23, 10))
        #expect(await device.pendingMoment() == nil, "7a")
        device.set(deadlines: [deadline()])
        await device.reconcile(at: at(2026, 11, 25, 10))
        #expect(await device.pendingMoment() == moment(2026, 11, 25, 10, 1), "7b")
        await device.deliver(upTo: at(2026, 11, 25, 10, 2))
        device.set(deadlines: [deadline(done: true)])
        await device.reconcile(at: at(2026, 11, 25, 11))
        device.set(deadlines: [deadline()])
        await device.reconcile(at: at(2026, 11, 25, 12))
        #expect(await device.pendingMoment() == nil, "7c")
        await device.deliver(upTo: at(2026, 11, 30))
        #expect(await device.shown() == 1, "7d")
    }

    /// The due day passed while the app did not run: nothing.
    @Test func case8APassedDayIsNotCaughtUp() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 28, 8))
        #expect(await device.pendingMoment() == nil)
    }

    /// Set on its due day after the time of day: nothing (the user has just entered it).
    @Test func case9SetOnItsDayAfterTheTimeRemindsNot() async {
        let device = ReminderDevice([deadline(setAt: at(2026, 11, 27, 10))])
        await device.reconcile(at: at(2026, 11, 27, 10, 0, 1))
        #expect(await device.pendingMoment() == nil)
    }

    /// After the first reminder fired, the day moves to 12-04: a new identifier, reminded at its own lead moment.
    @Test func case10AMovedDayIsANewIdentifier() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 22, 10))
        await device.deliver(upTo: at(2026, 11, 24, 9))
        let moved = deadline(day: ymd(2026, 12, 4), setAt: at(2026, 11, 24, 12))
        device.set(deadlines: [moved])
        await device.reconcile(at: at(2026, 11, 24, 12))
        #expect(await device.pendingMoment(moved.identifier) == moment(2026, 12, 1, 9, 0))
        #expect(await device.pendingMoment() == nil)
    }

    /// 11a: reminders off before the moment: withdrawn. 11b: on again inside the window: caught up.
    @Test func case11OffAndOnAgain() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 22, 10))
        device.set(settings: ReminderSettings(isOn: false))
        await device.reconcile(at: at(2026, 11, 23, 10))
        #expect(await device.pendingMoment() == nil, "11a")
        device.set(settings: ReminderSettings(isOn: true))
        await device.reconcile(at: at(2026, 11, 25, 10))
        #expect(await device.pendingMoment() == moment(2026, 11, 25, 10, 1), "11b")
    }

    /// 100 deadlines, one a day from 12-01: 60 pending, the earliest first, 11-28 … 2027-01-26 09:00.
    @Test func case12TheCap() async {
        let many = (0..<100).map { index in
            deadline(
                UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                day: ymd(2026, 12, 1).adding(days: index)!, setAt: at(2026, 11, 1))
        }
        let device = ReminderDevice(many)
        await device.reconcile(at: at(2026, 11, 14, 10))
        let pending = await device.center.pending()
        #expect(pending.count == 60)
        #expect(pending.map(\.moment).min() == moment(2026, 11, 28, 9, 0))
        #expect(pending.map(\.moment).max() == moment(2027, 1, 26, 9, 0))
    }

    // MARK: Probes A–F

    /// A (R1): scheduled in Berlin for 11-24 09:00, in New York from 11-23, reconciled at 05:00 New York, between the
    /// old-zone and the new-zone moment: still pending, shown once at 09:00 New York.
    @Test func probeAWestwardZoneChangeWhilePending() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        await device.move(to: Zones.newYork)
        await device.reconcile(at: at(2026, 11, 24, 5, in: Zones.newYork))
        #expect(await device.pendingMoment() == moment(2026, 11, 24, 9, 0))
        await device.deliver(upTo: at(2026, 11, 24, 8, 59, in: Zones.newYork))
        #expect(await device.shown() == 0, "not at 09:00 Berlin")
        await device.deliver(upTo: at(2026, 11, 30, in: Zones.newYork))
        #expect(await device.shown() == 1)
    }

    /// B (R2): fired 11-24; one launch reads no deadlines; the next reads them again: shown once.
    @Test func probeBOneEmptyReadThenTheData() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        await device.deliver(upTo: at(2026, 11, 24, 9, 0, 1))
        device.world.withLock { $0.nextReadEmpty = true }
        await device.reconcile(at: at(2026, 11, 25, 8))
        await device.reconcile(at: at(2026, 11, 25, 10))
        await device.deliver(upTo: at(2026, 11, 30))
        #expect(await device.shown() == 1)
    }

    /// C (R1): eastward to Tokyo, fired early (09:00 Tokyo), Notification Center cleared, reconciled: shown once.
    @Test func probeCEastwardFiredEarlyAndCleared() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        await device.move(to: Zones.tokyo)
        await device.deliver(upTo: at(2026, 11, 24, 9, 0, 1, in: Zones.tokyo))
        #expect(await device.shown() == 1)
        await device.center.clearDelivered()
        await device.reconcile(at: at(2026, 11, 24, 12, in: Zones.tokyo))
        await device.deliver(upTo: at(2026, 11, 30, in: Zones.tokyo))
        #expect(await device.shown() == 1)
    }

    /// D (R1): fired, then the clock set back a day: nothing happens.
    @Test func probeDTheClockSetBack() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        await device.deliver(upTo: at(2026, 11, 24, 9, 0, 1))
        await device.reconcile(at: at(2026, 11, 23, 12))
        #expect(await device.pendingMoment() == nil)
        await device.deliver(upTo: at(2026, 11, 30))
        #expect(await device.shown() == 1)
    }

    /// E (N1): a catch-up with reconciles every 30 s for 10 minutes fires at its first moment (10:02), once.
    @Test func probeECatchUpIsNotPushedBack() async {
        let device = ReminderDevice()
        let start = at(2026, 11, 25, 10, 0, 10)
        await device.reconcile(at: start)
        let first = await device.pendingMoment()
        #expect(first == moment(2026, 11, 25, 10, 2))
        for step in 1...20 {
            let instant = start.addingTimeInterval(30 * Double(step))
            await device.deliver(upTo: instant)
            await device.reconcile(at: instant)
        }
        #expect(await device.shown() == 1)
        #expect(await device.center.delivered().map(\.moment) == [moment(2026, 11, 25, 10, 2)])
    }

    /// F (R2): a reader that throws ends the reconcile; `S` and pending are unchanged.
    @Test func probeFAReaderThatThrowsChangesNothing() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        let scheduled = device.scheduled.identifiers
        let pending = await device.center.pending()
        device.world.withLock { $0.readFails = true }
        let report = await device.reconcile(at: at(2026, 11, 21, 10))
        #expect(report.outcome == .readFailed)
        #expect(device.scheduled.identifiers == scheduled)
        #expect(await device.center.pending() == pending)
        #expect(scheduled == [identifier])
    }
}
