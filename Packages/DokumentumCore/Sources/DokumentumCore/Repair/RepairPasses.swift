import DokumentumKit
import Foundation
import SwiftData

/// The passes of one repair run, in their order (plan of #2, "Repair passes").
public enum RepairPass: String, Sendable, CaseIterable {
    /// 1: references to tombstones go to the chain's live end.
    case repoint
    /// 2: live metadata of the same name merges; the loser becomes a tombstone.
    case merge
    /// 3: every tag cycle loses its oldest member's parent.
    case cycles
    /// 4: unlinked blobs are linked to their document.
    case relink
    /// 5: a loop's minimum, or a tombstone whose chain end stayed missing, is revived.
    case revive
}

/// What one run did: per pass the operations it applied and those it skipped because their precondition no
/// longer held or another save met the pass (I6; the next run plans them again), the passes that failed, and the
/// counts of what nothing acts on.
public struct RepairReport: Sendable, Equatable {
    public struct PassResult: Sendable, Equatable {
        public var pass: RepairPass
        public var applied: [RepairOperation]
        public var skipped: [RepairOperation]
        /// Another save changed a row this pass wrote, between its read and its write: the pass was undone, its
        /// operations are in `skipped`, and the rows hold that save's values (`ConcurrentSaveWatcher`).
        public var rolledBack = false
    }

    /// In the order they ran; passes 2 and 3 repeat while one of them changes something.
    public var passes: [PassResult] = []
    /// Passes that threw (logged): the run went on with the next pass, and the next run tries again.
    public var failed: [RepairPass] = []
    /// Orphans, documents with two blobs of one kind, `id` groups and tombstones, after the run.
    public var counts = RepairCounts()
    /// How often the run saved: once per pass that applied something (twice if it was rolled back), never
    /// otherwise (I7).
    public var saves = 0

    public init() {}

    /// Every applied operation in order: the plan the run carried out, for `RepairInvariants`.
    public var plan: RepairPlan { RepairPlan(passes.flatMap(\.applied)) }
    public var skipped: [RepairOperation] { passes.flatMap(\.skipped) }
}

/// One repair run on a store: synchronous, so a test can record its SQL on one thread (`RepairSQLTests`);
/// the app runs it through `RepairRunner`, off the main actor.
///
/// It reads the light snapshot once (`RepairStore`) and plans each pass on it with `RepairPlanner`, carrying the
/// changes forward. A pass with a non-empty plan runs in one transaction:
/// 1. A new context reads only what the plan writes (`RepairStore.touched(by:in:)`), and `RepairPlan.apply` on
///    that read decides which operations still apply; its preconditions are I6's compare-and-set (the reference
///    still holds the planned value, source and target are present and as live as planned, …). Only those change
///    the records (`MergeApplier`); a skipped one is planned again by the next run.
/// 2. From that read to the save, `ConcurrentSaveWatcher` keeps what every other save leaves in those rows. A
///    context writes back whole rows when it saves over a newer row, so after the save the pass compares: if
///    another save changed a row the pass wrote, the pass is undone in a second save. Those rows get that save's
///    values, the others what the pass read, and the next run (which that save triggers) plans again. I6 is
///    therefore kept except in one residual window, stated in `ConcurrentSaveWatcher`: a save on another thread
///    that commits before the pass's write but is handled only after it.
///
/// A pass that applies nothing does not save, so a run on repaired data writes nothing and its own save does not
/// start another (I7). A pass that throws is logged and skipped; the run goes on with the next.
public enum RepairRun {
    /// Called after a pass is planned and before its read; tests change the store here (I6), or throw.
    public typealias AfterPlanning = (RepairPass, RepairPlan) throws -> Void

