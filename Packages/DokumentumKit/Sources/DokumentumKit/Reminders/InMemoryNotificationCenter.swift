import Foundation

/// A notification center in memory (plan §4, §7): every test and every launch that stays away from this device's real
/// state uses it, so none reaches the system's center, shows a permission prompt or writes this device's reminders.
///
/// It **delivers by floating components in its current calendar** (R1), as the system does: `deliver(upTo:)` delivers
/// each pending request whose components name an instant at or before `now` in `calendar`'s time zone *now*; a test
/// moves the device with `setCalendar`. While the status does not allow notifications, a request that comes due leaves
/// pending without being shown, as on the system (the "authorization revoked" risk).
///
/// Without being told otherwise it answers `notDetermined`, and a request for permission answers `denied` and shows
/// nothing (`requestAnswer`): a launch without `-UITestNotifications` never needs UI.
public actor InMemoryNotificationCenter: NotificationScheduling {
    /// Hooks for tests: hold or fail an `add`, or let the system deliver at a chosen point of a reconcile.
    public struct Hooks: Sendable {
        /// Runs before each `add` stores its request; a throw fails the add, and nothing is stored.
        public var beforeAdd: (@Sendable (ReminderRequest) async throws -> Void)?
        /// Delivers up to this instant right after the next `pending()` took its snapshot, once: the system delivering
        /// between the reconciler's reads (N5).
        public var deliverAfterNextPendingRead: Date?
        /// Delivers up to this instant right before the next `removePending` removes anything, once: the system
        /// delivering between the reconciler's read and its withdrawal (re-review 2, N1).
        public var deliverBeforeNextRemovePending: Date?

        public init(
            beforeAdd: (@Sendable (ReminderRequest) async throws -> Void)? = nil,
            deliverAfterNextPendingRead: Date? = nil, deliverBeforeNextRemovePending: Date? = nil
        ) {
            self.beforeAdd = beforeAdd
            self.deliverAfterNextPendingRead = deliverAfterNextPendingRead
            self.deliverBeforeNextRemovePending = deliverBeforeNextRemovePending
        }
    }

    public private(set) var status: ReminderAuthorizationStatus
    /// What a request for permission turns `notDetermined` into.
    public private(set) var requestAnswer: ReminderAuthorizationStatus
    /// How often `requestAuthorization()` was called: the "never asks" tests read it.
    public private(set) var authorizationRequests = 0
    /// The calendar whose time zone delivers the floating triggers.
    public private(set) var calendar: Calendar
    /// How often each identifier was shown (delivered while allowed).
    public private(set) var shown: [String: Int] = [:]
    /// How often each identifier was added, replacements included.
    public private(set) var adds: [String: Int] = [:]
    public var hooks: Hooks

    private var pendingRequests: [String: ReminderRequest] = [:]
    /// In delivery order.
    private var deliveredRequests: [ReminderRequest] = []

    public init(
        status: ReminderAuthorizationStatus = .notDetermined, requestAnswer: ReminderAuthorizationStatus = .denied,
        calendar: Calendar = InMemoryNotificationCenter.gregorian(.current), hooks: Hooks = Hooks()
    ) {
        self.status = status
        self.requestAnswer = requestAnswer
        self.calendar = calendar
        self.hooks = hooks
    }

    /// A Gregorian calendar in `timeZone`.
    public static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // MARK: NotificationScheduling

    public func authorizationStatus() -> ReminderAuthorizationStatus { status }

    public func requestAuthorization() -> ReminderAuthorizationStatus {
        authorizationRequests += 1
        if status == .notDetermined { status = requestAnswer }
        return status
    }

    public func pending() -> [ReminderRequest] {
        let snapshot = pendingRequests.values.sorted { $0.identifier < $1.identifier }
        if let instant = hooks.deliverAfterNextPendingRead {
            hooks.deliverAfterNextPendingRead = nil
            deliver(upTo: instant)
        }
        return snapshot
    }

    public func delivered() -> [ReminderRequest] { deliveredRequests }

    public func add(_ request: ReminderRequest) async throws {
        if let beforeAdd = hooks.beforeAdd { try await beforeAdd(request) }
        pendingRequests[request.identifier] = request
        adds[request.identifier, default: 0] += 1
    }

    public func removePending(_ identifiers: [String]) {
        if let instant = hooks.deliverBeforeNextRemovePending {
            hooks.deliverBeforeNextRemovePending = nil
            deliver(upTo: instant)
        }
        for identifier in identifiers { pendingRequests[identifier] = nil }
    }

    public func removeDelivered(_ identifiers: [String]) {
        let removed = Set(identifiers)
        deliveredRequests.removeAll { removed.contains($0.identifier) }
    }

    // MARK: The system's side, for tests

    /// Delivers every pending request whose components name an instant at or before `now` in the current calendar, the
    /// earliest first; answers their identifiers. While not allowed, they leave pending unseen.
    @discardableResult
    public func deliver(upTo now: Date) -> [String] {
        let due = pendingRequests.values.compactMap { request -> (Date, ReminderRequest)? in
            guard let instant = request.moment.date(in: calendar), instant <= now else { return nil }
            return (instant, request)
        }
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.identifier < $1.1.identifier }
        for (_, request) in due {
            pendingRequests[request.identifier] = nil
            if status.allowsReminders {
                deliveredRequests.append(request)
                shown[request.identifier, default: 0] += 1
            }
        }
        return due.map(\.1.identifier)
    }

    /// The device moves to another time zone (or calendar).
    public func setCalendar(_ calendar: Calendar) {
        self.calendar = calendar
    }

    /// The user allows or turns off notifications in the system's settings.
    public func setStatus(_ status: ReminderAuthorizationStatus) {
        self.status = status
    }

    /// The user clears Notification Center.
    public func clearDelivered() {
        deliveredRequests = []
    }

    public func setHooks(_ hooks: Hooks) {
        self.hooks = hooks
    }

    /// The pending request with this identifier.
    public func pendingRequest(_ identifier: String) -> ReminderRequest? {
        pendingRequests[identifier]
    }

    /// The total times shown, over every identifier.
    public var shownTotal: Int { shown.values.reduce(0, +) }
}
