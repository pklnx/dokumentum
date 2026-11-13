import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// Every store opens through `DokumentumMigrationPlan`. **The template for later versions:** schema version N
/// adds a test that writes a store with V(N-1) (`writeEveryAttribute` and `writeCoreDataStore` with
/// `DokumentumSchemaV<N-1>.models`) and opens it with V(N), and the round trip moves to V(N).
struct StoreMigrationTests {
    /// Large enough for external storage (Core Data moves binary data over about 100 KB into a file).
    static let pdf = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    static let image = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    static let text = String(repeating: "Rechnung über 42,00 € ", count: 200)
    static let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// One record of every entity, every field set to a value other than its default, and every relationship.
    static func writeEveryField(into context: ModelContext) throws {
        let correspondent = Correspondent(name: "Stadtwerke", createdAt: date)
        correspondent.mergedIntoID = nil
        correspondent.matchModeRaw = "any"
        correspondent.matchPattern = "Stadtwerke „Stadtwerke München“"
        let tombstone = Correspondent(name: "Stadtwerke ", createdAt: date.addingTimeInterval(1))
        tombstone.mergedIntoID = correspondent.id
        tombstone.mergedAt = date.addingTimeInterval(2)
        tombstone.matchModeRaw = "fuzzy"
        tombstone.matchPattern = "from a newer build"
        let type = DocumentType(name: "Rechnung", createdAt: date)
        type.matchModeRaw = "regex"
        type.matchPattern = #"IBAN\s*DE\d{20}"#
        let parent = DokumentumCore.Tag(name: "Haus", createdAt: date)
        parent.colorHex = "#FF0000"
        parent.matchModeRaw = "all"
        parent.matchPattern = "Haus Grundsteuer"
        let child = DokumentumCore.Tag(name: "Strom", createdAt: date.addingTimeInterval(3))
        child.mergedAt = date.addingTimeInterval(4)
        child.mergedIntoID = UUID()
        child.parent = parent
        child.matchModeRaw = "exact"
        child.matchPattern = "Stadtwerke Strom"

        let document = Document(title: "Stromrechnung", createdAt: date)
        document.modifiedAt = date.addingTimeInterval(10)
        document.documentDate = date.addingTimeInterval(-86_400)
        document.isInbox = false
        document.pageCount = 3
        document.fileSize = pdf.count
        document.textSourceRaw = "vision"
        document.processingStateRaw = "done"
        document.processingDeviceID = "device-A"
        document.processingClaimedAt = date.addingTimeInterval(5)
        document.contentHash = String(repeating: "ab", count: 32)
        document.originalFileName = "strom.pdf"
        document.sourceRaw = "scan"
        document.deletedAt = date.addingTimeInterval(20)
        let file = DocumentFile(documentID: document.id, pdfData: pdf, createdAt: date)
        let thumbnail = DocumentThumbnail(documentID: document.id, imageData: image, createdAt: date)
        let text = DocumentText(documentID: document.id, extractedText: text, createdAt: date)
        for model in [correspondent, tombstone] as [any PersistentModel] { context.insert(model) }
        for model in [type, parent, child, document, file, thumbnail, text] as [any PersistentModel] {
            context.insert(model)
        }
        document.correspondent = correspondent
        document.documentType = type
        document.tags = [parent, child]
        document.file = file
        document.thumbnail = thumbnail
        document.text = text
        // An unlinked file that names a document not here: an orphan survives a round trip too.
        context.insert(DocumentFile(documentID: UUID(), pdfData: Data([1, 2, 3]), createdAt: date))
        try context.save()
    }

