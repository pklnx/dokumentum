import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// What the bulk run reads (plan of #10, T6): the scan only `Document` rows; a batch its documents, their text rows
/// by key and the metadata, never a file or a thumbnail. Each step is one synchronous call, so its SQL is recorded on
/// one thread. Runs under `swift test` only (`SQLLog.isReadable`).
struct MatchingRunSQLTests {
    /// Three documents with a file, a thumbnail and a text, and a rule that matches them.
    private func seed(_ store: ProcessingStore) throws -> [UUID] {
        try store.insertRule(.tag, "Strom", .any, "Strom")
        return try (0..<3).map { index in
            let id = try store.insertWithText("Strom \(index)", stateRaw: "done")
            try store.edit(id) { document, context in
                let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data(count: 1_000))
                context.insert(thumbnail)
                document.thumbnail = thumbnail
            }
            return id
        }
    }

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theScanSelectsOnlyFromDocument() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        _ = try seed(store)

        let recording = try SQLLog.Recording()
        let ids = try MatchingRun.scan(in: store.container)
        let statements = try recording.statements()

        #expect(ids.count == 3)
        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "\(statements)")
        for statement in statements {
            for table in ProcessingSQLTests.blobTables {
                #expect(!SQLLog.statement(statement, names: table), "\(statement)")
            }
        }
    }

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func aBatchReadsTheTextsByKeyAndNoFileOrThumbnail() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let ids = try seed(store)
        let rules = MatchingRules.Prepared(try MatchingStore.readRules(in: store.container))
        var slow: Set<UUID> = []
        var report = MatchingRun.Report()

        let recording = try SQLLog.Recording()
        try MatchingRun.runBatch(
            ids, rules: rules, budget: .production, slow: &slow, in: store.container, beforeCheck: nil, into: &report)
        let statements = try recording.statements()

        #expect(report.changed == 3)
        let textReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTTEXT") && $0.contains("SELECT") }
        #expect(!textReads.isEmpty, "\(statements)")
        #expect(
            textReads.allSatisfy { $0.contains("t0.Z_PK = ?") || $0.contains("t0.Z_PK IN ") },
            "not by key: \(textReads)")
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTFILE"), "\(statement)")
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTHUMBNAIL"), "\(statement)")
        }
    }
}
