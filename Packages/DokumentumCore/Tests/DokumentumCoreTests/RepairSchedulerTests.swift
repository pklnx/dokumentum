import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

/// When the repair runs: at launch, after debounced store changes, at the end of a CloudKit import (injected:
/// an `NSPersistentCloudKitContainer.Event` cannot be constructed), and never two runs at once.
@MainActor
struct RepairSchedulerTests {
    /// A runner that records its runs and, with a gate, holds each run at the gate until the test releases it.
    final class StubRunner: RepairRunning {
        let started = TestSignal()
        let finished = TestSignal()
        let gate: Checkpoint?
        private let importFlags = Mutex<[Bool]>([])

        init(gate: Checkpoint? = nil) { self.gate = gate }

        var hasCompletedImportPerRun: [Bool] { importFlags.withLock { $0 } }

        func run(hasCompletedImport: Bool) async -> RepairReport? {
            let number = importFlags.withLock {
                $0.append(hasCompletedImport)
                return $0.count
            }
            started.fire()
            if let gate { await gate.pass() }
            finished.fire()
            // Each run's report carries its number, so a test can tell which one the scheduler kept.
            var report = RepairReport()
            report.counts.tombstones = number
            return report
        }
    }

    private struct Setup {
        let scheduler: RepairScheduler
        /// Fires when the scheduler has finished a run (after the runner returned).
        let runs: TestSignal
        let debounce: ManualDebounce
        let center: NotificationCenter
        let container: ModelContainer
        let imports: AsyncStream<CloudImportEvent>.Continuation
    }

