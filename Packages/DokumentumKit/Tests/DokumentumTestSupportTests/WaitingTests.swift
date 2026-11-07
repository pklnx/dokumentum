import DokumentumTestSupport
import Foundation
import Testing

/// The waits of `Waiting.swift` (docs/development/index.md, "Waiting in tests"). When a helper is
/// broken, these tests fail at a safety net: they wait on `TestSignal`, never on a task that might
/// never end (`task.value` comes only after the signal that says it will end).
struct WaitingTests {
    /// Gives something that must not happen the time to happen. It only keeps a mutation from going
    /// unnoticed: a slow machine can miss it, but can never fail a correct helper with it.
    // allow-wait: a negative check has no signal to wait for
    private func negativeCheck() async {
        await TestSupport.safetyNet(.milliseconds(100), interval: .milliseconds(10))
    }

    // MARK: TestSignal

    @Test func aSignalThatAlreadyFiredIsNotWaitedFor() async {
        let signal = TestSignal()
        signal.fire()
        signal.fire()
        #expect(await signal.wait(for: 2))
        #expect(signal.count == 2)
    }

    @Test func aSignalWakesItsWaiter() async {
        let signal = TestSignal()
        let waiter = Task { await signal.wait(for: 1) }
        signal.fire()
        #expect(await waiter.value)
    }

    /// A waiter stays until the signal fired as often as it asked for.
    @Test func aSignalWakesItsWaiterOnlyAtItsCount() async {
        let signal = TestSignal()
        let woken = TestSignal()
        let waiter = Task {
            let reached = await signal.wait(for: 2)
            woken.fire()
            return reached
        }
        await negativeCheck()  // The waiter is waiting by now, so the first `fire()` can reach it.
        signal.fire()
        await negativeCheck()
        #expect(woken.count == 0, "one of two is not enough")
        signal.fire()
        #expect(await woken.wait())
        #expect(await waiter.value)
    }

