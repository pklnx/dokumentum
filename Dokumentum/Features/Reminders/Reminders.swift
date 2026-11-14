import DokumentumCore
import DokumentumKit
import Foundation
import Observation
import SwiftData

#if os(iOS)
    import UIKit
#endif

/// The app's reminders (#12, part 3): this device's settings, the permission, the router of tapped reminders and the
/// scheduler that keeps the notification center in step. One instance for the app; every window and the settings read
/// it.
///
/// - A settings change reconciles; turning the switch on also asks for permission (`ReminderAuthorization`).
/// - An answer to the permission request reconciles.
/// - Saving a deadline on this device asks for permission while reminders are on and the system has not been asked
///   (`deadlineSaved()`, called by `LibraryModel` after a user's save, never after a sync).
/// - The scene becoming active reads the status again and reconciles.
@MainActor
@Observable
final class Reminders {
    let settings: ReminderSettingsModel
    let authorization: ReminderAuthorization
    let router: ReminderRouter
    @ObservationIgnored let environment: ReminderEnvironment
    @ObservationIgnored let scheduler: ReminderScheduler

    /// - Parameter storeChanges: the debounced changes of the app's `StoreChangeObserver`; `nil` for an in-memory store.
    init(
        environment: ReminderEnvironment, container: ModelContainer, storeChanges: AsyncStream<Void>?,
        router: ReminderRouter = ReminderRouter()
    ) {
        self.environment = environment
        self.router = router
        let settings = ReminderSettingsModel(suite: environment.settingsSuite)
        self.settings = settings
        let suite = environment.settingsSuite
        let reconciler = ReminderScheduler.makeReconciler(
            container: container, center: environment.center, scheduledSet: environment.scheduledSet,
            settings: { ReminderSettingsModel.read(suite: suite) }, text: ReminderTexts.app)
        let scheduler = ReminderScheduler(reconciler: reconciler, container: container, storeChanges: storeChanges)
        self.scheduler = scheduler
        authorization = ReminderAuthorization(
            center: environment.center, isOn: { settings.settings.isOn }, answered: { scheduler.requestReconcile() })
        settings.changed = { [weak self] change in self?.settingsChanged(change) }
    }

    /// The iPhone's significant time change (midnight, a time zone or clock change while suspended), observed while the
    /// app runs.
    @ObservationIgnored private var timeChange: (any NSObjectProtocol)?

    /// Follows the triggers and reconciles once; reads the status for the settings. Never asks.
    func start() {
        scheduler.start()
        #if os(iOS)
            let scheduler = scheduler
            timeChange = NotificationCenter.default.addObserver(
                forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { scheduler.requestReconcile() }
            }
        #endif
        Task { await authorization.refresh() }
    }

    private func settingsChanged(_ change: ReminderSettingsModel.Change) {
        scheduler.requestReconcile()
        if change == .turnedOn {
            Task { await authorization.userAction(.turnedOn) }
        }
    }

    /// A user saved a deadline on this device (a new day, by hand or from a suggestion).
    func deadlineSaved() {
        Task { await authorization.userAction(.savedDeadline) }
    }

    /// "Allow Notifications" in the settings or the Deadlines list's notice.
    func allowTapped() {
        Task { await authorization.userAction(.tappedAllow) }
    }

    /// The scene became active: the status may have changed in the system's settings, and a reconcile catches up.
    func sceneBecameActive() {
        Task {
            await authorization.refresh()
            scheduler.requestReconcile()
        }
    }

    /// Whether the settings show the permission's status line and its button ("Allow Notifications", "Open (System)
    /// Settings"): only while reminders are on (maintainer decision on review B N4 of #222).
    var showsPermissionStatus: Bool {
        settings.settings.isOn
    }

    /// Whether the Deadlines list offers "Allow Notifications": reminders are on and the system has not been asked.
    var offersPermission: Bool {
        settings.settings.isOn && authorization.status == .notDetermined
    }
}
