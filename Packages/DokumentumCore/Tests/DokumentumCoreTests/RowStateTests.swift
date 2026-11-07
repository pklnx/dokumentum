import CoreData
import DokumentumKit
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// `RowState` holds every field a save can write, so the check before a pass's save compares whole rows
/// (`RepairRun`). A field added to a model later must be added there or named in
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

}
