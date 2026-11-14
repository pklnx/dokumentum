import DokumentumCore
import DokumentumKit
import Foundation

/// The reminder state a launch uses (#12, part 3; plan §7, N10, N2): the notification center, the settings suite and the
/// scheduled set `S`, chosen together by `NotificationCenterChoice`, so a run touches either all of this device's real
/// reminder state or none of it.
/// - **In memory** (every test run, every `-UITest*` launch, every in-memory store): `InMemoryNotificationCenter`, the
///   suite `inMemorySettingsSuite`, emptied at every such launch, and an empty `S` in memory. `-UITestNotifications`
///   sets the center's status (Debug builds).
/// - **System**: `SystemNotificationCenter`, this device's suite (`DokumentumApp.settingsSuite(isOnDisk: true)`), and
///   `S` in `ScheduledSetFile`, excluded from backup.
struct ReminderEnvironment {
    let choice: NotificationCenterChoice
    let center: any NotificationScheduling
    /// The suite of the reminder settings; `nil` is `UserDefaults.standard`.
    let settingsSuite: String?
    let scheduledSet: any ScheduledSetStoring

    /// The suite of the reminder settings of a launch on the in-memory center: emptied at each such launch, so a UI test
    /// that changes them never changes this device's real settings.
    static let inMemorySettingsSuite = "Dokumentum.InMemoryReminderSettings"

    /// The environment of this launch's choice. The in-memory suite is emptied here, before anything reads it.
    /// - Parameter inMemorySuite: tests pass a suite of their own.
    static func make(
        _ choice: NotificationCenterChoice, arguments: [String] = ProcessInfo.processInfo.arguments,
        inMemorySuite: String = inMemorySettingsSuite
    ) -> ReminderEnvironment {
        switch choice {
        case .inMemory:
            UserDefaults().removePersistentDomain(forName: inMemorySuite)
            #if DEBUG
                let (status, answer) = UITestNotifications.status(arguments: arguments)
            #else
                let (status, answer): (ReminderAuthorizationStatus, ReminderAuthorizationStatus) = (
                    .notDetermined, .denied
                )
            #endif
            return ReminderEnvironment(
                choice: choice, center: InMemoryNotificationCenter(status: status, requestAnswer: answer),
                settingsSuite: inMemorySuite, scheduledSet: InMemoryScheduledSet())
        case .system:
            return ReminderEnvironment(
                choice: choice, center: SystemNotificationCenter(),
                settingsSuite: DokumentumApp.settingsSuite(isOnDisk: true), scheduledSet: ScheduledSetFile())
        }
    }

    /// The environment the app launched with; `nil` before. For `AppHostTests`.
    @MainActor static var launched: ReminderEnvironment?
}
