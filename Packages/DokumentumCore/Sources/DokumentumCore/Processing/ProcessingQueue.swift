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
    /// Text result writes that set `classify` instead of `done` (#8): the classification step comes next.
    public var toClassify = 0
    /// Classification writes after a model answer (#8): the empty fields filled, `done`.
    public var classified = 0
    /// Documents the model declined (refusal, guardrail, language; #8): `done` without suggestions, never asked
    /// again. Logged only (P8).
    public var declined = 0
    /// Documents finished in `done` without a model answer (#8): the switch off, the model unavailable on this
    /// device, a text too short, the wait for the model ended after 6 hours, or the third failed attempt.
    public var classificationSkipped = 0
    /// Thumbnails the result writes of this run inserted for documents the re-queue pass recorded (#6, part 4, N3).
    public var thumbnailsBackfilled = 0
    /// Text result writes in which the matching rules set a correspondent or type or added tags (#10, part 1b).
    public var rulesApplied = 0
    /// Text result writes that left a correspondent or type empty because several records' rules matched (P2).
    public var rulesAmbiguous = 0
    /// Writes in which detection (#11) filled an empty correspondent, an existing one or a new one: the text write on
    /// the `done` path, the classification write on the `classify` path.
    public var detectedCorrespondents = 0
    /// …of them, the correspondents detection created (the maintainer's Q1).
    public var createdCorrespondents = 0
    /// Writes in which detection filled an empty date.
    public var detectedDates = 0
    /// The run ended early because a second stage was left behind after a timeout while the first had not
    /// returned yet (N1). The next run waits for one of them before it starts a stage.
    public var stalled = false
    /// When the first fresh claim of another device that this run waited for expires, by this device's clock.
    public var nextExpiry: Date?
    /// When the first backoff this run waited for, or started with a failed attempt, ends, by this device's clock.
    /// Also the end of a classifier's rate limit (#8).
    public var nextRetry: Date?
    /// When the first own claim of a document that waits for the model to become ready expires, by this device's
    /// clock (#8, review N4): the run then finishes it without suggestions.
    public var nextClaimEnd: Date?

    /// When the scheduler runs the queue again: the earliest of `nextExpiry`, `nextRetry` and `nextClaimEnd`.
    public var nextWake: Date? {
        [nextExpiry, nextRetry, nextClaimEnd].compactMap(\.self).min()
    }

    public init() {}
}

/// What "Try again" did (`ProcessingQueue.retry(_:)`).
public enum ProcessingRetryOutcome: Equatable, Sendable {
    /// Saved: the document is `pending` with this device's claim, and this device's failure counter is cleared.
    case queued
    /// The document is not `failed` (any more), or it is gone: nothing written.
    case notFailed
    /// A stage of this document runs on this device: nothing written.
    case busy
    /// The check before the save found the row changed by another save: rolled back, nothing written.
    case metAnotherSave
    /// The store failed (logged).
    case failed
}

