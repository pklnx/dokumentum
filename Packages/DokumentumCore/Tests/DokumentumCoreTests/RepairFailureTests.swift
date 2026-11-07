import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// A pass that fails is logged and skipped; the run goes on with the next pass, so one bad record does not stop
/// every later repair (review A of #56, N2).
struct RepairFailureTests {
    private struct Planted: Error {}

    @Test func aFailingPassIsSkippedAndTheNextPassesRun() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10)],
                metadata: [
                    correspondent(10, "Old", mergedInto: 11), correspondent(11, "New"), tag(20, "A"), tag(21, "a"),
                ],
                blobs: [blob(.text, 30, documentID: 1)]))

        let report = try RepairRun.perform(in: store.container, now: repairTime, hasCompletedImport: true) { pass, _ in
            if pass == .repoint { throw Planted() }
        }
        #expect(report.failed == [.repoint])
        #expect(report.passes.map(\.pass) == [.merge, .relink], "\(report.passes)")
        let after = try store.full()
        #expect(after.document(1)?.correspondent == uuid(10), "the failed pass changed nothing")
        #expect(after.record(21)?.isLive == false)
        #expect(after.blob(30)?.linkedDocumentInstanceID == uuid(1))
    }

    /// Two correspondents share an `instanceID` (a copied record): the pass's check and its write meet the same
    /// record, the first one read, and the run completes.
    @Test func recordsSharingAnInstanceIDDoNotStopTheRun() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10)],
                metadata: [correspondent(10, "Old", mergedInto: 11), correspondent(11, "New")],
                blobs: [blob(.text, 30, documentID: 1)]))
        // The copy: same `instanceID` as 11, its own `id`.
        let context = ModelContext(store.container)
        let copy = Correspondent(name: "New", createdAt: at(11))
        copy.instanceID = uuid(11)
        context.insert(copy)
        try context.save()

        let report = try #require(
            await RepairRunner(modelContainer: store.container, clock: { repairTime }).run(hasCompletedImport: true))
        #expect(report.failed.isEmpty)
        let after = try store.full()
        #expect(after.blob(30)?.linkedDocumentInstanceID == uuid(1), "the later passes ran")
        #expect(after.document(1)?.correspondent == uuid(11))
        // The record the check was made on (the first read, the original) is the one written.
        let stored = try #require(
            try ModelContext(store.container).fetch(FetchDescriptor<Document>()).first { $0.instanceID == uuid(1) })
        #expect(stored.correspondent?.id == uuid(1011))
    }
}
