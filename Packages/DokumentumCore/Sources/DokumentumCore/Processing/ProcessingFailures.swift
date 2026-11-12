import DokumentumKit
import Foundation
import Synchronization

/// This device's attempt counter per document (plan of #4, part 5, N10; review B of #96, N3; #97 points 2 and 4):
/// how many attempts on this device started and did not succeed, and when the last one started. The queue counts an
/// attempt before its stage runs (`begin`), so an attempt that never returned (a crash, an out-of-memory kill)
/// counts too, and clears the counter when the stage returns (`succeed`). A failed attempt (thrown or timed out)
/// keeps its count and starts the backoff (`ProcessingBackoff`). A **known interruption** gives its attempt back
/// (`refund`): the counter returns to its value before the attempt, and the backoff to its earlier start.
///
/// Kept in the per-device `UserDefaults` (`ProcessingEnvironment.defaultsSuite`), never synced: a synced counter
/// would be one more field both devices write. One dictionary under `defaultsKey`, keyed by the document's
/// `instanceID`, each value `attempts` and `lastAttemptAt` (a plain number, step 3's form, reads as attempts without
/// a time). The classification step (#8) keeps its own counter, the same kind under `classificationDefaultsKey`
/// (T5), so text and classification attempts never mix. A key is removed when a stage returns, and when the queue sees the document `done` or gone, so the keys
/// do not grow.
///
/// **Two callers, one lock (N2):** the queue (`begin`, `succeed`, `fail`, `remove`, `forget`) and
/// `ProcessingQueue.interruptNow()` from any thread (`refund`). Every read-modify-write of the dictionary and the
/// state of each attempt (running, then finished or interrupted) sit behind the same `Mutex`, so no update is
/// lost. A refund happens only while its attempt is running; `succeed` marks the attempt finished and removes the
/// counter in one step, so a late interruption neither refunds a finished attempt nor brings a counter back. One
/// instance per defaults suite **and key**: the lock is the instance's and guards only its own key, so the text
/// step's counter and the classification step's counter (#8, T5) are two instances on one suite, each the only
/// writer of its key.
public final class ProcessingFailures: Sendable {
    /// The key of the text step's counter in the per-device defaults.
    public static let defaultsKey = "processingFailures"
    /// The key of the classification step's counter (#8, T5).
    public static let classificationDefaultsKey = "classificationFailures"

    /// One document's counter.
    public struct Entry: Equatable, Sendable {
        public var attempts: Int
        /// When the last counted attempt started, by this device's clock; `nil` in step 3's form.
        public var lastAttemptAt: Date?

        public init(attempts: Int, lastAttemptAt: Date?) {
            self.attempts = attempts
            self.lastAttemptAt = lastAttemptAt
        }
    }

    /// One counted attempt, from `begin` until `succeed`, `fail` or `refund`.
    public struct Attempt: Equatable, Sendable {
        public let document: UUID
        /// The counter after this attempt was counted.
        public let number: Int
        let token: UInt64
        /// The start of the attempt before, which a refund restores.
        let previousStart: Date?
    }

    /// What a test hook sees: the operation that holds the lock.
    enum Operation: Equatable, Sendable {
        case begin, succeed, fail, refund, increment, remove, forget, backoff
    }

    private struct State {
        var running: Set<UInt64> = []
        var nextToken: UInt64 = 0
    }

    /// The `UserDefaults` suite; `nil` is `UserDefaults.standard`. A name, because `UserDefaults` is not `Sendable`.
    public let defaultsSuite: String?
    /// The key of this counter in the suite.
    public let key: String
    private let state = Mutex(State())
    /// Tests only: runs inside the lock, after the dictionary was read and before it is written.
    private let whileLocked: (@Sendable (Operation) -> Void)?

    public convenience init(defaultsSuite: String?, key: String = ProcessingFailures.defaultsKey) {
        self.init(defaultsSuite: defaultsSuite, key: key, whileLocked: nil)
    }

    init(
        defaultsSuite: String?, key: String = ProcessingFailures.defaultsKey,
        whileLocked: (@Sendable (Operation) -> Void)?
    ) {
        self.defaultsSuite = defaultsSuite
        self.key = key
        self.whileLocked = whileLocked
    }

    /// The counter of `environment`'s defaults (the app's: `UserDefaults.standard`).
    public convenience init(environment: ProcessingEnvironment = .current) {
        self.init(defaultsSuite: environment.defaultsSuite)
    }

    // MARK: Reads

    public func count(for document: UUID) -> Int {
        entry(for: document)?.attempts ?? 0
    }

    public func entry(for document: UUID) -> Entry? {
        state.withLock { _ in entries[document.uuidString] }
    }

    /// The documents that have a counter.
    public var documents: [UUID] {
        state.withLock { _ in entries.keys.compactMap(UUID.init(uuidString:)) }
    }

