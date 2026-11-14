import DokumentumKit
import Foundation

/// The texts of the "Reminders" settings and the Deadlines list's notice (#12, part 3; maintainer decisions Q3–Q5). The
/// device's name differs per platform: "this iPhone" and "Settings" on iOS, "this Mac" and "System Settings" on macOS.
enum ReminderSettingsText {
    static let section: LocalizedStringResource = LocalizedStringResource(
        "Reminders", comment: "Settings: the section of the deadline reminders.")
    static let toggle: LocalizedStringResource = LocalizedStringResource(
        "Remind me of deadlines", comment: "Settings: the switch that turns the deadline reminders on or off.")
    static let leadPicker: LocalizedStringResource = LocalizedStringResource(
        "Remind me", comment: "Settings: the picker of how many days before its day a deadline reminds.")
    static let timePicker: LocalizedStringResource = LocalizedStringResource(
        "At", comment: "Settings: the time of day of a deadline reminder, after “Remind me”.")
    static let allow: LocalizedStringResource = LocalizedStringResource(
        "Allow Notifications", comment: "Button: asks the system to allow Dokumentum's notifications.")

    /// "On the due day", "1 day before", "3 days before", "1 week before", "2 weeks before".
    static func lead(_ days: Int) -> LocalizedStringResource {
        switch days {
        case 0:
            LocalizedStringResource("On the due day", comment: "Settings: a deadline reminds on its own day.")
        case 7:
            LocalizedStringResource("1 week before", comment: "Settings: a deadline reminds one week before its day.")
        case 14:
            LocalizedStringResource("2 weeks before", comment: "Settings: a deadline reminds two weeks before its day.")
        default:
            LocalizedStringResource(
                "\(days) days before", comment: "Settings: a deadline reminds this many days before its day.")
        }
    }

    /// The status line under the pickers.
    static func status(_ status: ReminderAuthorizationStatus) -> LocalizedStringResource {
        switch status {
        case .authorized, .provisional, .ephemeral:
            #if os(macOS)
                LocalizedStringResource(
                    "Notifications are allowed on this Mac.", comment: "Settings: the reminders' permission is given.")
            #else
                LocalizedStringResource(
                    "Notifications are allowed on this iPhone.",
                    comment: "Settings: the reminders' permission is given.")
            #endif
        case .notDetermined:
            #if os(macOS)
                LocalizedStringResource(
                    "Allow notifications so this Mac can remind you.",
                    comment: "Settings: the system has not been asked for the reminders' permission yet.")
            #else
                LocalizedStringResource(
                    "Allow notifications so this iPhone can remind you.",
                    comment: "Settings: the system has not been asked for the reminders' permission yet.")
            #endif
        case .denied:
            #if os(macOS)
                LocalizedStringResource(
                    "Notifications are turned off for Dokumentum on this Mac. You can turn them on in System Settings > Notifications.",
                    comment: "Settings: the reminders' permission was refused.")
            #else
                LocalizedStringResource(
                    "Notifications are turned off for Dokumentum on this iPhone. You can turn them on in Settings > Notifications.",
                    comment: "Settings: the reminders' permission was refused.")
            #endif
        }
    }

    /// The button that opens the system's notification settings, while notifications are turned off.
    static var openSystemSettings: LocalizedStringResource {
        #if os(macOS)
            LocalizedStringResource(
                "Open System Settings", comment: "Button: opens the system's notification settings for Dokumentum.")
        #else
            LocalizedStringResource(
                "Open Settings", comment: "Button: opens the system's notification settings for Dokumentum.")
        #endif
    }

    /// What a reminder shows (Q5), and that the lock screen follows "Show Previews".
    static var footnote: LocalizedStringResource {
        #if os(macOS)
            LocalizedStringResource(
                "A reminder shows the document's title, its due day and the deadline's label, never the document's text. Whether it shows on the lock screen follows “Show Previews” in System Settings > Notifications.",
                comment: "Settings: what a deadline reminder shows (maintainer decision Q5).")
        #else
            LocalizedStringResource(
                "A reminder shows the document's title, its due day and the deadline's label, never the document's text. Whether it shows on the lock screen follows “Show Previews” in Settings > Notifications.",
                comment: "Settings: what a deadline reminder shows (maintainer decision Q5).")
        #endif
    }

    /// The settings are per device (Q3).
    static var perDevice: LocalizedStringResource {
        #if os(macOS)
            LocalizedStringResource(
                "These settings apply to this Mac only. Your other devices remind you by their own settings.",
                comment: "Settings: the reminder settings are per device.")
        #else
            LocalizedStringResource(
                "These settings apply to this iPhone only. Your other devices remind you by their own settings.",
                comment: "Settings: the reminder settings are per device.")
        #endif
    }

    /// The Deadlines list's notice while there are open deadlines and the system has not been asked.
    static var notice: LocalizedStringResource {
        #if os(macOS)
            LocalizedStringResource(
                "Allow notifications so this Mac can remind you of these deadlines.",
                comment: "The Deadlines list's notice while the reminders' permission has not been asked for.")
        #else
            LocalizedStringResource(
                "Allow notifications so this iPhone can remind you of these deadlines.",
                comment: "The Deadlines list's notice while the reminders' permission has not been asked for.")
        #endif
    }

    /// The status line's symbol.
    static func statusSymbol(_ status: ReminderAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: "bell"
        case .notDetermined: "bell.badge"
        case .denied: "bell.slash"
        }
    }

    /// The identifier part of a status: `authorized`, `notDetermined` or `denied` (provisional and ephemeral read as
    /// allowed).
    static func statusIdentifier(_ status: ReminderAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: "authorized"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        }
    }
}
