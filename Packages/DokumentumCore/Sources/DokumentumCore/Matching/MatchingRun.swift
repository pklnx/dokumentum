import DokumentumKit
import Foundation
import SwiftData
import Synchronization

/// "Apply Matching Rules" (plan of #10, §6, T6; maintainer's P3): the rules applied to every document outside the
/// trash that has a text record with non-empty text, in any processing state except `unknown` (review N7). The run
/// never writes the processing state; the text write of a `pending` or `processing` document applies the rules again
/// anyway.
///
/// - **Rules:** read once, then validated and compiled once per run. An invalid rule is reported and skipped. A
///   rule whose regular expression runs out of its budget is skipped for the rest of the run and reported. A rule
///   edited during a run applies from the next run (review N5 b).
/// - **What it writes** is the text write's fill (`MetadataFill.applyRules`, T4): an empty correspondent and type
///   filled, matching tags added (also ones removed by hand, P3), nothing removed or replaced, no `touch()`, and
///   nothing for a document it would not change, so a second run saves nothing.
/// - **Batches of `MatchingLimits.batchSize`**, walked by `instanceID`, each in a fresh context: fetch the documents
///   (never a file or thumbnail) and read their text rows by key (`MatchingRunSQLTests`), evaluate, fill, then check
///   every changed document row and every metadata row it linked again (`RowState.read`) and save once per batch.
///   On a mismatch the batch rolls back and its changed documents are written **one by one** under the same
///   discipline; a document whose own write meets another save again is skipped and counted ("run again"). Nothing
///   is ever written to undo.
/// - **Control:** cancellable between batches, progress after each batch, one run at a time per instance (the app
///   holds one).
/// - **Two devices:** both devices write only through the fill, a deterministic function of the text, the live rules
///   and the document's current fields, so with the same rules they reach the same values and a device that receives
///   the other's result finds nothing to write (T7). An edit on the other device that has not arrived yet can be
///   overwritten by last-writer-wins when a run fills the same field here (review N5 a).
public final class MatchingRun: Sendable {
    /// After each batch: documents handled so far and in all.
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
    }

    /// What a run did. Rule names are the user's data: shown, never logged.
    public struct Report: Sendable, Equatable {
        /// Documents with text the rules were evaluated on.
        public var documents = 0
        /// Documents the run gave a correspondent, a type or tags.
        public var changed = 0
        /// Documents whose write met another save twice: skipped, "run again".
        public var skipped = 0
        /// Documents whose correspondent or type stayed empty because several records matched (P2).
        public var ambiguous = 0
        /// Names of rules that cannot run (an invalid regular expression, a pattern over the limit), sorted.
        public var invalidRules: [String] = []
        /// Names of rules skipped after their regular expression ran out of its budget, sorted.
        public var slowRules: [String] = []
        /// Saves: one per batch that changed something, one per single write after a fallback.
        public var saves = 0
        /// Cancelled between batches: the earlier batches are saved, the later ones untouched.
        public var cancelled = false
        /// The store failed (logged); the batches before are saved.
        public var failed = false

        public init() {}
    }

    /// Where `Hooks.beforeCheck` runs.
    public enum Write: Sendable, Equatable {
        /// The batch's one write.
        case batch
        /// A document's own write after the batch met another save.
        case single
    }

    /// Test hooks; empty in the app.
    public struct Hooks: Sendable {
        /// Runs in each write after its fields were set and before the check reads the rows again: where a test
        /// saves another context's edit.
        public var beforeCheck: (@Sendable (Write) throws -> Void)?
        /// Runs after each batch with the documents handled so far: where a test cancels the run.
        public var afterBatch: (@Sendable (Int) async -> Void)?

        public init(
            beforeCheck: (@Sendable (Write) throws -> Void)? = nil, afterBatch: (@Sendable (Int) async -> Void)? = nil
        ) {
            self.beforeCheck = beforeCheck
            self.afterBatch = afterBatch
        }
    }

    public let container: ModelContainer
    private let budget: MatchingBudget
    private let batchSize: Int
    private let hooks: Hooks
    private let running = Mutex(false)

    /// - Parameters:
    ///   - budget: the regular expressions' budget; the clock in the app.
    ///   - batchSize: documents per batch; `MatchingLimits.batchSize` in the app.
    public init(
        container: ModelContainer, budget: MatchingBudget = .production, batchSize: Int = MatchingLimits.batchSize,
        hooks: Hooks = Hooks()
    ) {
        self.container = container
        self.budget = budget
        self.batchSize = max(1, batchSize)
        self.hooks = hooks
    }

    /// One run over every document with text. `nil` when a run of this instance is going on already. Off the
    /// caller's actor; cancel the calling task to stop it after the current batch.
    @concurrent
    public func run(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Report? {
        guard
            running.withLock({ isRunning in
                defer { isRunning = true }
                return !isRunning
            })
        else { return nil }
        defer { running.withLock { $0 = false } }
        var report = Report()
        let ids: [UUID]
        let rules: [MatchingRule]
        do {
            rules = try MatchingStore.readRules(in: container)
            ids = try Self.scan(in: container)
        } catch {
            Log.processing.error("Matching run could not read the store: \(Log.code(of: error), privacy: .public)")
            report.failed = true
            return report
        }
        let prepared = MatchingRules.Prepared(rules)
        var slow: Set<UUID> = []
        var done = 0
        progress(Progress(done: 0, total: ids.count))
        if !rules.isEmpty {
            for start in stride(from: 0, to: ids.count, by: batchSize) {
                if Task.isCancelled {
                    report.cancelled = true
                    break
                }
                let batch = Array(ids[start..<min(start + batchSize, ids.count)])
                do {
                    try Self.runBatch(
                        batch, rules: prepared, budget: budget, slow: &slow, in: container,
                        beforeCheck: hooks.beforeCheck, into: &report)
                } catch {
                    Log.processing.error("Matching run failed: \(Log.code(of: error), privacy: .public)")
                    report.failed = true
                    break
                }
                done += batch.count
                progress(Progress(done: done, total: ids.count))
                await hooks.afterBatch?(done)
            }
        }
        let names = Dictionary(rules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        report.invalidRules = prepared.invalid.compactMap { names[$0] }.sorted()
        report.slowRules = slow.compactMap { names[$0] }.sorted()
        Self.log(report)
        return report
    }

    // MARK: - The synchronous steps

    /// The `instanceID`s of the documents the run looks at, sorted by `uuidString`: outside the trash, a state other
    /// than `unknown`, a text record linked (`!= nil` reads the link from the document row). Only `Document` rows are
    /// read; whether the text is empty is seen in the batch. Copies sharing an `instanceID` count once.
    static func scan(in container: ModelContainer) throws -> [UUID] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let documents = try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.deletedAt == nil }))
        let ids = Set(documents.filter { $0.processingState != .unknown && $0.text != nil }.map(\.instanceID))
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    /// One batch: fetch, read the texts by key, evaluate, fill, check, one save; on a mismatch the changed documents
    /// one by one. Throws only when the store fails.
    static func runBatch(
        _ ids: [UUID], rules: MatchingRules.Prepared, budget: MatchingBudget, slow: inout Set<UUID>,
        in container: ModelContainer, beforeCheck: (@Sendable (Write) throws -> Void)?, into report: inout Report
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var seen: Set<UUID> = []
        let documents = try RowRecords.fetchDocuments(Set(ids), in: context).filter {
            seen.insert($0.instanceID).inserted && $0.deletedAt == nil && $0.processingState != .unknown
        }
        var outcomes: [UUID: RuleOutcome] = [:]
        var fill = MetadataFill(context: context)
        var read: [RowKey: RowState] = [:]
        for document in documents {
            // By key: the text row of each document, never its file or thumbnail.
            guard let text = document.text?.extractedText, !text.isEmpty else { continue }
            report.documents += 1
            let outcome = rules.evaluate(text: text, budget: budget, skipping: slow)
            slow.formUnion(outcome.timedOut)
            outcomes[document.instanceID] = outcome
            let state = RowState.capture(document)
            let result = try fill.applyRules(outcome, to: document)
            if result.ambiguous { report.ambiguous += 1 }
            if result.changed { read[RowKey(entity: .document, instanceID: document.instanceID)] = state }
        }
        guard !read.isEmpty else { return }
        try beforeCheck?(.batch)
        let rows = read.merging(fill.related) { first, _ in first }
        let stored = try RowState.read(Set(rows.keys), in: container)
        if rows.allSatisfy({ stored[$0.key] == $0.value }) {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            report.saves += 1
            report.changed += read.count
            return
        }
        context.rollback()
        Log.processing.notice("A matching batch met another save; its documents are written one by one")
        for key in read.keys.sorted(by: { $0.instanceID.uuidString < $1.instanceID.uuidString }) {
            guard let outcome = outcomes[key.instanceID] else { continue }
            switch try writeOne(key.instanceID, outcome: outcome, in: container, beforeCheck: beforeCheck) {
            case .saved:
                report.saves += 1
                report.changed += 1
            case .metAnotherSave:
                report.skipped += 1
            case .unchanged:
                break
            }
        }
    }

    enum SingleOutcome: Equatable {
        case saved, unchanged, metAnotherSave
    }

    /// One document's own write under the discipline, with the outcome the batch computed: a fresh context fetches
    /// it, re-checks that the run still applies to it, fills, checks the document row and the linked rows, saves.
    static func writeOne(
        _ instanceID: UUID, outcome: RuleOutcome, in container: ModelContainer,
        beforeCheck: (@Sendable (Write) throws -> Void)?
    ) throws -> SingleOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let document = try RowRecords.fetchDocuments([instanceID], in: context).first,
            document.deletedAt == nil, document.processingState != .unknown, document.text != nil
        else { return .unchanged }
        let state = RowState.capture(document)
        var fill = MetadataFill(context: context)
        guard try fill.applyRules(outcome, to: document).changed else { return .unchanged }
        try beforeCheck?(.single)
        let key = RowKey(entity: .document, instanceID: instanceID)
        let stored = try RowState.read(Set(fill.related.keys).union([key]), in: container)
        guard stored[key] == state, fill.related.allSatisfy({ stored[$0.key] == $0.value }) else {
            context.rollback()
            Log.processing.notice("A matching write met another save of its document and wrote nothing")
            return .metAnotherSave
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return .saved
    }

    /// Counts and fixed codes only (T11).
    private static func log(_ report: Report) {
        Log.processing.notice(
            """
            Matching run: documents \(report.documents, privacy: .public), rules.applied \
            \(report.changed, privacy: .public), skipped \(report.skipped, privacy: .public), rules.ambiguous \
            \(report.ambiguous, privacy: .public), regex.invalid \(report.invalidRules.count, privacy: .public), \
            regex.timeout \(report.slowRules.count, privacy: .public), saves \(report.saves, privacy: .public), \
            cancelled \(report.cancelled, privacy: .public), failed \(report.failed, privacy: .public)
            """)
    }
}
