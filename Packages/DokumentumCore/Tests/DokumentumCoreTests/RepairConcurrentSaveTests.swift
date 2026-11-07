import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Synchronization
import Testing

/// I6 against a save that lands while a pass holds its rows (reviews A and B of #56): after the pass read and
/// changed its records, and before its save. A context writes back the whole row when it saves over a newer row,
/// so the pass checks its rows right before the save. If another save changed one, the pass writes nothing, the
/// edit stays, and the next run plans again. The edit is saved in `RepairRun`'s `beforeCheck` hook.
struct RepairConcurrentSaveTests {
    /// Runs one repair; when the first pass that has something to write reaches its check, `edit` runs and
    /// saves. Returns the report and the store's full snapshot right after the edit.
    private func repair(
        _ store: TemporaryStore, editingInTheWindow edit: @escaping (ModelContainer) throws -> Void
    ) throws -> (report: RepairReport, afterEdit: RepairSnapshot) {
        var afterEdit: RepairSnapshot?
        let report = try RepairRun.perform(
            in: store.container, now: repairTime, hasCompletedImport: true,
            beforeCheck: { _ in
                guard afterEdit == nil else { return }
                try edit(store.container)
                afterEdit = try store.full()
            })
        return (report, try #require(afterEdit, "no pass reached its check"))
    }

    /// Saves `change` from a context of its own.
    private static func saving(_ change: @escaping (ModelContext) throws -> Void) -> (ModelContainer) throws -> Void {
        { container in
            let context = ModelContext(container)
            try change(context)
            try context.save()
        }
    }

    private static func fetch<T: PersistentModel & HasInstanceID>(
        _ type: T.Type, _ instance: Int, in context: ModelContext
    )
        throws -> T
    {
        try #require(try context.fetch(FetchDescriptor<T>()).first { $0.instanceID == uuid(instance) })
    }

    /// The pass wrote nothing: the store is what the edit left, and the pass is reported as having met it.
    private func expectSkipped(_ store: TemporaryStore, _ report: RepairReport, afterEdit: RepairSnapshot) throws {
        #expect(report.passes.contains { $0.metAnotherSave }, "\(report.passes)")
        #expect(report.plan.isEmpty, "\(report.plan)")
        #expect(report.saves == 0)
        #expect(try store.full().sorted == afterEdit.sorted)
    }

    @Test func aTitleSavedOnAMovedDocumentStays() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, afterEdit) = try repair(
            store,
            editingInTheWindow: Self.saving { try Self.fetch(Document.self, 1, in: $0).title = "User title" })
        try expectSkipped(store, report, afterEdit: afterEdit)
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

        let (report, afterEdit) = try repair(
            store,
            editingInTheWindow: Self.saving {
                try Self.fetch(Document.self, 1, in: $0).correspondent = try Self.fetch(Correspondent.self, 12, in: $0)
            })
        try expectSkipped(store, report, afterEdit: afterEdit)
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

