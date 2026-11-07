import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// Two devices that hold the same records repair to the same state (plan of #2, part 3). Each device is a
/// store of its own, seeded with the same shared records (same `id`s, `instanceID`s and values) in a different
/// order, plus records each device created offline, which then arrive on the other one (copied over after its
/// own). The repair runs on each store; their canonical dumps (records by `instanceID`, every value except
/// `modifiedAt` and `mergedAt`, references as `instanceID`s) must be equal, and no record may vanish.
struct RepairConvergenceTests {
    /// Synced before: a tag tree, a cycle from two concurrent moves, a tombstone and its keeper, documents.
    static let shared = RepairSnapshot(
        documents: [document(1, correspondent: 10, tags: [2]), document(2, tags: [4, 5]), document(3, type: 40)],
        metadata: [
            tag(1, "Haus"), tag(2, "Strom", parent: 1),
            // Device A moved X under Z, device B Y under X: the cycle X → Z → Y → X.
            tag(3, "X", created: 30, parent: 5), tag(4, "Y", created: 31, parent: 3),
            tag(5, "Z", created: 32, parent: 4),
            correspondent(10, "EnBW alt", mergedInto: 11), correspondent(11, "EnBW"),
            metadata(.documentType, 40, "Rechnung"),
        ],
        blobs: [blob(.file, 60, documentID: 1, linkedTo: 1), blob(.text, 61, documentID: 1, linkedTo: 1)])

    /// Created on device A while offline: "Stadtwerke", a "Tax" tag under Haus, a type, a document using them,
    /// and the text of B's document, which reached A before the document.
    static let deviceA = RepairSnapshot(
        documents: [document(20, correspondent: 21, type: 23, tags: [22])],
        metadata: [
            correspondent(21, "Stadtwerke", created: 100), tag(22, "Tax", created: 100, parent: 1),
            metadata(.documentType, 23, "rechnung", created: 100),
        ],
        blobs: [blob(.text, 24, documentID: 30), blob(.file, 25, documentID: 20, linkedTo: 20)])

    /// Created on device B while offline: the same names, at the same moment (so `instanceID` decides), and a
    /// document whose file arrived on its own.
    static let deviceB = RepairSnapshot(
        documents: [document(30, correspondent: 31, tags: [32])],
        metadata: [correspondent(31, "stadtwerke", created: 100), tag(32, "tax", created: 100, parent: 1)],
        blobs: [blob(.file, 34, documentID: 30), blob(.text, 35, created: 200, documentID: 30)])

    @Test(arguments: 0..<20)
    func twoDevicesRepairToTheSameState(seed: Int) async throws {
        let first = try TemporaryStore()
        let second = try TemporaryStore()
        defer {
            first.remove()
            second.remove()
        }
        try first.seed(Self.shared, order: seed)
        try first.seed(Self.deviceA, order: seed)
        try first.seed(Self.deviceB, order: seed)
        try second.seed(Self.shared, order: seed + 1000)
        try second.seed(Self.deviceB, order: seed + 1000)
        try second.seed(Self.deviceA, order: seed + 1000)

        let one = try await CheckedRepair.run(first)
        let two = try await CheckedRepair.run(second)
        #expect(one.after.canonical == two.after.canonical)
        #expect(!one.plan.isEmpty)
        for repair in [one, two] {
            #expect(repair.after.documents.count == 3 + 1 + 1)
            #expect(repair.after.metadata.count == 8 + 3 + 2)
            #expect(repair.after.blobs.count == 2 + 2 + 2)
        }
        // What the merges decided: the older record or, at the same moment, the smaller `instanceID`.
        let after = one.after
        #expect(after.record(31)?.isLive == false, "Stadtwerke keeps the smaller instanceID")
        #expect(after.document(30)?.correspondent == uuid(21))
        #expect(after.document(30)?.tags == [uuid(22)])
        #expect(after.document(20)?.documentType == uuid(40), "the older Rechnung is the keeper")
        #expect(after.document(1)?.correspondent == uuid(11))
        #expect(after.record(3)?.parentInstanceID == nil, "the cycle's oldest became the root")
        #expect(after.blob(34)?.linkedDocumentInstanceID == uuid(30))
        #expect(after.blob(24)?.linkedDocumentInstanceID == uuid(30), "the older of B's two texts")
        #expect(after.blob(35)?.linkedDocumentInstanceID == nil, "the other stays unlinked, counted")
        #expect(one.report.counts.documentsWithTwoTexts == 1)
    }
}
