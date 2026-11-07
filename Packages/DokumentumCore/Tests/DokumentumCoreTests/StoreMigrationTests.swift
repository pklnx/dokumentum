import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// Every store opens through `DokumentumMigrationPlan`. **The template for later versions:** schema version N
/// adds a test that writes a store with V(N-1) (`writeCoreDataStore` with `DokumentumSchemaV<N-1>.models`) and
/// opens it with V(N), and the round trip moves to V(N).
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
        let tombstone = Correspondent(name: "Stadtwerke ", createdAt: date.addingTimeInterval(1))
        tombstone.mergedIntoID = correspondent.id
        tombstone.mergedAt = date.addingTimeInterval(2)
        let type = DocumentType(name: "Rechnung", createdAt: date)
        let parent = DokumentumCore.Tag(name: "Haus", createdAt: date)
        parent.colorHex = "#FF0000"
        let child = DokumentumCore.Tag(name: "Strom", createdAt: date.addingTimeInterval(3))
        child.mergedAt = date.addingTimeInterval(4)
        child.mergedIntoID = UUID()
        child.parent = parent

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
                    + "parent=\(String(describing: t.parent?.instanceID)) children=\(ids(t.children) { $0.instanceID }) "
                    + "documents=\(ids(t.documents) { $0.instanceID })")
        }
        for c in try context.fetch(FetchDescriptor<Correspondent>()) {
            lines.append(
                "Correspondent \(c.instanceID) id=\(c.id) name=\(c.name) created=\(c.createdAt) "
                    + "mergedInto=\(String(describing: c.mergedIntoID)) mergedAt=\(String(describing: c.mergedAt)) "
                    + "documents=\(ids(c.documents) { $0.instanceID })")
        }
        for t in try context.fetch(FetchDescriptor<DocumentType>()) {
            lines.append(
                "DocumentType \(t.instanceID) id=\(t.id) name=\(t.name) created=\(t.createdAt) "
                    + "mergedInto=\(String(describing: t.mergedIntoID)) mergedAt=\(String(describing: t.mergedAt)) "
                    + "documents=\(ids(t.documents) { $0.instanceID })")
        }
        return lines.sorted()
    }

    /// V1 round trip on disk: everything written comes back after the store is closed and reopened through the
    /// migration plan, the external-storage blobs included.
    @Test func everyV1FieldSurvivesAReopen() throws {
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
    /// migration plan with its data.
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
