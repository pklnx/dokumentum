import CoreData
import DokumentumKit
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// `RowState` holds every field a save can write, so the repair's undo after a concurrent save restores whole
/// rows (`ConcurrentSaveWatcher`). A field added to a model later must be added there or named in
/// `RowState.excluded`, or this fails.
struct RowStateTests {
    private static let sample = UUID()

    /// The field names of the row type that holds `entity`.
    private static func captured(_ entity: String) -> Set<String> {
        let date = Date()
        func labels(_ value: Any) -> Set<String> { Set(Mirror(reflecting: value).children.compactMap(\.label)) }
        let blob = labels(
            RowState.BlobRow(id: sample, instanceID: sample, createdAt: date, documentID: nil, document: nil))
        switch entity {
        case "Document":
            return labels(
                RowState.DocumentRow(
                    id: sample, instanceID: sample, title: "", createdAt: date, modifiedAt: date, documentDate: date,
                    isInbox: true, pageCount: 0, fileSize: 0, textSourceRaw: "", processingStateRaw: "",
                    processingDeviceID: "", contentHash: "", originalFileName: "", sourceRaw: "", tags: []))
        case "Tag":
            return labels(RowState.TagRow(id: sample, instanceID: sample, name: "", colorHex: "", createdAt: date))
        case "Correspondent", "DocumentType":
            return labels(RowState.MetadataRow(id: sample, instanceID: sample, name: "", createdAt: date))
        case "DocumentText":
            return blob
        default:
            return blob.subtracting(["extractedText"])
        }
    }

    @Test func everyFieldOfEveryEntityIsCapturedOrExcluded() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: DokumentumSchemaV1.models))
        #expect(Set(model.entities.compactMap(\.name)) == Set(RowState.excluded.keys))
        for entity in model.entities {
            let name = try #require(entity.name)
            let fields = Set(entity.attributesByName.keys).union(entity.relationshipsByName.keys)
            let excluded = RowState.excluded[name] ?? []
            #expect(Self.captured(name).union(excluded) == fields, "\(name)")
            #expect(Self.captured(name).isDisjoint(with: excluded), "\(name)")
        }
    }

    /// A capture restored onto another record of the same kind gives that record the same state.
    @Test func aRestoredRowEqualsItsCapture() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        var source = document(1, correspondent: 10, type: 20, tags: [30, 31])
        (source.sourceRaw, source.processingStateRaw, source.textSourceRaw) = ("fax", "queued", "braille")
        try store.seed(
            RepairSnapshot(
                documents: [source, document(2)],
                metadata: [
                    correspondent(10, "A"), metadata(.documentType, 20, "T"), tag(30, "X"), tag(31, "Y", parent: 30),
                    tag(32, "Z"),
                ],
                blobs: [blob(.text, 40, documentID: 1, linkedTo: 1), blob(.text, 41, documentID: 2)]))
        let context = ModelContext(store.container)
        let keys: Set<RowKey> = [
            RowKey(entity: .document, instanceID: uuid(1)), RowKey(entity: .document, instanceID: uuid(2)),
            RowKey(entity: .text, instanceID: uuid(40)), RowKey(entity: .text, instanceID: uuid(41)),
            RowKey(entity: .tag, instanceID: uuid(31)), RowKey(entity: .tag, instanceID: uuid(32)),
        ]
        let records = try RepairStore.records(keys, in: context)
        let states = RowState.capture(records)
        let first = try #require(states[RowKey(entity: .document, instanceID: uuid(1))])
        let firstTag = try #require(states[RowKey(entity: .tag, instanceID: uuid(31))])
        // Move document 1's state, except its keys, onto document 2, and tag 31's onto tag 32.
        guard case .document(var row) = first, case .tag(var tagRow) = firstTag else { throw RowStateError() }
        (row.id, row.instanceID, row.createdAt) = (uuid(1002), uuid(2), at(2))
        (tagRow.id, tagRow.instanceID, tagRow.createdAt) = (uuid(1032), uuid(32), at(32))
        try RowState.restore(.document(row), to: RowKey(entity: .document, instanceID: uuid(2)), in: records)
        try RowState.restore(.tag(tagRow), to: RowKey(entity: .tag, instanceID: uuid(32)), in: records)
        try context.save()

        let again = try RowState.read(keys, in: store.container)
        #expect(again[RowKey(entity: .document, instanceID: uuid(2))] == .document(row))
        #expect(again[RowKey(entity: .tag, instanceID: uuid(32))] == .tag(tagRow))
    }

    private struct RowStateError: Error {}
}
