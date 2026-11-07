import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The trash (plan of #3, part 4): move and restore change only `deletedAt` and `modifiedAt`; Empty Trash deletes
/// exactly the confirmed documents that are still in the trash, with their linked file, thumbnail and text, and
/// nothing else.
@MainActor
struct DocumentTrashTests {
    nonisolated private static let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let trashedAt = Date(timeIntervalSinceReferenceDate: 810_000_000)
    private static let restoredAt = Date(timeIntervalSinceReferenceDate: 820_000_000)

    /// Every field of a document except `deletedAt` and `modifiedAt`, the two the trash writes.
    private struct Fields: Equatable {
        var values: [String]

        init(_ document: Document) {
            values = [
                document.id.uuidString, document.instanceID.uuidString, document.title, "\(document.createdAt)",
                "\(document.documentDate)", "\(document.isInbox)", "\(document.pageCount)", "\(document.fileSize)",
                document.textSourceRaw, document.processingStateRaw, document.processingDeviceID,
                "\(String(describing: document.processingClaimedAt))", document.contentHash,
                document.originalFileName, document.sourceRaw,
                document.correspondent?.instanceID.uuidString ?? "-",
                document.documentType?.instanceID.uuidString ?? "-",
                (document.tags ?? []).map(\.instanceID.uuidString).sorted().joined(separator: ","),
                document.file?.instanceID.uuidString ?? "-", document.thumbnail?.instanceID.uuidString ?? "-",
                document.text?.instanceID.uuidString ?? "-",
            ]
        }
    }

    /// Counts the saves of one container.
    private final class SaveCounter {
        let saves = TestSignal()
        private var observer: (any NSObjectProtocol)?

        init(_ container: ModelContainer) {
            let saves = saves
            observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
                notification in
                guard let saved = notification.object as? ModelContext, saved.container === container else { return }
                saves.fire()
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// A document with every field set, metadata, and a linked file, thumbnail and text.
    @discardableResult
    private static func insertDocument(
        _ title: String, inbox: Bool = true, trashed: Bool = false, metadata: Metadata? = nil,
        into context: ModelContext
    ) -> Document {
        let document = Document(title: title, createdAt: created)
        document.documentDate = created.addingTimeInterval(-86_400)
        document.isInbox = inbox
        document.pageCount = 3
        document.fileSize = 1234
        document.textSourceRaw = "ocr"
        document.processingStateRaw = "done"
        document.processingDeviceID = "device-a"
        document.processingClaimedAt = created
        document.contentHash = "hash-\(title)"
        document.originalFileName = "\(title).pdf"
        document.sourceRaw = "a-value-from-a-newer-build"
        if trashed { document.deletedAt = trashedAt }
        context.insert(document)
        let file = DocumentFile(documentID: document.id, pdfData: Data("%PDF-1.7 \(title)".utf8), createdAt: created)
        let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data([1, 2, 3]), createdAt: created)
        let text = DocumentText(documentID: document.id, extractedText: "text of \(title)", createdAt: created)
        context.insert(file)
        context.insert(thumbnail)
        context.insert(text)
        document.file = file
        document.thumbnail = thumbnail
        document.text = text
        if let metadata {
            document.correspondent = metadata.correspondent
            document.documentType = metadata.documentType
            document.tags = metadata.tags
        }
        return document
    }

    private struct Metadata {
        let correspondent: Correspondent
        let documentType: DocumentType
        let tags: [DokumentumCore.Tag]

        init(into context: ModelContext) {
            correspondent = Correspondent(name: "Stadtwerke", createdAt: DocumentTrashTests.created)
            documentType = DocumentType(name: "Invoice", createdAt: DocumentTrashTests.created)
            let auto = DokumentumCore.Tag(name: "Auto", createdAt: DocumentTrashTests.created)
            let golf = DokumentumCore.Tag(name: "Golf", createdAt: DocumentTrashTests.created)
            for record in [correspondent, documentType, auto, golf] as [any PersistentModel] { context.insert(record) }
            golf.parent = auto
            tags = [auto, golf]
        }
    }

    /// The number of records of each entity.
    private static func counts(in context: ModelContext) throws -> [String: Int] {
        [
            "Document": try context.fetchCount(FetchDescriptor<Document>()),
            "DocumentFile": try context.fetchCount(FetchDescriptor<DocumentFile>()),
            "DocumentThumbnail": try context.fetchCount(FetchDescriptor<DocumentThumbnail>()),
            "DocumentText": try context.fetchCount(FetchDescriptor<DocumentText>()),
            "Tag": try context.fetchCount(FetchDescriptor<DokumentumCore.Tag>()),
            "Correspondent": try context.fetchCount(FetchDescriptor<Correspondent>()),
            "DocumentType": try context.fetchCount(FetchDescriptor<DocumentType>()),
        ]
    }

    private static func instanceIDs(_ filter: DocumentListQuery.Filter, in context: ModelContext) throws -> Set<UUID> {
        Set(try DocumentListQuery.fetch(filter, in: context).map(\.instanceID))
    }

    // MARK: Move and restore

    @Test(arguments: [true, false])
    func moveAndRestoreKeepEveryOtherField(inbox: Bool) throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let document = Self.insertDocument(
            "Strom", inbox: inbox, metadata: Metadata(into: context), into: context)
        try context.save()
        let before = Fields(document)
        let counter = SaveCounter(container)
        var clock = Self.trashedAt
        let trash = DocumentTrash(context: context, now: { clock })

        #expect(try trash.moveToTrash([document.instanceID]) == [document.instanceID])
        #expect(counter.saves.count == 1, "one save")
        #expect(document.deletedAt == Self.trashedAt)
        #expect(document.modifiedAt == Self.trashedAt, "touch()")
        #expect(Fields(document) == before)

        clock = Self.restoredAt
        #expect(try trash.restore([document.instanceID]) == [document.instanceID])
        #expect(counter.saves.count == 2, "one save")
        #expect(document.deletedAt == nil)
        #expect(document.modifiedAt == Self.restoredAt, "touch()")
        #expect(document.isInbox == inbox, "the inbox state it had")
        #expect(Fields(document) == before)

        // What was saved, read back in a context of its own.
        let stored = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Document>()).first {
                $0.instanceID == document.instanceID
            })
        #expect(stored.deletedAt == nil)
        #expect(Fields(stored) == before)
    }

    @Test func movingWhatIsGoneOrAlreadyTrashedChangesNothing() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let trashed = Self.insertDocument("Alt", trashed: true, into: context)
        let live = Self.insertDocument("Neu", into: context)
        try context.save()
        let counter = SaveCounter(container)
        let trash = DocumentTrash(context: context, now: { Self.restoredAt })

        #expect(try trash.moveToTrash([trashed.instanceID, UUID()]).isEmpty)
        #expect(try trash.restore([live.instanceID, UUID()]).isEmpty)
        #expect(try trash.moveToTrash([]).isEmpty)
        #expect(try trash.emptyTrash(confirmed: []).isEmpty)
        #expect(try trash.emptyTrash(confirmed: [live.instanceID]).isEmpty, "a live document is never deleted")
        #expect(counter.saves.count == 0, "nothing to save")
        #expect(trashed.deletedAt == Self.trashedAt, "the first trash date stays")
        #expect(trashed.modifiedAt == Self.created)
        #expect(live.deletedAt == nil)
        #expect(try context.fetchCount(FetchDescriptor<Document>()) == 2)
    }

    @Test func theListQueryShowsATrashedDocumentOnlyInTheTrash() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let inbox = Self.insertDocument("Strom", inbox: true, into: context)
        let filed = Self.insertDocument("Wasser", inbox: false, into: context)
        try context.save()
        let trash = DocumentTrash(context: context, now: { Self.trashedAt })

        try trash.moveToTrash([inbox.instanceID, filed.instanceID])
        #expect(try Self.instanceIDs(.inbox, in: context).isEmpty)
        #expect(try Self.instanceIDs(.all, in: context).isEmpty)
        #expect(try Self.instanceIDs(.trash, in: context) == [inbox.instanceID, filed.instanceID])
        let counts = LibraryCounts(try StoreLibrarySource.read(in: context).documents, tree: TagTree([]))
        #expect([counts.inbox, counts.all, counts.trash] as [Int] == [0, 0, 2])

        try trash.restore([inbox.instanceID, filed.instanceID])
        #expect(try Self.instanceIDs(.inbox, in: context) == [inbox.instanceID])
        #expect(try Self.instanceIDs(.all, in: context) == [inbox.instanceID, filed.instanceID])
        #expect(try Self.instanceIDs(.trash, in: context).isEmpty)
    }

    // MARK: Empty Trash

    @Test func emptyTrashDeletesExactlyTheConfirmedTrashedDocumentsAndTheirLinkedRecords() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let metadata = Metadata(into: context)
        let confirmedA = Self.insertDocument("A", trashed: true, metadata: metadata, into: context)
        let confirmedB = Self.insertDocument("B", trashed: true, metadata: metadata, into: context)
        // Trashed after the confirmation was shown: not in the confirmed set.
        let trashedLater = Self.insertDocument("C", trashed: true, metadata: metadata, into: context)
        // In the confirmed set, but not in the trash (restored meanwhile).
        let restored = Self.insertDocument("D", trashed: false, metadata: metadata, into: context)
        let live = Self.insertDocument("E", metadata: metadata, into: context)
        try context.save()
        let before = try Self.counts(in: context)
        #expect(before["Document"] == 5)
        #expect(before["DocumentFile"] == 5)
        let counter = SaveCounter(container)
        let keptFields = [trashedLater, restored, live].map(Fields.init)

        let deleted = try DocumentTrash(context: context).emptyTrash(
            confirmed: [confirmedA.instanceID, confirmedB.instanceID, restored.instanceID])

        #expect(deleted == [confirmedA.instanceID, confirmedB.instanceID])
        #expect(counter.saves.count == 1, "one save")
        let after = try Self.counts(in: ModelContext(container))
        for entity in ["Document", "DocumentFile", "DocumentThumbnail", "DocumentText"] {
            #expect(after[entity] == before[entity].map { $0 - 2 }, "\(entity)")
        }
        // Metadata stays.
        for entity in ["Tag", "Correspondent", "DocumentType"] {
            #expect(after[entity] == before[entity], "\(entity)")
        }
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Document>())
        #expect(
            Set(remaining.map(\.instanceID)) == [trashedLater.instanceID, restored.instanceID, live.instanceID])
        #expect(Set(remaining.map(Fields.init).map(\.values)) == Set(keptFields.map(\.values)))
        // Each kept document still has its own records and metadata.
        for document in remaining {
            #expect(document.file?.documentID == document.id)
            #expect(document.thumbnail?.documentID == document.id)
            #expect(document.text?.documentID == document.id)
            #expect(document.correspondent?.name == "Stadtwerke")
            #expect(document.tags?.count == 2)
        }
        let blobDocumentIDs = Set(
            try ModelContext(container).fetch(FetchDescriptor<DocumentFile>()).compactMap(\.documentID))
        #expect(blobDocumentIDs == Set(remaining.map(\.id)))
    }

    /// The main context still holds the document as trashed when another context restores it (another device's
    /// restore, imported). The re-check reads the store, so the document stays.
    @Test func aDocumentRestoredInAnotherContextAfterTheConfirmationSurvives() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let document = Self.insertDocument("Strom", trashed: true, into: context)
        let other = Self.insertDocument("Wasser", trashed: true, into: context)
        try context.save()
        let confirmed: Set = [document.instanceID, other.instanceID]
        // The main context has read the document as trashed.
        #expect(document.deletedAt != nil)

        let importing = ModelContext(container)
        let imported = try #require(
            try importing.fetch(FetchDescriptor<Document>()).first { $0.instanceID == document.instanceID })
        imported.deletedAt = nil
        try importing.save()

        let deleted = try DocumentTrash(context: context).emptyTrash(confirmed: confirmed)

        #expect(deleted == [other.instanceID])
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Document>())
        #expect(remaining.map(\.instanceID) == [document.instanceID])
        #expect(remaining.first?.file != nil, "its file stays")
        #expect(try Self.instanceIDs(.all, in: ModelContext(container)) == [document.instanceID])
    }

    @Test func aDocumentRestoredOnThisDeviceAfterTheConfirmationSurvives() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let document = Self.insertDocument("Strom", trashed: true, into: context)
        try context.save()
        let trash = DocumentTrash(context: context)
        let confirmed: Set = [document.instanceID]

        try trash.restore([document.instanceID])
        #expect(try trash.emptyTrash(confirmed: confirmed).isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Document>()) == 1)
    }

    /// A file, thumbnail or text with the document's `id` that is not linked to it (still arriving by sync) is not
    /// deleted with it: it stays as an orphan for the repair to count (T7).
    @Test func anUnlinkedRecordWithTheDocumentsIDSurvives() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let document = Self.insertDocument("Strom", trashed: true, into: context)
        let file = DocumentFile(documentID: document.id, pdfData: Data("%PDF-1.7 second".utf8))
        let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data([9]))
        let text = DocumentText(documentID: document.id, extractedText: "second")
        context.insert(file)
        context.insert(thumbnail)
        context.insert(text)
        try context.save()
        let orphans = [file.instanceID, thumbnail.instanceID, text.instanceID]

        #expect(try DocumentTrash(context: context).emptyTrash(confirmed: [document.instanceID]).count == 1)

        let reading = ModelContext(container)
        #expect(try reading.fetchCount(FetchDescriptor<Document>()) == 0)
        let files = try reading.fetch(FetchDescriptor<DocumentFile>())
        let thumbnails = try reading.fetch(FetchDescriptor<DocumentThumbnail>())
        let texts = try reading.fetch(FetchDescriptor<DocumentText>())
        #expect(files.map(\.instanceID) + thumbnails.map(\.instanceID) + texts.map(\.instanceID) == orphans)
        #expect(files.first?.documentID == document.id)
        #expect(files.first?.document == nil)
    }

    /// The library, read from the main context as the app does, no longer shows what another context deleted.
    @Test func theMainContextNoLongerListsTheDeletedDocuments() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let document = Self.insertDocument("Strom", trashed: true, into: context)
        let kept = Self.insertDocument("Wasser", into: context)
        try context.save()
        #expect(try StoreLibrarySource.read(in: context).documents.count == 2)

        try DocumentTrash(context: context).emptyTrash(confirmed: [document.instanceID])

        let snapshot = try StoreLibrarySource.read(in: context)
        #expect(snapshot.documents.map(\.instanceID) == [kept.instanceID])
        #expect(try context.fetchCount(FetchDescriptor<Document>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<DocumentFile>()) == 1)
    }

    /// On disk: after Empty Trash, closed and reopened, the deleted documents and their records are gone, the
    /// others intact.
    @Test func emptyTrashSurvivesAReopenOnDisk() throws {
        SQLLog.enable()
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "Trash.store")
        let kept: (instanceID: UUID, fields: Fields)
        let pdf = Data(repeating: 0x25, count: 300_000)
        do {
            let container = try ArchiveStore.open(ArchiveStore.configuration(for: .local, at: url))
            let context = ModelContext(container)
            let metadata = Metadata(into: context)
            let deleted = Self.insertDocument("Alt", metadata: metadata, into: context)
            let document = Self.insertDocument("Neu", metadata: metadata, into: context)
            // Large enough for external storage, so the round trip covers that path too.
            deleted.file?.pdfData = pdf
            document.file?.pdfData = pdf
            try context.save()
            kept = (document.instanceID, Fields(document))
            let trash = DocumentTrash(context: context, now: { Self.trashedAt })
            try trash.moveToTrash([deleted.instanceID])
            #expect(try trash.emptyTrash(confirmed: [deleted.instanceID]) == [deleted.instanceID])
        }

        let reopened = try TestSupport.makeContainerOnDisk(at: url)
        let context = ModelContext(reopened)
        let counts = try Self.counts(in: context)
        #expect(
            counts == [
                "Document": 1, "DocumentFile": 1, "DocumentThumbnail": 1, "DocumentText": 1, "Tag": 2,
                "Correspondent": 1,
                "DocumentType": 1,
            ])
        let document = try #require(try context.fetch(FetchDescriptor<Document>()).first)
        #expect(document.instanceID == kept.instanceID)
        #expect(Fields(document) == kept.fields)
        #expect(document.deletedAt == nil)
        #expect(document.file?.pdfData == pdf)
        #expect(document.text?.extractedText == "text of Neu")
    }

    // MARK: SQL

    /// Moving and restoring read the document rows only, never the text, the PDF or the thumbnail, and write only
    /// `deletedAt` and `modifiedAt` (CloudKit's last writer wins per field, #2 I6). Runs under `swift test` on
    /// macOS, where the SQL can be read (`SQLLog.isReadable`).
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func moveAndRestoreReadNoLargeTableAndWriteOnlyTheirFields() throws {
        let container = try TestSupport.makeContainerOnDisk()
        do {
            let seeding = ModelContext(container)
            Self.insertDocument("Strom", into: seeding)
            try seeding.save()
        }
        let context = ModelContext(container)
        let instanceID = try #require(try DocumentListQuery.fetch(.all, in: context).first?.instanceID)
        var clock = Self.trashedAt
        let trash = DocumentTrash(context: context, now: { clock })

        let recording = try SQLLog.Recording()
        try trash.moveToTrash([instanceID])
        clock = Self.restoredAt
        try trash.restore([instanceID])
        let statements = try recording.statements()

        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "no SELECT on ZDOCUMENT: \(statements)")
        for statement in statements {
            for table in DocumentListQuerySQLTests.largeTables {
                #expect(!SQLLog.statement(statement, names: table), "\(statement)")
            }
        }
        // `UPDATE OR FAIL ZDOCUMENT SET ZDELETEDAT = ?, ZMODIFIEDAT = ?, Z_OPT = ?  WHERE …`
        let updates = statements.filter { $0.contains("UPDATE OR FAIL ZDOCUMENT SET") }
        #expect(updates.count == 2, "one UPDATE per save: \(statements)")
        for update in updates {
            let set = update.components(separatedBy: " SET ").last?.components(separatedBy: " WHERE ").first ?? ""
            let columns = set.components(separatedBy: ",").map {
                $0.components(separatedBy: "=").first?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            #expect(columns.sorted() == ["ZDELETEDAT", "ZMODIFIEDAT", "Z_OPT"], "\(update)")
        }
    }
}
