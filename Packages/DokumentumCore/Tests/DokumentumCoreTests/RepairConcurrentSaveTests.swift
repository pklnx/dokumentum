import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Synchronization
import Testing

/// I6 against a save that lands inside a pass's own `save()` (review A of #56): `ModelContext.willSave` is
/// posted synchronously on the saving thread before the write, after the pass changed its records, so another
/// context's edit saved there reaches the store between the pass's read and its write. A context writes back
/// the whole row when it saves over a newer row, so without a guard the pass reverts the edit, every field of it.
/// The pass is undone instead (`ConcurrentSaveWatcher`), the edit stays, and the next run repairs again.
struct RepairConcurrentSaveTests {
    /// Runs one repair; at its first save, `edit` runs in another context and saves. Returns the report, and the
    /// store's full snapshot right after the edit.
    private func repair(
        _ store: TemporaryStore, editingInTheWindow edit: @escaping @Sendable (ModelContext) throws -> Void
    ) throws -> (report: RepairReport, afterEdit: RepairSnapshot) {
        let state = Mutex<(started: Bool, snapshot: RepairSnapshot?, error: String?)>((false, nil, nil))
        let observed = ObjectIdentifier(store.container)
        let token = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: nil, queue: nil) {
            notification in
            guard let saving = notification.object as? ModelContext, ObjectIdentifier(saving.container) == observed,
                !state.withLock({ $0.started })
            else { return }
            state.withLock { $0.started = true }
            do {
                let context = ModelContext(store.container)
                try edit(context)
                try context.save()
                let snapshot = try store.full()
                state.withLock { $0.snapshot = snapshot }
            } catch {
                state.withLock { $0.error = "\(error)" }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let report = try RepairRun.perform(in: store.container, now: repairTime, hasCompletedImport: true)
        let (snapshot, error) = state.withLock { ($0.snapshot, $0.error) }
        if let error { Issue.record("the edit failed: \(error)") }
        return (report, try #require(snapshot, "nothing saved in the window"))
    }

    private static func fetch<T: PersistentModel & HasInstanceID>(
        _ type: T.Type, _ instance: Int, in context: ModelContext
    )
        throws -> T
    {
        try #require(try context.fetch(FetchDescriptor<T>()).first { $0.instanceID == uuid(instance) })
    }

    /// The pass left no trace: the store is what the edit left, and the pass is reported undone.
    private func expectUndone(_ store: TemporaryStore, _ report: RepairReport, afterEdit: RepairSnapshot) throws {
        #expect(report.passes.contains { $0.rolledBack }, "\(report.passes)")
        #expect(report.plan.isEmpty, "\(report.plan)")
        #expect(try store.full().sorted == afterEdit.sorted)
    }

    @Test func aTitleSavedOnAMovedDocumentStays() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, afterEdit) = try repair(store) { context in
            try Self.fetch(Document.self, 1, in: context).title = "User title"
        }
        try expectUndone(store, report, afterEdit: afterEdit)
        // The next run, which that save triggers, merges and keeps the title.
        let next = try await CheckedRepair.run(store)
        #expect(next.after.document(1)?.correspondent == uuid(10))
        #expect(try Self.fetch(Document.self, 1, in: ModelContext(store.container)).title == "User title")
    }

    @Test func aCorrespondentChosenDuringAMergeStays() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom"), correspondent(12, "Mine")]))

        let (report, afterEdit) = try repair(store) { context in
            try Self.fetch(Document.self, 1, in: context).correspondent = try Self.fetch(
                Correspondent.self, 12, in: context)
        }
        try expectUndone(store, report, afterEdit: afterEdit)
        #expect(afterEdit.document(1)?.correspondent == uuid(12))
        let next = try await CheckedRepair.run(store)
        #expect(next.after.document(1)?.correspondent == uuid(12), "the user's choice stays")
    }

    @Test func aCorrespondentChosenDuringARepointStays() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10)],
                metadata: [
                    correspondent(10, "Old", mergedInto: 11), correspondent(11, "New"), correspondent(12, "Mine"),
                ]))

        let (report, afterEdit) = try repair(store) { context in
            try Self.fetch(Document.self, 1, in: context).correspondent = try Self.fetch(
                Correspondent.self, 12, in: context)
        }
        try expectUndone(store, report, afterEdit: afterEdit)
        #expect(afterEdit.document(1)?.correspondent == uuid(12))
    }

    @Test func aRenameOfTheLoserStaysAndItStaysLive() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, afterEdit) = try repair(store) { context in
            try Self.fetch(Correspondent.self, 11, in: context).name = "Telekom Business"
        }
        try expectUndone(store, report, afterEdit: afterEdit)
        let after = try store.full()
        #expect(after.record(11)?.name == "Telekom Business")
        #expect(after.record(11)?.isLive == true, "no longer the same name, so no merge")
        #expect(after.document(1)?.correspondent == uuid(11))
        #expect(try await CheckedRepair.run(store).plan.isEmpty)
    }

    /// A save to a row the pass does not write does not undo it.
    @Test func aSaveElsewhereLeavesThePassAlone() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11), document(2)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, _) = try repair(store) { context in
            try Self.fetch(Document.self, 2, in: context).title = "Elsewhere"
        }
        #expect(!report.passes.contains { $0.rolledBack })
        let after = try store.full()
        #expect(after.document(1)?.correspondent == uuid(10))
        #expect(try Self.fetch(Document.self, 2, in: ModelContext(store.container)).title == "Elsewhere")
    }
}
