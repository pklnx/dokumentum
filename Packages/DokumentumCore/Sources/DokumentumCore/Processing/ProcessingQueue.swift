import DokumentumKit
import Foundation
import SwiftData

/// What one run of the queue did. Counts only; `Log.processing` logs them.
public struct ProcessingReport: Equatable, Sendable {
    /// Documents this run marked `done`.
    public var done = 0
    /// Documents this run marked `failed` (this device's third failure).
    public var failed = 0
    /// Failed attempts below the limit: counted on this device, nothing written; the next run tries again.
    public var failures = 0
    /// Documents waiting for another device's claim, their file's data or their text record.
    public var waiting = 0
    /// Documents skipped (`done`, `failed` here, `unknown`, trashed).
    public var skipped = 0
    /// Results not written: the claim the work ran under, or the document's file, changed meanwhile (a takeover, a
    /// replaced or relinked file, a trash).
    public var dropped = 0
    /// Writes whose check found the row changed by another save: rolled back, nothing written (T6).
    public var backedOff = 0
    /// Saves of this run: claim writes and result writes.
    public var saves = 0
    /// Attempts whose stage reported no progress for the stall timeout (#97 point 3): cancelled, left behind and
    /// counted as failed, so they are in `failures` or `failed` too.
    public var timedOut = 0
    /// Attempts ended by `interruptNow()` (#97 point 4): given back, not counted. The run ends with one.
    public var interrupted = 0
    /// Results whose text was over `ExtractedText.byteLimit` and was stored cut (T7, N6; logged).
    public var textsCapped = 0
    /// Documents the one-time re-queue pass at the start of this run set back to `pending` (`ProcessingRequeue`).
    public var requeued = 0
    /// Results that replaced the stored PDF with one with the invisible text layer (#6, part 3).
    public var layered = 0
    /// The run ended early because a second stage was left behind after a timeout while the first had not
    /// returned yet (N1). The next run waits for one of them before it starts a stage.
    public var stalled = false
    /// When the first fresh claim of another device that this run waited for expires, by this device's clock.
    public var nextExpiry: Date?
    /// When the first backoff this run waited for, or started with a failed attempt, ends, by this device's clock.
    public var nextRetry: Date?

    /// When the scheduler runs the queue again: the earlier of `nextExpiry` and `nextRetry`.
    public var nextWake: Date? {
        [nextExpiry, nextRetry].compactMap(\.self).min()
    }

    public init() {}
}

/// Something that runs the queue once; `ProcessingQueue` in the app, a stub in tests.
public protocol ProcessingRunning: Sendable {
    func run() async -> ProcessingReport
    /// Ends the stage that is going on at once and gives its attempt back (a known interruption: the app goes to the
    /// background or quits). Synchronous, from any thread.
    func interruptNow()
}

