import DokumentumKit
import Foundation
import Testing

/// `DeadlineStatus` (#12, part 2a): overdue, today or in N days, from "today" as a calendar day. Around local midnight
/// the status changes exactly when the day does, and a daylight saving change does not shift it. Fixed instants only.
struct DeadlineStatusTests {
    private static func day(_ year: Int, _ month: Int, _ day: Int) throws -> DeadlineDay {
        try #require(DeadlineDay(year: year, month: month, day: day), "\(year)-\(month)-\(day)")
    }

    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test func anOpenDeadlineIsOverdueTodayOrUpcoming() throws {
        let deadline = DocumentDeadline(day: try Self.day(2026, 11, 27), label: "Pay")
        #expect(DeadlineStatus(deadline, today: try Self.day(2026, 11, 29)) == .overdue(days: 2))
        #expect(DeadlineStatus(deadline, today: try Self.day(2026, 11, 28)) == .overdue(days: 1))
        #expect(DeadlineStatus(deadline, today: try Self.day(2026, 11, 27)) == .today)
        #expect(DeadlineStatus(deadline, today: try Self.day(2026, 11, 26)) == .upcoming(days: 1))
        #expect(DeadlineStatus(deadline, today: try Self.day(2026, 10, 28)) == .upcoming(days: 30))
        #expect(DeadlineStatus(deadline, today: try Self.day(2026, 11, 29)).isOverdue)
        #expect(!DeadlineStatus(deadline, today: try Self.day(2026, 11, 27)).isOverdue)
    }

    @Test func aDoneDeadlineIsDoneWhateverItsDay() throws {
        let done = DocumentDeadline(
            day: try Self.day(2026, 11, 27), doneAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        for today in [try Self.day(2026, 11, 1), try Self.day(2026, 11, 27), try Self.day(2027, 1, 1)] {
            #expect(DeadlineStatus(done, today: today) == .done)
            #expect(!DeadlineStatus(done, today: today).isOverdue)
        }
    }

    /// One second before Berlin's midnight a deadline of the 27th is still due tomorrow; at midnight it is due today,
    /// and one day later overdue.
    @Test func theStatusChangesAtLocalMidnight() throws {
        let deadline = DocumentDeadline(day: try Self.day(2026, 11, 27))
        // 2026-11-27 00:00 in Berlin (UTC+1).
        let midnight = Date(timeIntervalSince1970: 1_795_734_000)
        let status = { (instant: Date) throws -> DeadlineStatus in
            DeadlineStatus(deadline, today: try #require(DeadlineDay.today(in: Self.berlin, now: instant)))
        }
        #expect(try status(midnight.addingTimeInterval(-1)) == .upcoming(days: 1))
        #expect(try status(midnight) == .today)
        #expect(try status(midnight.addingTimeInterval(86_400 - 1)) == .today)
        #expect(try status(midnight.addingTimeInterval(86_400)) == .overdue(days: 1))
    }

    /// The night of 2027-03-28 in Berlin has 23 hours: a deadline of the 29th is due tomorrow all through the 28th and
    /// due today from midnight on, though that midnight comes 23 hours after the previous one.
    @Test func aDaylightSavingChangeDoesNotShiftTheStatus() throws {
        let deadline = DocumentDeadline(day: try Self.day(2027, 3, 29))
        // 2027-03-28 00:00 in Berlin (UTC+1); the clocks go forward at 02:00, so 2027-03-29 00:00 is 23 hours later.
        let startOfThe28th = Date(timeIntervalSince1970: 1_806_188_400)
        let startOfThe29th = startOfThe28th.addingTimeInterval(23 * 3600)
        let status = { (instant: Date) throws -> DeadlineStatus in
            DeadlineStatus(deadline, today: try #require(DeadlineDay.today(in: Self.berlin, now: instant)))
        }
        #expect(try status(startOfThe28th) == .upcoming(days: 1))
        #expect(try status(startOfThe29th.addingTimeInterval(-1)) == .upcoming(days: 1))
        #expect(try status(startOfThe29th) == .today)
        // And in October, when the night has 25 hours: 2027-10-31 00:00 (UTC+2) to 2027-11-01 00:00 (UTC+1).
        let october = DocumentDeadline(day: try Self.day(2027, 11, 1))
        let startOfThe31st = Date(timeIntervalSince1970: 1_824_933_600)
        let startOfNovember = startOfThe31st.addingTimeInterval(25 * 3600)
        let octoberStatus = { (instant: Date) throws -> DeadlineStatus in
            DeadlineStatus(october, today: try #require(DeadlineDay.today(in: Self.berlin, now: instant)))
        }
        #expect(try octoberStatus(startOfNovember.addingTimeInterval(-1)) == .upcoming(days: 1))
        #expect(try octoberStatus(startOfNovember) == .today)
    }
}
