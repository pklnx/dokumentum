import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The library on the store (plan of #3, part 2): what the sidebar and the list read, the open document's
/// file, and the change events.
@MainActor
struct StoreLibrarySourceTests {
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func theSnapshotMapsTheStoresDocumentsAndLiveMetadata() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let stadtwerke = Correspondent(name: "Stadtwerke")
        let merged = Correspondent(name: "stadtwerke")
        merged.mergedIntoID = stadtwerke.id
        merged.mergedAt = .now
        let invoice = DocumentType(name: "Invoice")
        let auto = DokumentumCore.Tag(name: "Auto")
        let golf = DokumentumCore.Tag(name: "Golf")
        golf.parent = auto
        for record in [stadtwerke, merged] { context.insert(record) }
        context.insert(invoice)
        context.insert(auto)
        context.insert(golf)
        let filed = Document(title: "Strom", createdAt: Self.base)
        filed.isInbox = false
        filed.correspondent = merged
        filed.documentType = invoice
        filed.tags = [golf]
        let bare = Document(title: "", createdAt: Self.base)
        let trashed = Document(title: "Alt", createdAt: Self.base)
        trashed.deletedAt = Self.base
        for document in [filed, bare, trashed] { context.insert(document) }
        try context.save()

        let snapshot = StoreLibrarySource(container: container).snapshot()
        #expect(Set(snapshot.documents.map(\.instanceID)) == [filed.instanceID, bare.instanceID, trashed.instanceID])
        let row = try #require(snapshot.documents.first { $0.instanceID == filed.instanceID })
        #expect(row.title == "Strom")
        #expect(!row.isInbox)
        #expect(row.correspondent == LibraryDocument.Reference(instanceID: stadtwerke.instanceID, name: "Stadtwerke"))
        #expect(row.documentType == LibraryDocument.Reference(instanceID: invoice.instanceID, name: "Invoice"))
        #expect(row.tagIDs == [golf.instanceID])
        let bareRow = try #require(snapshot.documents.first { $0.instanceID == bare.instanceID })
        #expect(bareRow.correspondent == nil)
        #expect(bareRow.documentType == nil)
        #expect(snapshot.documents.first { $0.instanceID == trashed.instanceID }?.isTrashed == true)

        // The tombstone is not in the sidebar; the tree keeps the nesting.
        #expect(snapshot.correspondents.map(\.instanceID) == [stadtwerke.instanceID])
        #expect(snapshot.documentTypes.map(\.instanceID) == [invoice.instanceID])
        #expect(TagTree(snapshot.tags).displayPath(of: golf.instanceID) == "Auto › Golf")
        let counts = LibraryCounts(snapshot.documents, tree: TagTree(snapshot.tags))
        #expect(counts.count(for: .all) == 2)
        #expect(counts.count(for: .inbox) == 1)
        #expect(counts.count(for: .trash) == 1)
        #expect(counts.count(for: .tag(auto.instanceID)) == 1)
    }

    @Test func aSaveFiresChanges() async throws {
        let container = try TestSupport.makeContainer()
        let source = StoreLibrarySource(container: container)
        let (saved, subscriber) = TestSignal.counting(source.changes)
        defer { subscriber.cancel() }
        container.mainContext.insert(Document(title: "Neu"))
        try container.mainContext.save()
        await saved.wait()
        #expect(source.snapshot().documents.map(\.title) == ["Neu"])

        // A save in another context of the same container counts too.
        let other = ModelContext(container)
        other.insert(Document(title: "Zweites"))
        try other.save()
        await saved.wait(for: 2)
    }

    // MARK: The file of the open document

    @Test func theLoaderReportsEachState() async throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let withoutFile = Document(title: "Ohne Datei")
        let withoutData = Document(title: "Ohne Daten")
        let withData = Document(title: "Mit Daten")
        let trashed = Document(title: "Im Papierkorb")
        trashed.deletedAt = .now
        for document in [withoutFile, withoutData, withData, trashed] { context.insert(document) }
        let empty = DocumentFile(documentID: withoutData.id, pdfData: nil)
        let pdf = DocumentFile(documentID: withData.id, pdfData: Data("%PDF-1.7 sample".utf8))
        let trashedPDF = DocumentFile(documentID: trashed.id, pdfData: Data("%PDF-1.7 old".utf8))
        for file in [empty, pdf, trashedPDF] { context.insert(file) }
        withoutData.file = empty
        withData.file = pdf
        trashed.file = trashedPDF
        try context.save()

        let source = StoreLibrarySource(container: container)
        #expect(await source.loadPDF(instanceID: UUID()) == .noDocument)
        #expect(await source.loadPDF(instanceID: withoutFile.instanceID) == .noFile)
        #expect(await source.loadPDF(instanceID: withoutData.instanceID) == .noData)
        #expect(await source.loadPDF(instanceID: withData.instanceID) == .data(Data("%PDF-1.7 sample".utf8)))
        // A trashed document stays readable (PQ10).
        #expect(await source.loadPDF(instanceID: trashed.instanceID) == .data(Data("%PDF-1.7 old".utf8)))
        // An empty file counts as not arrived.
        empty.pdfData = Data()
        try context.save()
        #expect(await source.loadPDF(instanceID: withoutData.instanceID) == .noData)
    }

    /// A file that arrives after the document was opened: the next change event's load finds it, without
    /// polling, and an earlier load's answer does not stick.
    @Test func aFileInsertedLaterIsFoundAfterTheChange() async throws {
        let container = try TestSupport.makeContainer()
        let document = Document(title: "Strom")
        container.mainContext.insert(document)
        try container.mainContext.save()
        let source = StoreLibrarySource(container: container)
        #expect(await source.loadPDF(instanceID: document.instanceID) == .noFile)

        let (saved, subscriber) = TestSignal.counting(source.changes)
        defer { subscriber.cancel() }
        // As the sync's import would: a context of its own links the file.
        let importer = ModelContext(container)
        let imported = try #require(
            try importer.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.title == "Strom" })).first)
        let file = DocumentFile(documentID: imported.id, pdfData: Data("%PDF-1.7 arrived".utf8))
        importer.insert(file)
        imported.file = file
        try importer.save()
        await saved.wait()
        #expect(await source.loadPDF(instanceID: document.instanceID) == .data(Data("%PDF-1.7 arrived".utf8)))
    }
}

/// The footer's "Sync off" reason comes from the store that opened, never from a guess.
struct SyncOffReasonTests {
    @Test func eachOpenedStoreHasItsReason() {
        #expect(SyncOffReason.reason(choice: .cloudKit, opened: .cloudKit) == nil)
        #expect(SyncOffReason.reason(choice: .local, opened: .local) == .noICloudAccess)
        #expect(SyncOffReason.reason(choice: .local, opened: .localFallback) == .noICloudAccess)
        #expect(SyncOffReason.reason(choice: .cloudKit, opened: .local) == .cloudKitStoreFailed)
        #expect(SyncOffReason.reason(choice: .cloudKit, opened: .localFallback) == .cloudKitStoreFailed)
        #expect(SyncOffReason.reason(choice: .inMemory(seed: true), opened: .sampleData) == .sampleData)
        #expect(SyncOffReason.reason(choice: .inMemory(seed: false), opened: .inMemory) == .sampleData)
    }
}
