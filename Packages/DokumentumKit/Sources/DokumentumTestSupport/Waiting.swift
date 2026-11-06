import Dispatch
import Foundation
import Synchronization
import Testing

// The tools a test waits with (docs/development/index.md, "Waiting in tests"). Tests never wait
// for time: they wait for a signal, and a scaled timeout is only the safety net that ends a test
// whose signal never comes. `scripts/check-test-waits.py` flags every `Task.sleep`, `Task.yield()`
// and fixed delay in the tests; the few that are allowed carry an `allow-wait:` comment.
//
// Why not the clock: under parallel tests on a busy runner, every `Task.sleep` needs a thread of
// the cooperative pool to wake up. When text recognition and PDF rendering fill the pool, every
// sleep in the process stalls, for a minute and more on the predecessor's iOS CI runner. A wait
// that compares the clock with a deadline then sees the deadline passed when it wakes up, while
// the work it waits for has not had its turn yet (the flaky store-change tests of
// pklnx/document-archive#92 and #93). The waits here count rounds instead: a stall costs one
// round, not the whole budget.

extension TestSupport {
    /// The safety net of every wait: returns after `timeout` (scaled) worth of `interval` rounds,
    /// or when the task is cancelled. It counts rounds, not the clock, so a process-wide stall
    /// uses up one round, not the budget.
    ///
    /// Every round also takes a turn on `actor`, the waiter's actor: the work a waiter on the
    /// main actor waits for usually needs the main actor too. While that actor is blocked or busy,
    /// the net stands still with it instead of running out.
    public static func safetyNet(
        _ timeout: Duration, interval: Duration = .milliseconds(50),
        on actor: (any Actor)? = nil
    ) async {
        for _ in 0..<rounds(timeout, interval: interval) {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: interval)  // allow-wait: the safety net itself
            if let actor { await takeTurn(on: actor) }
        }
    }

    /// Returns once `actor` ran this (empty) job: after the jobs queued before it.
    private static func takeTurn(on actor: isolated any Actor) async {}

    /// How many rounds of `interval` make `timeout`, scaled.
    public static func rounds(_ timeout: Duration, interval: Duration) -> Int {
        max(1, Int((scaled(timeout) / interval).rounded(.up)))
    }

    /// Checks `condition` until it holds; records an issue and returns `false` when it still does
    /// not hold after `timeout` (scaled, counted in rounds like `safetyNet`). Only for state that
    /// has no signal to wait for; prefer `TestSignal`, `Checkpoint` or `ManualDebounce`.
    @discardableResult
    public static func waitUntil(
        _ comment: Comment? = nil, timeout: Duration = .seconds(30),
        interval: Duration = .milliseconds(20),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () throws -> Bool
    ) async throws -> Bool {
        for _ in 0..<rounds(timeout, interval: interval) {
            if try condition() { return true }
            try await Task.sleep(for: interval)  // allow-wait: the one poll, for state without a signal
        }
        if try condition() { return true }
        Issue.record(comment ?? "Condition not reached within \(scaled(timeout))", sourceLocation: sourceLocation)
        return false
    }

    /// `waitUntil` for a condition that is checked asynchronously (an actor's state).
    @discardableResult
    public static func waitUntil(
        _ comment: Comment? = nil, timeout: Duration = .seconds(30),
        interval: Duration = .milliseconds(20),
        sourceLocation: SourceLocation = #_sourceLocation,
        asynchronously condition: () async throws -> Bool
    ) async throws -> Bool {
        for _ in 0..<rounds(timeout, interval: interval) {
            if try await condition() { return true }
            try await Task.sleep(for: interval)  // allow-wait: the one poll, for state without a signal
        }
        if try await condition() { return true }
        Issue.record(comment ?? "Condition not reached within \(scaled(timeout))", sourceLocation: sourceLocation)
        return false
    }

    /// Suspends until the task is cancelled; for a body that must keep running until its test
    /// stops it.
    public static func waitForCancellation() async {
        let gate = Checkpoint()
        await withTaskCancellationHandler {
            await gate.pass()
        } onCancel: {
            gate.release()
        }
    }
}

/// Something a test waits for. A hook, a stub or a subscriber calls `fire()`; the test awaits
/// `wait(for:)`, which returns as soon as `fire()` was called that often, at once if it already
/// was. The timeout is the safety net only.
///
/// ```swift
/// let analyzed = TestSignal()
/// environment.someHook = { _ in analyzed.fire() }
/// … start the work …
/// await analyzed.wait()
/// ```
public final class TestSignal: Sendable {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var count = 0
        var waiters: [UUID: Waiter] = [:]
        var expired: Set<UUID> = []
    }

    private let state = Mutex(State())

    public init() {}

    /// How often `fire()` was called.
    public var count: Int { state.withLock { $0.count } }

    public func fire() {
        let ready = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            state.count += 1
            let reached = state.waiters.filter { $0.value.count <= state.count }
            for id in reached.keys { state.waiters[id] = nil }
            return reached.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume(returning: true) }
    }

    /// Waits until `fire()` was called `count` times in all. Records an issue and returns `false`
    /// when that has not happened within `timeout` (scaled, see `TestSupport.safetyNet`).
    /// The safety net takes its rounds on the waiter's actor too (`TestSupport.safetyNet`).
    @discardableResult
    public func wait(
        for count: Int = 1, timeout: Duration = .seconds(30), _ comment: Comment? = nil,
        isolation: isolated (any Actor)? = #isolation,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let id = UUID()
        let watchdog = Task.detached { [self] in
            await TestSupport.safetyNet(timeout, on: isolation)
            guard !Task.isCancelled else { return }
            expire(id)
        }
        defer { watchdog.cancel() }
        let reached = await withCheckedContinuation { continuation in
            let answer = state.withLock { state -> Bool? in
                if state.count >= count { return true }
                if state.expired.remove(id) != nil { return false }
                state.waiters[id] = Waiter(count: count, continuation: continuation)
                return nil
            }
            if let answer { continuation.resume(returning: answer) }
        }
        if !reached {
            Issue.record(
                comment ?? "Signalled \(self.count) of \(count) times within \(TestSupport.scaled(timeout))",
                sourceLocation: sourceLocation)
        }
        return reached
    }

    private func expire(_ id: UUID) {
        let waiter = state.withLock { state -> Waiter? in
            guard let waiter = state.waiters.removeValue(forKey: id) else {
                state.expired.insert(id)
                return nil
            }
            return waiter
        }
        waiter?.continuation.resume(returning: false)
    }

    /// A signal that fires once for every element of `stream`. The subscriber runs on the main
    /// actor, so it never needs the cooperative thread pool. Cancel the task at the end of the test.
    @MainActor
    public static func counting(_ stream: AsyncStream<Void>) -> (TestSignal, Task<Void, Never>) {
        let signal = TestSignal()
        let task = Task { @MainActor in
            for await _ in stream { signal.fire() }
        }
        return (signal, task)
    }
}

