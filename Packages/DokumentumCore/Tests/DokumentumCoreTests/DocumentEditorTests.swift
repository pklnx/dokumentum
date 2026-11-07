import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// Editing a document's metadata (plan of #3, part 3): one field per edit, `touch()`, one save; gone and trashed
/// documents are left alone; new metadata reuses what is there by its merge key.
@MainActor
struct DocumentEditorTests {
    private static let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let edited = Date(timeIntervalSinceReferenceDate: 810_000_000)

    /// Every field a document's edit can touch, and those it must not.
    private struct Fields: Equatable {
        var title: String
        var documentDate: Date
        var isInbox: Bool
        var correspondent: UUID?
        var documentType: UUID?
        var tags: Set<UUID>
        var modifiedAt: Date
        var others: [String]

        init(_ document: Document) {
            title = document.title
            documentDate = document.documentDate
            isInbox = document.isInbox
            correspondent = document.correspondent?.instanceID
            documentType = document.documentType?.instanceID
            tags = Set((document.tags ?? []).map(\.instanceID))
            modifiedAt = document.modifiedAt
            others = [
                document.id.uuidString, document.instanceID.uuidString, "\(document.createdAt)",
                "\(document.pageCount)",
                "\(document.fileSize)", document.sourceRaw, document.textSourceRaw, document.processingStateRaw,
                document.contentHash, document.originalFileName, "\(String(describing: document.deletedAt))",
            ]
        }
    }

    @MainActor private struct Library {
        let container: ModelContainer
        let editor: DocumentEditor
        let document: Document
        let stadtwerke: Correspondent
        let bank: Correspondent
        let invoice: DocumentType
        let letter: DocumentType
        let tax: DokumentumCore.Tag
        let auto: DokumentumCore.Tag
        /// Counts the container's saves.
        let saves: TestSignal
        let observer: any NSObjectProtocol

        var context: ModelContext { container.mainContext }
    }

    /// A document with every field set, and spare metadata to switch to.
    private func makeLibrary(container: ModelContainer? = nil) throws -> Library {
        let container = try container ?? TestSupport.makeContainer()
        let context = container.mainContext
        let stadtwerke = Correspondent(name: "Stadtwerke", createdAt: Self.created)
        let bank = Correspondent(name: "Musterbank", createdAt: Self.created)
        let invoice = DocumentType(name: "Invoice", createdAt: Self.created)
        let letter = DocumentType(name: "Letter", createdAt: Self.created)
        let tax = DokumentumCore.Tag(name: "Tax", createdAt: Self.created)
        let auto = DokumentumCore.Tag(name: "Auto", createdAt: Self.created)
        for record in [stadtwerke, bank] { context.insert(record) }
        for record in [invoice, letter] { context.insert(record) }
        for record in [tax, auto] { context.insert(record) }
        let document = Document(title: "Strom", createdAt: Self.created)
        document.pageCount = 3
        document.fileSize = 1234
        document.contentHash = "abc"
        document.originalFileName = "strom.pdf"
        document.sourceRaw = "scan"
        document.textSourceRaw = "vision"
        document.processingStateRaw = "done"
        context.insert(document)
        document.correspondent = stadtwerke
        document.documentType = invoice
        document.tags = [tax]
        try context.save()

        let saves = TestSignal()
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { notification in
            guard let saved = notification.object as? ModelContext, saved.container === container else { return }
            saves.fire()
        }
        return Library(
            container: container, editor: DocumentEditor(context: context, now: { Self.edited }), document: document,
            stadtwerke: stadtwerke, bank: bank, invoice: invoice, letter: letter, tax: tax, auto: auto, saves: saves,
            observer: observer)
    }

