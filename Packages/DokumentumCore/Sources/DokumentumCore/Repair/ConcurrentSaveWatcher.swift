import CoreData
import Foundation
import SwiftData
import Synchronization

/// Sees the saves of other contexts while a pass holds rows it is going to write, and keeps what they left in the
/// store (I6).
///
/// A `ModelContext` writes back the whole row of a record that changed in the store since it read it (measured
/// on #56; `RowState`). So every save to the store between a pass's read and its write could be reverted by that
/// write: a title, a reference, a rename. The watcher listens to Core Data's `NSManagedObjectContextDidSave` for
/// the store's file, which every save posts synchronously on its thread after its commit (a `ModelContext`'s, and
/// the CloudKit mirroring's imports), and reads the rows the pass holds in a context of its own right then. After
/// the pass saved, `conflicts` gives each row whose state another save changed: different from what the pass
/// read and from what it wrote.
///
/// Residual window: a save on another thread that commits before the pass's write, but whose notification is
/// handled only after it. The capture then reads the pass's own values, and that save's values in the rows the
/// pass wrote are lost. It spans the time from that save's commit to its notification, both inside Core Data.
final class ConcurrentSaveWatcher: Sendable {
    private struct State {
        var keys: Set<RowKey> = []
        /// Every capture, in order: a later one can be the pass's own save, which must not hide an earlier one.
        var captured: [[RowKey: RowState]] = []
        /// A save arrived before `watch(_:)` named the rows.
        var savedBeforeKeys = false
        var failures = 0
    }

    private let container: ModelContainer
    private let storeURL: URL?
    private let state = Mutex(State())
    private let token = ObserverToken()

    /// Starts watching; call `stop()` (a `defer`).
    init(container: ModelContainer) {
        self.container = container
        storeURL = container.configurations.first?.url.standardizedFileURL
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let context = notification.object as? NSManagedObjectContext else { return }
            let url = context.persistentStoreCoordinator?.persistentStores.first?.url?.standardizedFileURL
            guard url == storeURL else { return }
            capture()
        }
        token.set(observer)
    }

    /// The rows to keep, named once the pass read them. If a save arrived while it read, the rows are captured
    /// now: such a save may have come after the pass read one of them.
    func watch(_ keys: Set<RowKey>) {
        let savedMeanwhile = state.withLock { state in
            state.keys = keys
            return state.savedBeforeKeys
        }
        if savedMeanwhile { capture() }
    }

    func stop() {
        token.remove()
    }

    /// The rows another save changed: captured with a state different from both `read` and `written`. A capture
    /// equal to `written` is the pass's own save. `nil` if a capture failed, so it is not known.
    /// For a row captured more than once, the last such capture.
    func conflicts(read: [RowKey: RowState], written: [RowKey: RowState]) -> [RowKey: RowState]? {
        let (captures, failures) = state.withLock { ($0.captured, $0.failures) }
        guard failures == 0 else { return nil }
        var conflicts: [RowKey: RowState] = [:]
        for capture in captures {
            for (key, value) in capture where value != read[key] && value != written[key] {
                conflicts[key] = value
            }
        }
        return conflicts
    }

    private func capture() {
        let keys = state.withLock { state in
            if state.keys.isEmpty { state.savedBeforeKeys = true }
            return state.keys
        }
        guard !keys.isEmpty else { return }
        do {
            let rows = try RowState.read(keys, in: container)
            state.withLock { $0.captured.append(rows) }
        } catch {
            state.withLock { $0.failures += 1 }
        }
    }

    deinit { stop() }

    /// The observer's token; removing it twice does nothing.
    private final class ObserverToken: @unchecked Sendable {
        // Guarded by `lock`.
        private var observer: (any NSObjectProtocol)?
        private let lock = NSLock()

        func set(_ observer: any NSObjectProtocol) { lock.withLock { self.observer = observer } }

        func remove() {
            let observer = lock.withLock {
                defer { self.observer = nil }
                return self.observer
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
