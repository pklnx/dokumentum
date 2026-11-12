import CoreData
import DokumentumKit
import Foundation

/// One `NSPersistentCloudKitContainer.Event` as plain values: an event cannot be constructed in a test, so everything
/// after this mapping takes these. A running event and its end are two notifications with the same `identifier`.
public struct CloudSyncEvent: Hashable, Sendable {
    public var identifier: UUID
    public var kind: SyncEventKind
    public var started: Date
    /// `nil` while the event runs.
    public var ended: Date?
    public var succeeded: Bool
    /// The event's error, flattened as `CloudErrorCategory.classify` expects it (`CloudSyncEvents.errorChain`).
    public var errorChain: [ErrorLink]

    public init(
        identifier: UUID = UUID(), kind: SyncEventKind, started: Date, ended: Date?, succeeded: Bool,
        errorChain: [ErrorLink] = []
    ) {
        self.identifier = identifier
        self.kind = kind
        self.started = started
        self.ended = ended
        self.succeeded = succeeded
        self.errorChain = errorChain
    }

    /// The reducer's input for this event.
    public var input: SyncStatusInput {
        .event(kind: kind, started: started, ended: ended, succeeded: succeeded, errorChain: errorChain)
    }
}

/// The mapping from `NSPersistentCloudKitContainer.eventChangedNotification` to plain values, shared by the sync status
/// (`CloudSyncMonitor`) and the repair (`CloudImportEvents`). It runs on the posting thread and keeps no reference to
/// the event.
public enum CloudSyncEvents {
    /// `CKPartialErrorsByItemIDKey`, spelled out so that only the adapter imports CloudKit; `CloudErrorCodesTests`
    /// pins it against the SDK.
    public static let partialErrorsKey = "CKPartialErrors"
    /// How deep the chain follows `NSUnderlyingErrorKey` and partial-failure items.
    public static let maximumDepth = 8

    /// The events of `center`, mapped as they are posted, in posting order.
    public static func stream(center: NotificationCenter = .default) -> AsyncStream<CloudSyncEvent> {
        NotificationStream.make(name: NSPersistentCloudKitContainer.eventChangedNotification, center: center) {
            event(of: $0)
        }
    }

    /// The event a notification carries; `nil` for a notification without one.
    public static func event(of notification: Notification) -> CloudSyncEvent? {
        guard
            let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
        else { return nil }
        return CloudSyncEvent(
            identifier: event.identifier, kind: kind(of: event.type), started: event.startDate, ended: event.endDate,
            succeeded: event.succeeded, errorChain: event.error.map(errorChain(of:)) ?? [])
    }

    public static func kind(of type: NSPersistentCloudKitContainer.EventType) -> SyncEventKind {
        switch type {
        case .setup: .setup
        case .import: .importing
        case .export: .exporting
        @unknown default: .setup
        }
    }

    /// The error, then for each error its partial-failure items and its `NSUnderlyingErrorKey`, depth first, each
    /// error once and at most `maximumDepth` deep, so a chain that refers to itself ends. The items are sorted by
    /// domain and code: a dictionary has no order, and `classify` looks at all of them anyway.
    public static func errorChain(of error: any Error) -> [ErrorLink] {
        var chain: [ErrorLink] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ error: NSError, depth: Int) {
            guard depth < maximumDepth, seen.insert(ObjectIdentifier(error)).inserted else { return }
            chain.append(ErrorLink(domain: error.domain, code: error.code))
            let userInfo = error.userInfo
            if let items = userInfo[partialErrorsKey] as? [AnyHashable: Any] {
                let errors = items.values.compactMap { $0 as? NSError }.sorted {
                    ($0.domain, $0.code) < ($1.domain, $1.code)
                }
                for item in errors { visit(item, depth: depth + 1) }
            }
            if let underlying = userInfo[NSUnderlyingErrorKey] as? NSError {
                visit(underlying, depth: depth + 1)
            }
        }
        visit(error as NSError, depth: 0)
        return chain
    }
}

/// A notification observer as an `AsyncStream`: the observer maps each notification on the posting thread and is
/// removed when the stream ends.
enum NotificationStream {
    static func make<Element: Sendable>(
        name: Notification.Name, center: NotificationCenter,
        map: @escaping @Sendable (Notification) -> Element?
    ) -> AsyncStream<Element> {
        make(names: [name], center: center, map: map)
    }

    static func make<Element: Sendable>(
        names: [Notification.Name], center: NotificationCenter,
        map: @escaping @Sendable (Notification) -> Element?
    ) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { notification in
                if let element = map(notification) { continuation.yield(element) }
            }
        }
        let observer = Observer(tokens: tokens, center: center)
        continuation.onTermination = { _ in observer.remove() }
        return stream
    }

    private final class Observer: @unchecked Sendable {
        // Read and cleared under `lock`.
        private var tokens: [any NSObjectProtocol]
        private let center: NotificationCenter
        private let lock = NSLock()

        init(tokens: [any NSObjectProtocol], center: NotificationCenter) {
            self.tokens = tokens
            self.center = center
        }

        func remove() {
            let tokens = lock.withLock {
                defer { self.tokens = [] }
                return self.tokens
            }
            for token in tokens { center.removeObserver(token) }
        }
    }
}
