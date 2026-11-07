import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// Pass 4 on real stores, for files, thumbnails and texts: relink only, never unlink or delete; orphans and
/// doubles are counted.
struct BlobRepairTests {
    /// A blob that arrived before its document stays unlinked, and is linked once the document arrives.
    @Test(arguments: BlobKind.allCases)
    func aBlobThatArrivedEarlyIsRelinkedWhenItsDocumentArrives(kind: BlobKind) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(RepairSnapshot(blobs: [blob(kind, 10, documentID: 1)]))
        let early = try await CheckedRepair.run(store)
        #expect(early.plan.isEmpty, "no document yet")
        #expect(early.report.counts == counts(orphans: kind))

        try store.seed(RepairSnapshot(documents: [document(1)]))
        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.operations == [.relink(blob: uuid(10), to: uuid(1))])
        #expect(repair.after.blob(10)?.linkedDocumentInstanceID == uuid(1))
        #expect(repair.report.counts == RepairCounts())
    }

    /// Two unlinked candidates for one document: the `keeperOrder` minimum is linked, whatever the insertion
    /// order; the other stays unlinked and is counted.
    @Test(arguments: BlobKind.allCases, [false, true])
    func twoCandidatesLinkTheOldest(kind: BlobKind, olderFirst: Bool) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let candidates = [blob(kind, 10, created: 5, documentID: 1), blob(kind, 11, created: 9, documentID: 1)]
        try store.seed(RepairSnapshot(documents: [document(1)], blobs: olderFirst ? candidates : candidates.reversed()))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.operations == [.relink(blob: uuid(10), to: uuid(1))])
        #expect(repair.after.blob(11)?.linkedDocumentInstanceID == nil)
        #expect(repair.report.counts == counts(doubles: kind))
    }

    /// A document that has a blob of that kind gets no second, and nothing is unlinked or deleted: an orphan
    /// and a double stay as they are and are counted.
    @Test(arguments: BlobKind.allCases)
    func orphansAndDoublesStayUntouched(kind: BlobKind) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1)],
                blobs: [
                    blob(kind, 10, documentID: 1, linkedTo: 1), blob(kind, 11, created: 1, documentID: 1),
                    blob(kind, 12, documentID: 7),
                ]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.isEmpty)
        #expect(repair.report.saves == 0)
        #expect(repair.after.blobs.count == 3)
        #expect(repair.report.counts == counts(orphans: kind, doubles: kind))
    }

    /// A file linked to the document does not keep its text from being linked.
    @Test func otherKindsDoNotCompete() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1)],
                blobs: [blob(.file, 10, documentID: 1, linkedTo: 1), blob(.text, 11, documentID: 1)]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.operations == [.relink(blob: uuid(11), to: uuid(1))])
    }

    private func counts(orphans: BlobKind? = nil, doubles: BlobKind? = nil) -> RepairCounts {
        var counts = RepairCounts()
        switch orphans {
        case .file: counts.orphanFiles = 1
        case .thumbnail: counts.orphanThumbnails = 1
        case .text: counts.orphanTexts = 1
        case nil: break
        }
        switch doubles {
        case .file: counts.documentsWithTwoFiles = 1
        case .thumbnail: counts.documentsWithTwoThumbnails = 1
        case .text: counts.documentsWithTwoTexts = 1
        case nil: break
        }
        return counts
    }
}