/// The processing queue (plan of #4, part 5): one document at a time, off the main actor.
///
/// A run scans the `Document` rows that are not `done` (never a blob), asks `ProcessingClaimRules` for each, and
/// processes those it may, oldest first:
/// 1. **load** the PDF in a short-lived context of its own (the `DocumentFileLoader` pattern): the only read of a
///    blob, once per processed document, by key. A file whose data has not arrived yet waits, and nothing is
///    written;
/// 2. **claim write**, unless the claim is already this device's and fresh (a document this device imported):
///    `processingDeviceID`, `processingClaimedAt`, `processingState = .processing`;
/// 3. **the stage**, with no context open (`ProcessingStage`; the app's is `DocumentStage`). **The attempt is
///    counted before the stage runs** (`ProcessingFailures`), so a crash or an out-of-memory kill during the stage
///    counts as well: an attempt that never returned stays counted. A stage that returns clears the counter; one
///    that throws or times out keeps its attempt and starts the backoff (1 min, then 10 min, `ProcessingBackoff`).
///    The third failed attempt writes `.failed`; an attempt beyond the third (the earlier ones never returned)
///    writes `.failed` without running the stage again, so such a PDF cannot crash every launch. `.failed` syncs,
///    but another device whose own counter is below 3 still tries it;
/// 4. **result write**: `pageCount` and `textSource` if they differ, the text record's `extractedText` (capped at
///    `ExtractedText.byteLimit` UTF-8 bytes), with a text layer the file record's `pdfData` and the document's
///    `fileSize` (#6, part 3), and `processingState = .done`, in one save. Its check before the save reads the
///    document row, the text row and, with a layer, the file row (each by key) again. `contentHash` stays the hash of
///    the imported bytes, so importing them again is still a duplicate.
///
/// Before its scan, a run does this device's one-time re-queue pass (`ProcessingRequeue`) until it completed once.
///
/// **A result is dropped** when the row no longer holds the claim the work ran under (another device took it
/// over, whatever its clock says) or links another file than the one whose data was processed (a replaced or
/// relinked file: compared by the file row's identifier, read from the document row without loading the file).
///
/// **Write discipline (T6, #56's principle: a background writer never writes over a row state it has not read).**
/// The claim write and the result write each run in one synchronous call (`write`), with no `await` from its first
/// step to its last and never a compensating write:
/// 1. a fresh `ModelContext` fetches the one document by `instanceID`;
/// 2. it re-checks what the decision was based on: state, claim device and time, not trashed, the same file, a
///    text record. If one differs, it writes nothing;
/// 3. it sets only the fields that change;
/// 4. it reads the row again in a second fresh context (`RowState.read`) and compares every field with what the
///    write context fetched;
/// 5. if they match it saves once; otherwise it rolls back, writes nothing and logs it. The next run comes from
///    the store change the other save caused.
///
/// **Residual window**, as in #56: a save to the same row that commits between the re-read (step 4) and the commit
/// of the queue's save is still written over with the values the queue read. Plan §3.2's "never overwrite an edit"
/// holds on one device except within this window; across devices it depends on CloudKit's merge, per field or per
/// record (#31's C1/C2, T6). The window is one document row's read plus its save (docs/development/index.md,
/// "The processing queue").
///
/// **Stall watchdog (#97 point 3, T10).** The stage reports progress per page; when none came for 300 s (on the
/// suspending clock, so a sleeping device never stalls), the queue cancels the stage without waiting for it, counts
/// the attempt as failed (`timedOut`) and goes on with the next document. A cancelled stage stops after its page,
/// but a framework call that ignores cancellation keeps running until it returns, and its result is always
/// dropped. So that there is never more than one extra job (N1, `StageTracker`): a stage starts only when every
/// stage cancelled by `interruptNow()` has returned and at most one timed-out stage is still alive, and a run whose
/// second timeout would leave two alive ends as `stalled`.
///
/// **Interruptions (#97 point 4, T11).** `interruptNow()` is synchronous and callable from any thread: it gives the
/// running attempt back (the counter returns to its value before the attempt, no backoff), cancels the stage and
/// ends the wait for it, so a stage that returns later writes nothing. The scheduler calls it through `pause()`
/// when the app goes to the background on iOS and when it quits on the Mac, and cancels the run, which ends before
/// its next document. A crash, a kill or a power loss during the stage still counts, as before.
///
/// **Resume after quit** is the next run: a document left in `.processing` with this device's claim is processed
/// again.
public actor ProcessingQueue: ProcessingRunning {
    /// Sleeps the stall watchdog's timeout; the suspending clock in the app.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// No progress for this long ends an attempt (T10).
    public static let stallTimeout: Duration = .seconds(300)

    /// Test hooks; empty in the app.
    public struct Hooks: Sendable {
        /// Runs once per run after the scan, before the first document is processed.
        public var afterScan: (@Sendable () async -> Void)?
        /// Runs in each write after its fields were set and before the check reads the row again (step 3 to 4):
        /// where a test saves another context's edit, or #56's repair.
        public var beforeCheck: (@Sendable (Write) throws -> Void)?
        /// Runs each time a run starts to wait for a stage that was let go before it starts its own (N1).
        public var waitsForStage: (@Sendable () -> Void)?

        public init(
            afterScan: (@Sendable () async -> Void)? = nil, beforeCheck: (@Sendable (Write) throws -> Void)? = nil,
            waitsForStage: (@Sendable () -> Void)? = nil
        ) {
            self.afterScan = afterScan
            self.beforeCheck = beforeCheck
            self.waitsForStage = waitsForStage
        }
    }

    /// The queue's two writes.
    public enum Write: Sendable, Equatable {
        case claim, result
    }

    public let container: ModelContainer
    /// This device's `processingDeviceID` (`DeviceIdentity`).
    public let deviceID: String
    private let failures: ProcessingFailures
    private let sightings: ClaimSightings
    private let stage: any ProcessingStage
    private let now: @Sendable () -> Date
    private let takeoverInterval: TimeInterval
    private let stallTimeout: Duration
    private let watchdogSleep: Sleep
    private let hooks: Hooks
    private let requeue: ProcessingRequeue?
    /// The stage this queue waits for and the ones it let go.
    let stages: StageTracker

    /// - Parameters:
    ///   - sightings: this device's claim sightings; by default in the failure counter's defaults suite.
    ///   - watchdogSleep: sleeps the stall timeout; `Task.sleep` on the suspending clock in the app.
    ///   - requeue: the one-time re-queue pass, run before the scan until it completed; `nil` runs none (tests of
    ///     other things).
    public init(
        container: ModelContainer, deviceID: String, failures: ProcessingFailures, sightings: ClaimSightings? = nil,
        stage: any ProcessingStage = DocumentStage(), requeue: ProcessingRequeue? = nil,
        takeoverInterval: TimeInterval = ProcessingClaimRules.takeoverInterval,
        stallTimeout: Duration = ProcessingQueue.stallTimeout,
        watchdogSleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
        now: @escaping @Sendable () -> Date = { Date() }, hooks: Hooks = Hooks()
    ) {
        self.container = container
        self.deviceID = deviceID
        self.failures = failures
        self.sightings = sightings ?? ClaimSightings(defaultsSuite: failures.defaultsSuite)
        self.stage = stage
        self.takeoverInterval = takeoverInterval
        self.stallTimeout = stallTimeout
        self.watchdogSleep = watchdogSleep
        self.now = now
        self.hooks = hooks
        self.requeue = requeue
        stages = StageTracker(onWait: hooks.waitsForStage)
    }

    /// A known interruption (#97 point 4): gives the running attempt back, cancels its stage and ends the wait for
    /// it, at once and without waiting for the stage. Callable from any thread; the refund is done when it returns.
    /// The run that waited ends; a run that is also cancelled (the scheduler's `pause()`) starts no further
    /// document.
    public nonisolated func interruptNow() {
        guard let current = stages.interruptCurrent() else { return }
        let refunded = failures.refund(current.attempt)
        current.task?.cancel()
        current.outcome.resolve(.interrupted)
        Log.processing.notice("Processing interrupted; attempt given back: \(refunded, privacy: .public)")
    }

    /// One run over every document that is not `done`.
    @discardableResult
    public func run() async -> ProcessingReport {
        var report = ProcessingReport()
        if let requeue, !requeue.isDone {
            report.requeued = requeue.run(in: container, deviceID: deviceID, now: now()).requeued
            report.saves += report.requeued
        }
        let candidates: [Candidate]
        do {
            try Self.forgetCounters(failures, sightings: sightings, in: container)
            candidates = try Self.scan(in: container)
        } catch {
            Log.processing.error("Processing scan failed: \(Log.code(of: error), privacy: .public)")
            return report
        }
        if let afterScan = hooks.afterScan { await afterScan() }
        documents: for candidate in candidates {
            // Cancelled: the scheduler paused (the app goes to the background or quits).
            if Task.isCancelled { break }
            let now = now()
            let input = decisionInput(for: candidate, now: now)
            let decision = ProcessingClaimRules.decide(
                input, thisDevice: deviceID, failures: failures.count(for: candidate.instanceID), now: now,
                takeoverInterval: takeoverInterval)
            switch decision {
            case .skip:
                report.skipped += 1
            case .wait(.claimedElsewhere(let until)):
                report.waiting += 1
                report.nextExpiry = min(report.nextExpiry ?? until, until)
            case .wait(.retryAfter(let date)):
                report.waiting += 1
                report.nextRetry = min(report.nextRetry ?? date, date)
            case .wait:
                report.waiting += 1
            case .process(let claim):
                guard await process(candidate, claim: claim, into: &report) else { break documents }
            }
        }
        Self.log(report)
        return report
    }

    /// The scan's input with this device's own knowledge: since when it has seen another device's claim (recorded
    /// now), and its backoff.
    private func decisionInput(for candidate: Candidate, now: Date) -> ProcessingClaimInput {
        var input = candidate.input
        let id = candidate.instanceID
        if input.state == .pending || input.state == .processing, !input.deviceID.isEmpty, input.deviceID != deviceID,
            let claimedAt = input.claimedAt
        {
            input.claimSeenSince = sightings.see(id, deviceID: input.deviceID, claimedAt: claimedAt, now: now)
        } else if sightings.sighting(of: id) != nil {
            sightings.forget([id])
        }
        input.retryNotBefore = failures.backoff(for: id, now: now).retryNotBefore
        return input
    }

    /// Processes one document; `false` ends the run (interrupted, cancelled, or stalled).
    private func process(
        _ candidate: Candidate, claim: ProcessingDecision.ClaimWrite, into report: inout ProcessingReport
    ) async -> Bool {
        let id = candidate.instanceID
        // One job at a time (N1): a stage that was let go and has not returned blocks the next one.
        guard await stages.waitUntilStartable(), !Task.isCancelled else { return false }
        let loaded: LoadedFile
        switch Self.loadFile(of: id, in: container) {
        case .file(let file): loaded = file
        case .noData:
            report.waiting += 1
            return true
        case .changed:
            report.dropped += 1
            return true
        }
        // The writes expect the file whose data was loaded: one relinked or replaced later drops the result.
        var held = candidate.held(file: loaded.file)
        if claim != .keep {
            let claimedAt = now()
            let outcome = write(.claim, id, expecting: held) { document in
                document.processingDeviceID = self.deviceID
                document.processingClaimedAt = claimedAt
                document.processingState = .processing
            }
            guard count(outcome, into: &report) else { return true }
            held = Held(
                stateRaw: ProcessingState.processing.storedValue ?? "", deviceID: deviceID, claimedAt: claimedAt,
                file: loaded.file)
        }
        // Counted before the stage: an attempt that never returns (a crash, a memory kill) stays counted.
        let attempt = failures.begin(id, at: now())
        guard attempt.number <= ProcessingClaimRules.failureLimit else {
            failures.fail(attempt)
            Log.processing.error(
                "Processing gave up: \(attempt.number - 1, privacy: .public) attempts on this device never returned")
            writeFailed(id, expecting: held, into: &report)
            return true
        }
        switch await runStage(pdfData: loaded.data, attempt: attempt) {
        case .returned(let result):
            // Finished before the counter goes, in one step: a late interruption changes nothing (N2).
            guard failures.succeed(attempt) else {
                report.interrupted += 1
                return false
            }
            let text = result.text.map { ($0.source, $0.capped()) }
            let layered = result.layeredPDF
            let outcome = write(.result, id, expecting: held, checksText: text != nil, checksFile: layered != nil) {
                document in
                if document.pageCount != result.pageCount { document.pageCount = result.pageCount }
                if let (source, capped) = text {
                    if document.textSource != source { document.textSource = source }
                    if let record = document.text, record.extractedText != capped.text {
                        record.extractedText = capped.text
                    }
                }
                // Only the result write changes a linked file's data, under the exact claim the work ran under, so
                // the data is the one the layer was built from (T16).
                if let layered, let file = document.file {
                    file.pdfData = layered
                    if document.fileSize != layered.count { document.fileSize = layered.count }
                }
                document.processingState = .done
            }
            if count(outcome, into: &report) {
                report.done += 1
                if layered != nil { report.layered += 1 }
                if let (_, capped) = text, capped.isCapped {
                    report.textsCapped += 1
                    Log.processing.notice(
                        "A document's text was over \(ExtractedText.byteLimit, privacy: .public) bytes and was cut")
                }
            }
            return true
        case .threw(let error):
            guard failures.fail(attempt) else {
                report.interrupted += 1
                return false
            }
            Log.processing.error(
                """
                Processing failed: \(Log.code(of: error), privacy: .public), attempt \(attempt.number, privacy: .public) \
                on this device
                """)
            failed(attempt, expecting: held, into: &report)
            return true
        case .timedOut:
            guard failures.fail(attempt) else {
                report.interrupted += 1
                return false
            }
            report.timedOut += 1
            Log.processing.error(
                "Processing timed out: no progress, attempt \(attempt.number, privacy: .public) on this device")
            failed(attempt, expecting: held, into: &report)
            guard stages.timedOutAlive < 2 else {
                report.stalled = true
                Log.processing.error("Processing stalled: two stages that timed out have not returned")
                return false
            }
            return true
        case .interrupted:
            report.interrupted += 1
            return false
        }
    }

    /// A failed attempt (thrown or timed out): below the limit nothing is written and the backoff starts; the third
    /// writes `failed`.
    private func failed(
        _ attempt: ProcessingFailures.Attempt, expecting held: Held, into report: inout ProcessingReport
    ) {
        guard attempt.number >= ProcessingClaimRules.failureLimit else {
            report.failures += 1
            if let retry = failures.backoff(for: attempt.document, now: now()).retryNotBefore {
                report.nextRetry = min(report.nextRetry ?? retry, retry)
            }
            return
        }
        writeFailed(attempt.document, expecting: held, into: &report)
    }

    private func writeFailed(_ id: UUID, expecting held: Held, into report: inout ProcessingReport) {
        let outcome = write(.result, id, expecting: held) { $0.processingState = .failed }
        if count(outcome, into: &report) { report.failed += 1 }
    }

    /// Runs the stage in a task of its own, raced by the stall watchdog and `interruptNow()`. A stage that loses the
    /// race is cancelled and not waited for; whatever it returns later is dropped.
    private func runStage(pdfData: Data, attempt: ProcessingFailures.Attempt) async -> StageOutcome {
        let outcome = FirstOutcome()
        let watchdog = StallWatchdog(timeout: stallTimeout, sleep: watchdogSleep) { outcome.resolve(.timedOut) }
        let stages = stages
        let stage = stage
        let id = stages.begin(attempt: attempt, outcome: outcome)
        // A pause that came before `begin` found no stage to interrupt; it cancelled the run first, so it is seen
        // here, and the stage never starts (review B1 of #120). One that comes after `begin` interrupts the stage.
        if Task.isCancelled {
            _ = stages.cancelBeforeStart(id)
            failures.refund(attempt)
            return .interrupted
        }
        watchdog.kick()
        let task = Task.detached {
            let result: StageOutcome
            do {
                result = .returned(try await stage.process(pdfData: pdfData) { _, _ in watchdog.kick() })
            } catch {
                result = .threw(error)
            }
            outcome.resolve(result)
            stages.ended(id)
        }
        stages.attach(task, to: id)
        let result = await outcome.value
        watchdog.stop()
        switch result {
        case .returned, .threw:
            stages.finish(id)
        case .timedOut:
            stages.abandonAfterTimeout(id)
            task.cancel()
        case .interrupted:
            break
        }
        return result
    }

    /// Adds a write's outcome to `report`; `true` when it saved.
    private func count(_ outcome: WriteOutcome, into report: inout ProcessingReport) -> Bool {
        switch outcome {
        case .saved:
            report.saves += 1
            return true
        case .changed:
            report.dropped += 1
        case .metAnotherSave:
            report.backedOff += 1
        case .failed:
            break
        }
        return false
    }

    private func write(
        _ kind: Write, _ instanceID: UUID, expecting held: Held, checksText: Bool = false, checksFile: Bool = false,
        change: (Document) -> Void
    ) -> WriteOutcome {
        Self.write(
            kind, instanceID, expecting: held, in: container, checksText: checksText, checksFile: checksFile,
            beforeCheck: hooks.beforeCheck, change: change)
    }

    private static func log(_ report: ProcessingReport) {
        Log.processing.notice(
            """
            Processing run: done \(report.done, privacy: .public), failed \(report.failed, privacy: .public), \
            failures \(report.failures, privacy: .public), waiting \(report.waiting, privacy: .public), skipped \
            \(report.skipped, privacy: .public), dropped \(report.dropped, privacy: .public), backed off \
            \(report.backedOff, privacy: .public), saves \(report.saves, privacy: .public), timed out \
            \(report.timedOut, privacy: .public), interrupted \(report.interrupted, privacy: .public), stalled \
            \(report.stalled, privacy: .public)
            """)
    }
}