    /// The counter and the earliest start of the next attempt (`ProcessingBackoff`), for the decision. A last
    /// attempt in the future (the clock was set back) is stored as `now` (N9), so the retry stays at `now` plus the
    /// delay instead of moving on with every later decision.
    public func backoff(for document: UUID, now: Date) -> (attempts: Int, retryNotBefore: Date?) {
        state.withLock { _ in
            var all = entries
            guard var entry = all[document.uuidString] else { return (0, nil) }
            if let last = entry.lastAttemptAt, last > now {
                whileLocked?(.backoff)
                entry.lastAttemptAt = now
                all[document.uuidString] = entry
                entries = all
            }
            return (
                entry.attempts,
                ProcessingBackoff.retryNotBefore(attempts: entry.attempts, lastAttemptAt: entry.lastAttemptAt, now: now)
            )
        }
    }

    // MARK: Attempts

    /// Counts an attempt that starts at `start` and marks it running.
    public func begin(_ document: UUID, at start: Date) -> Attempt {
        state.withLock { state in
            var all = entries
            whileLocked?(.begin)
            let previous = all[document.uuidString]
            let entry = Entry(attempts: (previous?.attempts ?? 0) + 1, lastAttemptAt: start)
            all[document.uuidString] = entry
            entries = all
            state.nextToken += 1
            state.running.insert(state.nextToken)
            return Attempt(
                document: document, number: entry.attempts, token: state.nextToken,
                previousStart: previous?.lastAttemptAt)
        }
    }

    /// The stage returned: marks the attempt finished and removes the counter, in one step. `false` when the
    /// attempt was no longer running (it was interrupted): nothing changes, and its result must not be written.
    @discardableResult
    public func succeed(_ attempt: Attempt) -> Bool {
        state.withLock { state in
            guard state.running.remove(attempt.token) != nil else { return false }
            var all = entries
            whileLocked?(.succeed)
            guard all.removeValue(forKey: attempt.document.uuidString) != nil else { return true }
            entries = all
            return true
        }
    }

    /// The stage threw or timed out: marks the attempt finished; its count stays. `false` when it was no longer
    /// running (interrupted, so already given back).
    @discardableResult
    public func fail(_ attempt: Attempt) -> Bool {
        state.withLock { state in
            whileLocked?(.fail)
            return state.running.remove(attempt.token) != nil
        }
    }

    /// A known interruption (#97 point 4): gives the attempt back, only while it is running, and marks it
    /// interrupted. The counter goes down by one and the backoff returns to the start of the attempt before.
    /// `false` when the attempt had finished already: nothing changes.
    @discardableResult
    public func refund(_ attempt: Attempt) -> Bool {
        state.withLock { state in
            guard state.running.remove(attempt.token) != nil else { return false }
            var all = entries
            whileLocked?(.refund)
            if var entry = all[attempt.document.uuidString] {
                entry.attempts -= 1
                entry.lastAttemptAt = attempt.previousStart
                all[attempt.document.uuidString] = entry.attempts > 0 ? entry : nil
                entries = all
            }
            return true
        }
    }

    // MARK: Counter only

    /// Counts one more failure, without a time, and returns the new count.
    @discardableResult
    public func increment(for document: UUID) -> Int {
        state.withLock { _ in
            var all = entries
            whileLocked?(.increment)
            var entry = all[document.uuidString] ?? Entry(attempts: 0, lastAttemptAt: nil)
            entry.attempts += 1
            all[document.uuidString] = entry
            entries = all
            return entry.attempts
        }
    }

    public func remove(_ document: UUID) {
        forget([document])
    }

    /// Removes the counters of `documents`, in one write.
    public func forget(_ documents: [UUID]) {
        state.withLock { _ in
            var all = entries
            whileLocked?(.forget)
            var changed = false
            for document in documents where all.removeValue(forKey: document.uuidString) != nil { changed = true }
            if changed { entries = all }
        }
    }

    // MARK: Storage (only under the lock)

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private static let attemptsKey = "attempts"
    private static let lastAttemptKey = "lastAttemptAt"

    private var entries: [String: Entry] {
        get {
            let stored = defaults.dictionary(forKey: key) ?? [:]
            return stored.compactMapValues { value in
                if let attempts = value as? Int { return Entry(attempts: attempts, lastAttemptAt: nil) }
                guard let fields = value as? [String: Any], let attempts = fields[Self.attemptsKey] as? Int else {
                    return nil
                }
                return Entry(attempts: attempts, lastAttemptAt: fields[Self.lastAttemptKey] as? Date)
            }
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: key)
                return
            }
            let stored = newValue.mapValues { entry -> [String: Any] in
                var fields: [String: Any] = [Self.attemptsKey: entry.attempts]
                if let last = entry.lastAttemptAt { fields[Self.lastAttemptKey] = last }
                return fields
            }
            defaults.set(stored, forKey: key)
        }
    }
}
