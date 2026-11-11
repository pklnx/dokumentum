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
    /// When the first fresh claim of another device that this run waited for expires, by this device's clock: the
    /// scheduler runs the queue again then.
    public var nextExpiry: Date?

    public init() {}
}

/// Something that runs the queue once; `ProcessingQueue` in the app, a stub in tests.
public protocol ProcessingRunning: Sendable {
    func run() async -> ProcessingReport
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
/// 3. **the stages**, with no context open (`ProcessingStage`; step 3 has one, `InspectStage`). **The attempt is
///    counted before the stage runs** (`ProcessingFailures`), so a crash or an out-of-memory kill during the stage
///    counts as well: an attempt that never returned stays counted. A stage that returns clears the counter; one
///    that throws keeps its attempt. The third failed attempt writes `.failed`; an attempt beyond the third (the
///    earlier ones never returned) writes `.failed` without running the stage again, so such a PDF cannot crash
///    every launch. `.failed` syncs, but another device whose own counter is below 3 still tries it;
/// 4. **result write**: `pageCount` if it differs and `processingState = .done`.
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
/// **Resume after quit** is the next run: a document left in `.processing` with this device's claim is processed
/// again.
public actor ProcessingQueue: ProcessingRunning {
    /// Test hooks; empty in the app.
    public struct Hooks: Sendable {
        /// Runs once per run after the scan, before the first document is processed.
        public var afterScan: (@Sendable () async -> Void)?
        /// Runs in each write after its fields were set and before the check reads the row again (step 3 to 4):
        /// where a test saves another context's edit, or #56's repair.
        public var beforeCheck: (@Sendable (Write) throws -> Void)?

        public init(
            afterScan: (@Sendable () async -> Void)? = nil, beforeCheck: (@Sendable (Write) throws -> Void)? = nil
        ) {
            self.afterScan = afterScan
            self.beforeCheck = beforeCheck
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
    private let stage: any ProcessingStage
    private let now: @Sendable () -> Date
    private let takeoverInterval: TimeInterval
    private let hooks: Hooks

    public init(
        container: ModelContainer, deviceID: String, failures: ProcessingFailures,
        stage: any ProcessingStage = InspectStage(),
        takeoverInterval: TimeInterval = ProcessingClaimRules.takeoverInterval,
        now: @escaping @Sendable () -> Date = { Date() }, hooks: Hooks = Hooks()
    ) {
        self.container = container
        self.deviceID = deviceID
        self.failures = failures
        self.stage = stage
        self.takeoverInterval = takeoverInterval
        self.now = now
        self.hooks = hooks
    }

    /// One run over every document that is not `done`.
    @discardableResult
    public func run() async -> ProcessingReport {
        var report = ProcessingReport()
        let candidates: [Candidate]
        do {
            try Self.forgetCounters(failures, in: container)
            candidates = try Self.scan(in: container)
        } catch {
            Log.processing.error("Processing scan failed: \(Log.code(of: error), privacy: .public)")
            return report
        }
        if let afterScan = hooks.afterScan { await afterScan() }
        for candidate in candidates {
            let decision = ProcessingClaimRules.decide(
                candidate.input, thisDevice: deviceID, failures: failures.count(for: candidate.instanceID), now: now(),
                takeoverInterval: takeoverInterval)
            switch decision {
            case .skip:
                report.skipped += 1
            case .wait(.claimedElsewhere(let until)):
                report.waiting += 1
                report.nextExpiry = min(report.nextExpiry ?? until, until)
            case .wait:
                report.waiting += 1
            case .process(let claim):
                await process(candidate, claim: claim, into: &report)
            }
        }
        Self.log(report)
        return report
    }

    private func process(
        _ candidate: Candidate, claim: ProcessingDecision.ClaimWrite, into report: inout ProcessingReport
    ) async {
        let id = candidate.instanceID
        let loaded: LoadedFile
        switch Self.loadFile(of: id, in: container) {
        case .file(let file): loaded = file
        case .noData:
            report.waiting += 1
            return
        case .changed:
            report.dropped += 1
            return
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
            guard count(outcome, into: &report) else { return }
            held = Held(
                stateRaw: ProcessingState.processing.storedValue ?? "", deviceID: deviceID, claimedAt: claimedAt,
                file: loaded.file)
        }
        // Counted before the stage: an attempt that never returns (a crash, a memory kill) stays counted.
        let attempts = failures.increment(for: id)
        guard attempts <= ProcessingClaimRules.failureLimit else {
            Log.processing.error(
                "Processing gave up: \(attempts - 1, privacy: .public) attempts on this device never returned")
            let outcome = write(.result, id, expecting: held) { $0.processingState = .failed }
            if count(outcome, into: &report) { report.failed += 1 }
            return
        }
        let result: ProcessingResult
        do {
            result = try await stage.process(pdfData: loaded.data)
        } catch {
            Log.processing.error(
                """
                Processing failed: \(Log.code(of: error), privacy: .public), attempt \(attempts, privacy: .public) \
                on this device
                """)
            guard attempts >= ProcessingClaimRules.failureLimit else {
                report.failures += 1
                return
            }
            let outcome = write(.result, id, expecting: held) { $0.processingState = .failed }
            if count(outcome, into: &report) { report.failed += 1 }
            return
        }
        // The stage returned: this device is not failing on the document.
        failures.remove(id)
        let outcome = write(.result, id, expecting: held) { document in
            if document.pageCount != result.pageCount { document.pageCount = result.pageCount }
            document.processingState = .done
        }
        if count(outcome, into: &report) { report.done += 1 }
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
        _ kind: Write, _ instanceID: UUID, expecting held: Held, change: (Document) -> Void
    ) -> WriteOutcome {
        Self.write(kind, instanceID, expecting: held, in: container, beforeCheck: hooks.beforeCheck, change: change)
    }

    private static func log(_ report: ProcessingReport) {
        Log.processing.notice(
            """
            Processing run: done \(report.done, privacy: .public), failed \(report.failed, privacy: .public), \
            failures \(report.failures, privacy: .public), waiting \(report.waiting, privacy: .public), skipped \
            \(report.skipped, privacy: .public), dropped \(report.dropped, privacy: .public), backed off \
            \(report.backedOff, privacy: .public), saves \(report.saves, privacy: .public)
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

    /// Removes the failure counters of documents that are `done` or gone, so the keys do not grow.
    static func forgetCounters(_ failures: ProcessingFailures, in container: ModelContainer) throws {
        let tracked = failures.documents
        guard !tracked.isEmpty else { return }
        let context = ModelContext(container)
        let documents = try context.fetch(
            FetchDescriptor<Document>(predicate: #Predicate { tracked.contains($0.instanceID) }))
        let open = Set(documents.filter { $0.processingState != .done }.map(\.instanceID))
        for id in tracked where !open.contains(id) { failures.remove(id) }
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

    /// One write, steps 1 to 5 of the discipline, without a suspension.
    static func write(
        _ kind: Write, _ instanceID: UUID, expecting held: Held, in container: ModelContainer,
        beforeCheck: (@Sendable (Write) throws -> Void)?, change: (Document) -> Void
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
            // 3. Only the fields that change.
            change(document)
            try beforeCheck?(kind)
            // 4. The row again, in a second fresh context, every field.
            let key = RowKey(entity: .document, instanceID: instanceID)
            let stored = try RowState.read([key], in: container)
            guard stored[key] == read else {
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
