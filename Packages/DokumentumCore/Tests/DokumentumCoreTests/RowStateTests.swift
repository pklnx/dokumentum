import CoreData
import DokumentumKit
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// `RowState` (`Store/RowStates.swift`) holds every field a save can write, so the check before a background
/// writer's save compares whole rows (`RepairRun`, `ProcessingQueue`). A field added to a model later must be added
/// there or named in `RowState.excluded`, or this fails.
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
            return labels(
                RowState.TagRow(
                    id: sample, instanceID: sample, name: "", colorHex: "", createdAt: date, matchModeRaw: "",
                    matchPattern: ""))
        case "Correspondent", "DocumentType":
            return labels(
                RowState.MetadataRow(
                    id: sample, instanceID: sample, name: "", createdAt: date, matchModeRaw: "", matchPattern: ""))
        case "DocumentText":
            return blob
        default:
            return blob.subtracting(["extractedText"])
        }
    }

    /// Checked against the current schema (`DokumentumMigrationPlan.current`), so a new version's fields are
    /// checked without an edit here.
    @Test func everyFieldOfEveryEntityIsCapturedOrExcluded() throws {
        let model = try #require(
            NSManagedObjectModel.makeManagedObjectModel(for: DokumentumMigrationPlan.current.models))
        #expect(Set(model.entities.compactMap(\.name)) == Set(RowState.excluded.keys))
        for entity in model.entities {
            let name = try #require(entity.name)
            let fields = Set(entity.attributesByName.keys).union(entity.relationshipsByName.keys)
            let excluded = RowState.excluded[name] ?? []
            #expect(Self.captured(name).union(excluded) == fields, "\(name)")
            #expect(Self.captured(name).isDisjoint(with: excluded), "\(name)")
        }
    }

    /// The rule fields (#10) are captured with their values, so a rule edited in a background writer's window shows
    /// as a changed row: for a tag, a correspondent and a document type, the captured row holds the record's mode
    /// and pattern, and changing either changes the row.
    @Test func theRuleFieldsAreCapturedWithTheirValues() throws {
        let tag = DokumentumCore.Tag(name: "Strom")
        (tag.matchModeRaw, tag.matchPattern) = ("any", "Strom Stadtwerke")
        let correspondent = Correspondent(name: "Stadtwerke")
        (correspondent.matchModeRaw, correspondent.matchPattern) = ("exact", "Stadtwerke München")
        let type = DocumentType(name: "Rechnung")
        (type.matchModeRaw, type.matchPattern) = ("regex", #"IBAN\s*DE\d{20}"#)

        func tagRule() throws -> [String] {
            guard case .tag(let row) = RowState.capture(tag) else { throw CaptureKindMismatch() }
            return [row.matchModeRaw, row.matchPattern]
        }
        func metadataRule(_ state: RowState) throws -> [String] {
            guard case .metadata(let row) = state else { throw CaptureKindMismatch() }
            return [row.matchModeRaw, row.matchPattern]
        }
        #expect(try tagRule() == ["any", "Strom Stadtwerke"])
        #expect(try metadataRule(RowState.capture(correspondent)) == ["exact", "Stadtwerke München"])
        #expect(try metadataRule(RowState.capture(type)) == ["regex", #"IBAN\s*DE\d{20}"#])

        // An edit of either field changes the captured row.
        let tagBefore = RowState.capture(tag)
        tag.matchPattern = "Strom"
        #expect(RowState.capture(tag) != tagBefore)
        tag.matchModeRaw = "all"
        #expect(try tagRule() == ["all", "Strom"])
        let correspondentBefore = RowState.capture(correspondent)
        correspondent.matchPattern = "Stadtwerke"
        #expect(RowState.capture(correspondent) != correspondentBefore)
        let typeBefore = RowState.capture(type)
        type.matchModeRaw = ""
        #expect(RowState.capture(type) != typeBefore)
        #expect(try metadataRule(RowState.capture(type)) == ["", #"IBAN\s*DE\d{20}"#])
    }

    private struct CaptureKindMismatch: Error {}
}
