import DokumentumKit
import Foundation
import Testing

/// `ReminderPlanner` alone (#12, part 3; plan §3): the due moment for each lead time, `setAt`, the states that plan
/// nothing, the times across both daylight saving changes in Berlin, the catch-up's minute, the cap's order, and the
/// identifiers. Fixed instants only.
struct ReminderPlannerTests {
    private static let calendar = InMemoryNotificationCenter.gregorian(Zones.berlin)

    private static func plan(
        _ deadlines: [ReminderDeadline], settings: ReminderSettings = ReminderSettings(),
        status: ReminderAuthorizationStatus = .authorized, now: Date, pending: [String: ReminderMoment] = [:],
        delivered: Set<String> = [], scheduled: Set<String> = []
    ) -> [PlannedReminder] {
        ReminderPlanner.plan(
            ReminderPlanner.Input(
                deadlines: deadlines, settings: settings, status: status, now: now, calendar: calendar,
                pending: pending, delivered: delivered, scheduled: scheduled))
    }

    // MARK: Defaults (Q3, Q4)

    @Test func theDefaultsAreOnThreeDaysBeforeAtNine() {
        let settings = ReminderSettings()
        #expect(settings.isOn)
        #expect(settings.leadDays == 3)
        #expect(settings.minuteOfDay == 9 * 60)
        #expect(ReminderSettings.defaultLeadDays == LibraryCounts.defaultDeadlineLeadDays)
        #expect(ReminderSettings.leadDayChoices == [0, 1, 2, 3, 7, 14])
        #expect(ReminderSettings(leadDays: 5).leadDays == 3, "not a choice")
        #expect(ReminderSettings(minuteOfDay: 24 * 60).minuteOfDay == 9 * 60, "not a minute of the day")
    }

    // MARK: Rule 3

    @Test(arguments: [(0, 27), (1, 26), (2, 25), (3, 24), (7, 20), (14, 13)])
    func eachLeadTimeRemindsThatManyDaysBefore(leadDays: Int, reminderDay: Int) {
        let planned = Self.plan(
            [deadline()], settings: ReminderSettings(leadDays: leadDays), now: at(2026, 11, 2, 10))
        #expect(planned.map(\.moment) == [moment(2026, 11, reminderDay, 9, 0)])
        #expect(planned.first?.isCatchUp == false)
    }

    /// Without `setAt` (a deadline from an older build) the lead moment applies.
    @Test func withoutSetAtTheLeadMomentApplies() {
        let planned = Self.plan([deadline(setAt: nil)], now: at(2026, 11, 2, 10))
        #expect(planned.map(\.moment) == [moment(2026, 11, 24, 9, 0)])
    }

