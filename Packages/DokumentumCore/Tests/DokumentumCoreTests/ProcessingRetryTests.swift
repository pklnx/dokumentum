import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// "Try again" (#6, P2; `ProcessingQueue.retry(_:)`): a `failed` document goes back to `pending` with this device's
/// claim under the write discipline, and this device's failure counter is cleared after the save, so the next run
/// processes it from attempt 1 without a backoff; nothing is written for a document that is not `failed`, on an edit
/// in the window, or while a stage of that document runs.
struct ProcessingRetryTests {
    private func queue(
        _ store: ProcessingStore, failures: ProcessingFailures, clock: TestClock,
        stage: any ProcessingStage = DocumentStage(recognizer: StubRecognizer()), hooks: ProcessingQueue.Hooks = .init()
    ) -> ProcessingQueue {
        store.queue(deviceA, failures: failures, stage: stage, clock: clock, hooks: hooks)
    }

    /// A document this device gave up on: `failed`, with this device's counter at the limit and a backoff running.
    private func failedHere(_ store: ProcessingStore, failures: ProcessingFailures, clock: TestClock) throws -> UUID {
        let id = try store.insert(stateRaw: "failed", device: deviceA, claimedAt: clock.now.addingTimeInterval(-hour))
        for _ in 0..<ProcessingClaimRules.failureLimit {
            failures.fail(failures.begin(id, at: clock.now))
        }
        try #require(failures.count(for: id) == ProcessingClaimRules.failureLimit)
        return id
    }

    @Test func aFailedDocumentGoesBackToPendingWithThisDevicesClaimAndItsCounterIsCleared() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try failedHere(store, failures: failures, clock: clock)
        let processing = queue(store, failures: failures, clock: clock)
        // Before: the queue skips it on this device.
        #expect(await processing.run().skipped == 1)

        clock.advance(by: 60)
        let outcome = await processing.retry(id)

        #expect(outcome == .queued)
        let row = try store.row(id)
        #expect(row.stateRaw == "pending")
        #expect(row.deviceID == deviceA)
        #expect(row.claimedAt == clock.now)
        #expect(failures.count(for: id) == 0, "this device's counter is cleared")
        #expect(failures.entry(for: id) == nil, "and its backoff with it")

        // The next run processes it at once, from attempt 1.
        let report = await processing.run()
        #expect(report.done == 1)
        #expect(try store.row(id).stateRaw == "done")
    }

    @Test(arguments: ["pending", "processing", "done", "newerState"])
    func aDocumentThatIsNotFailedIsLeftAlone(state: String) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try store.insert(stateRaw: state, device: deviceB, claimedAt: processingStart)
        failures.fail(failures.begin(id, at: clock.now))
        let before = try store.row(id)

        #expect(await queue(store, failures: failures, clock: clock).retry(id) == .notFailed)

        #expect(try store.row(id) == before)
        #expect(failures.count(for: id) == 1, "the counter stays")
    }

    @Test func aDocumentThatIsGoneIsLeftAlone() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let failures = store.failures(deviceA)
        #expect(await queue(store, failures: failures, clock: TestClock()).retry(UUID()) == .notFailed)
    }

    /// An edit saved in the window (after the fetch, before the check) makes the write back off: the edit stays, the
    /// document stays `failed`, and the counter stays, so nothing is lost and the user can press again.
    @Test func anEditInTheWindowBacksOffAndKeepsTheCounter() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try failedHere(store, failures: failures, clock: clock)
        let edited = Mutex(false)
        let hooks = ProcessingQueue.Hooks(beforeCheck: { write in
            guard write == .retry, !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            try store.edit(id) { document, _ in document.title = "User title" }
        })
        let processing = queue(store, failures: failures, clock: clock, hooks: hooks)

        #expect(await processing.retry(id) == .metAnotherSave)

        let row = try store.row(id)
        #expect(row.title == "User title")
        #expect(row.stateRaw == "failed")
        #expect(failures.count(for: id) == ProcessingClaimRules.failureLimit)

        #expect(await processing.retry(id) == .queued, "the next press goes through")
        #expect(try store.row(id).title == "User title")
        #expect(try store.row(id).stateRaw == "pending")
    }

    /// This device retries a `failed` document itself while its own counter is below the limit (another device gave
    /// up on it), and while its stage runs the other device's `failed` arrives by sync. "Try again" then writes
    /// nothing and leaves the counter, so it never races the running attempt (which would clear its counter and leave
    /// its result dropped); the attempt ends as usual, and its result is dropped for the changed claim.
    @Test func whileTheDocumentsStageRunsTryAgainIsRefused() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try store.insert(stateRaw: "failed", device: deviceB, claimedAt: processingStart)
        let recognition = Checkpoint()
        defer { recognition.release() }
        let processing = queue(
            store, failures: failures, clock: clock,
            stage: DocumentStage(recognizer: StubRecognizer(checkpoint: recognition)))
        let run = Task { await processing.run() }
        await recognition.reached()
        #expect(try store.row(id).stateRaw == "processing", "the claim write")
        #expect(failures.count(for: id) == 1, "the running attempt")
        // The other device's `failed` arrives while the stage runs.
        try store.edit(id) { document, _ in
            document.processingState = .failed
            document.processingDeviceID = deviceB
        }
        let during = try store.row(id)

        #expect(await processing.retry(id) == .busy)

        #expect(try store.row(id) == during)
        #expect(failures.count(for: id) == 1, "the running attempt's counter stays")
        recognition.release()
        let report = await run.value
        #expect(report.dropped == 1, "the claim changed under the stage")
        #expect(try store.row(id).stateRaw == "failed")
        // Now nothing runs: "Try again" goes through.
        #expect(await processing.retry(id) == .queued)
    }

    /// The scheduler's "Try again" writes through its queue and then runs it, which processes the document.
    @MainActor
    @Test func theSchedulersTryAgainRunsTheQueue() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let failures = store.failures(deviceA)
        let id = try failedHere(store, failures: failures, clock: clock)
        let observer = StoreChangeObserver(container: store.container, sleep: ManualDebounce().sleep)
        let scheduler = ProcessingScheduler(
            runner: queue(store, failures: failures, clock: clock), observer: observer,
            insertions: AsyncStream { _ in })
        let finished = TestSignal()
        scheduler.didFinishRun = { _ in finished.fire() }

        #expect(await scheduler.retry(id) == .queued)

        await finished.wait()
        #expect(try store.row(id).stateRaw == "done")
        #expect(scheduler.completedRuns == 1)
    }
}