    /// Every record of every entity with every field, keyed by `instanceID`, relationships as `instanceID`s.
    static func dump(_ context: ModelContext) throws -> [String] {
        func ids<T>(_ items: [T]?, _ key: (T) -> UUID) -> String {
            (items ?? []).map { key($0).uuidString }.sorted().joined(separator: ",")
        }
        var lines: [String] = []
        for d in try context.fetch(FetchDescriptor<Document>()) {
            lines.append(
                "Document \(d.instanceID) id=\(d.id) title=\(d.title) created=\(d.createdAt) modified=\(d.modifiedAt) "
                    + "date=\(d.documentDate) inbox=\(d.isInbox) pages=\(d.pageCount) size=\(d.fileSize) "
                    + "textSource=\(d.textSourceRaw) state=\(d.processingStateRaw) device=\(d.processingDeviceID) "
                    + "claimed=\(String(describing: d.processingClaimedAt)) hash=\(d.contentHash) "
                    + "name=\(d.originalFileName) source=\(d.sourceRaw) deleted=\(String(describing: d.deletedAt)) "
                    + "correspondent=\(String(describing: d.correspondent?.instanceID)) "
                    + "type=\(String(describing: d.documentType?.instanceID)) tags=\(ids(d.tags) { $0.instanceID }) "
                    + "file=\(String(describing: d.file?.instanceID)) "
                    + "thumbnail=\(String(describing: d.thumbnail?.instanceID)) "
                    + "text=\(String(describing: d.text?.instanceID))")
        }
        for f in try context.fetch(FetchDescriptor<DocumentFile>()) {
            lines.append(
                "DocumentFile \(f.instanceID) id=\(f.id) created=\(f.createdAt) documentID=\(String(describing: f.documentID)) "
                    + "data=\(f.pdfData.map { "\($0.count) \($0.hashValue)" } ?? "nil") "
                    + "document=\(String(describing: f.document?.instanceID))")
        }
        for t in try context.fetch(FetchDescriptor<DocumentThumbnail>()) {
            lines.append(
                "DocumentThumbnail \(t.instanceID) id=\(t.id) created=\(t.createdAt) "
                    + "documentID=\(String(describing: t.documentID)) "
                    + "data=\(t.imageData.map { "\($0.count) \($0.hashValue)" } ?? "nil") "
                    + "document=\(String(describing: t.document?.instanceID))")
        }
        for t in try context.fetch(FetchDescriptor<DocumentText>()) {
            lines.append(
                "DocumentText \(t.instanceID) id=\(t.id) created=\(t.createdAt) "
                    + "documentID=\(String(describing: t.documentID)) text=\(t.extractedText.count) \(t.extractedText.hashValue) "
                    + "document=\(String(describing: t.document?.instanceID))")
        }
        for t in try context.fetch(FetchDescriptor<DokumentumCore.Tag>()) {
            lines.append(
                "Tag \(t.instanceID) id=\(t.id) name=\(t.name) color=\(t.colorHex) created=\(t.createdAt) "
                    + "mergedInto=\(String(describing: t.mergedIntoID)) mergedAt=\(String(describing: t.mergedAt)) "
                    + "mode=\(t.matchModeRaw) pattern=\(t.matchPattern) "
                    + "parent=\(String(describing: t.parent?.instanceID)) children=\(ids(t.children) { $0.instanceID }) "
                    + "documents=\(ids(t.documents) { $0.instanceID })")
        }
        for c in try context.fetch(FetchDescriptor<Correspondent>()) {
            lines.append(
                "Correspondent \(c.instanceID) id=\(c.id) name=\(c.name) created=\(c.createdAt) "
                    + "mergedInto=\(String(describing: c.mergedIntoID)) mergedAt=\(String(describing: c.mergedAt)) "
                    + "mode=\(c.matchModeRaw) pattern=\(c.matchPattern) "
                    + "documents=\(ids(c.documents) { $0.instanceID })")
        }
        for t in try context.fetch(FetchDescriptor<DocumentType>()) {
            lines.append(
                "DocumentType \(t.instanceID) id=\(t.id) name=\(t.name) created=\(t.createdAt) "
                    + "mergedInto=\(String(describing: t.mergedIntoID)) mergedAt=\(String(describing: t.mergedAt)) "
                    + "mode=\(t.matchModeRaw) pattern=\(t.matchPattern) "
                    + "documents=\(ids(t.documents) { $0.instanceID })")
        }
        return lines.sorted()
    }

