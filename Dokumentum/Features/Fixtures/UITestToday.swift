#if DEBUG
    import DokumentumKit
    import Foundation

    /// `-UITestToday yyyy-MM-dd` (Debug builds only; #12, plan review B2): fixes the local day `AppDay` gives, so the
    /// seeded deadlines, their status and the Deadlines count are the same in every UI test run whatever day it runs.
    /// `UITestApp` always passes the runner's own local day. A value that is not a day (the read rule of
    /// `DeadlineDay(storedValue:)`, ten characters exactly) is ignored, and the system's day applies.
    enum UITestToday {
        static let argument = "-UITestToday"

        /// The day `arguments` fix, `nil` without the argument or with a value that is not a day.
        static func day(arguments: [String]) -> DeadlineDay? {
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else {
                return nil
            }
            let value = arguments[index + 1]
            guard value.count == 10 else { return nil }
            return DeadlineDay(storedValue: value)
        }
    }
#endif
