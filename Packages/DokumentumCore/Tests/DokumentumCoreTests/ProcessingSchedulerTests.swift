import CoreData
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// When the processing queue runs (plan of #4, part 5): at launch, after an import, after a debounced store
/// change, at the next claim expiry, and never two runs at once.
@MainActor
struct ProcessingSchedulerTests {
    /// A runner that records its runs, returns the reports it is given in turn (then empty ones) and, with a gate,
    /// holds each run until the test releases it.
    final class StubRunner: ProcessingRunning {
        let started = TestSignal()
        let gate: Checkpoint?
        private let reports: Mutex<[ProcessingReport]>

        init(gate: Checkpoint? = nil, reports: [ProcessingReport] = []) {
            self.gate = gate
            self.reports = Mutex(reports)
        }

        let interrupts = TestSignal()
        /// Per run: whether its task was cancelled when the gate let it go.
        let cancelled = Mutex<[Bool]>([])

        func run() async -> ProcessingReport {
            started.fire()
            if let gate { await gate.pass() }
            cancelled.withLock { $0.append(Task.isCancelled) }
            return reports.withLock { $0.isEmpty ? ProcessingReport() : $0.removeFirst() }
        }

        func interruptNow() {
            interrupts.fire()
        }
    }

    /// The durations the expiry timer asked to sleep.
    final class SleepLog: Sendable {
        let durations = Mutex<[Duration]>([])
    }

    private struct Setup {
        let scheduler: ProcessingScheduler
        let runs: TestSignal
        let debounce: ManualDebounce
        let expiry: ManualDebounce
        let center: NotificationCenter
        let container: ModelContainer
        let insertions: AsyncStream<Void>.Continuation
    }

    private func makeScheduler(
        runner: any ProcessingRunning, clock: TestClock = TestClock(), sleeps: SleepLog? = nil
    ) throws -> Setup {
        let container = try TestSupport.makeContainer()
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let expiry = ManualDebounce()
        let observer = StoreChangeObserver(container: container, center: center, sleep: debounce.sleep)
        let (stream, insertions) = AsyncStream<Void>.makeStream()
        let expirySleep = expiry.sleep
        let scheduler = ProcessingScheduler(
            runner: runner, observer: observer, insertions: stream,
            sleep: { duration in
                sleeps?.durations.withLock { $0.append(duration) }
                try await expirySleep(duration)
            }, now: clock.function)
        let runs = TestSignal()
        scheduler.didFinishRun = { _ in runs.fire() }
        return Setup(
            scheduler: scheduler, runs: runs, debounce: debounce, expiry: expiry, center: center, container: container,
            insertions: insertions)
    }

    @Test func itRunsOnceAtLaunch() async throws {
        let runner = StubRunner()
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }

