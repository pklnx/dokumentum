import DokumentumKit
import DokumentumTestSupport
import Foundation
import Synchronization
import Testing

@testable import DokumentumCore

/// This device's attempt counter (#97 points 2 and 4, N2 in the plan of #6): its stored form, the attempt states,
/// and the two callers (the queue and `interruptNow()` from another thread) behind one lock.
struct ProcessingFailuresTests {
    static let start = Date(timeIntervalSinceReferenceDate: 830_000_000)

    /// A counter in a defaults suite of its own, removed after `body`.
    private func withFailures(
        whileLocked: (@Sendable (ProcessingFailures.Operation) -> Void)? = nil,
        _ body: (ProcessingFailures, UserDefaults) async throws -> Void
    ) async throws {
        let suite = "DokumentumTests-Failures-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        try await body(ProcessingFailures(defaultsSuite: suite, whileLocked: whileLocked), defaults)
    }

    @Test func stepThreesFormReadsAsAttemptsWithoutATime() async throws {
        try await withFailures { failures, defaults in
            let id = UUID()
            defaults.set([id.uuidString: 2], forKey: ProcessingFailures.defaultsKey)
            #expect(failures.entry(for: id) == .init(attempts: 2, lastAttemptAt: nil))
            #expect(failures.backoff(for: id, now: Self.start).retryNotBefore == nil, "no time, no backoff")
            let attempt = failures.begin(id, at: Self.start)
            #expect(attempt.number == 3)
            #expect(failures.entry(for: id) == .init(attempts: 3, lastAttemptAt: Self.start))
        }
    }

    @Test func aSuccessRemovesTheCounterAndAFailureKeepsItWithItsStart() async throws {
        try await withFailures { failures, _ in
            let id = UUID()
            let first = failures.begin(id, at: Self.start)
            #expect(failures.fail(first))
            #expect(failures.entry(for: id) == .init(attempts: 1, lastAttemptAt: Self.start))
            #expect(failures.backoff(for: id, now: Self.start).retryNotBefore == Self.start.addingTimeInterval(60))
            let second = failures.begin(id, at: Self.start.addingTimeInterval(60))
            #expect(second.number == 2)
            #expect(failures.succeed(second))
            #expect(failures.entry(for: id) == nil)
            #expect(failures.documents.isEmpty)
        }
    }

    /// A refund puts back the counter and the start of the attempt before, so no backoff comes from it.
    @Test func aRefundGivesBackTheCountAndTheBackoff() async throws {
        try await withFailures { failures, _ in
            let id = UUID()
            #expect(failures.refund(failures.begin(id, at: Self.start)))
            #expect(failures.entry(for: id) == nil, "a first attempt given back leaves no key")
            failures.fail(failures.begin(id, at: Self.start))
            let later = Self.start.addingTimeInterval(120)
            #expect(failures.refund(failures.begin(id, at: later)))
            #expect(failures.entry(for: id) == .init(attempts: 1, lastAttemptAt: Self.start))
        }
    }

    /// N2: a refund only while the attempt runs. After `fail` or `succeed` it changes nothing, also when a newer
    /// attempt of the same document runs.
    @Test func aRefundAfterTheAttemptFinishedChangesNothing() async throws {
        try await withFailures { failures, _ in
            let id = UUID()
            let failed = failures.begin(id, at: Self.start)
            failures.fail(failed)
            #expect(!failures.refund(failed))
            #expect(failures.entry(for: id) == .init(attempts: 1, lastAttemptAt: Self.start))

            let succeeded = failures.begin(id, at: Self.start.addingTimeInterval(60))
            failures.succeed(succeeded)
            let next = failures.begin(id, at: Self.start.addingTimeInterval(120))
            #expect(!failures.refund(succeeded), "a late interruption of the finished attempt")
            #expect(failures.count(for: id) == 1, "the finished attempt's refund took the running one's count")
            #expect(failures.refund(next))
            #expect(!failures.succeed(next), "an interrupted attempt does not succeed afterwards")
            #expect(failures.count(for: id) == 0)
        }
    }

    /// N2: `interruptNow()`'s refund from another thread while the queue writes the dictionary (begin, succeed,
    /// remove, forget), in both orders. The one lock serializes them, so no update is lost.
    @Test(arguments: [ProcessingFailures.Operation.begin, .succeed, .forget])
    func aRefundFromAnotherThreadDuringAQueueWriteLosesNothing(operation: ProcessingFailures.Operation) async throws {
        for refundFirst in [false, true] {
            let paused = Checkpoint()
            defer { paused.release() }
            // The first operation stops inside the lock, between its read and its write; the other one is started
            // meanwhile and has to wait for the lock.
            let pauseOn: ProcessingFailures.Operation = refundFirst ? .refund : operation
            let armed = Mutex(false)
            let hook: @Sendable (ProcessingFailures.Operation) -> Void = { current in
                let pause = armed.withLock { armed in
                    defer { if current == pauseOn { armed = false } }
                    return armed && current == pauseOn
                }
                if pause { paused.passBlocking() }
            }
            try await withFailures(whileLocked: hook) { failures, _ in
                let interrupted = UUID()
                let other = UUID()
                // `other` has a failed attempt (for `forget`) or a running one (for `succeed`).
                let otherAttempt = failures.begin(other, at: Self.start)
                if operation != .succeed { failures.fail(otherAttempt) }
                let running = failures.begin(interrupted, at: Self.start)
                armed.withLock { $0 = true }

                let queueWrite: @Sendable () -> Void = {
                    switch operation {
                    case .begin: _ = failures.begin(other, at: Self.start.addingTimeInterval(60))
                    case .succeed: failures.succeed(otherAttempt)
                    default: failures.forget([other])
                    }
                }
                let refund: @Sendable () -> Void = { failures.refund(running) }
                let (first, second) = refundFirst ? (refund, queueWrite) : (queueWrite, refund)
                // Each on a thread of its own: the first blocks its thread inside the lock, the second blocks on
                // the lock. On the cooperative pool, the three cases of this test held all three threads of a
                // 3-CPU runner there, and nothing was left to run the `release()` below (#164).
                let firstDone = Task { await TestSupport.onOwnThread(first) }
                await paused.reached()
                let secondDone = Task { await TestSupport.onOwnThread(second) }
                paused.release()
                await firstDone.value
                await secondDone.value

                #expect(failures.entry(for: interrupted) == nil, "\(operation), refund first \(refundFirst)")
                let expected = operation == .begin ? 2 : 0
                #expect(failures.count(for: other) == expected, "\(operation), refund first \(refundFirst)")
            }
        }
    }

    /// N9: a stored start in the future (the clock was set back) is moved to now, so the retry stays put.
    @Test func aStartInTheFutureIsStoredAsNow() async throws {
        try await withFailures { failures, _ in
            let id = UUID()
            failures.fail(failures.begin(id, at: Self.start.addingTimeInterval(24 * 60 * 60)))
            #expect(failures.backoff(for: id, now: Self.start).retryNotBefore == Self.start.addingTimeInterval(60))
            #expect(failures.entry(for: id)?.lastAttemptAt == Self.start)
            let later = Self.start.addingTimeInterval(30)
            #expect(failures.backoff(for: id, now: later).retryNotBefore == Self.start.addingTimeInterval(60))
        }
    }
}
