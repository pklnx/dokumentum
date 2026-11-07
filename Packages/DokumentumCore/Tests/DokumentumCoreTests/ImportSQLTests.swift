import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The duplicate check reads only `Document` rows, never the file, the text or the thumbnail (plan of #4,
/// part 2): the predecessor's fallback that hashed stored PDFs of the same size is gone. Runs under
/// `swift test` only, where the SQL can be read (`SQLLog.isReadable`).
struct ImportSQLTests {
    static let blobTables = ["ZDOCUMENTFILE", "ZDOCUMENTTEXT", "ZDOCUMENTTHUMBNAIL"]

    /// A hash that is there and one that is not, for which a size fallback would have a candidate: a
    /// document whose file has the probe's size. Synchronous on purpose: `SQLLog` records one thread.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theDuplicateCheckReadsNoBlobTable() throws {
        let container = try TestSupport.makeContainerOnDisk()
        let probe = Data(repeating: 7, count: 4_096)
        let stored = try Self.seed(container, fileSize: probe.count)

        for (hash, expectsMatch) in [(stored, true), (ContentHash.sha256(probe), false)] {
            let context = ModelContext(container)
            let recording = try SQLLog.Recording()
            let match = try DocumentImporter.existingDocument(withHash: hash, in: context)
            let statements = try recording.statements()

            #expect((match != nil) == expectsMatch)
            #expect(
                statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "no SELECT on ZDOCUMENT: \(statements)")
            for statement in statements {
                for table in Self.blobTables {
                    #expect(!SQLLog.statement(statement, names: table), "\(statement)")
                }
            }
        }
    }

    /// Three documents with a file of `fileSize` bytes, a thumbnail and a text; one is trashed. Returns the
    /// first one's hash.
    static func seed(_ container: ModelContainer, fileSize: Int) throws -> String {
        let context = ModelContext(container)
        var first = ""
        for index in 0..<3 {
            let bytes = Data(repeating: UInt8(index), count: fileSize)
            let document = Document(title: "Document \(index)")
            document.contentHash = ContentHash.sha256(bytes)
            document.fileSize = fileSize
            if index == 0 { first = document.contentHash }
            if index == 2 { document.deletedAt = .now }
            let file = DocumentFile(documentID: document.id, pdfData: bytes)
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data(count: 1_000))
            let text = DocumentText(documentID: document.id, extractedText: "text")
            for model in [document, file, thumbnail, text] as [any PersistentModel] { context.insert(model) }
            document.file = file
            document.thumbnail = thumbnail
            document.text = text
        }
        try context.save()
        return first
    }
}