    /// A `fire()` reaches everyone who waits for that count, not just one of them.
    @Test func aSignalWakesAllItsWaiters() async {
        let signal = TestSignal()
        let reached = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask { await signal.wait() }
            }
            await negativeCheck()  // Both are waiting by now, so one `fire()` has to reach both.
            signal.fire()
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(reached == [true, true])
    }

    /// The safety net ends a wait whose signal never comes, with an issue and `false`. The result is
    /// checked outside `withKnownIssue`: inside, its failure would count as the known issue.
    @Test func aSignalThatNeverComesTimesOut() async {
        let signal = TestSignal()
        var reached = true
        await withKnownIssue {
            reached = await signal.wait(timeout: .milliseconds(100))
        }
        #expect(!reached)
    }

    @Test @MainActor func aCountingSignalFiresForEveryElement() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let (signal, task) = TestSignal.counting(stream)
        defer { task.cancel() }
        continuation.yield()
        continuation.yield()
        #expect(await signal.wait(for: 2))
        #expect(signal.count == 2)
    }

    // MARK: The safety net

    @Test func aCancelledSafetyNetEndsEarly() async {
        let ended = TestSignal()
        let net = Task {
            await TestSupport.safetyNet(.seconds(3600))
            ended.fire()
        }
        net.cancel()
        #expect(await ended.wait())
    }

    // MARK: Checkpoint

    /// The handshake. With a `release()` that does nothing, this fails at the safety net of
    /// `passed.wait()` and does not hang.
    @Test func aCheckpointHoldsTheHookUntilReleased() async throws {
        let checkpoint = Checkpoint()
        defer { checkpoint.release() }
        let passed = TestSignal()
        Task {
            await checkpoint.pass()
            passed.fire()
        }
        #expect(await checkpoint.reached())
        await negativeCheck()
        #expect(passed.count == 0, "still held")
        checkpoint.release()
        try #require(await passed.wait())

        // Once released, a later pass goes straight through.
        Task {
            await checkpoint.pass()
            passed.fire()
        }
        #expect(await passed.wait(for: 2))
    }

    @Test func aBlockingCheckpointHoldsItsThread() async {
        let checkpoint = Checkpoint()
        defer { checkpoint.release() }
        let passed = TestSignal()
        let thread = Thread {
            checkpoint.passBlocking()
            passed.fire()
        }
        thread.start()
        #expect(await checkpoint.reached())
        await negativeCheck()
        #expect(passed.count == 0, "still held")
        checkpoint.release()
        #expect(await passed.wait())
    }

    @Test func aCheckpointThatIsNeverReachedTimesOut() async {
        let checkpoint = Checkpoint()
        var reached = true
        await withKnownIssue {
            reached = await checkpoint.reached(timeout: .milliseconds(100))
        }
        #expect(!reached)
    }

    /// Suspends until cancelled, built on `Checkpoint`.
    @Test func waitForCancellationEndsWithItsTask() async {
        let started = TestSignal()
        let ended = TestSignal()
        let task = Task {
            started.fire()
            await TestSupport.waitForCancellation()
            ended.fire()
        }
        #expect(await started.wait())
        await negativeCheck()
        #expect(ended.count == 0, "still suspended")
        task.cancel()
        #expect(await ended.wait())
    }

    // MARK: ManualDebounce

    /// `fire()` ends the running sleep; a cancelled one throws, as `Task.sleep` does.
    @Test func manualDebounceEndsWhenFiredOrCancelled() async throws {
        let debounce = ManualDebounce()
        let ended = TestSignal()
        let fired = Task {
            defer { ended.fire() }
            try await debounce.sleep(.seconds(3600))
        }
        await debounce.waitForStarts(1)
        #expect(debounce.isWaiting)
        #expect(debounce.started == 1)
        await negativeCheck()
        #expect(ended.count == 0, "only `fire()` ends it, not its duration")
        debounce.fire()
        try #require(await ended.wait())
        try await fired.value
        #expect(!debounce.isWaiting)

        let cancelled = Task {
            defer { ended.fire() }
            try await debounce.sleep(.seconds(3600))
        }
        await debounce.waitForStarts(2)
        cancelled.cancel()
        try #require(await ended.wait(for: 2))
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!debounce.isWaiting)
    }

    @Test func aDebounceThatNeverStartsTimesOut() async {
        let debounce = ManualDebounce()
        var started = true
        await withKnownIssue {
            started = await debounce.waitForStarts(1, timeout: .milliseconds(100))
        }
        #expect(!started)
    }

    // MARK: waitUntil

    @Test func waitUntilReturnsOnceTheConditionHolds() async throws {
        let signal = TestSignal()
        signal.fire()
        let reached = try await TestSupport.waitUntil { signal.count == 1 }
        #expect(reached)
        var never = true
        await withKnownIssue {
            never = try await TestSupport.waitUntil(timeout: .milliseconds(100)) { false }
        }
        #expect(!never)
    }

    /// A main-actor test checks main-actor state: the condition runs on the caller's actor, and the waits let
    /// the main actor run what sets it.
    @Test @MainActor func waitUntilChecksMainActorState() async throws {
        let state = MainActorFlag()
        Task { @MainActor in state.isSet = true }
        let reached = try await TestSupport.waitUntil { state.isSet }
        #expect(reached)
    }

    /// The overload for a condition that needs an actor's turn.
    @Test func waitUntilChecksAnAsynchronousCondition() async throws {
        let counter = Counter()
        let reached = try await TestSupport.waitUntil(asynchronously: { await counter.next() >= 3 })
        #expect(reached)
        var never = true
        await withKnownIssue {
            never = try await TestSupport.waitUntil(timeout: .milliseconds(100), asynchronously: { false })
        }
        #expect(!never)
    }
}

