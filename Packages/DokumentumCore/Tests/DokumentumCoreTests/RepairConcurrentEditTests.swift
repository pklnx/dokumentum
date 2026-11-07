import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// I6, local compare-and-set: a user edit saved between a pass's plan and its save makes the operation it
/// touches skip, and the edit stays (no overwrite). The edit is saved from another context in the hook that
/// runs after planning; the run re-reads the store before it applies anything.
struct RepairConcurrentEditTests {
    /// Runs the repair, making `edit` in a context of its own after `pass` is planned. Checks the invariants
    /// from the state right after the edit, which is what the store's re-read sees.
    private func repair(
        _ store: TemporaryStore, editing pass: RepairPass, _ edit: @escaping (ModelContext) throws -> Void
    ) throws -> (report: RepairReport, after: RepairSnapshot) {
        var afterEdit: RepairSnapshot?
        var editError: (any Error)?
        let report = try RepairRun.perform(in: store.container, now: repairTime, hasCompletedImport: true) {
            planned, _ in
            guard planned == pass, afterEdit == nil else { return }
            do {
                let context = ModelContext(store.container)
                try edit(context)
                try context.save()
                afterEdit = try store.full()
            } catch {
                editError = error
            }
        }
        if let editError { throw editError }
        let before = try #require(afterEdit, "the \(pass) pass was not planned")
        let after = try store.full()
        let violations = RepairInvariants.violations(before: before, plan: report.plan, after: after)
        #expect(violations.isEmpty, "\(violations)")
        return (report, after)
    }

    private func fetch<T: PersistentModel>(_ type: T.Type, _ instance: Int, in context: ModelContext) throws -> T
    where T: HasInstanceID {
        try #require(try context.fetch(FetchDescriptor<T>()).first { $0.instanceID == uuid(instance) })
    }

    @Test func aRepointSkipsWhenTheUserChangedTheReference() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10)],
                metadata: [
                    correspondent(10, "Old", mergedInto: 11), correspondent(11, "New"), correspondent(12, "Mine"),
                ]))

        let (report, after) = try repair(store, editing: .repoint) { context in
            try fetch(Document.self, 1, in: context).correspondent = try fetch(Correspondent.self, 12, in: context)
        }
        #expect(
            report.skipped == [.repoint(reference: .correspondent(document: uuid(1)), from: uuid(10), to: uuid(11))])
        #expect(report.saves == 0)
        #expect(after.document(1)?.correspondent == uuid(12), "the user's choice stays")
    }

    @Test func aMergeSkipsWhenTheUserRenamedARecord() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let (report, after) = try repair(store, editing: .merge) { context in
            try fetch(Correspondent.self, 11, in: context).name = "Telekom Business"
        }
        #expect(report.skipped == [.mergeMetadata(kind: .correspondent, loser: uuid(11), into: uuid(10))])
        #expect(after.record(11)?.isLive == true)
        #expect(after.document(1)?.correspondent == uuid(11))
    }

    @Test func aMakeRootSkipsWhenTheUserMovedTheTag() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1), tag(3, "Elsewhere")]))

        let (report, after) = try repair(store, editing: .cycles) { context in
            try fetch(DokumentumCore.Tag.self, 1, in: context).parent = try fetch(
                DokumentumCore.Tag.self, 3, in: context)
        }
        #expect(report.skipped == [.makeRoot(tag: uuid(1), expectedParent: uuid(2))])
        #expect(after.record(1)?.parentInstanceID == uuid(3), "the user's move stays")
        #expect(after.record(2)?.parentInstanceID == uuid(1))
    }

    @Test func aRelinkSkipsWhenTheDocumentGotABlobMeanwhile() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1)],
                blobs: [blob(.text, 10, documentID: 1), blob(.text, 11, created: 50, documentID: 1)]))

        let (report, after) = try repair(store, editing: .relink) { context in
            try fetch(DocumentText.self, 11, in: context).document = try fetch(Document.self, 1, in: context)
        }
        #expect(report.skipped == [.relink(blob: uuid(10), to: uuid(1))])
        #expect(after.blob(11)?.linkedDocumentInstanceID == uuid(1))
        #expect(after.blob(10)?.linkedDocumentInstanceID == nil)
    }
}

/// The models with an `instanceID`, for fetching one in tests.
protocol HasInstanceID {
    var instanceID: UUID { get }
}

extension Document: HasInstanceID {}
extension Correspondent: HasInstanceID {}
extension DokumentumCore.Tag: HasInstanceID {}
extension DocumentText: HasInstanceID {}
