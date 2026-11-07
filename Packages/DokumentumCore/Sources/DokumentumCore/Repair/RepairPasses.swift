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
/// longer held (I6; the next run plans them again), and the counts of what nothing acts on.
public struct RepairReport: Sendable, Equatable {
    public struct PassResult: Sendable, Equatable {
        public var pass: RepairPass
        public var applied: [RepairOperation]
        public var skipped: [RepairOperation]
    }

    /// In the order they ran; passes 2 and 3 repeat while one of them changes something.
    public var passes: [PassResult] = []
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
/// Per pass it reads the light snapshot (`RepairStore`), asks `RepairPlanner`, and, only if the plan is not
/// empty, applies it in one transaction: a fresh context reads the store again right before the save, the
/// plan is applied to that read with `RepairPlan.apply`, whose preconditions are I6's compare-and-set (the
/// reference still holds the planned value, source and target are present and as live as planned, …), and
/// only the operations it applied change the records (`MergeApplier`). An operation whose precondition no
/// longer holds is skipped and planned again by the next run. A pass that applies nothing does not save, so a
/// run on repaired data writes nothing and its own save does not start another (I7).
public enum RepairRun {
    /// Called after a pass is planned and before its fresh read; tests change the store here (I6).
    public typealias AfterPlanning = (RepairPass, RepairPlan) -> Void

    public static func perform(
        in container: ModelContainer,
        now: Date,
        hasCompletedImport: Bool,
        afterPlanning: AfterPlanning = { _, _ in }
    ) throws -> RepairReport {
        var report = RepairReport()
        var state = try RepairStore.snapshot(in: ModelContext(container))

        func run(_ pass: RepairPass, _ plan: RepairPlan) throws -> Bool {
            guard !plan.isEmpty else { return false }
            afterPlanning(pass, plan)
            let context = ModelContext(container)
            let current = try RepairStore.read(in: context)
            let application = plan.apply(to: current.snapshot, now: now)
            for operation in application.applied {
                try MergeApplier.apply(operation, to: current.records, now: now)
            }
            if !application.applied.isEmpty {
                try context.save()
                report.saves += 1
            }
            state = application.snapshot
            report.passes.append(.init(pass: pass, applied: application.applied, skipped: application.skipped))
            return !application.applied.isEmpty
        }

        _ = try run(.repoint, RepairPlanner.repointReferences(in: state))
        // As in `RepairPlanner.plan`: breaking a cycle can make two tags siblings of the same name.
        var changed = true
        while changed {
            let merged = try run(.merge, RepairPlanner.mergeSameNames(in: state))
            let broken = try run(.cycles, RepairPlanner.breakCycles(in: state))
            changed = merged || broken
        }
        _ = try run(.relink, RepairPlanner.relinkBlobs(in: state))
        let context = RepairContext(now: now, hasCompletedImport: hasCompletedImport)
        _ = try run(.revive, RepairPlanner.reviveTombstones(in: state, context: context))
        report.counts = RepairPlanner.counts(in: state)
        return report
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
