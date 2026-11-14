import DokumentumKit
import Foundation
import Testing

/// `DeadlineDay` (#12, part 1): the stored form `yyyy-MM-dd`, the read rule (the first ten characters only), leap
/// days, "today" in a time zone, and the conversion from and to `SuggestedDate`.
struct DeadlineDayTests {
    private static func day(_ year: Int, _ month: Int, _ day: Int) throws -> DeadlineDay {
        try #require(DeadlineDay(year: year, month: month, day: day), "\(year)-\(month)-\(day)")
    }

    @Test func aDayRoundTripsThroughItsStoredValue() throws {
        let cases: [(DeadlineDay, String)] = [
            (try Self.day(2026, 11, 27), "2026-11-27"), (try Self.day(2026, 1, 5), "2026-01-05"),
            (try Self.day(1000, 1, 1), "1000-01-01"), (try Self.day(9999, 12, 31), "9999-12-31"),
        ]
        for (day, stored) in cases {
            #expect(day.storedValue == stored)
            #expect(day.storedValue.count == 10)
            #expect(DeadlineDay(storedValue: stored) == day)
            #expect(day.description == stored)
        }
    }

    /// The read rule: only the first ten characters are read, so a later build's suffix (a time) still reads as the
    /// day.
    @Test func onlyTheFirstTenCharactersAreRead() throws {
        let expected = try Self.day(2026, 11, 27)
        for stored in ["2026-11-27T14:00", "2026-11-27 ", "2026-11-27Z", "2026-11-27T14:00:00+01:00"] {
            #expect(DeadlineDay(storedValue: stored) == expected, "\(stored)")
        }
    }

    /// What does not read as a day reads as none, never as a nearby day.
    @Test func whatIsNotADayReadsAsNone() {
        let values = [
            "", "garbage", "2026-11-2", "2026-11", "2026/11/27", "27.11.2026", "2026-13-01", "2026-00-10",
            "2026-11-00", "2026-11-31", "2026-02-30", "2026-02-29", "1900-02-29", "0999-12-31", "+026-11-27",
            "2026-+1-27", " 2026-11-27", "２０２６-11-27", "2026-11-٢٧", "20261127",
        ]
        for stored in values {
            #expect(DeadlineDay(storedValue: stored) == nil, "\(stored)")
        }
    }

    /// Gregorian leap years: every fourth, except centuries not divisible by 400.
    @Test func leapDaysFollowTheGregorianRule() {
        for year in [2024, 2028, 2000, 2400, 1600] {
            #expect(DeadlineDay(year: year, month: 2, day: 29) != nil, "\(year)")
        }
        for year in [2026, 2027, 1900, 2100, 2200] {
            #expect(DeadlineDay(year: year, month: 2, day: 29) == nil, "\(year)")
            #expect(DeadlineDay(year: year, month: 2, day: 28) != nil, "\(year)")
        }
        #expect(DeadlineDay(storedValue: "2028-02-29")?.storedValue == "2028-02-29")
        for (month, last) in [(1, 31), (3, 31), (4, 30), (6, 30), (9, 30), (11, 30), (12, 31)] {
            #expect(DeadlineDay(year: 2026, month: month, day: last) != nil, "\(month)")
            #expect(DeadlineDay(year: 2026, month: month, day: last + 1) == nil, "\(month)")
        }
    }

    /// Only four-digit years are days, so the stored value is always ten characters (review N8).
    @Test func onlyFourDigitYearsAreDays() {
        for year in [0, 26, 999, 10_000, -2026] {
            #expect(DeadlineDay(year: year, month: 1, day: 1) == nil, "\(year)")
        }
        #expect(DeadlineDay.years == 1000...9999)
    }

    /// "Today" depends on the time zone: one instant is the 27th in Berlin and still the 26th in New York.
    @Test func todayIsTheDayInTheGivenTimeZone() throws {
        // 2026-11-27 03:00 in Berlin (UTC+1) is 2026-11-26 21:00 in New York (UTC−5).
        let instant = Date(timeIntervalSince1970: 1_795_744_800)
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(DeadlineDay.today(in: berlin, now: instant) == (try Self.day(2026, 11, 27)))
        #expect(DeadlineDay.today(in: newYork, now: instant) == (try Self.day(2026, 11, 26)))
        // One second before Berlin's midnight it is still the 26th there.
        let beforeMidnight = instant.addingTimeInterval(-3 * 3600 - 1)
        #expect(DeadlineDay.today(in: berlin, now: beforeMidnight) == (try Self.day(2026, 11, 26)))
        let midnight = beforeMidnight.addingTimeInterval(1)
        #expect(DeadlineDay.today(in: berlin, now: midnight) == (try Self.day(2026, 11, 27)))
    }

    @Test func aDayConvertsFromAndToASuggestedDate() throws {
        let suggested = SuggestedDate(day: 27, month: 11, year: 2026)
        let day = try #require(DeadlineDay(suggested))
        #expect(day == (try Self.day(2026, 11, 27)))
        #expect(day.suggestedDate == suggested)
        #expect(DeadlineDay(SuggestedDate(day: 30, month: 2, year: 2026)) == nil)
        #expect(DeadlineDay(SuggestedDate(day: 1, month: 1, year: 26)) == nil)
    }

    @Test func daysSortInCalendarOrder() throws {
        let days = [
            try Self.day(2027, 1, 1), try Self.day(2026, 11, 27), try Self.day(2026, 12, 1), try Self.day(2026, 11, 3),
        ]
        #expect(days.sorted().map(\.storedValue) == ["2026-11-03", "2026-11-27", "2026-12-01", "2027-01-01"])
        // The stored strings sort the same way.
        #expect(days.map(\.storedValue).sorted() == days.sorted().map(\.storedValue))
        #expect(max(try Self.day(2026, 11, 27), try Self.day(2026, 12, 15)) == (try Self.day(2026, 12, 15)))
    }

    @Test func aDeadlineIsDoneWhileItHasADoneDate() throws {
        var deadline = DocumentDeadline(day: try Self.day(2026, 11, 27), label: "Pay")
        #expect(!deadline.isDone)
        deadline.doneAt = Date(timeIntervalSince1970: 0)
        #expect(deadline.isDone)
    }
}