    private func makeScheduler(runner: any RepairRunning, container: ModelContainer? = nil) throws -> Setup {
        let container = try container ?? TestSupport.makeContainer()
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: container, center: center, sleep: debounce.sleep)
        let (events, imports) = AsyncStream<CloudImportEvent>.makeStream()
        let scheduler = RepairScheduler(runner: runner, observer: observer, importEvents: events)
        let runs = TestSignal()
        scheduler.didFinishRun = { _ in runs.fire() }
        return Setup(
            scheduler: scheduler, runs: runs, debounce: debounce, center: center, container: container, imports: imports
        )
    }

    @Test func itRunsOnceAtLaunch() async throws {
        let runner = StubRunner()
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }

        setup.scheduler.start()
        setup.scheduler.start()
        #expect(setup.scheduler.lastReport == nil)
        await setup.runs.wait(for: 1)
        #expect(setup.scheduler.completedRuns == 1)
        #expect(runner.started.count == 1, "a second start() does not run again")
        #expect(runner.hasCompletedImportPerRun == [false])
        // The Sync lab shows the last report's counts (#31, part 2).
        #expect(setup.scheduler.lastReport?.counts.tombstones == 1)
    }

    /// Requests during a run queue exactly one more run, however many arrive.
    @Test func overlappingRequestsQueueOneMoreRun() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }

        let queuedAtEnd = Mutex<[Bool]>([])
        let scheduler = setup.scheduler
        scheduler.didFinishRun = { _ in
            queuedAtEnd.withLock { $0.append(scheduler.isQueued) }
            setup.runs.fire()
        }

        scheduler.start()
        await gate.reached()
        for _ in 0..<5 { scheduler.requestRun() }
        #expect(runner.started.count == 1, "no second run while the first is going on")
        gate.release()
        await setup.runs.wait(for: 2)
        #expect(runner.started.count == 2)
        #expect(queuedAtEnd.withLock { $0 } == [true, false], "five requests queued one run, and only one")
        #expect(scheduler.lastReport?.counts.tombstones == 2, "the last report is the second run's")
    }

    /// The end of an import restarts the debounce; when it is over, a run follows. A successful import is
    /// recorded for the revive rule.
    @Test func anImportEndTriggersARun() async throws {
        let runner = StubRunner()
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }
        setup.scheduler.start()
        await runner.finished.wait(for: 1)

        setup.imports.yield(CloudImportEvent(succeeded: false))
        await setup.debounce.waitForStarts(1)
        #expect(!setup.scheduler.hasCompletedImport, "a failed import is no completed import")
        setup.imports.yield(CloudImportEvent(succeeded: true))
        await setup.debounce.waitForStarts(2)
        #expect(runner.started.count == 1, "still in the quiet period")
        setup.debounce.fire()
        await runner.finished.wait(for: 2)
        #expect(setup.scheduler.hasCompletedImport)
        #expect(runner.hasCompletedImportPerRun == [false, true])
    }

    @Test func aStoreChangeTriggersARunAfterTheDebounce() async throws {
        let runner = StubRunner()
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }
        setup.scheduler.start()
        await runner.finished.wait(for: 1)

        setup.center.post(name: ModelContext.didSave, object: setup.container.mainContext)
        await setup.debounce.waitForStarts(1)
        #expect(runner.started.count == 1)
        setup.debounce.fire()
        await runner.finished.wait(for: 2)
    }

    /// `stop()` ends the scheduler's subscriptions: the import stream is let go, and a store change no longer
    /// reaches the observer.
    @Test func stopEndsTheSubscriptions() async throws {
        let runner = StubRunner()
        let container = try TestSupport.makeContainer()
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: container, center: center, sleep: debounce.sleep)
        let (events, imports) = AsyncStream<CloudImportEvent>.makeStream()
        let released = TestSignal()
        imports.onTermination = { _ in released.fire() }
        let scheduler = RepairScheduler(runner: runner, observer: observer, importEvents: events)
        let runs = TestSignal()
        scheduler.didFinishRun = { _ in runs.fire() }
        scheduler.start()
        await runs.wait(for: 1)

        scheduler.stop()
        await released.wait(for: 1, "the import stream was not let go")
        center.post(name: ModelContext.didSave, object: container.mainContext)
        // The observer's handler hops to the main actor; let the jobs it queued run.
        for _ in 0..<3 { await Task { @MainActor in }.value }
        #expect(observer.receivedSignals == 0, "a store change after stop() still reached the observer")
    }

    /// With the real runner on a store: the launch run repairs off the main thread, its own save is a store
    /// change, and the run that follows plans nothing and saves nothing, so the chain of runs ends there.
    @Test func theRepairsOwnSaveEndsAfterOneMoreRun() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        // The seed's own remote change notification is awaited first, so it cannot arrive during the runs.
        let storeURL = try #require(store.container.configurations.first?.url)
        let seeded = TestSignal()
        let token = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil
        ) {
            notification in
            if StoreChangeObserver.isSameStore(
                notification.userInfo?[StoreChangeObserver.storeURLKey] as? URL, storeURL)
            {
                seeded.fire()
            }
        }
        try store.seed(RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1)]))
        await seeded.wait(for: 1)
        NotificationCenter.default.removeObserver(token)
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: store.container, sleep: debounce.sleep)
        let (events, _) = AsyncStream<CloudImportEvent>.makeStream()
        let onMainThread = Mutex<[Bool]>([])
        let runner = RepairRunner(modelContainer: store.container) {
            onMainThread.withLock { $0.append(pthread_main_np() != 0) }
            return repairTime
        }
        let scheduler = RepairScheduler(runner: runner, observer: observer, importEvents: events)
        defer { scheduler.stop() }
        let runs = TestSignal()
        let saves = Mutex<[Int]>([])
        scheduler.didFinishRun = { report in
            saves.withLock { $0.append(report?.saves ?? -1) }
            runs.fire()
        }

        scheduler.start()
        await runs.wait(for: 1)
        // The run's one save is seen twice: `didSave` and the store's remote change notification.
        await debounce.waitForStarts(2, "the repair's save was not seen")
        #expect(try store.full().record(1)?.parentInstanceID == nil)
        debounce.fire()
        await runs.wait(for: 2)
        #expect(saves.withLock { $0 } == [1, 0], "the second run did not save")
        #expect(observer.receivedSignals == 2, "nothing signalled after the second run")
        #expect(!debounce.isWaiting, "no further run is pending")
        #expect(onMainThread.withLock { $0 } == [false, false], "the repair ran on the main thread")
    }
}

/// The import filter: only an import that has ended counts (review B of #56).
struct CloudImportEventsTests {
    @Test func onlyAnEndedImportCounts() {
        let now = Date()
        #expect(
            CloudImportEvents.importEnd(type: .import, endDate: now, succeeded: true)
                == CloudImportEvent(succeeded: true))
        #expect(
            CloudImportEvents.importEnd(type: .import, endDate: now, succeeded: false)
                == CloudImportEvent(succeeded: false))
        #expect(CloudImportEvents.importEnd(type: .import, endDate: nil, succeeded: false) == nil, "still running")
        #expect(CloudImportEvents.importEnd(type: .export, endDate: now, succeeded: true) == nil)
        #expect(CloudImportEvents.importEnd(type: .setup, endDate: now, succeeded: true) == nil)
    }

    @Test func aNotificationWithoutAnEventIsIgnored() {
        let notification = Notification(name: NSPersistentCloudKitContainer.eventChangedNotification)
        #expect(CloudImportEvents.importEnd(of: notification) == nil)
    }
}
