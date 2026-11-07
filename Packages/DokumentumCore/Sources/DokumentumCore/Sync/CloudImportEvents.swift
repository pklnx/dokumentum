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
/// Whether SwiftData on 27 posts the notification is unverified until #2's part 4.
public enum CloudImportEvents {
    public static func stream(center: NotificationCenter = .default) -> AsyncStream<CloudImportEvent> {
        let (stream, continuation) = AsyncStream<CloudImportEvent>.makeStream()
        let token = center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil
        ) { notification in
            if let event = importEnd(of: notification) { continuation.yield(event) }
        }
        let observer = Observer(token: token, center: center)
        continuation.onTermination = { _ in observer.remove() }
        return stream
    }

    /// The import end a notification reports; `nil` for setup and export events, a running import, or a
    /// notification without an event.
    public static func importEnd(of notification: Notification) -> CloudImportEvent? {
        guard
            let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
            event.type == .import, event.endDate != nil
        else { return nil }
        return CloudImportEvent(succeeded: event.succeeded)
    }

    private final class Observer: @unchecked Sendable {
        // Read and cleared under `lock`.
        private var token: (any NSObjectProtocol)?
        private let center: NotificationCenter
        private let lock = NSLock()

        init(token: any NSObjectProtocol, center: NotificationCenter) {
            self.token = token
            self.center = center
        }

        func remove() {
            let token = lock.withLock {
                defer { self.token = nil }
                return self.token
            }
            if let token { center.removeObserver(token) }
        }
    }
}
