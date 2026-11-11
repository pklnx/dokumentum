import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

/// The queue's hardening from #97 (plan of #6, part 1): the retry backoff (point 2), the stall watchdog (point 3),
/// at most one job besides the current one (N1), and `interruptNow()` (point 4). The watchdog sleeps on a
/// `ManualDebounce` the test fires; stuck stages stand at a `Checkpoint` the test releases in a `defer`.
struct ProcessingInterruptionTests {
    // MARK: Backoff (#97 point 2)

    /// B-N4 with a stage that throws (N8): the two runs of one import (its insertion, then its store change) spend
    /// one attempt, and the next waits for the backoff, which the report names as its next wake. Three failures take
    /// at least 11 minutes.
    @Test func twoRunsOfOneImportSpendOneAttemptAndTheNextWaitsForTheBackoff() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let failures = store.failures(deviceA)
        let stage = TestStage(failing: 100)
        let queue = store.queue(deviceA, failures: failures, stage: stage, clock: clock)

        let first = await queue.run()
        let second = await queue.run()
        #expect(first.failures == 1)
        #expect(first.nextRetry == processingStart.addingTimeInterval(60), "the failed attempt starts the backoff")
        #expect(second.waiting == 1)
        #expect(second.saves == 0)
        #expect(second.nextWake == processingStart.addingTimeInterval(60))
        #expect(stage.count == 1, "the second run of the same trigger spent an attempt")
        #expect(failures.count(for: id) == 1)

        clock.advance(by: 59)
        #expect(await queue.run().waiting == 1, "one second before the backoff ends")
        #expect(stage.count == 1)
        clock.advance(by: 1)
        let retried = await queue.run()
        #expect(retried.failures == 1)
        #expect(stage.count == 2)
        #expect(retried.nextRetry == clock.now.addingTimeInterval(10 * 60), "the second wait is 10 minutes")