    public static func perform(
        in container: ModelContainer,
        now: Date,
        hasCompletedImport: Bool,
        afterPlanning: AfterPlanning = { _, _ in }
    ) throws -> RepairReport {
        var report = RepairReport()
        var state = try RepairStore.snapshot(in: ModelContext(container))

        func run(_ pass: RepairPass, _ plan: RepairPlan) -> Bool {
            guard !plan.isEmpty else { return false }
            do {
                try afterPlanning(pass, plan)
                let result = try transaction(plan, in: container, now: now)
                report.saves += result.saves
                if !result.rolledBack { state = overlay(state, with: result.snapshot) }
                report.passes.append(
                    .init(
                        pass: pass, applied: result.rolledBack ? [] : result.applied,
                        skipped: result.rolledBack ? result.applied + result.skipped : result.skipped,
                        rolledBack: result.rolledBack))
                return !result.rolledBack && !result.applied.isEmpty
            } catch {
                Log.repair.error(
                    "Repair pass \(pass.rawValue, privacy: .public) failed: \(Log.code(of: error), privacy: .public)")
                report.failed.append(pass)
                return false
            }
        }

        _ = run(.repoint, RepairPlanner.repointReferences(in: state))
        // As in `RepairPlanner.plan`: breaking a cycle can make two tags siblings of the same name.
        var changed = true
        while changed {
            let merged = run(.merge, RepairPlanner.mergeSameNames(in: state))
            let broken = run(.cycles, RepairPlanner.breakCycles(in: state))
            changed = merged || broken
        }
        _ = run(.relink, RepairPlanner.relinkBlobs(in: state))
        let context = RepairContext(now: now, hasCompletedImport: hasCompletedImport)
        _ = run(.revive, RepairPlanner.reviveTombstones(in: state, context: context))
        report.counts = RepairPlanner.counts(in: state)
        return report
    }

    private struct Transaction {
        var applied: [RepairOperation] = []
        var skipped: [RepairOperation] = []
        var snapshot = RepairSnapshot()
        var saves = 0
        var rolledBack = false
    }

    private static func transaction(_ plan: RepairPlan, in container: ModelContainer, now: Date) throws -> Transaction {
        let watcher = ConcurrentSaveWatcher(container: container)
        defer { watcher.stop() }
        let context = ModelContext(container)
        let current = try RepairStore.touched(by: plan, in: context)
        let read = RowState.capture(current.records)
        watcher.watch(Set(read.keys))
        let application = plan.apply(to: current.snapshot, now: now)
        var result = Transaction(
            applied: application.applied, skipped: application.skipped, snapshot: application.snapshot)
        guard !application.applied.isEmpty else { return result }
        for operation in application.applied {
            try MergeApplier.apply(operation, to: current.records, now: now)
        }
        let written = RowState.capture(current.records)
        // Rows whose captured values changed, and rows Core Data writes for an inverse relationship only.
        let dirty = Set(read.keys.filter { read[$0] != written[$0] }).union(
            context.changedModelsArray.compactMap(key(of:)))
        try context.save()
        result.saves = 1
        watcher.stop()
        guard let conflicts = watcher.conflicts(read: read, written: written) else {
            throw ConcurrentSaveUnknown()
        }
        let met = conflicts.filter { dirty.contains($0.key) }
        guard !met.isEmpty else { return result }

        // Undo the pass: what the other save left where it met the pass, what the pass read everywhere else.
        let undo = ModelContext(container)
        let records = try RepairStore.records(dirty, in: undo)
        for key in dirty {
            guard let target = met[key] ?? read[key] else { continue }
            try RowState.restore(target, to: key, in: records)
        }
        try undo.save()
        result.saves = 2
        result.rolledBack = true
        Log.repair.notice("A repair pass met another save on \(met.count, privacy: .public) rows and was undone")
        return result
    }

    /// A capture of the watcher failed, so whether another save met the pass is not known. The pass is saved;
    /// the run reports it as failed.
    struct ConcurrentSaveUnknown: Error {}

