import Foundation
import SwiftData

/// Something that runs the repair once; `RepairRunner` in the app, a stub in tests.
public protocol RepairRunning: Sendable {
    func run(hasCompletedImport: Bool) async -> RepairReport?
}

/// Decides when the repair runs (plan of #2, part 3, "Triggers"):
/// - once at launch, after the container opened (`start()`);
/// - after each debounced store change (`StoreChangeObserver`); the repair's own save is one too, and the run
///   it triggers plans nothing and saves nothing (I7);
/// - at the end of every CloudKit import, which restarts the debounce, as the predecessor's `TagCycleRepair`
///   did. A successful one is recorded in `hasCompletedImport`, which the revive rule needs (pass 5).
///
/// At most one run at a time: a request during a run queues exactly one more run, however many arrive.
@MainActor
public final class RepairScheduler {
    private let runner: any RepairRunning
    private let observer: StoreChangeObserver
    private let importEvents: AsyncStream<CloudImportEvent>
    private var subscriptions: [Task<Void, Never>] = []
    private var running: Task<Void, Never>?

    /// Whether a CloudKit import completed successfully in this app session.
    public private(set) var hasCompletedImport = false
    /// Whether a request arrived during the run that is going on, so one more run follows it.
    public private(set) var isQueued = false
    /// How many runs ended. For tests.
    public private(set) var completedRuns = 0
    /// The report of the last run that ended (`nil` before the first, or when it failed). The Sync lab shows its
    /// counts.
    public private(set) var lastReport: RepairReport?
    /// Called on the main actor after each run, with its report (`nil` if it failed). For tests, which wait for
    /// it instead of polling.
    public var didFinishRun: (@MainActor (RepairReport?) -> Void)?

    public init(runner: any RepairRunning, observer: StoreChangeObserver, importEvents: AsyncStream<CloudImportEvent>) {
        self.runner = runner
        self.observer = observer
        self.importEvents = importEvents
    }

    /// The app's scheduler for `container`, started: the repair in the background, the debounced store
    /// changes, and the CloudKit import events. Only for stores on disk; test stores never start one, except
    /// in tests that do so on purpose.
    ///
    /// - Parameter observer: the app's shared store observer, which the library follows too; the end of a
    ///   CloudKit import restarts its debounce, so the library reads what the import brought. A new one by default.
    public static func start(for container: ModelContainer, observer: StoreChangeObserver? = nil) -> RepairScheduler {
        let scheduler = RepairScheduler(
            runner: RepairRunner(modelContainer: container),
            observer: observer ?? StoreChangeObserver(container: container),
            importEvents: CloudImportEvents.stream())
        scheduler.start()
        return scheduler
    }

    /// Follows the triggers and starts the launch run. A second call does nothing.
    public func start() {
        guard subscriptions.isEmpty else { return }
        let changes = observer.changes()
        let events = importEvents
        subscriptions.append(
            Task { [weak self] in
                for await _ in changes { self?.requestRun() }
            })
        subscriptions.append(
            Task { [weak self] in
                for await event in events { self?.importEnded(event) }
            })
        requestRun()
    }

    /// Stops following the triggers; a run that is going on finishes.
    public func stop() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        observer.stop()
    }

    /// Runs the repair now, or once more after the run that is going on.
    public func requestRun() {
        guard running == nil else {
            isQueued = true
            return
        }
        running = Task { [weak self] in await self?.drain() }
    }

    private func importEnded(_ event: CloudImportEvent) {
        if event.succeeded { hasCompletedImport = true }
        observer.signal()
    }

    private func drain() async {
        repeat {
            isQueued = false
            // Off the main actor: a model actor's default executor runs a job on the thread that enqueues it, so
            // a call from here would run the whole repair on the main thread (measured on #56).
            let (runner, flag) = (runner, hasCompletedImport)
            let report = await Task.detached { await runner.run(hasCompletedImport: flag) }.value
            completedRuns += 1
            lastReport = report
            didFinishRun?(report)
        } while isQueued
        running = nil
    }
}