/// A handshake with a hook: the hook stops at `pass()` until the test lets it go. The test
/// awaits `reached()`, does what must happen at that point (stop the run, change the input), then
/// calls `release()`. Once released, every later `pass()` goes straight through. Release in a
/// `defer`, so a failing test does not leave the hook waiting.
///
/// ```swift
/// let recognition = Checkpoint()
/// environment.someCheckpoint = { _ in await recognition.pass() }
/// let run = Task { await work(environment) }
/// await recognition.reached()
/// run.cancel()
/// recognition.release()
/// ```
public final class Checkpoint: Sendable {
    private struct State {
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var blocked: [DispatchSemaphore] = []
    }

    private let arrivals = TestSignal()
    private let state = Mutex(State())

    public init() {}

    /// For the hook: stops until `release()`.
    public func pass() async {
        arrivals.fire()
        await withCheckedContinuation { continuation in
            let released = state.withLock { state in
                if !state.released { state.waiting.append(continuation) }
                return state.released
            }
            if released { continuation.resume() }
        }
    }

    /// `pass()` for a synchronous hook (it blocks its thread, which runs off the main actor).
    public func passBlocking() {
        arrivals.fire()
        let semaphore = DispatchSemaphore(value: 0)
        let released = state.withLock { state in
            if !state.released { state.blocked.append(semaphore) }
            return state.released
        }
        if !released { semaphore.wait() }
    }

    /// For the test: waits until the hook is at `pass()`.
    @discardableResult
    public func reached(
        timeout: Duration = .seconds(60), _ comment: Comment? = nil,
        isolation: isolated (any Actor)? = #isolation,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await arrivals.wait(
            timeout: timeout, comment ?? "The hook was not reached", isolation: isolation,
            sourceLocation: sourceLocation)
    }

    /// Lets every waiting and every later `pass()` go on.
    public func release() {
        let (waiting, blocked) = state.withLock { state in
            state.released = true
            defer {
                state.waiting = []
                state.blocked = []
            }
            return (state.waiting, state.blocked)
        }
        for continuation in waiting { continuation.resume() }
        for semaphore in blocked { semaphore.signal() }
    }
}

/// A debounce whose quiet period ends when the test says so: the code under test sleeps with
/// `debounce.sleep`. Each debounced event starts a sleep (`started` counts them, so a test waits
/// for the events it expects with `waitForStarts`); a new event cancels the running sleep, as the
/// real timer would be restarted. `fire()` ends the sleep that is running, and the code under test
/// goes on.
///
/// ```swift
/// let debounce = ManualDebounce()
/// let observer = SomeObserver(sleep: debounce.sleep)
/// … cause two changes …
/// await debounce.waitForStarts(2)
/// debounce.fire()                   // the quiet period is over
/// ```
public final class ManualDebounce: Sendable {
    /// What the code under test sleeps with, in place of `Task.sleep(for:)`.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct State {
        var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
        var cancelled: Set<Int> = []
        var next = 0
    }

    private let starts = TestSignal()
    private let state = Mutex(State())

    public init() {}

    /// What the code under test sleeps with.
    public var sleep: Sleep {
        { [self] _ in try await wait() }
    }

    /// How many sleeps were started.
    public var started: Int { starts.count }

    /// Whether a sleep is running, i.e. something would follow `fire()`.
    public var isWaiting: Bool { state.withLock { !$0.waiting.isEmpty } }

    /// Waits until `count` sleeps were started in all.
    @discardableResult
    public func waitForStarts(
        _ count: Int, timeout: Duration = .seconds(60), _ comment: Comment? = nil,
        isolation: isolated (any Actor)? = #isolation,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await starts.wait(
            for: count, timeout: timeout, comment ?? "\(count) sleeps were not started",
            isolation: isolation, sourceLocation: sourceLocation)
    }

    /// Ends the running sleep: the quiet period is over.
    public func fire() {
        let waiting = state.withLock { state in
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    private func wait() async throws {
        let id = state.withLock { state in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return true }
                    state.waiting[id] = continuation
                    return false
                }
                // Counted once the sleep can be fired, so a test that saw it start can end it.
                starts.fire()
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                guard let continuation = state.waiting.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return nil as CheckedContinuation<Void, any Error>?
                }
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
