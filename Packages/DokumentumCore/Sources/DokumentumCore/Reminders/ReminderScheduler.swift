import DokumentumKit
import Foundation
import SwiftData

/// Decides when the reminders are reconciled (#12, part 3; plan §9), for every store, in-memory ones included:
/// - at launch (`start()`);
/// - after every save of a context of the app's container (`ModelContext.didSave`, as `SearchIndexer` follows them):
///   an edit, a trash move, an import, the queue's writes;
/// - after each debounced store change (`StoreChangeObserver`): another device's changes and, through
///   `RepairScheduler`, the end of each CloudKit import;
/// - at each change of the calendar day, the system time zone and the system clock (`NSCalendarDayChanged`,
///   `NSSystemTimeZoneDidChange`, `NSSystemClockDidChange`);
/// - when the app asks (`requestReconcile()`): a settings change, an authorization answer, the scene becoming active.
///
/// One reconcile runs at a time with one more queued (`ReminderReconciler.reconcile()`). **The scheduler never asks for
/// permission**: only a user action does (`ReminderAuthorization` in the app, maintainer decision Q4).
@MainActor
public final class ReminderScheduler {
    /// The system's notifications after which "now" may name another day, zone or time.
    public nonisolated static let timeNotifications: [Notification.Name] = [
        .NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
    ]

    public let reconciler: ReminderReconciler
    private let container: ModelContainer
    private let storeChanges: AsyncStream<Void>?
    private let center: NotificationCenter
    private var observation: SaveObservation?
    private var tokens: [any NSObjectProtocol] = []
    private var forwarding: Task<Void, Never>?

    /// How often a reconcile was requested, whatever its trigger. For tests.
    public private(set) var requests = 0
    /// Called on the main actor with the report of each requested reconcile. For tests, which wait for it.
    public var didFinishReconcile: (@MainActor (ReminderReconcileReport) -> Void)?

    /// - Parameters:
    ///   - storeChanges: the debounced changes of the app's `StoreChangeObserver`; `nil` for a store nothing else writes.
    ///   - center: where the day, zone and clock changes are posted; tests post their own.
    public init(
        reconciler: ReminderReconciler, container: ModelContainer, storeChanges: AsyncStream<Void>?,
        center: NotificationCenter = .default
    ) {
        self.reconciler = reconciler
        self.container = container
        self.storeChanges = storeChanges
        self.center = center
    }

    /// The app's reconciler: the store's deadlines through `ReminderStoreReader`, the real clock, and the Gregorian
    /// calendar in the device's current time zone (it follows a zone change).
    public nonisolated static func makeReconciler(
        container: ModelContainer, center: any NotificationScheduling, scheduledSet: any ScheduledSetStoring,
        settings: @escaping @Sendable () async -> ReminderSettings, text: ReminderText
    ) -> ReminderReconciler {
        let reader = ReminderStoreReader(container: container)
        return ReminderReconciler(
            center: center, scheduledSet: scheduledSet, readDeadlines: { try await reader.read() },
            settings: settings, text: text, now: { Date() },
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .autoupdatingCurrent
                return calendar
            })
    }

    /// Follows the triggers and reconciles once. A second call does nothing.
    public func start() {
        guard observation == nil else { return }
        observation = SaveObservation(container: container) { [weak self] in
            Task { @MainActor in self?.requestReconcile() }
        }
        for name in Self.timeNotifications {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    Task { @MainActor in self?.requestReconcile() }
                })
        }
        if let storeChanges {
            forwarding = Task { [weak self] in
                for await _ in storeChanges { self?.requestReconcile() }
            }
        }
        requestReconcile()
    }

    /// Stops following the triggers; a reconcile that is going on finishes.
    public func stop() {
        observation?.cancel()
        for token in tokens { center.removeObserver(token) }
        tokens = []
        forwarding?.cancel()
        forwarding = nil
    }

    /// Reconciles now, or once more after the reconcile that is going on.
    public func requestReconcile() {
        requests += 1
        let reconciler = reconciler
        Task { [weak self] in
            let report = await reconciler.reconcile()
            Self.log(report)
            self?.didFinishReconcile?(report)
        }
    }

    /// Counts and fixed codes only (T11): never a title, a label or an identifier.
    private static func log(_ report: ReminderReconcileReport) {
        switch report.outcome {
        case .readFailed:
            Log.reminders.error("Reminders not reconciled: the deadlines could not be read")
        case .scheduledSetUnreadable:
            Log.reminders.error("Reminders not reconciled: the scheduled set could not be read")
        case .reconciled:
            guard
                report.added + report.replaced + report.withdrawn + report.removedDelivered + report.failedAdds > 0
                    || report.scheduledSetSaveFailed
            else { return }
            Log.reminders.notice(
                "Reminders reconciled: \(report.planned, privacy: .public) planned, \(report.added, privacy: .public) added, \(report.replaced, privacy: .public) replaced, \(report.withdrawn, privacy: .public) withdrawn, \(report.removedDelivered, privacy: .public) delivered removed, \(report.failedAdds, privacy: .public) adds failed, set saved: \(!report.scheduledSetSaveFailed, privacy: .public)"
            )
        }
    }
}