    private static func key(of model: any PersistentModel) -> RowKey? {
        switch model {
        case let document as Document: RowKey(entity: .document, instanceID: document.instanceID)
        case let tag as Tag: RowKey(entity: .tag, instanceID: tag.instanceID)
        case let record as Correspondent: RowKey(entity: .correspondent, instanceID: record.instanceID)
        case let record as DocumentType: RowKey(entity: .documentType, instanceID: record.instanceID)
        case let file as DocumentFile: RowKey(entity: .file, instanceID: file.instanceID)
        case let thumbnail as DocumentThumbnail: RowKey(entity: .thumbnail, instanceID: thumbnail.instanceID)
        case let text as DocumentText: RowKey(entity: .text, instanceID: text.instanceID)
        default: nil
        }
    }

    /// `state` with the records of `partial` in place of its own: what the run plans the next pass on.
    static func overlay(_ state: RepairSnapshot, with partial: RepairSnapshot) -> RepairSnapshot {
        func replaced<T: KeeperOrdered>(_ old: [T], _ new: [T]) -> [T] {
            let byID = Dictionary(new.map { ($0.instanceID, $0) }, uniquingKeysWith: { first, _ in first })
            var seen: Set<UUID> = []
            return old.map { record in
                guard seen.insert(record.instanceID).inserted, let fresh = byID[record.instanceID] else {
                    return record
                }
                return fresh
            }
        }
        return RepairSnapshot(
            documents: replaced(state.documents, partial.documents),
            metadata: replaced(state.metadata, partial.metadata), blobs: relinked(state.blobs, partial.blobs))
    }

    /// A blob the pass linked stays listed, now with its link; the planner treats it like a kind in the
    /// document's `linkedBlobs`.
    private static func relinked(_ old: [BlobSnapshot], _ new: [BlobSnapshot]) -> [BlobSnapshot] {
        let linked = Set(new.filter { $0.linkedDocumentInstanceID != nil }.map(\.instanceID))
        return old.filter { !linked.contains($0.instanceID) } + new.filter { $0.linkedDocumentInstanceID != nil }
    }
}

/// Runs the repair off the main actor, one run at a time per call (`RepairScheduler` keeps runs from
/// overlapping). Logs each run's report at `.notice` in `Log.repair`.
///
/// A model actor written out instead of `@ModelActor`, whose generated `init` takes no clock. Each pass reads
/// through a fresh `ModelContext` (`RepairRun`), so no context caches values from an earlier read.
public actor RepairRunner: ModelActor, RepairRunning {
    public nonisolated let modelExecutor: any ModelExecutor
    public nonisolated let modelContainer: ModelContainer
    /// The time of a run; the app's clock unless a test passes its own.
    private let clock: @Sendable () -> Date

    public init(modelContainer: ModelContainer, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.modelContainer = modelContainer
        self.clock = clock
    }

    /// One run; `nil` if reading or saving failed (logged). A failed pass is not saved; the next run tries again.
    @discardableResult
    public func run(hasCompletedImport: Bool) -> RepairReport? {
        do {
            let report = try RepairRun.perform(in: modelContainer, now: clock(), hasCompletedImport: hasCompletedImport)
            Self.log(report)
            return report
        } catch {
            Log.repair.error("Repair run failed: \(Log.code(of: error), privacy: .public)")
            return nil
        }
    }

    private static func log(_ report: RepairReport) {
        let applied = report.passes.map { "\($0.pass.rawValue) \($0.applied.count)" }.joined(separator: ", ")
        let counts = report.counts
        Log.repair.notice(
            """
            Repair run: applied [\(applied, privacy: .public)], skipped \(report.skipped.count, privacy: .public), \
            saves \(report.saves, privacy: .public); orphans \(counts.orphanFiles, privacy: .public)/\
            \(counts.orphanThumbnails, privacy: .public)/\(counts.orphanTexts, privacy: .public), doubles \
            \(counts.documentsWithTwoFiles, privacy: .public)/\(counts.documentsWithTwoThumbnails, privacy: .public)/\
            \(counts.documentsWithTwoTexts, privacy: .public), id groups \
            \(counts.idGroupsWithSeveralRecords, privacy: .public), tombstones \(counts.tombstones, privacy: .public)
            """)
    }
}
