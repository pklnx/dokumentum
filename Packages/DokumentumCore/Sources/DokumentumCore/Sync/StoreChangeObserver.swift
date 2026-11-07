import CoreData
import Foundation
import SwiftData

/// One debounced signal "the store changed", shared by everything that follows the archive's changes: the
/// repair (`RepairScheduler`) now, later the library, Spotlight and search. Subscribers call `changes()`
/// instead of observing notifications themselves. Ported from the predecessor's `StoreChangeObserver`
/// (pklnx/document-archive).
///
/// Sources:
/// - `ModelContext.didSave` of any context of the observed container (local edits, imports, the repair);
/// - `NSPersistentStoreRemoteChange` of the container's store. SwiftData keeps persistent history and posts it
///   after every save to the store (`StoreChangeObserverTests` checks this). The CloudKit mirroring saves what
///   it imports from other devices into the same store without a `ModelContext` of the app, so it arrives
///   this way. That an import posts it is unverified (#2, part 4); the end of an import also restarts the
///   debounce through `RepairScheduler`.
///
/// Many saves in a short time (an import, a bulk edit) give one signal after `debounce`.
@MainActor
public final class StoreChangeObserver {
    /// Waits out the debounce; `Task.sleep` in the app. Tests pass their own, so they decide when the quiet
    /// period ends instead of waiting for time (`ManualDebounce`).
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let debounce: Duration
    private let sleep: Sleep
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var pending: Task<Void, Never>?
    /// How often `signal()` ran (before the debounce). For tests: a change that is ignored never gets here,
    /// which a test can check without waiting for a signal that must not come.
    public private(set) var receivedSignals = 0

    public init(
        container: ModelContainer, debounce: Duration = .seconds(5), center: NotificationCenter = .default,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.debounce = debounce
        self.sleep = sleep
        self.center = center
        let observed = ObjectIdentifier(container)
        tokens.append(
            center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] notification in
                // Other containers (tests, previews) are ignored.
                guard let context = notification.object as? ModelContext,
                    ObjectIdentifier(context.container) == observed
                else { return }
                Task { @MainActor in self?.signal() }
            })
        let storeURL = container.configurations.first?.url
        tokens.append(
            center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) {
                [weak self] notification in
                guard Self.isSameStore(notification.userInfo?[Self.storeURLKey] as? URL, storeURL) else { return }
                Task { @MainActor in self?.signal() }
            })
    }

    /// The `userInfo` key of the store's URL in `NSPersistentStoreRemoteChange`.
    public nonisolated static let storeURLKey = "storeURL"

    /// A notification without a URL is accepted; one for another store file is not.
    public nonisolated static func isSameStore(_ notified: URL?, _ observed: URL?) -> Bool {
        guard let notified, let observed else { return true }
        return notified.standardizedFileURL.resolvingSymlinksInPath()
            == observed.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// A new stream for one subscriber; it yields once per debounced change.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        return stream
    }

    /// Stops observing and ends every stream.
    public func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
        pending?.cancel()
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }

    /// Restarts the debounce timer; also used for triggers that are no store change (an import's end).
    public func signal() {
        receivedSignals += 1
        pending?.cancel()
        pending = Task { [debounce, sleep] in
            try? await sleep(debounce)
            guard !Task.isCancelled else { return }
            for continuation in self.continuations.values { continuation.yield() }
        }
    }
}
