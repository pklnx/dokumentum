import CoreData
import DokumentumCore
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

    /// (a) A model change without a new snapshot fails here. The message holds the new dump. With
    /// `DOKUMENTUM_SCHEMA_DUMP_DIRECTORY` set, the test also writes it there as `schema-v1.txt`, to replace
    /// the committed file after a reviewed change (docs/development/index.md, "Data model and sync").
    @Test func theV1ModelGivesTheCommittedSnapshot() throws {
        let dump = SchemaDump.text(
            of: try Self.model(of: DokumentumSchemaV1.self), header: Self.header(of: DokumentumSchemaV1.self))
        if let directory = ProcessInfo.processInfo.environment["DOKUMENTUM_SCHEMA_DUMP_DIRECTORY"] {
            try dump.write(
                to: URL(filePath: directory).appending(path: "schema-v1.txt"), atomically: true, encoding: .utf8)
        }
        let committed = try Self.committedSnapshot(1)
        #expect(dump == committed, "Schema/schema-v1.txt differs from the model. The model gives:\n\(dump)")
    }

    /// (b) The rules of a CloudKit-mirrored model.
    @Test func theModelMeetsTheCloudKitRules() throws {
        let model = try Self.model(of: DokumentumSchemaV1.self)
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
    /// model class (`DokumentumSchemaV1.Document`) still gives its plain name.
    @Test func theEntityNamesAreTheSixRecordTypes() throws {
        let names = try Self.model(of: DokumentumSchemaV1.self).entities.compactMap(\.name)
        #expect(
            Set(names) == ["Document", "DocumentFile", "DocumentThumbnail", "Tag", "Correspondent", "DocumentType"])
        #expect(names.count == 6)
    }

    /// The large data sits in its own records, as external storage; `Document` holds none.
    @Test func onlyTheBlobsAreExternalStorage() throws {
        let model = try Self.model(of: DokumentumSchemaV1.self)
        let external = model.entities.flatMap { entity in
            entity.attributesByName.values.filter { $0.allowsExternalBinaryDataStorage }.map {
                "\(entity.name ?? "?").\($0.name)"
            }
        }
        #expect(Set(external) == ["DocumentFile.pdfData", "DocumentThumbnail.imageData"])
    }

    /// The migration plan lists every version once, in order, ends with the version the typealiases name,
    /// and has a committed snapshot for each.
    @Test func theMigrationPlanEndsWithTheCurrentVersion() throws {
        let versions = DokumentumMigrationPlan.schemas
        #expect(versions.map { $0.versionIdentifier } == [Schema.Version(1, 0, 0)])
        #expect(DokumentumMigrationPlan.stages.isEmpty)
        #expect(ObjectIdentifier(try #require(versions.last)) == ObjectIdentifier(DokumentumSchemaV1.self))
        #expect(ObjectIdentifier(Document.self) == ObjectIdentifier(DokumentumSchemaV1.Document.self))
        #expect(ArchiveStore.schema.version == Schema.Version(1, 0, 0))
        for number in 1...versions.count {
            _ = try Self.committedSnapshot(number)
        }
        #expect(
            Bundle.module.url(forResource: "schema-v\(versions.count + 1)", withExtension: "txt", subdirectory: "Schema")
                == nil, "a snapshot without a version in the migration plan")
    }
}
