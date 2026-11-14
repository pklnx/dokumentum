import DokumentumCore
import DokumentumKit
import Foundation
import UserNotifications

/// The system's notification center behind `NotificationScheduling` (#12, part 3; plan §4): a thin wrapper of
/// `UNUserNotificationCenter`, and **the app's only `UserNotifications` code**. Only a launch whose
/// `NotificationCenterChoice` is `.system` creates it: never a test run, never a `-UITest*` launch, never an in-memory
/// store. So no test reaches it; it is compiled, and exercised only on the maintainer's signed builds (M1).
///
/// A request: the title (the document's title), the body (the due day and the label, never the document's text, Q5),
/// the thread `deadlines`, the document's `instanceID` in `userInfo`, and a calendar trigger with floating components
/// (year, month, day, hour, minute; Gregorian, no time zone), so 09:00 is 09:00 wherever the device is.
final class SystemNotificationCenter: NotificationScheduling, @unchecked Sendable {
    /// The key of the document's `instanceID` in a request's `userInfo`.
    static let instanceIDKey = "instanceID"

    // `UNUserNotificationCenter` is thread-safe; the wrapper holds nothing else.
    private let center: UNUserNotificationCenter

    init() {
        precondition(!TestEnvironment.isRunningTests, "The system notification center is never used in a test run.")
        center = UNUserNotificationCenter.current()
    }

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        Self.status(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> ReminderAuthorizationStatus {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.reminders.error("Notification permission request failed: \(Log.code(of: error), privacy: .public)")
        }
        return await authorizationStatus()
    }

    func pending() async -> [ReminderRequest] {
        await center.pendingNotificationRequests().compactMap(Self.reminderRequest)
    }

    func delivered() async -> [ReminderRequest] {
        await center.deliveredNotifications().compactMap { Self.reminderRequest($0.request) }
    }

    func add(_ request: ReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.sound = .default
        if let instanceID = request.instanceID {
            content.userInfo = [Self.instanceIDKey: instanceID.uuidString]
        }
        var components = request.moment.components
        components.calendar = Calendar(identifier: .gregorian)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    func removePending(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Sets the delegate that shows a reminder while the app is in front and opens the document of a tapped one. Only
    /// for the system center, before the app finishes launching, so a tap that launched the app is not missed.
    @MainActor
    func setDelegate(_ delegate: ReminderNotificationDelegate) {
        center.delegate = delegate
    }

    private static func status(_ status: UNAuthorizationStatus) -> ReminderAuthorizationStatus {
        switch status {
        case .authorized: .authorized
        case .provisional: .provisional
        case .denied: .denied
        case .notDetermined: .notDetermined
        #if os(iOS)
            case .ephemeral: .ephemeral
        #endif
        @unknown default: .denied
        }
    }

    /// The request as the reconciler sees it; `nil` for one without a calendar trigger.
    private static func reminderRequest(_ request: UNNotificationRequest) -> ReminderRequest? {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
        let parts = trigger.dateComponents
        let moment = ReminderMoment(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0, hour: parts.hour ?? 0,
            minute: parts.minute ?? 0)
        let instanceID = (request.content.userInfo[instanceIDKey] as? String).flatMap(UUID.init(uuidString:))
        return ReminderRequest(
            identifier: request.identifier, moment: moment, title: request.content.title, body: request.content.body,
            instanceID: instanceID, threadIdentifier: request.content.threadIdentifier)
    }
}

/// Shows a reminder as a banner while the app is in front (`willPresent`) and opens the document of a tapped one
/// (`ReminderRouter`, plan §8).
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // Set once, at launch; the router is main-actor isolated.
    private let router: ReminderRouter

    init(router: ReminderRouter) {
        self.router = router
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        guard ReminderIdentifier.isReminder(request.identifier),
            let instanceID = (request.content.userInfo[SystemNotificationCenter.instanceIDKey] as? String).flatMap(
                UUID.init(uuidString:))
        else { return }
        await router.open(instanceID)
    }
}