/// The safety net while the waiter's actor is blocked. Serialized, because each test blocks a thread
/// of the cooperative pool for its whole run, and together they could use up a small pool.
@Suite(.serialized) struct BlockedActorTests {
    /// The safety net takes its rounds on the waiter's actor: while that actor is blocked, the
    /// net stands still, and a net without an actor with twice the budget runs out first.
    @Test func aBlockedActorHoldsItsSafetyNet() async {
        let busy = BusyActor()
        let blocked = Checkpoint()
        defer { blocked.release() }
        Task { await busy.block(blocked) }
        #expect(await blocked.reached())

        let ranOut = TestSignal()
        Task.detached {
            await TestSupport.safetyNet(.milliseconds(100), interval: .milliseconds(10), on: busy)
            ranOut.fire()
        }
        // The free net gets the same treatment (detached, no actor) and twice the budget, so a
        // loaded machine slows both alike; we wait for it to finish, not for a time.
        let free = Task.detached {
            await TestSupport.safetyNet(.milliseconds(200), interval: .milliseconds(10))
        }
        await free.value
        #expect(ranOut.count == 0, "the net ran out while its actor was blocked")

        blocked.release()
        #expect(await ranOut.wait(), "it runs out once the actor is free again")
    }

    /// The budget of the waits below, against the longer free net that runs while their actor is
    /// blocked. A wait that does not pass on its actor runs out during the free net, so the event
    /// that comes after it is too late: the wait reports `false` with an issue.
    private static let budget = Duration.milliseconds(300)

    private func aWaitStandsStillWithItsActor(
        wait: @escaping @Sendable (isolated BusyActor) async -> Bool,
        event: @escaping @Sendable () async -> Void
    ) async throws {
        let busy = BusyActor()
        let blocked = Checkpoint()
        defer { blocked.release() }
        let ended = TestSignal()
        let waiter = Task {
            let reached = await busy.blockOnceSuspended(blocked, during: wait)
            ended.fire()
            return reached
        }
        #expect(await blocked.reached())

        // allow-wait: a negative check, the wait must not run out during this
        await TestSupport.safetyNet(Self.budget * 3)
        await event()
        blocked.release()
        try #require(await ended.wait())
        #expect(await waiter.value)
    }

    @Test func aSignalWaitStandsStillWithItsActor() async throws {
        let signal = TestSignal()
        try await aWaitStandsStillWithItsActor(
            wait: { _ in await signal.wait(timeout: Self.budget) },
            event: { signal.fire() })
    }

    @Test func aCheckpointWaitStandsStillWithItsActor() async throws {
        let checkpoint = Checkpoint()
        defer { checkpoint.release() }
        try await aWaitStandsStillWithItsActor(
            wait: { _ in await checkpoint.reached(timeout: Self.budget) },
            event: {
                Task { await checkpoint.pass() }
                await checkpoint.reached()
            })
    }

    @Test func aDebounceWaitStandsStillWithItsActor() async throws {
        let debounce = ManualDebounce()
        defer { debounce.fire() }
        try await aWaitStandsStillWithItsActor(
            wait: { _ in await debounce.waitForStarts(1, timeout: Self.budget) },
            event: {
                Task { _ = try? await debounce.sleep(.seconds(3600)) }
                await debounce.waitForStarts(1)
            })
    }
}

/// An actor whose executor a test blocks (`BlockedActorTests`).
private actor BusyActor {
    /// Blocks this actor's thread until `checkpoint` is released.
    func block(_ checkpoint: Checkpoint) {
        checkpoint.passBlocking()
    }

    /// Runs `wait` on this actor. The actor is blocked from the moment `wait` suspends: the task is
    /// this actor's next job, so the wait's safety net cannot take a turn before it.
    func blockOnceSuspended(
        _ checkpoint: Checkpoint, during wait: @Sendable (isolated BusyActor) async -> Bool
    ) async -> Bool {
        Task { block(checkpoint) }
        return await wait(self)
    }
}

/// State that only an asynchronous condition can read (`waitUntilChecksAnAsynchronousCondition`).
private actor Counter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

/// State that is not `Sendable`, owned by a main-actor test.
private final class MainActorFlag {
    var isSet = false
}
