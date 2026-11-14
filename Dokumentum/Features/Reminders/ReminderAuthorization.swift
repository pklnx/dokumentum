import DokumentumKit
import Foundation
import Observation

/// Asks this device for permission to show reminders (#12, part 3; plan §7, maintainer decision Q4), and nothing else
/// does: the only caller of `NotificationScheduling.requestAuthorization()`. It asks only from **a user action on this
/// device**, and only while the system has not been asked (`notDetermined`):
/// - saving a deadline here, by hand or by accepting a suggestion, while reminders are on;
/// - turning the reminders switch on;
/// - tapping "Allow Notifications", in the settings or in the Deadlines list's notice.
///
/// Never at launch, after a sync, or in the background: the scheduler and the reconciler never ask. Denied, the settings
/// say so and offer the system's settings; an answer reconciles at once (`answered`), and allowing later catches up what
/// is inside the lead time.
@MainActor
@Observable
final class ReminderAuthorization {
    /// The status as last read.
    private(set) var status: ReminderAuthorizationStatus = .notDetermined
    /// While the one request is open: a second action does not ask again.
    private(set) var isAsking = false

    enum Action: Equatable {
        case savedDeadline
        case turnedOn
        case tappedAllow
    }

    @ObservationIgnored private let center: any NotificationScheduling
    @ObservationIgnored private let isOn: @MainActor () -> Bool
    @ObservationIgnored private let answered: @MainActor () -> Void

    /// - Parameters:
    ///   - isOn: this device's reminders switch; a saved deadline asks only while it is on.
    ///   - answered: called after an answer (the app reconciles).
    init(
        center: any NotificationScheduling, isOn: @escaping @MainActor () -> Bool,
        answered: @escaping @MainActor () -> Void = {}
    ) {
        self.center = center
        self.isOn = isOn
        self.answered = answered
    }

    /// Reads the status again (the scene became active: the user may have changed it in the system's settings).
    func refresh() async {
        status = await center.authorizationStatus()
    }

    /// A user action that may ask; answers whether it asked.
    @discardableResult
    func userAction(_ action: Action) async -> Bool {
        guard !isAsking else { return false }
        await refresh()
        guard status == .notDetermined, !isAsking else { return false }
        if action == .savedDeadline, !isOn() { return false }
        isAsking = true
        defer { isAsking = false }
        status = await center.requestAuthorization()
        answered()
        return true
    }
}
