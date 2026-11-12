import DokumentumKit
import Foundation
import Synchronization

// The pieces of one stage run in `ProcessingQueue` (#97 points 3 and 4, N1 in the plan of #6): the outcome that the
// stage, the stall watchdog and `interruptNow()` race for, the watchdog, and the record of stages the queue let go.

/// How one stage run ended for the queue.
enum StageOutcome: Sendable {
    case returned(ProcessingResult)
    /// The classification stage answered (#8).
    case suggested(ClassificationSuggestion)
    case threw(any Error)
    /// No progress for the stall timeout: the stage was cancelled and left behind.
    case timedOut
    /// `interruptNow()`: the stage was cancelled and left behind, its attempt given back.
    case interrupted
}

/// A value set once, by whoever comes first; later values are dropped. One waiter.
final class FirstOutcome: Sendable {
    private struct State {
        var value: StageOutcome?
        var waiter: CheckedContinuation<StageOutcome, Never>?
    }

    private let state = Mutex(State())

    /// Sets the outcome unless one is set already.
    func resolve(_ value: StageOutcome) {
        let waiter = state.withLock { state -> CheckedContinuation<StageOutcome, Never>? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    var value: StageOutcome {
        get async {
            await withCheckedContinuation { continuation in
                let value = state.withLock { state -> StageOutcome? in
                    if state.value == nil { state.waiter = continuation }
                    return state.value
                }
                if let value { continuation.resume(returning: value) }
            }
        }
    }
}

/// Fires `onStall` when `kick()` was not called for `timeout`. Each `kick()` restarts the sleep (cancelling the
/// one before); `stop()` ends it for good. The sleep is injected: the suspending clock in the app, so time the device
/// sleeps is never a stall; `ManualDebounce` in tests.
final class StallWatchdog: Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct State {
        var timer: Task<Void, Never>?
        var stopped = false
    }

    private let sleep: Sleep
    private let timeout: Duration
    private let onStall: @Sendable () -> Void
    private let state = Mutex(State())

    init(timeout: Duration, sleep: @escaping Sleep, onStall: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.sleep = sleep
        self.onStall = onStall
    }

    func kick() {
        let sleep = sleep
        let timeout = timeout
        let onStall = onStall
        state.withLock { state in
            guard !state.stopped else { return }
            state.timer?.cancel()
            state.timer = Task {
                do {
                    try await sleep(timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                onStall()
            }
        }
    }

    func stop() {
        let timer = state.withLock { state in
            state.stopped = true
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }
}

/// The stage the queue waits for, and the stages it let go that have not returned yet (N1). One job at a time,
/// across both kinds of stage (the text stage and the classification stage, #8 T6): before a stage starts, every stage cancelled by `interruptNow()` has returned (it stops after its current
/// page), and at most one stage abandoned after a timeout is still alive. A stage that never returns therefore
/// blocks the next stage, never more than one extra job runs, and the run that would leave two abandoned stages ends
/// as `stalled`.
final class StageTracker: Sendable {
    enum Abandoned: Equatable, Sendable {
        case interrupted, timedOut
    }

    struct Current: Sendable {
        let id: UInt64
        let attempt: ProcessingFailures.Attempt
        /// The counter the attempt was counted in (the text step's or the classification step's, #8): a refund
        /// goes there.
        let counter: ProcessingFailures
        let outcome: FirstOutcome
        var task: Task<Void, Never>?
        var ended = false
    }

    private struct State {
        var nextID: UInt64 = 0
        var current: Current?
        /// Let go and not returned yet.
        var abandoned: [UInt64: Abandoned] = [:]
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var cancelledWaiters: Set<UInt64> = []
        var nextWaiter: UInt64 = 0

        var isStartable: Bool {
            !abandoned.values.contains(.interrupted) && abandoned.values.count(where: { $0 == .timedOut }) <= 1
        }
    }

    private let state = Mutex(State())
    /// Tests only: called each time a run starts to wait for a stage that was let go.
    private let onWait: (@Sendable () -> Void)?

    init(onWait: (@Sendable () -> Void)? = nil) {
        self.onWait = onWait
    }

    /// The stages let go after a timeout that are still alive.
    var timedOutAlive: Int {
        state.withLock { $0.abandoned.values.count(where: { $0 == .timedOut }) }
    }

    /// The stages let go (interrupted or timed out) that are still alive. For tests.
    var abandonedAlive: Int {
        state.withLock { $0.abandoned.count }
    }

    /// Waits until a stage may start. `false` when the waiting task was cancelled (the run ends).
    func waitUntilStartable() async -> Bool {
        while !state.withLock({ $0.isStartable }) {
            if Task.isCancelled { return false }
            let id = state.withLock { state in
                state.nextWaiter += 1
                return state.nextWaiter
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let waitingFor = state.withLock { state -> (interrupted: Int, timedOut: Int)? in
                        if state.isStartable || state.cancelledWaiters.remove(id) != nil { return nil }
                        state.waiters[id] = continuation
                        return (
                            state.abandoned.values.count(where: { $0 == .interrupted }),
                            state.abandoned.values.count(where: { $0 == .timedOut })
                        )
                    }
                    guard let waitingFor else {
                        continuation.resume()
                        return
                    }
                    // Visible in the field: a stage that ignores its cancellation and never returns blocks every
                    // later run until the app is relaunched (review N3 of #120).
                    Log.processing.notice(
                        """
                        Processing waits for stages that were let go: interrupted \
                        \(waitingFor.interrupted, privacy: .public), timed out \(waitingFor.timedOut, privacy: .public)
                        """)
                    onWait?()
                }
            } onCancel: {
                let continuation = state.withLock { state in
                    guard let continuation = state.waiters.removeValue(forKey: id) else {
                        state.cancelledWaiters.insert(id)
                        return nil as CheckedContinuation<Void, Never>?
                    }
                    return continuation
                }
                continuation?.resume()
            }
        }
        return !Task.isCancelled
    }

    /// The stage the queue is about to start.
    func begin(attempt: ProcessingFailures.Attempt, counter: ProcessingFailures, outcome: FirstOutcome) -> UInt64 {
        state.withLock { state in
            state.nextID += 1
            state.current = Current(id: state.nextID, attempt: attempt, counter: counter, outcome: outcome)
            return state.nextID
        }
    }

    /// The stage's task, once it exists. A stage interrupted before this is cancelled at once.
    func attach(_ task: Task<Void, Never>, to id: UInt64) {
        let interrupted = state.withLock { state -> Bool in
            guard state.current?.id == id else { return true }
            state.current?.task = task
            return false
        }
        if interrupted { task.cancel() }
    }

    /// The stage's task ended (returned, threw or noticed its cancellation).
    func ended(_ id: UInt64) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if state.current?.id == id { state.current?.ended = true }
            guard state.abandoned.removeValue(forKey: id) != nil else { return [] }
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// The queue is done with the stage it waited for (returned or threw).
    func finish(_ id: UInt64) {
        state.withLock { state in
            if state.current?.id == id { state.current = nil }
        }
    }

    /// The run was cancelled after `begin` and before the stage's task was created: the stage never starts. Returns
    /// the stage if it was still current (the caller gives its attempt back); if `interruptCurrent()` took it first,
    /// its mark as let go is removed, since no task will ever end it.
    func cancelBeforeStart(_ id: UInt64) -> Current? {
        let (current, waiters) = state.withLock { state -> (Current?, [CheckedContinuation<Void, Never>]) in
            if let current = state.current, current.id == id {
                state.current = nil
                return (current, [])
            }
            guard state.abandoned.removeValue(forKey: id) != nil else { return (nil, []) }
            defer { state.waiters = [:] }
            return (nil, Array(state.waiters.values))
        }
        for waiter in waiters { waiter.resume() }
        return current
    }

    /// The watchdog fired: the stage is let go; it counts as alive until it ends.
    func abandonAfterTimeout(_ id: UInt64) {
        state.withLock { state in
            guard let current = state.current, current.id == id else { return }
            state.current = nil
            if !current.ended { state.abandoned[id] = .timedOut }
        }
    }

    /// `interruptNow()`: lets the current stage go and returns it, so the caller refunds its attempt and cancels it.
    func interruptCurrent() -> Current? {
        state.withLock { state in
            guard let current = state.current else { return nil }
            state.current = nil
            if !current.ended { state.abandoned[current.id] = .interrupted }
            return current
        }
    }
}