/// Something that sets a `failed` document back to `pending` ("Try again"); `ProcessingQueue` in the app.
public protocol ProcessingRetrying: Sendable {
    func retry(_ instanceID: UUID) async -> ProcessingRetryOutcome
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
///    the imported bytes, so importing them again is still a duplicate. **Thumbnail backfill** (#6, part 4, N3): only
///    for a document the re-queue pass recorded (`ProcessingRequeue.thumbnailBackfill`, imported before step 5), the
///    stage's task renders a thumbnail from the loaded original bytes after the stage returned (`Thumbnail`; the
///    layer is invisible), and the result write inserts and links it only when the document still has none; a
///    thumbnail another save links in the window makes the write back off (the link is part of the row). A document
///    imported by this build got its thumbnail at import and is never recorded, so a device that has the document
///    before its thumbnail never makes a second one. A recorded document leaves the record when a result write saved,
///    or when it is seen `done` or gone.
///
/// **Try again** (`retry(_:)`, #6 P2): a `failed` document goes back to `pending` with this device's claim in one
/// write under the discipline below, and this device's failure counter is cleared after it saved; refused while the
/// queue holds a stage of that document, from its start until the queue has handled its outcome.
///
/// **Classification (#8, part 1).** With a classifier (`DocumentClassifying`), the text result write sets `classify`
/// instead of `done` when this device's switch is on, the classifier is not unavailable on this device, and the
/// document was created at or after this device's cut-off (`ClassificationSettings`, P9). The same run then
/// classifies that document next (T7). A document in `classify` (claims, takeover, trash and backoff as for the text,
/// the text record needed, the file not) is handled by `classify(_:claim:into:)`, which always ends in `done`:
///
/// | Situation | Write | Attempt |
/// |---|---|---|
/// | no classifier, the switch off, the model unavailable (`deviceNotEligible`, `appleIntelligenceNotEnabled`) | `done` | none |
/// | the model not ready | nothing; waits until this device's own claim is 6 h old, then `done` (N4) | none |
/// | fewer than 50 non-whitespace characters | `done`, the model not called | none |
/// | an answer | the empty fields filled (`ClassificationFields`), `done` | cleared |
/// | declined (refusal, guardrail, language) | `done`, nothing filled, logged | cleared |
/// | rate limited | nothing; classification pauses until its reset (else 15 min) | given back |
/// | any other error, the stall timeout | nothing, backoff 1 min, 10 min; the third writes `done`, never `failed` | counted |
/// | `interruptNow()` | nothing | given back |
///
/// The classification counter is its own (`ProcessingFailures.classificationDefaultsKey`, T5); both kinds of stage
/// share `StageTracker`, so one stage runs at a time (T6). An answer is checked (`SuggestionRules`) and kept in memory
/// keyed by document and text record until its write saved, so a write that met another save is retried by the next
/// run without asking the model again (T3). The result write (`writeClassification`) follows the discipline below:
/// it decides each field's emptiness on the row it fetched, resolves names against the live records it fetches
/// (`MetadataMatcher`; a new correspondent or type is inserted, a tag never), sets only the fields it fills and `done`,
/// never calls `touch()`, and its check reads the document row and every metadata row it linked or found linked again.
///
/// Before its scan, a run does this device's one-time re-queue pass (`ProcessingRequeue`) until it completed once.
///
/// **A result is dropped** when the row no longer holds the claim the work ran under (another device took it
/// over, whatever its clock says) or links another file than the one whose data was processed (a replaced or
/// relinked file: compared by the file row's identifier, read from the document row without loading the file).
///
/// **Matching rules (#10, part 1b).** The text result write also applies the matching rules, rules first in the shared
/// fill (`MetadataFill`, plan of #10 §4a): after the stage returned and before the write, a short context reads the
/// live rule records (`MatchingStore.readRules`) and evaluates them on the text the write stores. The write applies
/// the outcome to the row it fetched (an empty correspondent and type filled, tags added, no `touch()`), evaluates
/// again only when the live rules it fetched differ from the snapshot, and its check reads every metadata row it
/// links again with the document row. Without rule records it fetches no metadata at all (review N4).
///
/// **Detection (#11, part 2).** The text result write also detects the sender and the issue date (`MetadataFill`,
/// `DetectionFill.swift`), after the rules and only into empty fields, and never calls `touch()`. The maintainer's
/// Q3 (Apple Intelligence wins) decides where:
/// - the write sets **`done`**: detection fills the date (`IssueDateDetector` on the text it stores) and the
///   correspondent (`SenderDetector` on the stage's `firstPageLayout` and the live correspondents; a structural name
///   is resolved with `MetadataMatcher`, else a new correspondent is created) in the same save;
/// - the write sets **`classify`**: detection fills nothing. Right before the save the sender is written to this
///   device's `DetectionStash`, and both exits of the classification step fill detection after the classifier.
///
/// Neither field empty: no fetch and no detector run (N6). The check reads every correspondent it links again.
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
public actor ProcessingQueue: ProcessingRunning, ProcessingRetrying {
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
        /// Runs after the text result write's rules were read and evaluated, before the write (#10, N6): where a test
        /// edits a rule between the snapshot and the write.
        public var afterRules: (@Sendable () -> Void)?

        public init(
            afterScan: (@Sendable () async -> Void)? = nil, beforeCheck: (@Sendable (Write) throws -> Void)? = nil,
            waitsForStage: (@Sendable () -> Void)? = nil, afterRules: (@Sendable () -> Void)? = nil
        ) {
            self.afterScan = afterScan
            self.beforeCheck = beforeCheck
            self.waitsForStage = waitsForStage
            self.afterRules = afterRules
        }
    }

