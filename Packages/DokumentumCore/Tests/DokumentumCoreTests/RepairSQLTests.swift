import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// The repair never loads a linked blob (plan of #2, part 3, Revision 5): a run's SQL selects from
/// `ZDOCUMENTFILE`, `ZDOCUMENTTHUMBNAIL` and `ZDOCUMENTTEXT` only rows without a document
/// (`WHERE t0.ZDOCUMENT IS NULL`), and reads the linked kinds from the document row without a statement.
///
/// Synchronous on purpose: `SQLLog` records the statements of one thread, so the run goes through
/// `RepairRun.perform` on the test's thread. Runs under `swift test` on macOS only (`SQLLog.isReadable`).
struct RepairSQLTests {
    static let blobTables = ["ZDOCUMENTFILE", "ZDOCUMENTTHUMBNAIL", "ZDOCUMENTTEXT"]

    /// Documents with a linked file, thumbnail and 1,000-character text each, references to metadata, an
    /// orphan of every kind, and `pending` unlinked blobs waiting for document 1 (pass 4 relinks them).
    private func seed(_ store: TemporaryStore, pending: Bool) throws {
        let context = ModelContext(store.container)
        let correspondent = Correspondent(name: "Stadtwerke")
        let tag = DokumentumCore.Tag(name: "Haus")
        context.insert(correspondent)
        context.insert(tag)
        for index in 0..<3 {
            let document = Document(title: "Document \(index)")
            context.insert(document)
            document.correspondent = correspondent
            document.tags = [tag]
            if index == 0, pending {
                context.insert(DocumentFile(documentID: document.id, pdfData: Data(count: 200_000)))
                context.insert(DocumentThumbnail(documentID: document.id, imageData: Data(count: 20_000)))
                context.insert(
                    DocumentText(documentID: document.id, extractedText: String(repeating: "y", count: 1000)))
                continue
            }
            let file = DocumentFile(documentID: document.id, pdfData: Data(count: 200_000))
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data(count: 20_000))
            let text = DocumentText(documentID: document.id, extractedText: String(repeating: "x", count: 1000))
            context.insert(file)
            context.insert(thumbnail)
            context.insert(text)
            (document.file, document.thumbnail, document.text) = (file, thumbnail, text)
        }
        context.insert(DocumentFile(documentID: UUID(), pdfData: Data(count: 1000)))
        context.insert(DocumentThumbnail(documentID: UUID(), imageData: Data(count: 100)))
        context.insert(DocumentText(documentID: UUID(), extractedText: "orphan"))
        try context.save()
    }

    @Test(
        .enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"),
        arguments: [false, true])
    func aRunSelectsOnlyBlobsWithoutADocument(pending: Bool) throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try seed(store, pending: pending)

        let recording = try SQLLog.Recording()
        let report = try RepairRun.perform(in: store.container, now: Date(), hasCompletedImport: true)
        let statements = try recording.statements()

        #expect(report.plan.operations.count == (pending ? 3 : 0), "\(report.plan)")
        #expect(report.counts.orphanFiles == 1)
        #expect(report.counts.orphanTexts == 1)
        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "no SELECT on ZDOCUMENT: \(statements)")
        for table in Self.blobTables {
            let selects = statements.filter { $0.hasPrefix("SELECT") && SQLLog.statement($0, names: table) }
            let unlinked = selects.filter { $0.contains("t0.ZDOCUMENT IS NULL") }
            #expect(!unlinked.isEmpty, "no SELECT of unlinked rows on \(table): \(statements)")
            // Saving a relink selects the relinked blob again by its key, right before the UPDATE that links it
            // (measured: `context.save()` re-reads each object it updates). That row is the unlinked blob the
            // run fetched, so at most one such statement per relinked blob of the kind, and none without one.
            let byKey = selects.filter { $0.hasSuffix("WHERE  t0.Z_PK = ?") }
            #expect(byKey.count <= (pending ? 1 : 0), "\(byKey)")
            // `ConcurrentSaveWatcher` reads the rows the pass holds after each save to the store while the pass
            // runs, its own save included: then the blob it just linked, by `instanceID`, once.
            let watched = selects.filter { $0.hasSuffix("WHERE  t0.ZINSTANCEID IN  (?)") }
            #expect(watched.count <= (pending ? 1 : 0), "\(watched)")
            #expect(
                selects.count == unlinked.count + byKey.count + watched.count, "a SELECT of linked rows: \(selects)")
        }
    }

    /// The re-check read of a pass covers what the pass writes, not the archive (#56, review A): of 30
    /// documents, one points at a tombstone. The run's only read of every document is its planning read; the
    /// pass reads the one it re-points (`ZINSTANCEID IN (?)`), and the watcher the same one after the save.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func aPassReadsOnlyTheDocumentsItWrites() throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10)] + (2...30).map { document($0, correspondent: 11) },
                metadata: [correspondent(10, "Old", mergedInto: 11), correspondent(11, "New")]))

        let recording = try SQLLog.Recording()
        let report = try RepairRun.perform(in: store.container, now: Date(), hasCompletedImport: true)
        let statements = try recording.statements()

        #expect(report.plan.operations.count == 1)
        let documentReads = statements.filter { $0.hasPrefix("SELECT") && $0.contains("FROM ZDOCUMENT t0") }
        let whole = documentReads.filter { !$0.contains("WHERE") }
        #expect(whole.count == 1, "the archive is read once, to plan: \(documentReads)")
        let byInstance = documentReads.filter { $0.contains("t0.ZINSTANCEID IN") }
        #expect(!byInstance.isEmpty, "the pass read its document by instanceID: \(documentReads)")
        for statement in byInstance {
            #expect(statement.hasSuffix("IN  (?)"), "one document, not more: \(statement)")
        }
    }
}
