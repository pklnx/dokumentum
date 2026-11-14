import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The SQL the Spotlight indexer's reads run (#13, part 1; plan §3): the metadata read of every pass never touches the
/// tables of texts, PDFs or thumbnails, and a push reads the text and thumbnail rows of its documents by key only.
/// Synchronous on purpose (`SQLLog` records one thread); `swift test` only, where the SQL can be read.
struct SpotlightIndexerSQLTests {
    static let largeTables = ["ZDOCUMENTTEXT", "ZDOCUMENTFILE", "ZDOCUMENTTHUMBNAIL"]

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theMetadataReadReadsNoLargeTable() throws {
        let container = try TestSupport.makeContainerOnDisk()
        try SpotlightStore.insert(
            [
                .init(
                    title: "Rechnung", text: "Steuer", correspondent: "Finanzamt", tags: ["Haus"], thumbnail: Data([1])),
                .init(title: "Brief", text: "Damen"),
            ], in: container)

        let recording = try SQLLog.Recording()
        let documents = try SpotlightStoreReader.documents(in: ModelContext(container))
        let statements = try recording.statements()

        #expect(documents.count == 2)
        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "no SELECT on ZDOCUMENT: \(statements)")
        for statement in statements {
            for table in Self.largeTables {
                #expect(!SQLLog.statement(statement, names: table), "\(statement)")
            }
        }
    }

    /// The push of two of five documents reads their text and thumbnail rows by key, never the whole tables and never
    /// the PDFs.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func aPushReadsTextsAndThumbnailsByKeyOnly() throws {
        let container = try TestSupport.makeContainerOnDisk()
        let ids = try SpotlightStore.insert(
            (0..<5).map { .init(title: "Akte \($0)", text: "Text \($0)", thumbnail: Data([UInt8($0)])) }, in: container)

        let recording = try SQLLog.Recording()
        let contents = try SpotlightStoreReader.contents(of: [ids[1], ids[3]], in: ModelContext(container))
        let statements = try recording.statements()

        #expect(contents[ids[1]] == .init(text: "Text 1", thumbnail: Data([1])))
        #expect(contents[ids[3]] == .init(text: "Text 3", thumbnail: Data([3])))
        for table in ["ZDOCUMENTTEXT", "ZDOCUMENTTHUMBNAIL"] {
            let reads = statements.filter { SQLLog.statement($0, names: table) && $0.contains("SELECT") }
            #expect(!reads.isEmpty, "no SELECT on \(table): \(statements)")
            for statement in reads {
                #expect(statement.contains("WHERE"), "an unkeyed read of \(table): \(statement)")
                #expect(statement.contains("Z_PK"), "a read of \(table) not by key: \(statement)")
            }
        }
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTFILE"), "\(statement)")
        }
    }
}