        let (report, afterEdit) = try repair(
            store,
            editingInTheWindow: Self.saving {
                try Self.fetch(Document.self, 1, in: $0).correspondent = try Self.fetch(Correspondent.self, 12, in: $0)
            })
        try expectSkipped(store, report, afterEdit: afterEdit)
        #expect(afterEdit.document(1)?.correspondent == uuid(12))
    }

    @Test func aRenameOfTheLoserStaysAndItStaysLive() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, afterEdit) = try repair(
            store,
            editingInTheWindow: Self.saving {
                try Self.fetch(Correspondent.self, 11, in: $0).name = "Telekom Business"
            })
        try expectSkipped(store, report, afterEdit: afterEdit)
        let after = try store.full()
        #expect(after.record(11)?.name == "Telekom Business")
        #expect(after.record(11)?.isLive == true, "no longer the same name, so no merge")
        #expect(after.document(1)?.correspondent == uuid(11))
        #expect(try await CheckedRepair.run(store).plan.isEmpty)
    }

    /// A record the pass names but does not write: the keeper of a merge that moves no document. Renamed in the
    /// window, the merge's precondition (same name) no longer holds, so the pass must not save.
    @Test func aRenameOfTheKeeperSkipsAMergeThatWritesOnlyTheLoser() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(RepairSnapshot(metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, afterEdit) = try repair(
            store,
            editingInTheWindow: Self.saving { try Self.fetch(Correspondent.self, 10, in: $0).name = "Telekom AG" })
        try expectSkipped(store, report, afterEdit: afterEdit)
        #expect(try store.full().record(11)?.isLive == true)
    }

    /// Two other saves in one window, to two rows the pass writes (review A's undo probe, adapted; review B's
    /// B12): both stay.
    @Test func twoSavesInOneWindowBothStay() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11), document(2, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom"), correspondent(12, "Mine")]))

        let (report, afterEdit) = try repair(store) { container in
            try Self.saving { try Self.fetch(Document.self, 1, in: $0).title = "Edit 2" }(container)
            try Self.saving { context in
                try Self.fetch(Document.self, 1, in: context).title = "Edit 3"
                let second = try Self.fetch(Document.self, 2, in: context)
                second.title = "Edit 3 on doc 2"
                second.correspondent = try Self.fetch(Correspondent.self, 12, in: context)
            }(container)
        }
        try expectSkipped(store, report, afterEdit: afterEdit)
        let context = ModelContext(store.container)
        #expect(try Self.fetch(Document.self, 1, in: context).title == "Edit 3")
        #expect(try Self.fetch(Document.self, 2, in: context).title == "Edit 3 on doc 2")
        #expect(try Self.fetch(Document.self, 2, in: context).correspondent?.instanceID == uuid(12))
    }

    /// The user's edit saved from the main context, on the main thread (review B's B11), as the app's UI saves.
    @Test func aSaveFromTheMainContextStays() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, afterEdit) = try repair(store) { container in
            var failure: String?
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    do {
                        let context = container.mainContext
                        try Self.fetch(Document.self, 1, in: context).title = "From the main context"
                        try context.save()
                    } catch {
                        failure = "\(error)"
                    }
                }
            }
            if let message = failure { Issue.record("the main context did not save: \(message)") }
        }
        try expectSkipped(store, report, afterEdit: afterEdit)
        #expect(try Self.fetch(Document.self, 1, in: ModelContext(store.container)).title == "From the main context")
    }

    /// A blob another save links to a document the pass moves (review A's D2): the link is on the document's row
    /// as far as the pass can see, so the pass skips and the link stays.
    @Test(arguments: BlobKind.allCases)
    func aBlobLinkedDuringAMergeStays(kind: BlobKind) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        // Its `documentID` names another document, so pass 4 never links it to document 1 itself.
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")],
                blobs: [blob(kind, 30, documentID: 999)]))

        let (report, afterEdit) = try repair(
            store,
            editingInTheWindow: Self.saving { context in
                let target = try Self.fetch(Document.self, 1, in: context)
                switch kind {
                case .file: try Self.fetch(DocumentFile.self, 30, in: context).document = target
                case .thumbnail: try Self.fetch(DocumentThumbnail.self, 30, in: context).document = target
                case .text: try Self.fetch(DocumentText.self, 30, in: context).document = target
                }
            })
        try expectSkipped(store, report, afterEdit: afterEdit)
        #expect(try store.full().blob(30)?.linkedDocumentInstanceID == uuid(1))
        let next = try await CheckedRepair.run(store)
        #expect(next.after.blob(30)?.linkedDocumentInstanceID == uuid(1), "and stays after the merge")
        #expect(next.after.document(1)?.correspondent == uuid(10))
    }

    /// Another save links a second text to the document the relink pass is linking a text to: that link stays,
    /// and the pass's text stays unlinked (counted as a double).
    @Test func aTextLinkedDuringARelinkStays() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1)],
                blobs: [blob(.text, 10, documentID: 1), blob(.text, 11, created: 50, documentID: 1)]))

        let (report, afterEdit) = try repair(
            store,
            editingInTheWindow: Self.saving { context in
                try Self.fetch(DocumentText.self, 11, in: context).document = try Self.fetch(
                    Document.self, 1, in: context)
            })
        try expectSkipped(store, report, afterEdit: afterEdit)
        let after = try store.full()
        #expect(after.blob(11)?.linkedDocumentInstanceID == uuid(1))
        #expect(after.blob(10)?.linkedDocumentInstanceID == nil)
        #expect(RepairPlanner.counts(in: after).documentsWithTwoTexts == 1)
    }

    /// A save to a row the pass neither writes nor names leaves the pass alone.
    @Test func aSaveElsewhereLeavesThePassAlone() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11), document(2)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom"), tag(20, "Unrelated")]))

        let (report, _) = try repair(
            store,
            editingInTheWindow: Self.saving { context in
                try Self.fetch(Document.self, 2, in: context).title = "Elsewhere"
                try Self.fetch(DokumentumCore.Tag.self, 20, in: context).name = "Renamed"
            })
        #expect(!report.passes.contains { $0.metAnotherSave })
        #expect(report.saves == 1)
        let after = try store.full()
        #expect(after.document(1)?.correspondent == uuid(10))
        #expect(after.record(20)?.name == "Renamed")
        #expect(try Self.fetch(Document.self, 2, in: ModelContext(store.container)).title == "Elsewhere")
    }

    /// Two devices that hold the same records still converge when one of them meets a save in a window: it skips,
    /// re-plans on the next run, and ends where the other device ended without interruption.
    @Test func aSkippedPassConvergesOnTheNextRun() async throws {
        let first = try TemporaryStore()
        let second = try TemporaryStore()
        defer {
            first.remove()
            second.remove()
        }
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 11, tags: [21]), document(2, tags: [20])],
            metadata: [
                correspondent(10, "Telekom"), correspondent(11, "telekom"), tag(20, "Tax"), tag(21, "tax"),
                tag(22, "A", parent: 23), tag(23, "B", parent: 22),
            ])
        try first.seed(state)
        try second.seed(state, order: 7)

        // The user edits a title (not part of the canonical dump) on a document the merge moves.
        let (report, _) = try repair(
            first,
            editingInTheWindow: Self.saving { try Self.fetch(Document.self, 1, in: $0).title = "Edited" })
        #expect(report.passes.contains { $0.metAnotherSave })
        _ = try await CheckedRepair.run(first)
        _ = try await CheckedRepair.run(second)
        #expect(try first.full().canonical == second.full().canonical)
    }
}