// MARK: - The synchronous steps

// Each step that touches the store is one synchronous call with its own context, so no context lives across an
// `await`, and `ProcessingSQLTests` can record its SQL on one thread.
extension ProcessingQueue {
    /// What the decision is based on, as the scan read it.
    struct Candidate: Equatable {
        var instanceID: UUID
        var input: ProcessingClaimInput
        var stateRaw: String

        func held(file: PersistentIdentifier) -> Held {
            Held(stateRaw: stateRaw, deviceID: input.deviceID, claimedAt: input.claimedAt, file: file)
        }
    }

    /// The row state a write expects: the claim the decision or the work is based on, and the file processed.
    /// A write also expects the document not trashed and with its text record.
    struct Held: Equatable {
        var stateRaw: String
        var deviceID: String
        var claimedAt: Date?
        var file: PersistentIdentifier?

        func matches(_ document: Document) -> Bool {
            document.processingStateRaw == stateRaw && document.processingDeviceID == deviceID
                && document.processingClaimedAt == claimedAt && document.deletedAt == nil
                && document.file?.persistentModelID == file && document.text != nil
        }
    }

    struct LoadedFile {
        var data: Data
        var file: PersistentIdentifier
    }

    enum Load {
        case file(LoadedFile)
        /// The file has not arrived, or its data has not: wait.
        case noData
        /// The document is gone.
        case changed
    }

