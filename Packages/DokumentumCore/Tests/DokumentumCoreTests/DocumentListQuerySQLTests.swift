import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The automated SQL proof of #2's DW4: the list fetch reads the document rows and never the tables of the
/// text, the PDF or the thumbnail. SwiftData on 27 ignores `propertiesToFetch` (measured on #29), so this holds
/// only because those are records of their own; this test is what notices if that changes.
struct DocumentListQuerySQLTests {
    static let largeTables = ["ZDOCUMENTTEXT", "ZDOCUMENTFILE", "ZDOCUMENTTHUMBNAIL"]

    /// Synchronous on purpose: `SQLLog` records the statements of one thread.
    @Test(arguments: [DocumentListQuery.Filter.inbox, .all, .trash])
    func theListFetchReadsNoLargeTable(filter: DocumentListQuery.Filter) throws {
        let container = try TestSupport.makeContainerOnDisk()
        try Self.seed(container)
        // After seeding, which writes `INSERT INTO ZDOCUMENTTEXT` and the like.
        let recording = try SQLLog.Recording()
        let rows = try DocumentListQuery.fetch(filter, in: ModelContext(container))
        _ = rows.map { ($0.title, $0.correspondent?.name, $0.tagInstanceIDs.count) }
        let statements = try recording.statements()

        #expect(rows.count == (filter == .trash ? 1 : 2))
        let documentReads = statements.filter { $0.contains("FROM ZDOCUMENT t0") }
        #expect(!documentReads.isEmpty, "no SELECT on ZDOCUMENT was recorded; is the SQL log on? \(statements)")
        for statement in statements {
            for table in Self.largeTables {
                #expect(!SQLLog.statement(statement, names: table), "\(statement)")
            }
        }
    }

    @Test func theTableMatchIsAWholeWord() {
        #expect(SQLLog.statement("SELECT 0 FROM ZDOCUMENTTEXT t0", names: "ZDOCUMENTTEXT"))
        #expect(!SQLLog.statement("SELECT 0 FROM ZDOCUMENTTEXT t0", names: "ZDOCUMENT"))
        #expect(!SQLLog.statement("SELECT t0.ZTEXT FROM ZDOCUMENT t0", names: "ZDOCUMENTTEXT"))
    }

    /// Two listed documents and a trashed one, each with a file, a thumbnail and a 1,000-character text,
    /// a correspondent and tags.
    static func seed(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        let correspondent = Correspondent(name: "Stadtwerke")
        let tag = DokumentumCore.Tag(name: "Haus")
        context.insert(correspondent)
        context.insert(tag)
        for index in 0..<3 {
            let document = Document(title: "Document \(index)")
            if index == 2 { document.deletedAt = .now }
            context.insert(document)
            let file = DocumentFile(documentID: document.id, pdfData: Data(count: 200_000))
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data(count: 20_000))
            let text = DocumentText(documentID: document.id, extractedText: String(repeating: "x", count: 1000))
            context.insert(file)
            context.insert(thumbnail)
            context.insert(text)
            document.file = file
            document.thumbnail = thumbnail
            document.text = text
            document.correspondent = correspondent
            document.tags = [tag]
        }
        try context.save()
    }
}
