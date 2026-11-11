#if DEBUG
    import Foundation

    /// `-ProcessingTakeoverSeconds <n>` (Debug builds only): the processing queue takes another device's claim over
    /// after `n` seconds instead of 6 hours, for the two-device claim check (plan of #4, part 5, M4). Release builds
    /// do not contain it.
    enum ProcessingTakeoverArgument {
        static let argument = "-ProcessingTakeoverSeconds"

        /// The seconds `arguments` ask for: a positive number after the argument, otherwise `nil` (6 hours).
        static func seconds(arguments: [String]) -> TimeInterval? {
            guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count,
                let seconds = TimeInterval(arguments[index + 1]), seconds.isFinite, seconds > 0
            else { return nil }
            return seconds
        }
    }
#endif
