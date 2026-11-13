import CoreData
import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// The synced schema: what the app's models give as a Core Data model, which `NSPersistentCloudKitContainer`
/// turns into CloudKit record types. `scripts/check-schema-snapshots.py` checks the committed dumps against
/// each other (additive only); these tests check that the code gives the committed dump.
struct SchemaTests {
    static func model(of version: any VersionedSchema.Type) throws -> NSManagedObjectModel {
        try #require(NSManagedObjectModel.makeManagedObjectModel(for: version.models))
    }

    static func header(of version: any VersionedSchema.Type) -> String {
        "\(String(describing: version)) \(version.versionIdentifier)"
    }

    static func committedSnapshot(_ number: Int) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "schema-v\(number)", withExtension: "txt", subdirectory: "Schema"),
            "Schema/schema-v\(number).txt is missing")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// (a) A model change without a new snapshot fails here, for every version of the migration plan: version N is
    /// `schemas[N - 1]` and its snapshot `schema-v<N>.txt`. The message holds the new dump. With
    /// `DOKUMENTUM_SCHEMA_DUMP_DIRECTORY` set, the test also writes each dump there as `schema-v<N>.txt`, to replace
    /// the committed file after a reviewed change (docs/development/index.md, "Data model and sync").
    @Test(arguments: 1...DokumentumMigrationPlan.schemas.count)
    func eachVersionGivesItsCommittedSnapshot(number: Int) throws {
        let version = DokumentumMigrationPlan.schemas[number - 1]
        #expect(version.versionIdentifier == Schema.Version(number, 0, 0))
        let dump = SchemaDump.text(of: try Self.model(of: version), header: Self.header(of: version))
        if let directory = ProcessInfo.processInfo.environment["DOKUMENTUM_SCHEMA_DUMP_DIRECTORY"] {
            try dump.write(
                to: URL(filePath: directory).appending(path: "schema-v\(number).txt"), atomically: true,
                encoding: .utf8)
        }
        let committed = try Self.committedSnapshot(number)
        #expect(
            dump == committed, "Schema/schema-v\(number).txt differs from the model. The model gives:\n\(dump)")
    }

    /// V2 (#10, part 1a) adds exactly the two rule fields to `Tag`, `Correspondent` and `DocumentType`, both
    /// `String` with the default `""`; everything of V1 is unchanged (the snapshot script checks that too).
    @Test func theV2ModelAddsTheMatchingRuleFields() throws {
        let v1 = try Self.model(of: DokumentumSchemaV1.self)
        let v2 = try Self.model(of: DokumentumSchemaV2.self)
        func properties(_ model: NSManagedObjectModel) -> Set<String> {
            Set(
                model.entities.flatMap { entity in
                    entity.propertiesByName.keys.map { "\(entity.name ?? "?").\($0)" }
                })
        }
        let added = properties(v2).subtracting(properties(v1))
        #expect(
            added == [
                "Tag.matchModeRaw", "Tag.matchPattern", "Correspondent.matchModeRaw", "Correspondent.matchPattern",
                "DocumentType.matchModeRaw", "DocumentType.matchPattern",
            ])
        #expect(properties(v1).isSubset(of: properties(v2)))
        for name in added {
            let parts = name.split(separator: ".").map(String.init)
            let attribute = try #require(v2.entitiesByName[parts[0]]?.attributesByName[parts[1]], "\(name)")
            #expect(attribute.attributeType == .stringAttributeType, "\(name)")
            #expect(!attribute.isOptional, "\(name)")
            #expect(attribute.defaultValue as? String == "", "\(name)")
        }
    }

    /// (b) The rules of a CloudKit-mirrored model.
    @Test func theModelMeetsTheCloudKitRules() throws {
        let model = try Self.model(of: DokumentumMigrationPlan.current)
        var problems: [String] = []
        for entity in model.entities {
            let name = entity.name ?? "?"
            if !entity.uniquenessConstraints.isEmpty { problems.append("\(name) has a uniqueness constraint") }
            for attribute in entity.attributesByName.values
            where !attribute.isOptional && attribute.defaultValue == nil {
                problems.append("\(name).\(attribute.name) is neither optional nor defaulted")
            }
            for relationship in entity.relationshipsByName.values {
                let label = "\(name).\(relationship.name)"
                if !relationship.isOptional { problems.append("\(label) is not optional") }
                if relationship.inverseRelationship == nil { problems.append("\(label) has no inverse") }
                if relationship.deleteRule == .denyDeleteRule { problems.append("\(label) has the delete rule deny") }
                if relationship.isOrdered { problems.append("\(label) is ordered") }
            }
        }
        #expect(problems.isEmpty, "\(problems.sorted())")
    }

    /// (c) The entity names become the CloudKit record types (`CD_<name>`), so they are pinned. A nested
    /// model class (`DokumentumSchemaV2.Document`) still gives its plain name.
    @Test func theEntityNamesAreTheSevenRecordTypes() throws {
        let names = try Self.model(of: DokumentumMigrationPlan.current).entities.compactMap { $0.name }
        #expect(
            Set(names) == [
                "Document", "DocumentFile", "DocumentThumbnail", "DocumentText", "Tag", "Correspondent", "DocumentType",
            ])
        #expect(names.count == 7)
    }

    /// (d) Every blob kind of the repair has its entity, each the target of a to-one, cascade relationship of
    /// `Document` with a to-one inverse, so a document holds at most one linked blob of each kind.
    @Test func everyBlobKindHasItsEntityBehindAToOneCascade() throws {
        let model = try Self.model(of: DokumentumMigrationPlan.current)
        let document = try #require(model.entitiesByName["Document"])
        let expected: [BlobKind: (relationship: String, entity: String)] = [
            .file: ("file", "DocumentFile"), .thumbnail: ("thumbnail", "DocumentThumbnail"),
            .text: ("text", "DocumentText"),
        ]
        #expect(Set(expected.keys) == Set(BlobKind.allCases))
        for (kind, names) in expected {
            let relationship = try #require(document.relationshipsByName[names.relationship], "\(kind)")
            #expect(relationship.destinationEntity?.name == names.entity, "\(kind)")
            #expect(!relationship.isToMany, "\(kind)")
            #expect(relationship.deleteRule == .cascadeDeleteRule, "\(kind)")
            let inverse = try #require(relationship.inverseRelationship, "\(kind)")
            #expect(inverse.name == "document" && !inverse.isToMany, "\(kind)")
            #expect(inverse.deleteRule == .nullifyDeleteRule, "\(kind)")
        }
    }

    /// `Document` holds no large field: no text beyond the row scalars, no binary data (DW4).
    @Test func theDocumentHoldsNoLargeField() throws {
        let document = try #require(try Self.model(of: DokumentumMigrationPlan.current).entitiesByName["Document"])
        let names = Set(document.attributesByName.keys)
        #expect(!names.contains("extractedText"))
        #expect(!document.attributesByName.values.contains { $0.attributeType == .binaryDataAttributeType })
    }

    /// The large data sits in its own records, as external storage; `Document` holds none.
    @Test func onlyTheBlobsAreExternalStorage() throws {
        let model = try Self.model(of: DokumentumMigrationPlan.current)
        let external = model.entities.flatMap { entity in
            entity.attributesByName.values.filter { $0.allowsExternalBinaryDataStorage }.map {
                "\(entity.name ?? "?").\($0.name)"
            }
        }
        #expect(Set(external) == ["DocumentFile.pdfData", "DocumentThumbnail.imageData"])
    }

    /// The migration plan lists every version once, in order, with one lightweight stage between neighbours; it
    /// ends with `current`, the version the typealiases and `ArchiveStore.schema` name, and has a committed snapshot
    /// for each.
    @Test func theMigrationPlanEndsWithTheCurrentVersion() throws {
        let versions = DokumentumMigrationPlan.schemas
        #expect(versions.map { $0.versionIdentifier } == [Schema.Version(1, 0, 0), Schema.Version(2, 0, 0)])
        #expect(DokumentumMigrationPlan.stages.count == versions.count - 1)
        #expect(ObjectIdentifier(try #require(versions.last)) == ObjectIdentifier(DokumentumSchemaV2.self))
        #expect(ObjectIdentifier(DokumentumMigrationPlan.current) == ObjectIdentifier(DokumentumSchemaV2.self))
        #expect(ObjectIdentifier(Document.self) == ObjectIdentifier(DokumentumSchemaV2.Document.self))
        #expect(ObjectIdentifier(DokumentumCore.Tag.self) == ObjectIdentifier(DokumentumSchemaV2.Tag.self))
        #expect(ArchiveStore.schema.version == Schema.Version(2, 0, 0))
        for number in 1...versions.count {
            _ = try Self.committedSnapshot(number)
        }
        #expect(
            Bundle.module.url(
                forResource: "schema-v\(versions.count + 1)", withExtension: "txt", subdirectory: "Schema")
                == nil, "a snapshot without a version in the migration plan")
    }
}