    /// Round trip of the current version on disk: everything written, the rule fields of V2 included, comes back
    /// after the store is closed and reopened through the migration plan, the external-storage blobs included.
    @Test func everyFieldSurvivesAReopen() throws {
        SQLLog.enable()
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "RoundTrip.store")
        let written: [String]
        do {
            let container = try ArchiveStore.open(ArchiveStore.configuration(for: .local, at: url))
            let context = ModelContext(container)
            try Self.writeEveryField(into: context)
            written = try Self.dump(ModelContext(container))
        }
        let reopened = try TestSupport.makeContainerOnDisk(at: url)
        let read = try Self.dump(ModelContext(reopened))
        #expect(read == written)
        #expect(written.count == 10)
        // The five records with a rule hold both of its fields, so a rule field that is not stored fails here.
        let rules = written.filter { $0.contains(" mode=") && !$0.contains(" mode= ") && !$0.contains(" pattern= ") }
        #expect(rules.count == 5, "\(rules)")
        // The blobs went to external storage, so the round trip covered that path.
        let externalFolder = url.deletingLastPathComponent().appending(path: ".RoundTrip_SUPPORT/_EXTERNAL_DATA")
        let external = try FileManager.default.contentsOfDirectory(atPath: externalFolder.path)
        #expect(external.count == 2)
        let file = try #require(
            try ModelContext(reopened).fetch(FetchDescriptor<DocumentFile>()).first { $0.document != nil })
        #expect(file.pdfData == Self.pdf)
        let text = try #require(try ModelContext(reopened).fetch(FetchDescriptor<DocumentText>()).first)
        #expect(text.extractedText == Self.text)
    }

    /// A store written by Core Data with the V1 model, as another build or device writes it, opens through the
    /// migration plan with its data (in V2 since #10, part 1a).
    @Test func aCoreDataV1StoreOpensThroughThePlan() throws {
        SQLLog.enable()
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "CoreData-V1.store")
        let documentID = UUID()
        try Self.writeCoreDataStore(at: url, models: DokumentumSchemaV1.models, documentID: documentID)

        let container = try TestSupport.makeContainerOnDisk(at: url)
        let documents = try ModelContext(container).fetch(FetchDescriptor<Document>())
        let document = try #require(documents.first)
        #expect(documents.count == 1)
        #expect(document.id == documentID)
        #expect(document.title == "Reisepass")
        #expect(document.tags?.map(\.name) == ["Ausweise"])
        #expect(document.text?.extractedText == "Bundesrepublik")
        #expect(document.text?.documentID == documentID)
        #expect(document.isInbox, "the default written by the model")
    }

    /// V1 → V2 (#10, part 1a): a store written with V1's model, every attribute of every entity set to a value
    /// other than its default and every relationship set, opens with V2 through the migration plan. Every V1 value
    /// and link is kept, and the fields V2 adds read their defaults: the rule fields `""`, so no rule.
    ///
    /// SwiftData opens such a store even when V1 is missing from the plan: it then infers the same lightweight
    /// migration (measured on #198; probe P-1 of #10's plan found the same for a model changed in place). So this
    /// test checks what the open keeps, not that the stage is listed; `SchemaTests` pins the versions and stages.
    @Test func aV1StoreWithEveryFieldOpensWithV2() throws {
        SQLLog.enable()
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "EveryField-V1.store")
        let v1 = try #require(NSManagedObjectModel.makeManagedObjectModel(for: DokumentumSchemaV1.models))
        let written = try Self.writeEveryAttribute(at: url, model: v1)
        let records = Set(written.map { $0.split(separator: " ").prefix(2).joined(separator: " ") })
        #expect(records.count == 8, "one record of each entity and a second tag: \(records.sorted())")
        // Every relationship of V1 links something in the written store, so a relationship that a later version's
        // `writeEveryAttribute` forgets to set fails here instead of comparing equal as empty on both sides.
        let linked = Set(
            written.compactMap { line -> String? in
                let parts = line.split(separator: " ")
                guard parts.count == 3, let arrow = parts[2].range(of: "->"), arrow.upperBound != parts[2].endIndex
                else { return nil }
                return "\(parts[0]).\(parts[2][..<arrow.lowerBound])"
            })
        let relationships = Set(
            v1.entities.flatMap { entity in entity.relationshipsByName.keys.map { "\(entity.name ?? "?").\($0)" } })
        #expect(linked == relationships, "relationships left empty: \(relationships.subtracting(linked).sorted())")

        let container = try TestSupport.makeContainerOnDisk(at: url)
        let context = ModelContext(container)
        #expect(ArchiveStore.schema.version == Schema.Version(2, 0, 0))
        // Read through the typealiases (V2): the V1 values are there and the rule fields read as no rule.
        let tags = try context.fetch(FetchDescriptor<DokumentumCore.Tag>())
        let correspondents = try context.fetch(FetchDescriptor<Correspondent>())
        let types = try context.fetch(FetchDescriptor<DocumentType>())
        #expect(tags.count == 2 && correspondents.count == 1 && types.count == 1)
        #expect(Set(tags.map(\.name)) == ["Tag.name 1 ü", "Tag.name 2 ü"])
        #expect(correspondents.map(\.name) == ["Correspondent.name 1 ü"])
        let rules =
            tags.map { [$0.matchModeRaw, $0.matchPattern] } + correspondents.map { [$0.matchModeRaw, $0.matchPattern] }
            + types.map { [$0.matchModeRaw, $0.matchPattern] }
        #expect(rules == Array(repeating: ["", ""], count: 4))
        let modes = tags.map(\.matchMode) + correspondents.map(\.matchMode) + types.map(\.matchMode)
        #expect(modes == [.none, .none, .none, .none])
        let document = try #require(try context.fetch(FetchDescriptor<Document>()).first)
        #expect(document.correspondent?.name == "Correspondent.name 1 ü")
        #expect(document.tags?.count == 2)

        // Every V1 attribute and relationship, read again with the current model's Core Data form: unchanged.
        let current = try #require(
            NSManagedObjectModel.makeManagedObjectModel(for: DokumentumMigrationPlan.current.models))
        let read = try Self.readEveryAttribute(at: url, model: current, keeping: v1)
        #expect(read.kept == written)
        #expect(read.added.count == 8, "two fields on two tags, one correspondent and one type: \(read.added)")
        #expect(
            read.added.allSatisfy { $0.hasSuffix("=\"\"") }, "every field V2 adds reads its default: \(read.added)")
        let addedFields = Set(
            read.added.map { line in
                let parts = line.split(separator: " ")
                return "\(parts[0]).\(parts[2].prefix { $0 != "=" })"
            })
        #expect(
            addedFields == [
                "Tag.matchModeRaw", "Tag.matchPattern", "Correspondent.matchModeRaw", "Correspondent.matchPattern",
                "DocumentType.matchModeRaw", "DocumentType.matchPattern",
            ])
    }

    /// Writes a new store at `url` with `model` (an older version's Core Data form, as another build writes it):
    /// for every entity one record and a second `Tag` as the first one's child, every attribute set to a value other
    /// than its default, and every relationship set (`Document`'s links and `Tag.parent`; the others are their
    /// inverses).
    /// Returns what the store then holds (`describe`), read back in a new context.
    static func writeEveryAttribute(at url: URL, model: NSManagedObjectModel) throws -> [String] {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: url)
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(.privateQueue)
        context.persistentStoreCoordinator = coordinator
        var failure: (any Error)?
        context.performAndWait {
            do {
                var objects: [String: [NSManagedObject]] = [:]
                for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                    let name = entity.name ?? "?"
                    let count = name == "Tag" ? 2 : 1
                    for index in 1...count {
                        let object = NSEntityDescription.insertNewObject(forEntityName: name, into: context)
                        for (key, attribute) in entity.attributesByName {
                            object.setValue(try Self.value(for: attribute, of: name, index: index), forKey: key)
                        }
                        objects[name, default: []].append(object)
                    }
                }
                let document = try #require(objects["Document"]?.first)
                let tags = try #require(objects["Tag"])
                tags[1].setValue(tags[0], forKey: "parent")
                document.setValue(NSSet(array: tags), forKey: "tags")
                for (key, entity) in [
                    "correspondent": "Correspondent", "documentType": "DocumentType", "file": "DocumentFile",
                    "thumbnail": "DocumentThumbnail", "text": "DocumentText",
                ] {
                    document.setValue(try #require(objects[entity]?.first), forKey: key)
                }
                try context.save()
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return try Self.describe(in: coordinator, model: model, keeping: model).kept
    }

    /// The store at `url` read with `model`: `kept` describes the attributes and relationships that `older` has too,
    /// `added` the attributes only `model` has.
    static func readEveryAttribute(at url: URL, model: NSManagedObjectModel, keeping older: NSManagedObjectModel)
        throws -> (kept: [String], added: [String])
    {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: url)
        defer { try? coordinator.remove(store) }
        return try describe(in: coordinator, model: model, keeping: older)
    }

    /// One line per record and property, `<entity> <instanceID> <property>=<value>`, sorted; relationships as the
    /// sorted `instanceID`s they link, data as its size and hash, dates as seconds.
    static func describe(
        in coordinator: NSPersistentStoreCoordinator, model: NSManagedObjectModel, keeping older: NSManagedObjectModel
    ) throws -> (kept: [String], added: [String]) {
        let context = NSManagedObjectContext(.privateQueue)
        context.persistentStoreCoordinator = coordinator
        var kept: [String] = []
        var added: [String] = []
        var failure: (any Error)?
        context.performAndWait {
            do {
                for entity in model.entities {
                    let name = entity.name ?? "?"
                    let old = older.entitiesByName[name]
                    for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                        let id = String(describing: object.value(forKey: "instanceID") ?? "nil")
                        for key in entity.attributesByName.keys {
                            let line = "\(name) \(id) \(key)=\(Self.text(of: object.value(forKey: key)))"
                            if old?.attributesByName[key] != nil { kept.append(line) } else { added.append(line) }
                        }
                        for key in entity.relationshipsByName.keys where old?.relationshipsByName[key] != nil {
                            let linked: [NSManagedObject] =
                                switch object.value(forKey: key) {
                                case let set as Set<NSManagedObject>: Array(set)
                                case let one as NSManagedObject: [one]
                                default: []
                                }
                            let ids = linked.map { String(describing: $0.value(forKey: "instanceID") ?? "nil") }
                            kept.append("\(name) \(id) \(key)->\(ids.sorted().joined(separator: ","))")
                        }
                    }
                }
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return (kept.sorted(), added.sorted())
    }

    /// A value other than the attribute's default. Strings are distinct per entity, attribute and record; other
    /// types need not be, because the test only needs values that differ from the defaults.
    static func value(for attribute: NSAttributeDescription, of entity: String, index: Int) throws -> Any {
        switch attribute.attributeType {
        case .stringAttributeType: return "\(entity).\(attribute.name) \(index) ü"
        case .UUIDAttributeType: return UUID()
        case .dateAttributeType: return date.addingTimeInterval(Double(attribute.name.count * 10 + index))
        case .integer64AttributeType: return 40 + attribute.name.count + index
        case .booleanAttributeType: return !((attribute.defaultValue as? Bool) ?? false)
        case .binaryDataAttributeType:
            // Large enough for external storage where the model asks for it.
            return attribute.allowsExternalBinaryDataStorage ? (index == 1 ? pdf : image) : Data([1, 2, UInt8(index)])
        default:
            throw CocoaError(
                .coreData, userInfo: [NSDebugDescriptionErrorKey: "no test value for \(entity).\(attribute.name)"])
        }
    }

    static func text(of value: Any?) -> String {
        switch value {
        case nil: "nil"
        case let data as Data: "data \(data.count) \(data.hashValue)"
        case let date as Date: "date \(date.timeIntervalSinceReferenceDate)"
        case let string as String: "\"\(string)\""
        case let value?: String(describing: value)
        }
    }

    /// Writes one document with a tag and a text into a new store file with the Core Data model of `models`.
    static func writeCoreDataStore(at url: URL, models: [any PersistentModel.Type], documentID: UUID) throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: models))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: url)
        let context = NSManagedObjectContext(.privateQueue)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let document = NSEntityDescription.insertNewObject(forEntityName: "Document", into: context)
            document.setValue(documentID, forKey: "id")
            document.setValue(UUID(), forKey: "instanceID")
            document.setValue("Reisepass", forKey: "title")
            let tag = NSEntityDescription.insertNewObject(forEntityName: "Tag", into: context)
            tag.setValue(UUID(), forKey: "instanceID")
            tag.setValue("Ausweise", forKey: "name")
            document.setValue(NSSet(object: tag), forKey: "tags")
            let text = NSEntityDescription.insertNewObject(forEntityName: "DocumentText", into: context)
            text.setValue(UUID(), forKey: "instanceID")
            text.setValue(documentID, forKey: "documentID")
            text.setValue("Bundesrepublik", forKey: "extractedText")
            document.setValue(text, forKey: "text")
            try context.save()
        }
        try coordinator.remove(store)
    }
}
