import DokumentumKit
import Foundation
import SwiftData

/// Decides when the processing queue runs (plan of #4, part 5):
/// - at launch (`start()`);
/// - after each import: a save of the app's container that inserts a `Document` (`documentInsertions`), whichever
///   context saved it (the importer of any window, the share queue);
/// - on `scenePhase == .active` (`DokumentumApp` calls `requestRun()`);
/// - after each debounced store change (`StoreChangeObserver`, #56): edits, a restore from the trash, a text record
///   that arrived, another device's changes. The queue's own saves are store changes too; the run they trigger
///   finds nothing to write, so the chain ends there;
/// - at the next expiry of another device's claim that a run waited for, while the app runs (`nextExpiry`; the
///   sleep is injected, so tests end it with `ManualDebounce`).
///
/// At most one run at a time: a request during a run queues exactly one more run, however many arrive (#56's
/// `RepairScheduler`). Only for stores on disk (`StoreChoice.isOnDisk`): the app's in-memory stores of tests and
/// UI tests never start one.
@MainActor
public final class ProcessingScheduler {
    /// Waits until a claim expires; `Task.sleep` in the app.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let runner: any ProcessingRunning
    private let observer: StoreChangeObserver
    private let insertions: AsyncStream<Void>
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private var subscriptions: [Task<Void, Never>] = []
    private var running: Task<Void, Never>?
    private var expiryTimer: Task<Void, Never>?

    /// Whether a request arrived during the run that is going on, so one more run follows it.
    public private(set) var isQueued = false
    /// How many runs ended. For tests.
    public private(set) var completedRuns = 0
    /// The claim expiry the scheduler waits for, if any. For tests.
    public private(set) var scheduledExpiry: Date?
    /// Called on the main actor after each run, with its report. For tests, which wait for it instead of polling.
    public var didFinishRun: (@MainActor (ProcessingReport) -> Void)?

    public init(
        runner: any ProcessingRunning, observer: StoreChangeObserver, insertions: AsyncStream<Void>,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.observer = observer
        self.insertions = insertions
        self.sleep = sleep
        self.now = now
    }

    /// The app's scheduler for a store on disk, started.
    /// - Parameters:
    ///   - observer: the app's shared store observer (the repair and the library follow it too).
    ///   - deviceID: this device's `processingDeviceID`.
    ///   - takeoverInterval: 6 hours; Debug builds can pass `-ProcessingTakeoverSeconds` (M4).
    public static func start(
        for container: ModelContainer, observer: StoreChangeObserver, deviceID: String,
        takeoverInterval: TimeInterval? = nil
    ) -> ProcessingScheduler {
        let queue = ProcessingQueue(
            container: container, deviceID: deviceID, failures: ProcessingFailures(),
            takeoverInterval: takeoverInterval ?? ProcessingClaimRules.takeoverInterval)
        let scheduler = ProcessingScheduler(
            runner: queue, observer: observer, insertions: documentInsertions(of: container))
        scheduler.start()
        return scheduler
    }

    /// Follows the triggers and starts the launch run. A second call does nothing.
    public func start() {
        guard subscriptions.isEmpty else { return }
        let changes = observer.changes()
        let insertions = insertions
        subscriptions.append(
            Task { [weak self] in
                for await _ in changes { self?.requestRun() }
            })
        subscriptions.append(
            Task { [weak self] in
                for await _ in insertions { self?.requestRun() }
            })
        requestRun()
    }

    /// Stops following the triggers and the expiry; a run that is going on finishes.
    public func stop() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        expiryTimer?.cancel()
        expiryTimer = nil
        scheduledExpiry = nil
    }

    /// Runs the queue now, or once more after the run that is going on.
    public func requestRun() {
        guard running == nil else {
            isQueued = true
            return
        }
        running = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        repeat {
            isQueued = false
            // The queue is an actor of its own: the run leaves the main actor.
            let report = await runner.run()
            completedRuns += 1
            scheduleExpiry(report.nextExpiry)
            didFinishRun?(report)
        } while isQueued
        running = nil
    }

    /// One timer for the earliest claim the last run waited for; each run replaces it.
    private func scheduleExpiry(_ expiry: Date?) {
        expiryTimer?.cancel()
        expiryTimer = nil
        scheduledExpiry = expiry
        guard let expiry else { return }
        let delay = max(0, expiry.timeIntervalSince(now()))
        let sleep = sleep
        expiryTimer = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.scheduledExpiry = nil
            self?.requestRun()
        }
    }

    /// One element for every save of `container` that inserts a `Document`: an import, from any context. Updates
    /// (the queue's own writes, edits) yield nothing here; the debounced store change covers them.
    public nonisolated static func documentInsertions(
        of container: ModelContainer, center: NotificationCenter = .default
    ) -> AsyncStream<Void> {
        let observed = ObjectIdentifier(container)
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = center.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { notification in
            guard let context = notification.object as? ModelContext, ObjectIdentifier(context.container) == observed,
                insertsDocument(notification.userInfo)
            else { return }
            continuation.yield()
        }
        let registration = ObserverToken(token)
        continuation.onTermination = { _ in center.removeObserver(registration.token) }
        return stream
    }

    /// Whether a `ModelContext.didSave` notification's `userInfo` names an inserted `Document`.
    nonisolated static func insertsDocument(_ userInfo: [AnyHashable: Any]?) -> Bool {
        let key = ModelContext.NotificationKey.insertedIdentifiers.rawValue
        let inserted = userInfo?[key] as? [PersistentIdentifier] ?? []
        return inserted.contains { $0.entityName == Schema.entityName(for: Document.self) }
    }
}

/// Holds a notification observer for the stream's termination handler.
private final class ObserverToken: @unchecked Sendable {
    // Written once, in `init`, and only read afterwards.
    let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }
}
