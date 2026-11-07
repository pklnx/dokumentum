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
/// longer held or another save changed its rows (I6; the next run plans them again), the passes that failed, and
/// the counts of what nothing acts on.
public struct RepairReport: Sendable, Equatable {
    public struct PassResult: Sendable, Equatable {
        public var pass: RepairPass
        public var applied: [RepairOperation]
        public var skipped: [RepairOperation]
        /// Another save changed a row this pass was about to write, or a record its operations name, after the
        /// pass read it: the pass wrote nothing, and its operations are in `skipped`.
        public var metAnotherSave = false
    }

    /// In the order they ran; passes 2 and 3 repeat while one of them changes something.
    public var passes: [PassResult] = []
    /// Passes that threw (logged): the run went on with the next pass, and the next run tries again.
    public var failed: [RepairPass] = []
    /// Orphans, documents with two blobs of one kind, `id` groups and tombstones, after the run.
    public var counts = RepairCounts()
    /// How often the run saved: once per pass that applied something, never otherwise (I7).
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
/// changes forward. A pass with a non-empty plan runs in one transaction, on one principle: **the repair never
/// writes over a row state it has not read; it checks that last, and it never writes to undo.**
/// 1. A new context reads only what the plan touches (`RepairStore.touched(by:in:)`), and `RepairPlan.apply` on
///    that read decides which operations still apply; its preconditions are I6's compare-and-set (the reference
///    still holds the planned value, source and target are present and as live as planned, …). Only those change
///    the records (`MergeApplier`); a skipped one is planned again by the next run.
/// 2. Right before the save, the rows the pass changed (`changedModelsArray`, which includes rows Core Data
///    writes only for an inverse relationship) and the records its operations name are read again in another
///    context (`RowState.read`) and compared with what the pass read, every field. A context writes back the
///    whole row when it saves over a row changed since it read it, so any difference means another save would be
///    overwritten: the pass discards its changes and writes nothing, and the next run (which that save triggers)
///    plans again.
/// 3. Otherwise it saves.
///
/// I6 then holds except for a save to one of those rows that commits between the check's read and the pass's
/// commit: it is overwritten in that row. The window is the check's read plus the save, bounded by the rows the
/// pass writes, not by the archive: measured 0.06 s for a merge moving 300 documents and 0.24 s for 1,500
/// (docs/development/index.md, "Concurrent saves").
///
/// A pass that applies nothing does not save, so a run on repaired data writes nothing and its own save does not
/// start another (I7). A pass that throws is logged and skipped; the run goes on with the next.
public enum RepairRun {
    /// Called after a pass is planned and before its read; tests change the store here (I6), or throw.
    public typealias AfterPlanning = (RepairPass, RepairPlan) throws -> Void
    /// Called after a pass changed its records and before its check; tests save another context's edit here.
    public typealias BeforeCheck = (RepairPass) throws -> Void

    public static func perform(
        in container: ModelContainer,
        now: Date,
        hasCompletedImport: Bool,
        afterPlanning: AfterPlanning = { _, _ in },
        beforeCheck: BeforeCheck = { _ in }
    ) throws -> RepairReport {
        var report = RepairReport()
        var state = try RepairStore.snapshot(in: ModelContext(container))

        func run(_ pass: RepairPass, _ plan: RepairPlan) -> Bool {
            guard !plan.isEmpty else { return false }
            do {
                try afterPlanning(pass, plan)
                let result = try transaction(plan, in: container, now: now) { try beforeCheck(pass) }
                report.saves += result.saved ? 1 : 0
                if result.saved { state = overlay(state, with: result.snapshot) }
                report.passes.append(
                    .init(
                        pass: pass, applied: result.saved ? result.applied : [],
                        skipped: result.saved ? result.skipped : result.applied + result.skipped,
                        metAnotherSave: result.metAnotherSave))
                return result.saved
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
        var saved = false
        var metAnotherSave = false
    }

    private static func transaction(
        _ plan: RepairPlan, in container: ModelContainer, now: Date, beforeCheck: () throws -> Void
    ) throws -> Transaction {
        let context = ModelContext(container)
        let current = try RepairStore.touched(by: plan, in: context)
        let read = RowState.capture(current.records)
        let application = plan.apply(to: current.snapshot, now: now)
        var result = Transaction(
            applied: application.applied, skipped: application.skipped, snapshot: application.snapshot)
        guard !application.applied.isEmpty else { return result }
        for operation in application.applied {
            try MergeApplier.apply(operation, to: current.records, now: now)
        }
        try beforeCheck()
        let checked = Set(context.changedModelsArray.compactMap(key(of:))).union(named(by: application.applied))
        let stored = try RowState.read(checked, in: container)
        if checked.contains(where: { stored[$0] != read[$0] }) {
            context.rollback()
            result.metAnotherSave = true
            Log.repair.notice("A repair pass met another save of its rows and wrote nothing")
            return result
        }
        try context.save()
        result.saved = true
        return result
    }

    /// The records an operation's precondition reads, whether or not it writes them.
    private static func named(by operations: [RepairOperation]) -> Set<RowKey> {
        func metadata(_ kind: MetadataKind, _ id: UUID) -> RowKey {
            switch kind {
            case .correspondent: RowKey(entity: .correspondent, instanceID: id)
            case .documentType: RowKey(entity: .documentType, instanceID: id)
            case .tag: RowKey(entity: .tag, instanceID: id)
            }
        }
        func kind(of reference: RepairReference) -> MetadataKind {
            switch reference {
            case .correspondent: .correspondent
            case .documentType: .documentType
            case .tag, .parent: .tag
            }
        }
        var keys: Set<RowKey> = []
        for operation in operations {
            switch operation {
            case .repoint(let reference, let from, let to):
                keys.formUnion([metadata(kind(of: reference), from), metadata(kind(of: reference), to)])
                switch reference {
                case .correspondent(let document), .documentType(let document), .tag(let document):
                    keys.insert(RowKey(entity: .document, instanceID: document))
                case .parent(let tag):
                    keys.insert(RowKey(entity: .tag, instanceID: tag))
                }
            case .mergeMetadata(let kind, let loser, let keeper):
                keys.formUnion([metadata(kind, loser), metadata(kind, keeper)])
            case .makeRoot(let tag, let parent):
                keys.formUnion([RowKey(entity: .tag, instanceID: tag), RowKey(entity: .tag, instanceID: parent)])
            case .relink(let blob, let document):
                keys.insert(RowKey(entity: .document, instanceID: document))
                for entity in [RowKey.Entity.file, .thumbnail, .text] {
                    keys.insert(RowKey(entity: entity, instanceID: blob))
                }
            case .revive(let tombstone):
                for kind in MetadataKind.allCases { keys.insert(metadata(kind, tombstone)) }
            }
        }
        return keys
    }

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