    /// The queue's writes: the claim and the result of a run, the classification's result (#8), and "Try again"
    /// (`retry(_:)`).
    public enum Write: Sendable, Equatable {
        case claim, result, classification, retry
    }

    public let container: ModelContainer
    /// This device's `processingDeviceID` (`DeviceIdentity`).
    public let deviceID: String
    private let failures: ProcessingFailures
    private let sightings: ClaimSightings
    private let stage: any ProcessingStage
    let now: @Sendable () -> Date
    let takeoverInterval: TimeInterval
    private let stallTimeout: Duration
    private let watchdogSleep: Sleep
    let hooks: Hooks
    private let requeue: ProcessingRequeue?
    let classifier: (any DocumentClassifying)?
    let classificationFailures: ProcessingFailures
    let classificationSettings: ClassificationSettings
    /// The sender detection found in a text write that set `classify` (#11, Q3), per device.
    nonisolated let detectionStash: DetectionStash
    let calendar: Calendar
    /// The matching rules' regex budget (#10): `.production` in the app; tests pass a generous clock, so a loaded
    /// runner never times out an ordinary rule (review A of #205, B4).
    let matchingBudget: MatchingBudget
    /// The stage this queue waits for and the ones it let go.
    let stages: StageTracker
    /// Checked answers whose write has not saved yet, by document, with the text record they were made from (T3).
    var suggestions: [UUID: CachedSuggestion] = [:]
    /// No classification request before this time: the classifier was rate limited.
    var classificationPausedUntil: Date?
    /// Documents whose request threw `notReady`, by document (review B1 of #146).
    var modelWaits: [UUID: ModelWait] = [:]

    /// - Parameters:
    ///   - sightings: this device's claim sightings; by default in the failure counter's defaults suite.
    ///   - watchdogSleep: sleeps the stall timeout; `Task.sleep` on the suspending clock in the app.
    ///   - requeue: the one-time re-queue pass, run before the scan until it completed; `nil` runs none (tests of
    ///     other things).
    ///   - classifier: the classification step's model (#8); `nil`: no step, the text result write sets `done`.
    ///   - classificationFailures: its own attempt counter; by default under `classificationDefaultsKey` in the
    ///     text counter's defaults suite.
    ///   - classificationSettings: the switch and the cut-off; by default in the text counter's defaults suite. With
    ///     a classifier, the cut-off is recorded now if there is none yet (P9).
    ///   - detectionStash: the detected senders of documents in `classify` (#11); by default in the failure counter's
    ///     defaults suite.
    ///   - calendar: the calendar a suggested or detected date is stored in (the detail's date picker uses the
    ///     current one).
    ///   - matchingBudget: the matching rules' regex budget per rule and document (#10).
    public init(
        container: ModelContainer, deviceID: String, failures: ProcessingFailures, sightings: ClaimSightings? = nil,
        stage: any ProcessingStage = DocumentStage(), requeue: ProcessingRequeue? = nil,
        classifier: (any DocumentClassifying)? = nil, classificationFailures: ProcessingFailures? = nil,
        classificationSettings: ClassificationSettings? = nil, detectionStash: DetectionStash? = nil,
        calendar: Calendar = .current,
        matchingBudget: MatchingBudget = .production,
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
        self.classifier = classifier
        self.classificationFailures =
            classificationFailures
            ?? ProcessingFailures(
                defaultsSuite: failures.defaultsSuite, key: ProcessingFailures.classificationDefaultsKey)
        let settings = classificationSettings ?? ClassificationSettings(defaultsSuite: failures.defaultsSuite)
        self.classificationSettings = settings
        self.detectionStash = detectionStash ?? DetectionStash(defaultsSuite: failures.defaultsSuite)
        self.calendar = calendar
        self.matchingBudget = matchingBudget
        stages = StageTracker(onWait: hooks.waitsForStage)
        // P9: the cut-off is recorded when the queue is set up, before its first run: the app creates the queue at
        // launch before anything of that launch is imported (the share queue, a drop), so such a document is
        // classified (review A N-c of #146).
        if classifier != nil { settings.recordSince(now()) }
    }