        setup.scheduler.start()
        setup.scheduler.start()
        await setup.runs.wait(for: 1)
        #expect(setup.scheduler.completedRuns == 1)
        #expect(runner.started.count == 1, "a second start() does not run again")
    }

    /// Requests during a run queue exactly one more run, however many arrive: the launch, an import, `.active`.
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
        let requests = TestSignal()
        scheduler.didRequestRun = { requests.fire() }

        scheduler.start()
        await gate.reached()
        setup.insertions.yield()
        // The insertion reaches the scheduler through its subscription task: wait until it was handled, so it
        // cannot land after the gate is released and queue a third run (#119).
        await requests.wait(for: 2, "the insertion was not handled")
        for _ in 0..<5 { scheduler.requestRun() }
        #expect(runner.started.count == 1, "no second run while the first is going on")
        gate.release()
        await setup.runs.wait(for: 2)
        #expect(runner.started.count == 2)
        #expect(queuedAtEnd.withLock { $0 } == [true, false], "the requests queued one run, and only one")
    }

    @Test func anImportTriggersARun() async throws {
        let runner = StubRunner()
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }
        setup.scheduler.start()
        await setup.runs.wait(for: 1)

        setup.insertions.yield()
        await setup.runs.wait(for: 2)
        #expect(runner.started.count == 2)
    }

    @Test func aStoreChangeTriggersARunAfterTheDebounce() async throws {
        let runner = StubRunner()
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }
        setup.scheduler.start()
        await setup.runs.wait(for: 1)

        setup.center.post(name: ModelContext.didSave, object: setup.container.mainContext)
        await setup.debounce.waitForStarts(1)
        #expect(runner.started.count == 1)
        setup.debounce.fire()
        await setup.runs.wait(for: 2)
    }

    /// A run that waited for another device's claim runs again when it expires; the next run, which waits for
    /// nothing, leaves no timer.
    @Test func theNextClaimExpiryTriggersARun() async throws {
        let clock = TestClock()
        var waiting = ProcessingReport()
        waiting.waiting = 1
        waiting.nextExpiry = clock.now.addingTimeInterval(5 * hour)
        let runner = StubRunner(reports: [waiting])
        let sleeps = SleepLog()
        let setup = try makeScheduler(runner: runner, clock: clock, sleeps: sleeps)
        defer { setup.scheduler.stop() }

        setup.scheduler.start()
        await setup.runs.wait(for: 1)
        #expect(setup.scheduler.scheduledWake == waiting.nextExpiry)
        await setup.expiry.waitForStarts(1)
        #expect(sleeps.durations.withLock { $0 } == [.seconds(5 * 60 * 60)], "the timer waits until the claim expires")
        #expect(runner.started.count == 1, "nothing runs before the claim expires")
        setup.expiry.fire()
        await setup.runs.wait(for: 2)
        #expect(setup.scheduler.scheduledWake == nil)
        #expect(!setup.expiry.isWaiting)
    }

    /// A backoff the run waited for wakes the scheduler like a claim expiry: the earlier of the two.
    @Test func theEarlierOfExpiryAndRetryWakesTheScheduler() async throws {
        let clock = TestClock()
        var waiting = ProcessingReport()
        waiting.nextExpiry = clock.now.addingTimeInterval(5 * hour)
        waiting.nextRetry = clock.now.addingTimeInterval(60)
        let runner = StubRunner(reports: [waiting])
        let sleeps = SleepLog()
        let setup = try makeScheduler(runner: runner, clock: clock, sleeps: sleeps)
        defer { setup.scheduler.stop() }

        setup.scheduler.start()
        await setup.runs.wait(for: 1)
        #expect(setup.scheduler.scheduledWake == waiting.nextRetry)
        await setup.expiry.waitForStarts(1)
        #expect(sleeps.durations.withLock { $0 } == [.seconds(60)])
        setup.expiry.fire()
        await setup.runs.wait(for: 2)
    }

    /// `pause()` during a run interrupts it at once (the attempt is given back) and cancels it; no run starts until
    /// `resume()`, which starts one.
    @Test func pauseInterruptsTheRunAndHoldsRunsUntilResume() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }
        let scheduler = setup.scheduler

        scheduler.start()
        await gate.reached()
        scheduler.pause()
        #expect(runner.interrupts.count == 1, "the refund is synchronous")
        #expect(scheduler.isPaused)
        gate.release()
        await setup.runs.wait(for: 1)
        #expect(runner.cancelled.withLock { $0 } == [true], "the run was not cancelled")

        // Every trigger (launch, import, store change, timer, activation) goes through `requestRun()`.
        scheduler.requestRun()
        #expect(!scheduler.isRunning, "a run started while paused")
        #expect(!scheduler.isQueued)
        #expect(runner.started.count == 1)

        scheduler.resume()
        #expect(!scheduler.isPaused)
        await setup.runs.wait(for: 2)
        #expect(runner.started.count == 2)
        #expect(runner.cancelled.withLock { $0 } == [true, false])
    }

    /// A `resume()` that comes while the paused run is still ending starts one more run after it.
    @Test func aResumeWhileThePausedRunEndsRunsAgain() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }
        let scheduler = setup.scheduler

        scheduler.start()
        await gate.reached()
        scheduler.pause()
        scheduler.resume()
        gate.release()
        await setup.runs.wait(for: 2)
        #expect(runner.cancelled.withLock { $0 } == [true, false])
        #expect(runner.interrupts.count == 1)
    }

    /// `didDrain` (the background tasks' hook, plan of #6, part 5) comes once when the runs end and none follows:
    /// not after each run of a queued chain, and not after a run that `pause()` ended.
    @Test func theRunsDrainOnceAndNotWhenPaused() async throws {
        let gate = Checkpoint()
        defer { gate.release() }
        let runner = StubRunner(gate: gate)
        let setup = try makeScheduler(runner: runner)
        defer { setup.scheduler.stop() }
        let scheduler = setup.scheduler
        let drains = TestSignal()
        let pausedAtDrain = Mutex<[Bool]>([])
        scheduler.didDrain = {
            pausedAtDrain.withLock { $0.append(scheduler.isPaused) }
            drains.fire()
        }

        scheduler.start()
        await gate.reached()
        scheduler.requestRun()
        gate.release()
        await setup.runs.wait(for: 2)
        await drains.wait(for: 1, "the runs did not drain")
        #expect(drains.count == 1, "a queued chain of two runs drained twice")

        let held = Checkpoint()
        defer { held.release() }
        let pausedRunner = StubRunner(gate: held)
        let paused = try makeScheduler(runner: pausedRunner)
        defer { paused.scheduler.stop() }
        let pausedDrains = TestSignal()
        paused.scheduler.didDrain = { pausedDrains.fire() }
        paused.scheduler.start()
        await held.reached()
        paused.scheduler.pause()
        held.release()
        await paused.runs.wait(for: 1)
        #expect(pausedDrains.count == 0, "a run ended by pause() drained")
        paused.scheduler.resume()
        await paused.runs.wait(for: 2)
        await pausedDrains.wait(for: 1, "the run after resume() did not drain")
        #expect(pausedAtDrain.withLock { $0 } == [false])
    }

    /// With the real queue: a failed attempt (#97 point 2) names its backoff, and the scheduler's timer runs the
    /// queue again when it ends, not before.
    @Test func aFailedAttemptWakesTheSchedulerWhenItsBackoffEnds() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let seeded = remoteChange(of: store.container)
        try store.insert(device: deviceA, claimedAt: processingStart)
        await seeded.signal.wait(for: 1)
        NotificationCenter.default.removeObserver(seeded.token)
        let clock = TestClock()
        let stage = TestStage(failing: 100)
        let wake = ManualDebounce()
        let sleeps = SleepLog()
        let (insertions, _) = AsyncStream<Void>.makeStream()
        let wakeSleep = wake.sleep
        let scheduler = ProcessingScheduler(
            runner: store.queue(deviceA, stage: stage, clock: clock),
            observer: StoreChangeObserver(container: store.container, sleep: ManualDebounce().sleep),
            insertions: insertions,
            sleep: { duration in
                sleeps.durations.withLock { $0.append(duration) }
                try await wakeSleep(duration)
            }, now: clock.function)
        defer { scheduler.stop() }
        let runs = TestSignal()
        scheduler.didFinishRun = { _ in runs.fire() }

        scheduler.start()
        await runs.wait(for: 1)
        #expect(stage.count == 1)
        #expect(scheduler.scheduledWake == processingStart.addingTimeInterval(60))
        await wake.waitForStarts(1)
        #expect(sleeps.durations.withLock { $0 } == [.seconds(60)])
        clock.advance(by: 60)
        wake.fire()
        await runs.wait(for: 2)
        #expect(stage.count == 2)
        #expect(scheduler.scheduledWake == clock.now.addingTimeInterval(10 * 60))
    }

    /// `ModelContext.didSave` names an inserted `Document` for an import, and only then.
    @Test func onlyASaveThatInsertsADocumentIsAnImport() async throws {
        let container = try TestSupport.makeContainer()
        let inserts = Mutex<[Bool]>([])
        let saved = TestSignal()
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
            notification in
            guard let context = notification.object as? ModelContext,
                ObjectIdentifier(context.container) == ObjectIdentifier(container)
            else { return }
            let insertsDocument = ProcessingScheduler.insertsDocument(notification.userInfo)
            inserts.withLock { $0.append(insertsDocument) }
            saved.fire()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let insertions = ProcessingScheduler.documentInsertions(of: container)
        let (signal, counting) = TestSignal.counting(insertions)
        defer { counting.cancel() }

        let context = ModelContext(container)
        let document = Document(title: "Imported")
        context.insert(document)
        try context.save()
        document.title = "Edited"
        try context.save()
        context.insert(Correspondent(name: "Only metadata"))
        try context.save()
        await saved.wait(for: 3)
        await signal.wait(for: 1)

        #expect(inserts.withLock { $0 } == [true, false, false])
    }

    /// With the real queue on a store on disk: the launch run processes off the main thread, its own save is a
    /// store change, and the run that follows writes nothing, so the chain of runs ends there.
    @Test func theQueuesOwnSaveEndsAfterOneMoreRun() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        // The seed's own remote change notification is awaited first, so it cannot arrive during the runs.
        let seeded = remoteChange(of: store.container)
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        await seeded.signal.wait(for: 1)
        NotificationCenter.default.removeObserver(seeded.token)
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: store.container, sleep: debounce.sleep)
        let onMainThread = Mutex<[Bool]>([])
        let stage = TestStage { _ in onMainThread.withLock { $0.append(pthread_main_np() != 0) } }
        let queue = store.queue(deviceA, stage: stage, clock: TestClock())
        let (insertions, _) = AsyncStream<Void>.makeStream()
        let scheduler = ProcessingScheduler(runner: queue, observer: observer, insertions: insertions)
        defer { scheduler.stop() }
        let runs = TestSignal()
        let saves = Mutex<[Int]>([])
        scheduler.didFinishRun = { report in
            saves.withLock { $0.append(report.saves) }
            runs.fire()
        }

        scheduler.start()
        await runs.wait(for: 1)
        // The run's one save is seen twice: `didSave` and the store's remote change notification.
        await debounce.waitForStarts(2, "the queue's save was not seen")
        #expect(try store.row(id).stateRaw == "done")
        debounce.fire()
        await runs.wait(for: 2)
        #expect(saves.withLock { $0 } == [1, 0], "the second run did not save")
        #expect(observer.receivedSignals == 2, "nothing signalled after the second run")
        #expect(!debounce.isWaiting, "no further run is pending")
        #expect(onMainThread.withLock { $0 } == [false], "the stage ran on the main thread")
    }

    /// A document waits for its text record; the text arriving later is a store change, and the run it triggers
    /// processes the document.
    @Test func aTextThatArrivesLaterStartsTheRunThatProcessesIt() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let seeded = remoteChange(of: store.container)
        let id = try store.insert(device: deviceA, claimedAt: processingStart, text: false)
        await seeded.signal.wait(for: 1)
        NotificationCenter.default.removeObserver(seeded.token)
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: store.container, sleep: debounce.sleep)
        let (insertions, _) = AsyncStream<Void>.makeStream()
        let scheduler = ProcessingScheduler(
            runner: store.queue(deviceA, clock: TestClock()), observer: observer, insertions: insertions)
        defer { scheduler.stop() }
        let runs = TestSignal()
        let reports = Mutex<[ProcessingReport]>([])
        scheduler.didFinishRun = { report in
            reports.withLock { $0.append(report) }
            runs.fire()
        }

        scheduler.start()
        await runs.wait(for: 1)
        #expect(reports.withLock { $0.first?.waiting } == 1)
        try store.edit(id) { document, context in
            let text = DocumentText(documentID: document.id)
            context.insert(text)
            document.text = text
        }
        // Seen twice, as every save: `didSave` and the store's remote change notification.
        await debounce.waitForStarts(2, "the text's save was not seen")
        debounce.fire()
        await runs.wait(for: 2)
        #expect(reports.withLock { $0.last?.done } == 1)
        #expect(try store.row(id).stateRaw == "done")
    }

    /// A signal for the store's next remote change notification; remove the token after waiting.
    private func remoteChange(of container: ModelContainer) -> (signal: TestSignal, token: any NSObjectProtocol) {
        let storeURL = container.configurations.first?.url
        let signal = TestSignal()
        let token = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil
        ) { notification in
            let notified = notification.userInfo?[StoreChangeObserver.storeURLKey] as? URL
            if StoreChangeObserver.isSameStore(notified, storeURL) { signal.fire() }
        }
        return (signal, token)
    }
}