        clock.advance(by: 10 * 60 - 1)
        #expect(await queue.run().waiting == 1)
        clock.advance(by: 1)
        let third = await queue.run()
        #expect(third.failed == 1)
        #expect(third.nextRetry == nil, "nothing left to retry on this device")
        #expect(stage.count == 3)
        #expect(clock.now.timeIntervalSince(processingStart) == 11 * 60)
        #expect(try store.row(id).stateRaw == "failed")
    }

    /// N9: a last attempt in the future (the clock was set back) retries at `now` plus the delay, and that time
    /// stays put in later runs instead of moving on.
    @Test func aLastAttemptInTheFutureRetriesAfterNowPlusTheDelay() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let failures = store.failures(deviceA)
        failures.fail(failures.begin(id, at: processingStart.addingTimeInterval(24 * hour)))
        let queue = store.queue(deviceA, failures: failures, clock: clock)

        let first = await queue.run()
        #expect(first.waiting == 1)
        #expect(first.nextRetry == processingStart.addingTimeInterval(60))
        clock.advance(by: 30)
        #expect(await queue.run().nextRetry == processingStart.addingTimeInterval(60), "the retry moved on")
        clock.advance(by: 30)
        #expect(await queue.run().done == 1)
        #expect(try store.row(id).stateRaw == "done")
    }

    // MARK: Stall watchdog (#97 point 3)

    /// A stage that never reports progress is cancelled when the watchdog fires: its attempt stays counted, the
    /// report has `timedOut`, and the next document of the same run is processed. The stage's late result is dropped.
    @Test func aStageWithoutProgressTimesOutAndTheRunGoesOn() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let stuckID = try store.insert(
            title: "Stuck", created: processingStart, device: deviceA, claimedAt: processingStart)
        let nextID = try store.insert(
            title: "Next", created: processingStart.addingTimeInterval(1), device: deviceA, claimedAt: processingStart)
        let stuck = Checkpoint()
        defer { stuck.release() }
        let stage = TestStage { call in if call == 1 { await stuck.pass() } }
        let watchdog = ManualDebounce()
        let failures = store.failures(deviceA)
        let queue = store.queue(deviceA, failures: failures, stage: stage, clock: clock, watchdog: watchdog)

        let finished = TestSignal()
        let run = Task {
            defer { finished.fire() }
            return await queue.run()
        }
        await stuck.reached()
        await watchdog.waitForStarts(1)
        watchdog.fire()
        // Without a watchdog the run never ends: let the stage go so the test fails instead of hanging.
        if !(await finished.wait(timeout: .seconds(30), "the run never ended: no watchdog")) { stuck.release() }
        let report = await run.value

        #expect(report.timedOut == 1)
        #expect(report.failures == 1, "a timeout is a failed attempt")
        #expect(report.done == 1, "the next document was not processed")
        #expect(report.nextRetry == processingStart.addingTimeInterval(60))
        #expect(failures.count(for: stuckID) == 1)
        #expect(try store.row(nextID).stateRaw == "done")
        // The stage returns late; nothing of it is written.
        stuck.release()
        await stage.processed.wait(for: 2)
        #expect(try store.row(stuckID).stateRaw == "pending")
        #expect(failures.count(for: stuckID) == 1)
    }

    /// Each progress report restarts the watchdog's sleep.
    @Test func progressRestartsTheWatchdog() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        try store.insert(device: deviceA, claimedAt: processingStart)
        let firstPage = Checkpoint()
        let secondPage = Checkpoint()
        defer {
            firstPage.release()
            secondPage.release()
        }
        let stage = ClosureStage { _, progress in
            await firstPage.pass()
            progress(1, 2)
            await secondPage.pass()
            return ProcessingResult(pageCount: 2)
        }
        let watchdog = ManualDebounce()
        let queue = store.queue(deviceA, stage: stage, clock: clock, watchdog: watchdog)

        let run = Task { await queue.run() }
        await firstPage.reached()
        await watchdog.waitForStarts(1)
        firstPage.release()
        await secondPage.reached()
        await watchdog.waitForStarts(2, "the progress did not restart the watchdog")
        #expect(watchdog.started == 2)
        watchdog.fire()
        #expect(await run.value.timedOut == 1)
    }

    // MARK: One job at a time (N1)

    /// After a timeout one abandoned stage may still be alive; a second timeout while the first has not returned
    /// ends the run as `stalled`, and the next run starts no stage until the first returned.
    @Test func aSecondTimeoutEndsTheRunStalledAndNoThirdStageStartsBeforeTheFirstReturned() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let ids = try (0..<3).map { index in
            try store.insert(
                title: "D\(index)", created: processingStart.addingTimeInterval(TimeInterval(index)), device: deviceA,
                claimedAt: processingStart)
        }
        let pages = (0..<2).map { _ in Checkpoint() }
        defer { for page in pages { page.release() } }
        let firstReturned = Mutex(false)
        let thirdSawFirstReturned = Mutex<Bool?>(nil)
        let stage = TestStage { call in
            switch call {
            case 1:
                await pages[0].pass()
                firstReturned.withLock { $0 = true }
            case 2:
                await pages[1].pass()
            default:
                thirdSawFirstReturned.withLock { $0 = firstReturned.withLock { $0 } }
            }
        }
        let watchdog = ManualDebounce()
        let waits = TestSignal()
        let queue = store.queue(
            deviceA, stage: stage, clock: clock, watchdog: watchdog, hooks: .init(waitsForStage: { waits.fire() }))

        let first = Task { await queue.run() }
        await pages[0].reached()
        await watchdog.waitForStarts(1)
        watchdog.fire()
        await pages[1].reached()
        #expect(waits.count == 0, "one abandoned stage does not block the next")
        await watchdog.waitForStarts(2)
        watchdog.fire()
        let stalled = await first.value
        #expect(stalled.timedOut == 2)
        #expect(stalled.stalled)
        #expect(stage.count == 2, "the run went on after its second timeout")
        #expect(try store.row(ids[2]).stateRaw == "pending")

        let second = Task { await queue.run() }
        await waits.wait(for: 1, "the next run did not wait for the abandoned stages")
        #expect(stage.count == 2, "a third stage started while two abandoned stages were alive")
        pages[0].release()
        let report = await second.value
        #expect(thirdSawFirstReturned.withLock { $0 } == true)
        #expect(report.done == 1)
        #expect(try store.row(ids[2]).stateRaw == "done")
    }

    /// After `interruptNow()` the next run waits for the cancelled stage before it starts its own, so two stages
    /// never stand at their pages at once.
    @Test func theNextRunWaitsForTheStageThatWasInterrupted() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let page = Checkpoint()
        defer { page.release() }
        let firstReturned = Mutex(false)
        let secondSawFirstReturned = Mutex<Bool?>(nil)
        let stage = TestStage { call in
            if call == 1 {
                await page.pass()
                firstReturned.withLock { $0 = true }
            } else {
                secondSawFirstReturned.withLock { $0 = firstReturned.withLock { $0 } }
            }
        }
        let waits = TestSignal()
        let queue = store.queue(deviceA, stage: stage, clock: clock, hooks: .init(waitsForStage: { waits.fire() }))

        let first = Task { await queue.run() }
        await page.reached()
        queue.interruptNow()
        #expect(await first.value.interrupted == 1)

        let second = Task { await queue.run() }
        await waits.wait(for: 1, "the next run did not wait for the interrupted stage")
        #expect(stage.count == 1)
        page.release()
        #expect(await second.value.done == 1)
        #expect(secondSawFirstReturned.withLock { $0 } == true, "two stages ran at once")
        #expect(try store.row(id).stateRaw == "done")
    }

    // MARK: Interruptions (#97 point 4)

    /// `interruptNow()` while the stage stands at its page: the counter is back where it was before the attempt
    /// (with its backoff), the run ends, the stage that returns later writes nothing, and the next run processes the
    /// document.
    @Test func anInterruptedAttemptIsGivenBackAndItsLateResultIsDropped() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let other = try store.insert(
            title: "Later", created: processingStart.addingTimeInterval(1), device: deviceA, claimedAt: processingStart)
        let failures = store.failures(deviceA)
        // One failed attempt before, whose backoff is over.
        failures.fail(failures.begin(id, at: processingStart.addingTimeInterval(-hour)))
        let before = failures.entry(for: id)
        let page = Checkpoint()
        defer { page.release() }
        let stage = TestStage { call in if call == 1 { await page.pass() } }
        let queue = store.queue(deviceA, failures: failures, stage: stage, clock: clock)

        let run = Task { await queue.run() }
        await page.reached()
        #expect(failures.count(for: id) == 2, "counted before the stage")
        queue.interruptNow()
        #expect(failures.entry(for: id) == before, "the refund is done when interruptNow() returns")
        let report = await run.value
        #expect(report.interrupted == 1)
        #expect(report.done == 0, "the run went on after the interruption")
        #expect(report.failures == 0)

        page.release()
        await stage.processed.wait(for: 1)
        #expect(try store.row(id).stateRaw == "pending", "the interrupted stage wrote its result")
        #expect(failures.entry(for: id) == before, "the late return touched the counter")

        let next = await queue.run()
        #expect(next.done == 2)
        #expect(try store.row(id).stateRaw == "done")
        #expect(try store.row(other).stateRaw == "done")
        #expect(failures.count(for: id) == 0)
    }

    /// Review B1 of #120: a pause that lands after the decision and before the stage starts (here in the claim
    /// write) finds no stage to interrupt. The run is cancelled first, as `ProcessingScheduler.pause()` does, so the
    /// queue sees it before it starts the stage: the stage never starts and the attempt is given back.
    @Test func aPauseBeforeTheStageStartsGivesTheAttemptBackAndStartsNoStage() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        // Another device's expired claim, so the queue writes a claim (a takeover) before the stage.
        let id = try store.insert(device: deviceB, claimedAt: processingStart.addingTimeInterval(-7 * hour))
        let failures = store.failures(deviceA)
        let page = Checkpoint()
        defer { page.release() }
        let stage = TestStage { _ in await page.pass() }
        let run = Mutex<Task<ProcessingReport, Never>?>(nil)
        let started = TestSignal()
        let interrupt = Mutex<(@Sendable () -> Void)?>(nil)
        let queue = store.queue(
            deviceA, failures: failures, stage: stage, clock: clock,
            hooks: .init(
                afterScan: { await started.wait() },
                beforeCheck: { kind in
                    guard kind == .claim else { return }
                    // What `pause()` does: cancel the run, then interrupt.
                    run.withLock { $0 }?.cancel()
                    interrupt.withLock { $0 }?()
                }))
        interrupt.withLock { $0 = { queue.interruptNow() } }
        let finished = TestSignal()
        let task = Task {
            defer { finished.fire() }
            return await queue.run()
        }
        run.withLock { $0 = task }
        started.fire()

        // Without the check the stage stands at its page and the run never ends: let it go so the test fails.
        if !(await finished.wait(timeout: .seconds(30), "the run waited for a stage started after the pause")) {
            page.release()
        }
        let report = await task.value
        #expect(stage.count == 0, "a stage started after the pause")
        #expect(failures.count(for: id) == 0, "the attempt stayed counted although the app paused")
        #expect(report.interrupted == 1)
        #expect(try store.row(id).deviceID == deviceA, "the claim write itself went through")

        // The next run is not blocked by the stage that never started, and processes the document.
        page.release()
        #expect(await queue.run().done == 1)
        #expect(try store.row(id).stateRaw == "done")
    }

    /// `interruptNow()` with no stage running changes nothing.
    @Test func anInterruptionWithoutAStageChangesNothing() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let failures = store.failures(deviceA)
        failures.fail(failures.begin(id, at: processingStart.addingTimeInterval(-hour)))
        let queue = store.queue(deviceA, failures: failures, clock: clock)

        queue.interruptNow()
        #expect(failures.count(for: id) == 1)
        #expect(await queue.run().done == 1)
    }
}
