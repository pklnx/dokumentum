#if DEBUG
    import DokumentumKit
    import Foundation

    /// `-UITestNotifications <status>` (Debug builds only; #12, part 3, plan §7): the status the in-memory notification
    /// center of a UI-test launch answers. `UITestApp` always passes `authorized`. Without the argument, or with a value
    /// that is not a status, the center answers `notDetermined` and a request for permission answers `denied`, so a
    /// launch never needs UI. `notDetermined` lets a request answer `authorized` (the "Allow Notifications" flow, with
    /// no system prompt).
    enum UITestNotifications {
        static let argument = "-UITestNotifications"

        /// The center's status and its answer to a request for permission.
        static func status(arguments: [String]) -> (
            status: ReminderAuthorizationStatus, requestAnswer: ReminderAuthorizationStatus
        ) {
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
                let status = ReminderAuthorizationStatus(rawValue: arguments[index + 1])
            else { return (.notDetermined, .denied) }
            return (status, status == .notDetermined ? .authorized : status)
        }
    }
#endif