    /// Each change writes its own field, `modifiedAt` and nothing else, with one save. The same value again
    /// writes nothing and does not save.
    @Test(arguments: 0..<8)
    func eachFieldWritesOnlyItself(field: Int) throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let document = library.document
        let before = Fields(document)
        var expected = before
        let change: DocumentEditor.Change
        switch field {
        case 0:
            change = .title("  Strom Oktober ")
            expected.title = "Strom Oktober"
        case 1:
            change = .documentDate(Self.edited)
            expected.documentDate = Self.edited
        case 2:
            change = .inbox(false)
            expected.isInbox = false
        case 3:
            change = .correspondent(library.bank.instanceID)
            expected.correspondent = library.bank.instanceID
        case 4:
            change = .documentType(nil)
            expected.documentType = nil
        case 5:
            change = .tag(library.auto.instanceID, true)
            expected.tags = [library.tax.instanceID, library.auto.instanceID]
        case 6:
            // "None" in the picker.
            change = .correspondent(nil)
            expected.correspondent = nil
        default:
            change = .tag(library.tax.instanceID, false)
            expected.tags = []
        }
        expected.modifiedAt = Self.edited

        #expect(try library.editor.apply(change, to: document.instanceID) == .saved)
        #expect(library.saves.count == 1)
        #expect(!library.context.hasChanges)
        // Read back from the store, not from the edited object.
        let stored = try #require(
            try ModelContext(library.container).fetch(FetchDescriptor<Document>()).first {
                $0.instanceID == document.instanceID
            })
        #expect(Fields(stored) == expected)

        #expect(try library.editor.apply(change, to: document.instanceID) == .unchanged)
        #expect(library.saves.count == 1, "the same value saved again")
    }

    @Test func anUnchangedValueDoesNotTouch() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        let unchanged: [DocumentEditor.Change] = [
            .title("Strom"), .title(" Strom\n"), .documentDate(Self.created), .inbox(true),
            .correspondent(library.stadtwerke.instanceID), .documentType(library.invoice.instanceID),
            .tag(library.tax.instanceID, true), .tag(library.auto.instanceID, false),
        ]
        for change in unchanged {
            #expect(try library.editor.apply(change, to: instanceID) == .unchanged, "\(change)")
        }
        #expect(library.saves.count == 0)
        #expect(library.document.modifiedAt == Self.created)
    }

    /// The SQL of a title edit: one `UPDATE ZDOCUMENT` that sets the title and `modifiedAt` (and Core Data's
    /// optimistic-locking counter) and no other column. Runs under `swift test` on macOS only (`SQLLog`).
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func aTitleEditUpdatesOnlyTheTitleColumn() throws {
        let library = try makeLibrary(container: TestSupport.makeContainerOnDisk())
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let recording = try SQLLog.Recording()
        #expect(try library.editor.apply(.title("Strom Oktober"), to: library.document.instanceID) == .saved)
        let statements = try recording.statements()

        let updates = statements.filter { $0.hasPrefix("UPDATE ") }
        #expect(updates.count == 1, "\(statements)")
        let update = try #require(updates.first)
        #expect(SQLLog.statement(update, names: "ZDOCUMENT"), "\(update)")
        let set = try #require(update.range(of: " SET ")).upperBound
        let end = try #require(update.range(of: " WHERE ")).lowerBound
        let columns = update[set..<end].split(separator: ",").map {
            $0.split(separator: "=")[0].trimmingCharacters(in: .whitespaces)
        }
        #expect(Set(columns) == ["ZTITLE", "ZMODIFIEDAT", "Z_OPT"], "\(update)")
        // No other table is written: no relationship, no join table. Core Data's persistent history records the
        // transaction in its own tables.
        let written = Set(statements.compactMap(Self.writtenTable))
        #expect(
            written.subtracting(["ATRANSACTION", "ACHANGE", "ATRANSACTIONSTRING"]) == ["ZDOCUMENT"], "\(statements)")
    }

    /// The table an `INSERT`, `UPDATE` or `DELETE` statement writes; `nil` for any other statement.
    private static func writtenTable(_ statement: String) -> String? {
        let pattern = /^(?:INSERT(?: OR \w+)? INTO|UPDATE(?: OR \w+)?|DELETE FROM)\s+(\w+)/
        return (try? pattern.firstMatch(in: statement)).flatMap { $0.map { String($0.1) } }
    }

    @Test func modifiedAtMovesWithEachEdit() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        var clock = Self.edited
        let editor = DocumentEditor(context: library.context, now: { clock })
        try editor.apply(.inbox(false), to: library.document.instanceID)
        #expect(library.document.modifiedAt == Self.edited)
        clock = Self.edited.addingTimeInterval(60)
        try editor.apply(.title("Neu"), to: library.document.instanceID)
        #expect(library.document.modifiedAt == clock)
        #expect(library.document.createdAt == Self.created)
    }

    // MARK: Gone and trashed

    /// A document deleted by another context after the main context had read it: the edit finds nothing,
    /// writes nothing and does not crash.
    @Test func aDocumentDeletedMeanwhileIsNotEdited() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        // The main context has the document registered and read.
        #expect(library.document.title == "Strom")
        let other = ModelContext(library.container)
        for document in try other.fetch(FetchDescriptor<Document>()) { other.delete(document) }
        try other.save()
        #expect(library.saves.count == 1)

        for change: DocumentEditor.Change in [.title("Neu"), .inbox(false), .tag(library.auto.instanceID, true)] {
            #expect(try library.editor.apply(change, to: instanceID) == .noDocument)
        }
        #expect(try library.editor.apply(.title("Neu"), to: UUID()) == .noDocument)
        #expect(library.saves.count == 1)
        #expect(try library.context.fetchCount(FetchDescriptor<Document>()) == 0)
    }

    @Test func aTrashedDocumentIsNotEdited() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let trashedAt = Self.created.addingTimeInterval(10)
        library.document.deletedAt = trashedAt
        try library.context.save()
        let before = Fields(library.document)
        let savesBefore = library.saves.count

        for change: DocumentEditor.Change in [
            .title("Neu"), .documentDate(Self.edited), .inbox(false), .correspondent(nil), .documentType(nil),
            .tag(library.auto.instanceID, true), .tag(library.tax.instanceID, false),
        ] {
            #expect(try library.editor.apply(change, to: library.document.instanceID) == .trashed, "\(change)")
        }
        #expect(Fields(library.document) == before)
        #expect(library.document.deletedAt == trashedAt)
        #expect(library.saves.count == savesBefore)
    }

    /// A correspondent, type or tag that was merged away (or never existed) is not set.
    @Test func aTombstoneOrUnknownRecordIsNotSet() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        library.bank.mergedIntoID = library.stadtwerke.id
        library.letter.mergedIntoID = library.invoice.id
        library.auto.mergedIntoID = library.tax.id
        try library.context.save()
        let before = Fields(library.document)
        let instanceID = library.document.instanceID
        #expect(try library.editor.apply(.correspondent(library.bank.instanceID), to: instanceID) == .noMetadata)
        #expect(try library.editor.apply(.documentType(library.letter.instanceID), to: instanceID) == .noMetadata)
        #expect(try library.editor.apply(.tag(library.auto.instanceID, true), to: instanceID) == .noMetadata)
        #expect(try library.editor.apply(.correspondent(UUID()), to: instanceID) == .noMetadata)
        #expect(Fields(library.document) == before)
    }

    /// The library shows a tag merged into Tax as Tax (`LibraryMapping`), so unchecking Tax removes both.
    @Test func removingATagAlsoRemovesTombstonesShownAsIt() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let merged = DokumentumCore.Tag(name: "Steuer", createdAt: Self.created)
        let lost = DokumentumCore.Tag(name: "Lost", createdAt: Self.created)
        // Merged into Auto, so shown as Auto: unchecking Tax keeps it.
        let kfz = DokumentumCore.Tag(name: "Kfz", createdAt: Self.created)
        for tag in [merged, lost, kfz] { library.context.insert(tag) }
        merged.mergedIntoID = library.tax.id
        lost.mergedIntoID = UUID()
        kfz.mergedIntoID = library.auto.id
        library.document.tags = [library.tax, merged, lost, kfz]
        try library.context.save()

        #expect(
            try library.editor.apply(.tag(library.tax.instanceID, false), to: library.document.instanceID) == .saved)
        #expect(Set((library.document.tags ?? []).map(\.instanceID)) == [lost.instanceID, kfz.instanceID])

        // Only the tombstone left, shown as Tax: unchecking Tax removes it.
        library.document.tags = [merged]
        try library.context.save()
        #expect(
            try library.editor.apply(.tag(library.tax.instanceID, false), to: library.document.instanceID) == .saved)
        #expect(library.document.tags?.isEmpty == true)
    }

    // MARK: New metadata

    @Test func aSameNameCorrespondentOrTypeIsReused() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let mueller = Correspondent(name: "Müller GmbH", createdAt: Self.created)
        library.context.insert(mueller)
        try library.context.save()
        let correspondents = try library.context.fetchCount(FetchDescriptor<Correspondent>())
        let types = try library.context.fetchCount(FetchDescriptor<DocumentType>())

        #expect(try library.editor.createMetadata(kind: .correspondent, name: "  MULLER gmbh ") == mueller.instanceID)
        #expect(try library.editor.createMetadata(kind: .correspondent, name: "ｍüller GmbH") == mueller.instanceID)
        #expect(try library.editor.createMetadata(kind: .documentType, name: "invoice") == library.invoice.instanceID)
        #expect(try library.context.fetchCount(FetchDescriptor<Correspondent>()) == correspondents)
        #expect(try library.context.fetchCount(FetchDescriptor<DocumentType>()) == types)

        let new = try library.editor.createMetadata(kind: .correspondent, name: "  Dr. Beispiel ")
        let record = try #require(
            try library.context.fetch(FetchDescriptor<Correspondent>()).first { $0.instanceID == new })
        #expect(record.name == "Dr. Beispiel")
        #expect(record.createdAt == Self.edited)
        #expect(record.mergedIntoID == nil)
        #expect(!library.context.hasChanges, "a new record is saved")
        let newType = try library.editor.createMetadata(kind: .documentType, name: "Contract")
        #expect(try library.context.fetch(FetchDescriptor<DocumentType>()).contains { $0.instanceID == newType })
    }

    /// Several live records with the name: the first in `keeperOrder` (the one the repair's pass 2 keeps).
    /// A tombstone with the name is never reused.
    @Test func theKeeperOrderMinimumIsReusedAndTombstonesAreNot() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        let editor = DocumentEditor(context: context, now: { Self.edited })
        let tombstone = Correspondent(name: "Bank", createdAt: Self.created.addingTimeInterval(-100))
        tombstone.mergedIntoID = UUID()
        let newer = Correspondent(name: "Bank", createdAt: Self.created.addingTimeInterval(10))
        let older = Correspondent(name: "bank", createdAt: Self.created)
        // The same `createdAt`, the larger `instanceID`.
        let twin = Correspondent(name: "BANK", createdAt: Self.created)
        // Inserted newest first, so input order cannot pick the keeper by chance.
        for record in [tombstone, newer, twin, older] { context.insert(record) }
        if twin.instanceID.uuidString < older.instanceID.uuidString { swap(&twin.instanceID, &older.instanceID) }
        try context.save()
        #expect(try editor.createMetadata(kind: .correspondent, name: "Bank") == older.instanceID)

        // Only the tombstone: a new record.
        let lonely = Correspondent(name: "Sparkasse", createdAt: Self.created)
        lonely.mergedIntoID = UUID()
        context.insert(lonely)
        try context.save()
        let new = try editor.createMetadata(kind: .correspondent, name: "Sparkasse")
        #expect(new != lonely.instanceID)
    }

    /// Tags are reused only with the same parent: "golf" at the top level is not "Auto › Golf". New tags are top
    /// level, and a second top-level "Golf" reuses the first.
    @Test func aNewTagReusesOnlyATopLevelTagOfTheSameName() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let nested = DokumentumCore.Tag(name: "Golf", createdAt: Self.created)
        library.context.insert(nested)
        nested.parent = library.auto
        try library.context.save()

        let topLevel = try library.editor.createMetadata(kind: .tag, name: "golf")
        #expect(topLevel != nested.instanceID)
        let tags = try library.context.fetch(FetchDescriptor<DokumentumCore.Tag>())
        let created = try #require(tags.first { $0.instanceID == topLevel })
        #expect(created.parent == nil)
        #expect(created.name == "golf")
        #expect(try library.editor.createMetadata(kind: .tag, name: "Golf") == topLevel)
        #expect(try library.editor.createMetadata(kind: .tag, name: "TAX") == library.tax.instanceID)
        #expect(try library.context.fetchCount(FetchDescriptor<DokumentumCore.Tag>()) == tags.count)
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func anEmptyNameIsRefused(name: String) throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        for kind in MetadataKind.allCases {
            #expect(throws: DocumentEditor.MetadataError.emptyName) {
                try library.editor.createMetadata(kind: kind, name: name)
            }
        }
        #expect(library.saves.count == 0)
        #expect(!library.context.hasChanges)
    }

    /// A tag or type merged away keeps its name, but "New Tag…" and "New…" never return it: setting a tombstone
    /// would be refused (`.noMetadata`), and the user's choice would do nothing.
    @Test func aTombstoneTagOrTypeIsNotReused() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let tagTombstone = DokumentumCore.Tag(name: "Steuer", createdAt: Self.created.addingTimeInterval(-100))
        tagTombstone.mergedIntoID = library.tax.id
        let typeTombstone = DocumentType(name: "Vertrag", createdAt: Self.created.addingTimeInterval(-100))
        typeTombstone.mergedIntoID = library.invoice.id
        library.context.insert(tagTombstone)
        library.context.insert(typeTombstone)
        try library.context.save()

        let tag = try library.editor.createMetadata(kind: .tag, name: "steuer")
        let type = try library.editor.createMetadata(kind: .documentType, name: "Vertrag")
        #expect(tag != tagTombstone.instanceID)
        #expect(type != typeTombstone.instanceID)
        #expect(try library.editor.apply(.tag(tag, true), to: library.document.instanceID) == .saved)
        #expect(try library.editor.apply(.documentType(type), to: library.document.instanceID) == .saved)
    }

    // MARK: Failed saves

    private struct SaveFailed: Error {}

    /// A save that fails is rolled back: the field keeps its committed value, nothing stays pending, and the next
    /// edit's save writes only its own field.
    @Test func aFailedSaveIsRolledBack() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        let failing = DocumentEditor(context: library.context, now: { Self.edited }, save: { _ in throw SaveFailed() })
        #expect(throws: SaveFailed.self) { try failing.apply(.title("Lost"), to: instanceID) }
        #expect(throws: SaveFailed.self) { try failing.createMetadata(kind: .correspondent, name: "Neu") }
        #expect(!library.context.hasChanges)
        #expect(library.document.title == "Strom")
        #expect(library.document.modifiedAt == Self.created)
        #expect(try library.context.fetch(FetchDescriptor<Correspondent>()).allSatisfy { $0.name != "Neu" })

        #expect(try library.editor.apply(.inbox(false), to: instanceID) == .saved)
        let stored = try #require(
            try ModelContext(library.container).fetch(FetchDescriptor<Document>()).first { $0.instanceID == instanceID }
        )
        #expect(stored.title == "Strom")
        #expect(!stored.isInbox)
        #expect(try ModelContext(library.container).fetch(FetchDescriptor<Correspondent>()).count == 2)
    }

    // MARK: Frozen enums

    /// An edit keeps raw values a newer build wrote (as `FrozenEnumModelTests`), through a save and a reopen.
    @Test func unknownRawValuesSurviveAnEdit() throws {
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "Editor.store")
        let instanceID: UUID
        do {
            let container = try TestSupport.makeContainerOnDisk(at: url)
            let context = container.mainContext
            let document = Document(title: "From a newer build")
            document.sourceRaw = "fax"
            document.processingStateRaw = "queued"
            document.textSourceRaw = "braille"
            context.insert(document)
            try context.save()
            instanceID = document.instanceID
            let editor = DocumentEditor(context: context)
            #expect(try editor.apply(.title("Edited"), to: instanceID) == .saved)
            #expect(try editor.apply(.inbox(false), to: instanceID) == .saved)
            let tag = try editor.createMetadata(kind: .tag, name: "Neu")
            #expect(try editor.apply(.tag(tag, true), to: instanceID) == .saved)
        }
        let reopened = try TestSupport.makeContainerOnDisk(at: url)
        let read = try #require(
            try ModelContext(reopened).fetch(FetchDescriptor<Document>()).first { $0.instanceID == instanceID })
        #expect(read.title == "Edited")
        #expect(!read.isInbox)
        #expect(read.tags?.map(\.name) == ["Neu"])
        #expect([read.sourceRaw, read.processingStateRaw, read.textSourceRaw] == ["fax", "queued", "braille"])
    }
}
