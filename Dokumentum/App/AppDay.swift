import DokumentumKit
import Foundation

/// The one source of "today" in the app (#12, plan review B2): the local day, as a calendar day. The Deadlines list's
/// status and count, the detail's deadline bar, the sample documents' deadlines (`FixtureSeeder`,
/// `FixtureLibrarySource`) and "Add Deadline"'s default day read it; unit tests pass their own day. In Debug builds,
/// `-UITestToday yyyy-MM-dd` (`UITestToday`) fixes it, so UI tests do not depend on the day they run.
///
/// A day, not an instant: a deadline is due on a day wherever the device is. The library reads it again when the day
/// changes (`LibraryModel.observeDayChanges`).
enum AppDay {
    /// The local day now: the system's in the device's current time zone, or the day `-UITestToday` fixes.
    static func today(
        arguments: [String] = ProcessInfo.processInfo.arguments, now: Date = Date(), timeZone: TimeZone = .current
    ) -> DeadlineDay {
        #if DEBUG
            if let fixed = UITestToday.day(arguments: arguments) { return fixed }
        #endif
        return DeadlineDay.today(in: timeZone, now: now) ?? outOfRange(now)
    }

    /// A clock outside the years 1000–9999 cannot name a day; it reads as the first or the last day there is.
    private static func outOfRange(_ now: Date) -> DeadlineDay {
        now < Date(timeIntervalSince1970: 0)
            ? DeadlineDay(year: DeadlineDay.years.lowerBound, month: 1, day: 1)!
            : DeadlineDay(year: DeadlineDay.years.upperBound, month: 12, day: 31)!
    }
}