    enum WriteOutcome: Equatable {
        case saved
        /// The re-check found what the decision was based on changed: nothing written.
        case changed
        /// The check before the save found the row changed by another save: rolled back.
        case metAnotherSave
        /// The store failed (logged).
        case failed
    }

    /// Every document that is not `done`, oldest first: only `Document` rows (`ProcessingSQLTests`). An unknown
    /// state is included and skipped by the rules. Records sharing an `instanceID` keep the first in
    /// `RowRecords.oldestFirst` order, as every other reader does.
    static func scan(in container: ModelContainer) throws -> [Candidate] {
        let context = ModelContext(container)
        let done = ProcessingState.done.storedValue ?? "done"
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.processingStateRaw != done })
        var seen: Set<UUID> = []
        var candidates: [Candidate] = []
        for document in RowRecords.oldestFirst(try context.fetch(descriptor))
        where seen.insert(document.instanceID).inserted {
            // `!= nil` reads the link from the document row; it does not load the blob.
            let input = ProcessingClaimInput(
                state: document.processingState, deviceID: document.processingDeviceID,
                claimedAt: document.processingClaimedAt, isTrashed: document.deletedAt != nil,
                hasFile: document.file != nil, hasText: document.text != nil)
            candidates.append(
                Candidate(instanceID: document.instanceID, input: input, stateRaw: document.processingStateRaw))
        }
        return candidates
    }

    /// Removes the failure counters and claim sightings of documents that are `done` or gone, so the keys do not
    /// grow.
    static func forgetCounters(
        _ failures: ProcessingFailures, sightings: ClaimSightings, in container: ModelContainer
    ) throws {
        let tracked = Array(Set(failures.documents + sightings.documents))
        guard !tracked.isEmpty else { return }
        let context = ModelContext(container)
        let documents = try context.fetch(
            FetchDescriptor<Document>(predicate: #Predicate { tracked.contains($0.instanceID) }))
        let open = Set(documents.filter { $0.processingState != .done }.map(\.instanceID))
        let gone = tracked.filter { !open.contains($0) }
        guard !gone.isEmpty else { return }
        failures.forget(gone)
        sightings.forget(gone)
    }

    /// The document's PDF, in a context of its own that ends with the load: the one blob read of a run.
    static func loadFile(of instanceID: UUID, in container: ModelContainer) -> Load {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let document = try fetch(instanceID, in: context) else { return .changed }
            guard let file = document.file, let data = file.pdfData, !data.isEmpty else { return .noData }
            return .file(LoadedFile(data: data, file: file.persistentModelID))
        } catch {
            Log.processing.error("Could not load a document's file: \(Log.code(of: error), privacy: .public)")
            return .noData
        }
    }

    /// One write, steps 1 to 5 of the discipline, without a suspension. With `checksText` the write also changes the
    /// document's text record, and step 4 reads that row again too, by key (`RowState.readText`); with `checksFile`
    /// likewise its file record (`RowState.readFile`; `pdfData` is not compared, `RowState.excluded`).
    static func write(
        _ kind: Write, _ instanceID: UUID, expecting held: Held, in container: ModelContainer,
        checksText: Bool = false, checksFile: Bool = false, beforeCheck: (@Sendable (Write) throws -> Void)?,
        change: (Document) -> Void
    ) -> WriteOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            // 1. A fresh context fetches the one document; 2. the re-check.
            guard let document = try fetch(instanceID, in: context), held.matches(document) else {
                Log.processing.notice("A document changed since the queue decided; nothing written")
                return .changed
            }
            let read = RowState.capture(document)
            // The text record, by key, as this context read it (`held` made sure one is linked).
            let textRead = checksText ? document.text.map { ($0.persistentModelID, RowState.capture($0)) } : nil
            // The file record, by key (`held` made sure it is the one processed).
            let fileRead = checksFile ? document.file.map { ($0.persistentModelID, RowState.capture($0)) } : nil
            if checksFile, fileRead == nil { return .changed }
            // 3. Only the fields that change.
            change(document)
            try beforeCheck?(kind)
            // 4. The rows again, in a second fresh context, every field.
            let key = RowKey(entity: .document, instanceID: instanceID)
            let stored = try RowState.read([key], in: container)
            var textUnchanged = true
            if let (textID, textState) = textRead {
                textUnchanged = try RowState.readText(textID, in: container) == textState
            }
            var fileUnchanged = true
            if let (fileID, fileState) = fileRead {
                fileUnchanged = try RowState.readFile(fileID, in: container) == fileState
            }
            guard stored[key] == read, textUnchanged, fileUnchanged else {
                context.rollback()
                Log.processing.notice("A processing write met another save of its document and wrote nothing")
                return .metAnotherSave
            }
            // 5. One save.
            try context.save()
            return .saved
        } catch {
            context.rollback()
            Log.processing.error("A processing write failed: \(Log.code(of: error), privacy: .public)")
            return .failed
        }
    }

    /// The document with `instanceID`, without its blobs: the first in `RowRecords.oldestFirst` order, as the
    /// scan, `RowState.read` and the repair pick it, so a copy sharing the `instanceID` never mixes into one write.
    /// Usually one row; all copies are fetched so the order can be applied.
    static func fetch(_ instanceID: UUID, in context: ModelContext) throws -> Document? {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID })
        return RowRecords.oldestFirst(try context.fetch(descriptor)).first
    }
}