    /// Set inside the lead window: the due day; on the due day after the time: nothing.
    @Test func setAtDecidesBetweenTheLeadMomentAndTheDueDay() {
        let calendar = Self.calendar
        let settings = ReminderSettings()
        #expect(
            ReminderPlanner.dueMoment(
                of: ymd(2026, 11, 27), settings: settings, setAt: at(2026, 11, 24, 8, 59), calendar: calendar)
                == at(2026, 11, 24, 9))
        #expect(
            ReminderPlanner.dueMoment(
                of: ymd(2026, 11, 27), settings: settings, setAt: at(2026, 11, 24, 9), calendar: calendar)
                == at(2026, 11, 27, 9))
        #expect(
            ReminderPlanner.dueMoment(
                of: ymd(2026, 11, 27), settings: settings, setAt: at(2026, 11, 27, 9), calendar: calendar)
                == nil)
    }

    // MARK: Rule 1

    @Test func doneTrashedOrOffPlansNothing() {
        let now = at(2026, 11, 2, 10)
        #expect(Self.plan([deadline(done: true)], now: now).isEmpty)
        #expect(Self.plan([deadline(trashed: true)], now: now).isEmpty)
        #expect(Self.plan([deadline()], settings: ReminderSettings(isOn: false), now: now).isEmpty)
        #expect(Self.plan([deadline()], now: now).count == 1)
    }

    @Test(arguments: ReminderAuthorizationStatus.allCases)
    func onlyAnAllowingStatusPlans(status: ReminderAuthorizationStatus) {
        let planned = Self.plan([deadline()], status: status, now: at(2026, 11, 2, 10))
        #expect(planned.count == (status.allowsReminders ? 1 : 0))
        #expect(status.allowsReminders == [.authorized, .provisional, .ephemeral].contains(status))
    }

    // MARK: Rule 2

    @Test func firedIsDeliveredOrScheduledAndNoLongerPending() {
        let id = deadline().identifier
        #expect(ReminderPlanner.isFired(id, pending: [], delivered: [id], scheduled: []))
        #expect(ReminderPlanner.isFired(id, pending: [], delivered: [], scheduled: [id]))
        #expect(!ReminderPlanner.isFired(id, pending: [id], delivered: [], scheduled: [id]))
        #expect(!ReminderPlanner.isFired(id, pending: [], delivered: [], scheduled: []))
        let now = at(2026, 11, 2, 10)
        #expect(Self.plan([deadline()], now: now, scheduled: [id]).isEmpty)
        #expect(Self.plan([deadline()], now: now, delivered: [id]).isEmpty)
        #expect(
            Self.plan([deadline()], now: now, pending: [id: moment(2026, 11, 24, 9, 0)], scheduled: [id]).count == 1)
    }

    // MARK: Rule 5

    /// `C` is the start of the minute after `now` + 60 s.
    @Test func theCatchUpIsTheStartOfTheMinuteAfterAMinute() {
        #expect(ReminderPlanner.catchUp(after: at(2026, 11, 25, 10)) == at(2026, 11, 25, 10, 1))
        #expect(ReminderPlanner.catchUp(after: at(2026, 11, 25, 10, 0, 1)) == at(2026, 11, 25, 10, 2))
        #expect(ReminderPlanner.catchUp(after: at(2026, 11, 25, 10, 0, 59)) == at(2026, 11, 25, 10, 2))
    }

    /// N1: a pending moment between `now` and `C` is kept; one later than `C`, or already passed, is not.
    @Test func aPendingCatchUpIsNeverMovedLater() {
        let id = deadline().identifier
        let now = at(2026, 11, 25, 10, 0, 30)
        let kept = Self.plan([deadline()], now: now, pending: [id: moment(2026, 11, 25, 10, 1)])
        #expect(kept.map(\.moment) == [moment(2026, 11, 25, 10, 1)])
        let later = Self.plan([deadline()], now: now, pending: [id: moment(2026, 11, 25, 10, 5)])
        #expect(later.map(\.moment) == [moment(2026, 11, 25, 10, 2)])
        let passed = Self.plan([deadline()], now: now, pending: [id: moment(2026, 11, 25, 10, 0)])
        #expect(passed.map(\.moment) == [moment(2026, 11, 25, 10, 2)])
    }

    @Test func aCatchUpOnTheDueDayItselfButNotAfterIt() {
        #expect(Self.plan([deadline()], now: at(2026, 11, 27, 23, 0)).map(\.isCatchUp) == [true])
        #expect(Self.plan([deadline()], now: at(2026, 11, 28, 0, 0, 1)).isEmpty)
    }

    // MARK: Times (N7)

    /// 09:00 is 09:00 local across both changes: the instant moves by an hour, the components do not.
    @Test func nineOClockAcrossBothDaylightSavingChanges() {
        let spring = Self.plan(
            [deadline(day: ymd(2026, 3, 30), setAt: nil)], settings: ReminderSettings(leadDays: 1),
            now: at(2026, 3, 1))
        #expect(spring.map(\.moment) == [moment(2026, 3, 29, 9, 0)])
        #expect(spring.first?.instant == Date(timeIntervalSince1970: 1_774_767_600), "07:00 UTC, summer time")
        let beforeSpring = Self.plan(
            [deadline(day: ymd(2026, 3, 31), setAt: nil)], now: at(2026, 3, 1))
        #expect(beforeSpring.first?.instant == Date(timeIntervalSince1970: 1_774_684_800), "08:00 UTC, winter time")
        let autumn = Self.plan(
            [deadline(day: ymd(2026, 10, 26), setAt: nil)], settings: ReminderSettings(leadDays: 1),
            now: at(2026, 10, 1))
        #expect(autumn.map(\.moment) == [moment(2026, 10, 25, 9, 0)])
        #expect(autumn.first?.instant == Date(timeIntervalSince1970: 1_792_915_200), "08:00 UTC, winter time")
    }

    /// 02:30 on the spring-forward day does not exist: 03:30 is planned and its components scheduled.
    @Test func theSpringForwardGapMovesOn() {
        let planned = Self.plan(
            [deadline(day: ymd(2026, 3, 29), setAt: nil)],
            settings: ReminderSettings(leadDays: 0, minuteOfDay: 2 * 60 + 30), now: at(2026, 3, 1))
        #expect(planned.map(\.moment) == [moment(2026, 3, 29, 3, 30)])
        #expect(planned.first?.instant == Date(timeIntervalSince1970: 1_774_747_800), "01:30 UTC")
    }

    /// 02:30 on the fall-back day happens twice: the first occurrence (summer time, 00:30 UTC).
    @Test func theRepeatedHourTakesTheFirstOccurrence() {
        let planned = Self.plan(
            [deadline(day: ymd(2026, 10, 25), setAt: nil)],
            settings: ReminderSettings(leadDays: 0, minuteOfDay: 2 * 60 + 30), now: at(2026, 10, 1))
        #expect(planned.map(\.moment) == [moment(2026, 10, 25, 2, 30)])
        #expect(planned.first?.instant == Date(timeIntervalSince1970: 1_792_888_200), "00:30 UTC")
    }

    // MARK: Rule 6

    /// The earliest 60, tie-broken by identifier.
    @Test func theCapKeepsTheEarliestByMomentThenIdentifier() {
        let deadlines = (0..<61).map { index in
            deadline(
                UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 60 - index))!,
                day: ymd(2026, 12, 1), setAt: nil)
        }
        let planned = Self.plan(deadlines, now: at(2026, 11, 2))
        #expect(ReminderLimits.pending == 60)
        #expect(planned.count == 60)
        #expect(planned.map(\.identifier) == planned.map(\.identifier).sorted())
        #expect(!planned.contains { $0.deadline.instanceID.uuidString.hasSuffix("000000000060") })
    }

    // MARK: Identifiers and the scheduled set

    @Test func theIdentifierNamesTheDocumentAndTheDay() throws {
        let id = ReminderIdentifier.make(instanceID: documentA, day: ymd(2026, 11, 27))
        #expect(id == "deadline.00000000-0000-4000-8000-00000000000A.2026-11-27")
        let parsed = try #require(ReminderIdentifier.parse(id))
        #expect(parsed.instanceID == documentA)
        #expect(parsed.day == ymd(2026, 11, 27))
        #expect(ReminderIdentifier.parse("other.00000000-0000-4000-8000-00000000000A.2026-11-27") == nil)
        #expect(ReminderIdentifier.parse("deadline.nope.2026-11-27") == nil)
        #expect(ReminderIdentifier.parse("deadline.00000000-0000-4000-8000-00000000000A.2026-11-27T09") == nil)
        #expect(ReminderIdentifier.isReminder(id))
        #expect(!ReminderIdentifier.isReminder("import.done"))
    }

    /// R2: pruned by the identifier's day only: today − 1 stays, today − 2 goes, and so does anything else.
    @Test func pruningKeepsYesterdayAndDropsTheDayBefore() {
        let today = ymd(2026, 11, 27)
        let yesterday = ReminderIdentifier.make(instanceID: documentA, day: ymd(2026, 11, 26))
        let twoDaysAgo = ReminderIdentifier.make(instanceID: documentB, day: ymd(2026, 11, 25))
        let ahead = ReminderIdentifier.make(instanceID: documentB, day: ymd(2027, 1, 1))
        #expect(
            ScheduledSet.pruned([yesterday, twoDaysAgo, ahead, "import.done"], today: today) == [yesterday, ahead])
    }
}
