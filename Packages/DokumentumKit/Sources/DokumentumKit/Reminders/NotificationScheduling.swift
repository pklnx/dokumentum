import Foundation

/// A notification request as the reconciler sees it, pending or delivered (plan §4): the identifier, the trigger's
/// floating components, the texts and the document.
public struct ReminderRequest: Hashable, Sendable {
    public var identifier: String
    public var moment: ReminderMoment
    public var title: String
    public var body: String
    /// The document a tap opens (`userInfo`); `nil` for a request the app did not make.
    public var instanceID: UUID?
    public var threadIdentifier: String

    public init(
        identifier: String, moment: ReminderMoment, title: String, body: String, instanceID: UUID?,
        threadIdentifier: String = ReminderLimits.threadIdentifier
    ) {
        self.identifier = identifier
        self.moment = moment
        self.title = title
        self.body = body
        self.instanceID = instanceID
        self.threadIdentifier = threadIdentifier
    }
}

/// The notification center behind the reconciler (plan §4): the system's in the app
/// (`SystemNotificationCenter`, the app's only `UserNotifications` code), `InMemoryNotificationCenter` in every test and
/// in every launch that stays away from this device's real state (`NotificationCenterChoice`).
public protocol NotificationScheduling: Sendable {
    func authorizationStatus() async -> ReminderAuthorizationStatus
    /// Asks the user once; answers the status after the answer. Only the app's `ReminderAuthorization` calls it, and
    /// only from a user action on this device (Q4): never the reconciler or the scheduler.
    func requestAuthorization() async -> ReminderAuthorizationStatus
    /// Every pending request of the app (the reconciler keeps those with the `deadline.` prefix).
    func pending() async -> [ReminderRequest]
    /// Every delivered notification of the app that is still in Notification Center.
    func delivered() async -> [ReminderRequest]
    /// Adds a request; one with the identifier of a pending one replaces it.
    func add(_ request: ReminderRequest) async throws
    func removePending(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
}

/// What a reminder's texts are made from (plan §4, maintainer decision Q5): the document's title, the deadline's day
/// and label, and the day the reminder shows on. Never any text of the document.
public struct ReminderContent: Hashable, Sendable {
    public var title: String
    public var label: String
    public var day: DeadlineDay
    /// The day of the trigger's moment: the body is relative to it, not to the reconcile's day (N6).
    public var momentDay: DeadlineDay

    public init(title: String, label: String, day: DeadlineDay, momentDay: DeadlineDay) {
        self.title = title
        self.label = label
        self.day = day
        self.momentDay = momentDay
    }

    /// How far the due day lies after the day the reminder shows: 0 is "today", 1 "tomorrow".
    public var daysAhead: Int { momentDay.days(until: day) }
}

/// The reminder's title and body; the app makes them (Kit emits no user-facing strings).
public struct ReminderText: Sendable {
    public var title: @Sendable (ReminderContent) -> String
    public var body: @Sendable (ReminderContent) -> String

    public init(
        title: @escaping @Sendable (ReminderContent) -> String, body: @escaping @Sendable (ReminderContent) -> String
    ) {
        self.title = title
        self.body = body
    }
}