    /// A known interruption (#97 point 4): gives the running attempt back, cancels its stage and ends the wait for
    /// it, at once and without waiting for the stage. Callable from any thread; the refund is done when it returns.
    /// The run that waited ends; a run that is also cancelled (the scheduler's `pause()`) starts no further
    /// document.
    public nonisolated func interruptNow() {
        guard let current = stages.interruptCurrent() else { return }
        let refunded = current.counter.refund(current.attempt)
        current.task?.cancel()
        current.outcome.resolve(.interrupted)
        Log.processing.notice("Processing interrupted; attempt given back: \(refunded, privacy: .public)")
    }

    /// "Try again" for a `failed` document (#6, P2): sets it back to `pending` with this device's claim, so this
    /// device processes it at once, in one write under the discipline (re-check `failed`, `RowState` check, one save,
    /// nothing written on a mismatch), then clears this device's failure counter (and its claim sighting), so the
    /// next run starts again from attempt 1 without a backoff. Refused (`busy`) while the queue holds a stage of this
    /// document, from its start until the queue has handled its outcome (`StageTracker.isRunning`): this device can be
    /// retrying a `failed` document itself when its own counter is below the limit. The method
    /// has no suspension, so no run of this queue interleaves with it; a run that decided on the document before and
    /// has not written its claim yet finds the state changed and writes nothing. The caller asks for a run.
    public func retry(_ instanceID: UUID) -> ProcessingRetryOutcome {
        guard !stages.isRunning(document: instanceID) else {
            Log.processing.notice("Try again refused: the document's stage is running")
            return .busy
        }
        let outcome = Self.retryWrite(
            instanceID, deviceID: deviceID, now: now(), in: container, beforeCheck: hooks.beforeCheck)
        if outcome == .queued {
            // After the save: a write that did not save leaves the counter, and the document stays `failed`.
            failures.forget([instanceID])
            sightings.forget([instanceID])
        }
        Log.processing.notice("Try again: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// One run over every document that is not `done`.
    @discardableResult
    public func run() async -> ProcessingReport {
        var report = ProcessingReport()
        if let requeue, !requeue.isDone {
            report.requeued = requeue.run(in: container, deviceID: deviceID, now: now()).requeued
            report.saves += report.requeued
        }
        // P9: the cut-off, recorded by `init` (and here only when its defaults were cleared since).
        let classificationSince = classifier.map { _ in classificationSettings.recordSince(now()) }
        let candidates: [Candidate]
        do {
            try Self.forgetCounters(
                [failures, classificationFailures], sightings: sightings, requeue: requeue, stash: detectionStash,
                in: container)
            candidates = try Self.scan(in: container)
        } catch {
            Log.processing.error("Processing scan failed: \(Log.code(of: error), privacy: .public)")
            return report
        }
        forgetClassificationMemory(keeping: candidates)
        if let afterScan = hooks.afterScan { await afterScan() }
        documents: for candidate in candidates {
            var next: Candidate? = candidate
            // T7: a text result write that set `classify` hands its document on, so it is classified next.
            while let current = next {
                // Cancelled: the scheduler paused (the app goes to the background or quits).
                if Task.isCancelled { break documents }
                next = nil
                let now = now()
                let input = decisionInput(for: current, now: now)
                let counter = current.input.state == .classify ? classificationFailures : failures
                let decision = ProcessingClaimRules.decide(
                    input, thisDevice: deviceID, failures: counter.count(for: current.instanceID), now: now,
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
                case .process(let claim) where current.input.state == .classify:
                    guard await classify(current, claim: claim, into: &report) else { break documents }
                case .process(let claim):
                    switch await process(current, claim: claim, since: classificationSince, into: &report) {
                    case .next: break
                    case .stop: break documents
                    case .classify(let handed): next = handed
                    }
                }
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
        if input.state == .pending || input.state == .processing || input.state == .classify, !input.deviceID.isEmpty,
            input.deviceID != deviceID,
            let claimedAt = input.claimedAt
        {
            input.claimSeenSince = sightings.see(id, deviceID: input.deviceID, claimedAt: claimedAt, now: now)
        } else if sightings.sighting(of: id) != nil {
            sightings.forget([id])
        }
        let counter = input.state == .classify ? classificationFailures : failures
        input.retryNotBefore = counter.backoff(for: id, now: now).retryNotBefore
        return input
    }

    /// What follows a document's text step.
    enum Next {
        case next
        /// The run ends (interrupted, cancelled, or stalled).
        case stop
        /// The result write set `classify`: classify this document next (T7).
        case classify(Candidate)
    }

    /// Processes one document's text.
    /// - Parameter since: the classification cut-off (P9); `nil` without a classifier.
    private func process(
        _ candidate: Candidate, claim: ProcessingDecision.ClaimWrite, since: Date?,
        into report: inout ProcessingReport
    ) async -> Next {
        let id = candidate.instanceID
        // One job at a time (N1): a stage that was let go and has not returned blocks the next one.
        guard await stages.waitUntilStartable(), !Task.isCancelled else { return .stop }
        let loaded: LoadedFile
        switch Self.loadFile(of: id, in: container) {
        case .file(let file): loaded = file
        case .noData:
            report.waiting += 1
            return .next
        case .changed:
            report.dropped += 1
            return .next
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
            guard count(outcome, into: &report) else { return .next }
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
            return .next
        }
        // N3: only a document the re-queue pass recorded gets a thumbnail from processing.
        let backfills = requeue?.thumbnailBackfill.contains(id) ?? false
        switch await runStage(pdfData: loaded.data, attempt: attempt, makesThumbnail: backfills) {
        case .returned(let result):
            // Finished before the counter goes, in one step: a late interruption changes nothing (N2).
            guard failures.succeed(attempt) else {
                report.interrupted += 1
                return .stop
            }
            let text = result.text.map { ($0.source, $0.capped()) }
            let layered = result.layeredPDF
            // Decided before the write, read from the row inside it (the cut-off compares its `createdAt`).
            let classifies = since != nil && classificationIsOn
            var nextState = ProcessingState.done
            let thumbnail = backfills ? result.thumbnail : nil
            var inserted = false
            // The rules, outside the write's window (N6); `nil` without a text or without rule records (N4).
            let rules = text.flatMap { Self.textWriteRules(on: $0.1.text, in: container, budget: matchingBudget) }
            if rules != nil { hooks.afterRules?() }
            var ruleFill = RuleFill()
            var detected = DetectionFill()
            let layout = result.firstPageLayout
            let stash = detectionStash
            let (writeTime, writeCalendar) = (now(), calendar)
            // Rules first, then detection (#11): with a text, the fill always runs; it fetches the metadata only when
            // a rule or an empty correspondent with a layout needs it (N4, N6).
            let fill: MetadataFillStep? = text.map { _, capped in
                { document, context in
                    var fill = MetadataFill(context: context)
                    if let rules { ruleFill = try fill.applyRules(rules, to: document) }
                    if nextState == .classify {
                        // Q3: nothing detected is filled now. The sender goes to the stash, always written (N-r1).
                        guard let textID = document.text?.instanceID else { return fill.related }
                        let sender =
                            document.correspondent == nil ? try layout.flatMap { try fill.detectSender(in: $0) } : nil
                        stash.write(DetectionStash.Entry(text: textID, sender: sender), for: id)
                    } else {
                        detected = try fill.applyDetection(
                            text: capped.text, layout: layout, to: document, now: writeTime,
                            calendar: writeCalendar)
                    }
                    return fill.related
                }
            }
            let outcome = write(
                .result, id, expecting: held, checksText: text != nil, checksFile: layered != nil, fill: fill
            ) { document in
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
                // Only when none is linked: a second one would leave one of them an orphan.
                if let thumbnail, document.thumbnail == nil, let context = document.modelContext {
                    let record = DocumentThumbnail(documentID: document.id, imageData: thumbnail, createdAt: self.now())
                    context.insert(record)
                    document.thumbnail = record
                    inserted = true
                }
                if classifies, let since, document.createdAt >= since { nextState = .classify }
                document.processingState = nextState
            }
            if count(outcome, into: &report) {
                if nextState == .classify { report.toClassify += 1 } else { report.done += 1 }
                if layered != nil { report.layered += 1 }
                if inserted { report.thumbnailsBackfilled += 1 }
                if ruleFill.changed { report.rulesApplied += 1 }
                if ruleFill.ambiguous { report.rulesAmbiguous += 1 }
                Self.log(ruleFill)
                count(detected, into: &report)
                if backfills { requeue?.forgetThumbnailBackfill([id]) }
                if let (_, capped) = text, capped.isCapped {
                    report.textsCapped += 1
                    Log.processing.notice(
                        "A document's text was over \(ExtractedText.byteLimit, privacy: .public) bytes and was cut")
                }
                if nextState == .classify {
                    var input = candidate.input
                    input.state = .classify
                    input.deviceID = held.deviceID
                    input.claimedAt = held.claimedAt
                    input.hasText = true
                    let stateRaw = ProcessingState.classify.storedValue ?? "classify"
                    return .classify(Candidate(instanceID: id, input: input, stateRaw: stateRaw))
                }
            }
            return .next
        case .suggested:
            // Unreachable: the text stage's work always returns `.returned`. `StageOutcome` is shared with the
            // classification stage, so the switch names it; counted as a failed attempt, never written.
            guard failures.fail(attempt) else {
                report.interrupted += 1
                return .stop
            }
            failed(attempt, expecting: held, into: &report)
            return .next
        case .threw(let error):
            guard failures.fail(attempt) else {
                report.interrupted += 1
                return .stop
            }
            Log.processing.error(
                """
                Processing failed: \(Log.code(of: error), privacy: .public), attempt \(attempt.number, privacy: .public) \
                on this device
                """)
            failed(attempt, expecting: held, into: &report)
            return .next
        case .timedOut:
            guard failures.fail(attempt) else {
                report.interrupted += 1
                return .stop
            }
            report.timedOut += 1
            Log.processing.error(
                "Processing timed out: no progress, attempt \(attempt.number, privacy: .public) on this device")
            failed(attempt, expecting: held, into: &report)
            guard stages.timedOutAlive < 2 else {
                report.stalled = true
                Log.processing.error("Processing stalled: two stages that timed out have not returned")
                return .stop
            }
            return .next
        case .interrupted:
            report.interrupted += 1
            return .stop
        }
    }

    /// Logs what the rules of one saved text write did: fixed codes and counts only (T11); names and patterns are
    /// user data.
    private static func log(_ fill: RuleFill) {
        if fill.invalid > 0 {
            Log.processing.notice("Matching rules skipped: regex.invalid \(fill.invalid, privacy: .public)")
        }
        if fill.timedOut > 0 {
            Log.processing.notice("Matching rules skipped: regex.timeout \(fill.timedOut, privacy: .public)")
        }
        if fill.changed { Log.processing.notice("Matching rules: rules.applied") }
        if fill.ambiguous { Log.processing.notice("Matching rules: rules.ambiguous") }
    }

    /// Adds what detection did in a saved write to `report`, and logs it: fixed codes and counts only (T10); a
    /// name, a date or any text of the document is never logged.
    func count(_ fill: DetectionFill, into report: inout ProcessingReport) {
        if fill.correspondent {
            report.detectedCorrespondents += 1
            Log.processing.notice("Detection: detection.correspondent")
        }
        if fill.created {
            report.createdCorrespondents += 1
            Log.processing.notice("Detection: detection.created")
        }
        if fill.date {
            report.detectedDates += 1
            Log.processing.notice("Detection: detection.date")
        }
        if fill.noStash { Log.processing.notice("Detection: detection.noStash") }
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
    /// With `makesThumbnail`, the stage's task renders the thumbnail after the stage returned (the backfill, N3).
    private func runStage(pdfData: Data, attempt: ProcessingFailures.Attempt, makesThumbnail: Bool) async
        -> StageOutcome
    {
        let stage = stage
        return await race(attempt: attempt, counter: failures) { progress in
            var returned = try await stage.process(pdfData: pdfData, progress: progress)
            if makesThumbnail, returned.thumbnail == nil, !Task.isCancelled {
                returned.thumbnail = Thumbnail.make(fromPDF: pdfData)
                progress(1, 1)
            }
            return .returned(returned)
        }
    }

    /// Runs `work` (either kind of stage) in a task of its own, raced by the stall watchdog and `interruptNow()`,
    /// under the one `StageTracker` (T6). `counter` is the one `attempt` was counted in.
    func race(
        attempt: ProcessingFailures.Attempt, counter: ProcessingFailures,
        work: @escaping @Sendable (@escaping ProcessingProgress) async throws -> StageOutcome
    ) async -> StageOutcome {
        let outcome = FirstOutcome()
        let watchdog = StallWatchdog(timeout: stallTimeout, sleep: watchdogSleep) { outcome.resolve(.timedOut) }
        let stages = stages
        let id = stages.begin(attempt: attempt, counter: counter, outcome: outcome)
        // A pause that came before `begin` found no stage to interrupt; it cancelled the run first, so it is seen
        // here, and the stage never starts (review B1 of #120). One that comes after `begin` interrupts the stage.
        if Task.isCancelled {
            _ = stages.cancelBeforeStart(id)
            counter.refund(attempt)
            return .interrupted
        }
        watchdog.kick()
        let task = Task.detached {
            let result: StageOutcome
            do {
                result = try await work { _, _ in watchdog.kick() }
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
        case .returned, .suggested, .threw:
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
    func count(_ outcome: WriteOutcome, into report: inout ProcessingReport) -> Bool {
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

    func write(
        _ kind: Write, _ instanceID: UUID, expecting held: Held, checksText: Bool = false, checksFile: Bool = false,
        fill: MetadataFillStep? = nil, change: (Document) -> Void
    ) -> WriteOutcome {
        Self.write(
            kind, instanceID, expecting: held, in: container, checksText: checksText, checksFile: checksFile,
            beforeCheck: hooks.beforeCheck, fill: fill, change: change)
    }

    private static func log(_ report: ProcessingReport) {
        Log.processing.notice(
            """
            Processing run: done \(report.done, privacy: .public), failed \(report.failed, privacy: .public), \
            failures \(report.failures, privacy: .public), waiting \(report.waiting, privacy: .public), skipped \
            \(report.skipped, privacy: .public), dropped \(report.dropped, privacy: .public), backed off \
            \(report.backedOff, privacy: .public), saves \(report.saves, privacy: .public), timed out \
            \(report.timedOut, privacy: .public), interrupted \(report.interrupted, privacy: .public), stalled \
            \(report.stalled, privacy: .public), thumbnails backfilled \(report.thumbnailsBackfilled, privacy: .public), \
            to classify \(report.toClassify, privacy: .public), classified \(report.classified, privacy: .public), \
            declined \(report.declined, privacy: .public), classification skipped \
            \(report.classificationSkipped, privacy: .public), rules applied \(report.rulesApplied, privacy: .public), \
            rules ambiguous \(report.rulesAmbiguous, privacy: .public), detected correspondents \
            \(report.detectedCorrespondents, privacy: .public), created correspondents \
            \(report.createdCorrespondents, privacy: .public), detected dates \(report.detectedDates, privacy: .public)
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
        /// The classification step (#8) works on the text, not the file: it expects the same text record instead
        /// (`text`, when set) and leaves the file out.
        var checksFile = true
        var text: PersistentIdentifier?

        func matches(_ document: Document) -> Bool {
            document.processingStateRaw == stateRaw && document.processingDeviceID == deviceID
                && document.processingClaimedAt == claimedAt && document.deletedAt == nil
                && (!checksFile || document.file?.persistentModelID == file) && document.text != nil
                && (text == nil || document.text?.persistentModelID == text)
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

    /// Removes the failure counters (the text step's and the classification step's, review N3 of #8), claim sightings,
    /// thumbnail-backfill records and detection stash entries (#11) of documents that are `done` or gone, so the keys
    /// do not grow.
    static func forgetCounters(
        _ counters: [ProcessingFailures], sightings: ClaimSightings, requeue: ProcessingRequeue? = nil,
        stash: DetectionStash? = nil, in container: ModelContainer
    ) throws {
        let backfill = requeue?.thumbnailBackfill ?? []
        let tracked = Array(
            Set(counters.flatMap(\.documents) + sightings.documents + (stash?.documents ?? [])).union(backfill))
        guard !tracked.isEmpty else { return }
        let context = ModelContext(container)
        let documents = try context.fetch(
            FetchDescriptor<Document>(predicate: #Predicate { tracked.contains($0.instanceID) }))
        let open = Set(documents.filter { $0.processingState != .done }.map(\.instanceID))
        let gone = tracked.filter { !open.contains($0) }
        guard !gone.isEmpty else { return }
        for counter in counters { counter.forget(gone) }
        sightings.forget(gone)
        stash?.forget(gone)
        requeue?.forgetThumbnailBackfill(Set(gone).intersection(backfill))
    }

    /// The text result write's rules (plan of #10, §4, N6): the live rule records, read in a context that ends with
    /// the read, evaluated on `text` (the text the write stores), outside the write's window. `nil` when there is no
    /// rule record: the write then fetches no metadata (review N4, `ProcessingSQLTests`). A read that fails is logged,
    /// and the write goes on without rules; "Apply Matching Rules" applies them later.
    static func textWriteRules(
        on text: String, in container: ModelContainer, budget: MatchingBudget = .production
    ) -> TextWriteRules? {
        let rules: [MatchingRule]
        do {
            rules = try MatchingStore.readRules(in: container)
        } catch {
            Log.processing.error("Could not read the matching rules: \(Log.code(of: error), privacy: .public)")
            return nil
        }
        guard !rules.isEmpty else { return nil }
        let outcome = MatchingRules.evaluate(text: text, rules: rules, budget: budget)
        return TextWriteRules(rules: rules, outcome: outcome, text: text, budget: budget)
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

    /// A step of the shared metadata fill in a write (`MetadataFill`, plan of #10 §4a): it changes the fetched
    /// document in the write's context and returns the metadata rows it linked, which the check reads again.
    typealias MetadataFillStep = (Document, ModelContext) throws -> [RowKey: RowState]

    /// One write, steps 1 to 5 of the discipline, without a suspension. With `checksText` the write also changes the
    /// document's text record, and step 4 reads that row again too, by key (`RowState.readText`); with `checksFile`
    /// likewise its file record (`RowState.readFile`; `pdfData` is not compared, `RowState.excluded`). With `fill`
    /// (the text result write's rules) step 3 also runs the fill after `change`, and step 4 reads the metadata rows
    /// it linked again with the document row.
    static func write(
        _ kind: Write, _ instanceID: UUID, expecting held: Held, in container: ModelContainer,
        checksText: Bool = false, checksFile: Bool = false, beforeCheck: (@Sendable (Write) throws -> Void)?,
        fill: MetadataFillStep? = nil, change: (Document) -> Void
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
            let related = try fill?(document, context) ?? [:]
            try beforeCheck?(kind)
            // 4. The rows again, in a second fresh context, every field.
            let key = RowKey(entity: .document, instanceID: instanceID)
            let stored = try RowState.read(Set(related.keys).union([key]), in: container)
            var textUnchanged = true
            if let (textID, textState) = textRead {
                textUnchanged = try RowState.readText(textID, in: container) == textState
            }
            var fileUnchanged = true
            if let (fileID, fileState) = fileRead {
                fileUnchanged = try RowState.readFile(fileID, in: container) == fileState
            }
            guard stored[key] == read, related.allSatisfy({ stored[$0.key] == $0.value }), textUnchanged, fileUnchanged
            else {
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

    /// The write of `retry(_:)`, steps 1 to 5 of the discipline, without a suspension.
    static func retryWrite(
        _ instanceID: UUID, deviceID: String, now: Date, in container: ModelContainer,
        beforeCheck: (@Sendable (Write) throws -> Void)?
    ) -> ProcessingRetryOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let document = try fetch(instanceID, in: context), document.processingState == .failed else {
                return .notFailed
            }
            let read = RowState.capture(document)
            document.processingState = .pending
            document.processingDeviceID = deviceID
            document.processingClaimedAt = now
            try beforeCheck?(.retry)
            let key = RowKey(entity: .document, instanceID: instanceID)
            guard try RowState.read([key], in: container)[key] == read else {
                context.rollback()
                Log.processing.notice("A Try again write met another save of its document and wrote nothing")
                return .metAnotherSave
            }
            try context.save()
            return .queued
        } catch {
            context.rollback()
            Log.processing.error("A Try again write failed: \(Log.code(of: error), privacy: .public)")
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
