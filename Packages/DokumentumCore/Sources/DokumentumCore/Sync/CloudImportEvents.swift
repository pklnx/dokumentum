import CoreData
import Foundation

/// The end of a CloudKit import, as the repair needs it.
public struct CloudImportEvent: Sendable, Equatable {
    /// Whether the import completed without an error.
    public var succeeded: Bool

    public init(succeeded: Bool) {
        self.succeeded = succeeded
    }
}

/// The ended imports of the CloudKit mirroring, from `NSPersistentCloudKitContainer.eventChangedNotification`
/// (as the predecessor's `TagCycleRepair` observed them). A thin mapping: an `NSPersistentCloudKitContainer.Event`
/// cannot be constructed in a test, so `RepairScheduler` takes the mapped stream and its tests inject their own.
/// Whether SwiftData on 27 posts the notification is unverified until #2's part 4 (#31, run 1, step 0).
public enum CloudImportEvents {
    public static func stream(center: NotificationCenter = .default) -> AsyncStream<CloudImportEvent> {
        NotificationStream.make(name: NSPersistentCloudKitContainer.eventChangedNotification, center: center) {
            importEnd(of: $0)
        }
    }

    /// The import end a notification reports; `nil` for setup and export events, a running import, or a
    /// notification without an event. Through the plain-value mapping the sync status shares (`CloudSyncEvents`).
    public static func importEnd(of notification: Notification) -> CloudImportEvent? {
        CloudSyncEvents.event(of: notification).flatMap(importEnd(of:))
    }

    /// The filter over a mapped event.
    public static func importEnd(of event: CloudSyncEvent) -> CloudImportEvent? {
        guard event.kind == .importing, event.ended != nil else { return nil }
        return CloudImportEvent(succeeded: event.succeeded)
    }

    /// The filter itself, over the event's plain values: only an import that has ended counts. A setup or an
    /// export never does, or a successful export would set `hasCompletedImport` and let pass 5 revive tombstones
    /// whose end is still downloading.
    public static func importEnd(
        type: NSPersistentCloudKitContainer.EventType, endDate: Date?, succeeded: Bool
    ) -> CloudImportEvent? {
        importEnd(
            of: CloudSyncEvent(
                kind: CloudSyncEvents.kind(of: type), started: endDate ?? .distantPast, ended: endDate,
                succeeded: succeeded))
    }
}
