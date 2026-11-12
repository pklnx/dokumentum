import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The SQL the indexer's reads run (plan of #7, Tests): the metadata re-read of every event never touches the
/// tables of texts, PDFs or thumbnails, and an update after one text write reads that one text row by key, never
/// the whole table. Synchronous on purpose (`SQLLog` records one thread); `swift test` only, where the SQL can be
/// read.
struct SearchIndexerSQLTests {
    static let largeTables = ["ZDOCUMENTTEXT", "ZDOCUMENTFILE", "ZDOCUMENTTHUMBNAIL"]

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theMetadataReadReadsNoLargeTable() throws {
        let container = try TestSupport.makeContainerOnDisk()
        try SearchStore.insert(
            title: "Rechnung", text: "Steuer", correspondent: "Finanzamt", tags: ["Haus"], in: container)
        try SearchStore.insert(title: "Brief", text: "Damen", in: container)

        let recording = try SQLLog.Recording()
        let fields = try SearchStoreReader.metadata(in: ModelContext(container))
        let statements = try recording.statements()

        #expect(fields.count == 2)
        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "no SELECT on ZDOCUMENT: \(statements)")
        for statement in statements {
            for table in Self.largeTables {
                #expect(!SQLLog.statement(statement, names: table), "\(statement)")
            }
        }
    }

    /// The update path after one text write: the history since the token, then the changed row by key.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func anUpdateReadsTheChangedTextRowByKeyOnly() throws {
        let container = try TestSupport.makeContainerOnDisk()
        var documents: [UUID] = []
        for number in 0..<5 {
            documents.append(try SearchStore.insert(title: "Akte \(number)", text: "alt \(number)", in: container))
        }
        let history = StoreSearchHistory(container: container)
        let token = try history.newestToken()
        try SearchStore.setText("neu", of: documents[2], in: container)

        let recording = try SQLLog.Recording()
        let (changes, newest) = try history.changes(since: token)
        let ids = changes.compactMap { change -> PersistentIdentifier? in
            if case .upsert(let id) = change { id } else { nil }
        }
        let rows = try SearchStoreReader.texts(ids, in: ModelContext(container))
        _ = try SearchStoreReader.metadata(in: ModelContext(container))
        let statements = try recording.statements()

        #expect(newest != nil && newest != token)
        #expect(rows.map(\.text) == ["neu"])
        let textReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTTEXT") && $0.contains("SELECT") }
        #expect(!textReads.isEmpty, "no SELECT on ZDOCUMENTTEXT: \(statements)")
        for statement in textReads {
            #expect(statement.contains("WHERE"), "an unkeyed read of the text table: \(statement)")
            #expect(statement.contains("Z_PK"), "a read of the text table not by key: \(statement)")
        }
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTFILE"), "\(statement)")
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTHUMBNAIL"), "\(statement)")
        }
    }
}
