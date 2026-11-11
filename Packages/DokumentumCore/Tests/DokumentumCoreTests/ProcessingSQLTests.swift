import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// What the queue's steps read (plan of #4, part 5): the scan reads only `Document` rows; the file's data is
/// read once per processed document, by key; the writes read no blob table (the file is compared by the
/// identifier on the document row). Each step is one synchronous call, so its SQL is recorded on one thread. Runs
/// under `swift test` only (`SQLLog.isReadable`).
struct ProcessingSQLTests {
    static let blobTables = ["ZDOCUMENTFILE", "ZDOCUMENTTEXT", "ZDOCUMENTTHUMBNAIL"]

    /// Three documents with a file, a thumbnail and a text whose text is not empty; one `done`. Returns the first.
    private func seed(_ store: ProcessingStore) throws -> UUID {
        var first: UUID?
        for index in 0..<3 {
            let id = try store.insert(
                title: "Document \(index)", stateRaw: index == 2 ? "done" : "pending", device: deviceA,
                claimedAt: processingStart)
            try store.edit(id) { document, context in
                let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data(count: 1_000))
                context.insert(thumbnail)
                document.thumbnail = thumbnail
                document.text?.extractedText = "text \(index)"
            }
            first = first ?? id
        }
        return try #require(first)
    }

    private func expectNoBlobTable(_ statements: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!statements.isEmpty, "nothing recorded", sourceLocation: sourceLocation)
        for statement in statements {
            for table in Self.blobTables {
                #expect(!SQLLog.statement(statement, names: table), "\(statement)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theScanSelectsOnlyFromDocument() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        _ = try seed(store)

        let recording = try SQLLog.Recording()
        let candidates = try ProcessingQueue.scan(in: store.container)
        let statements = try recording.statements()

        #expect(candidates.count == 2)
        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "\(statements)")
        expectNoBlobTable(statements)
    }

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theFileIsReadOnceByKeyAndNothingElseOfTheBlobs() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store)

        let recording = try SQLLog.Recording()
        let load = ProcessingQueue.loadFile(of: id, in: store.container)
        let statements = try recording.statements()

        guard case .file = load else {
            Issue.record("no file: \(load)")
            return
        }
        let fileReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTFILE") }
        #expect(fileReads.count == 1, "\(fileReads)")
        #expect(fileReads.allSatisfy { $0.contains("WHERE  t0.Z_PK IN  (?)") }, "not by key: \(fileReads)")
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTEXT"), "\(statement)")
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTHUMBNAIL"), "\(statement)")
        }
    }

    /// The claim write and the result write, each with its fetch, re-check, re-read and save.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theWritesReadNoBlobTable() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store)
        let file = try #require(try store.fileIdentifier(of: id))
        let claimedAt = processingStart.addingTimeInterval(hour)

        let claimRecording = try SQLLog.Recording()
        let claim = ProcessingQueue.write(
            .claim, id,
            expecting: .init(stateRaw: "pending", deviceID: deviceA, claimedAt: processingStart, file: file),
            in: store.container, beforeCheck: nil
        ) { document in
            document.processingClaimedAt = claimedAt
            document.processingState = .processing
        }
        let claimStatements = try claimRecording.statements()

        let resultRecording = try SQLLog.Recording()
        let result = ProcessingQueue.write(
            .result, id, expecting: .init(stateRaw: "processing", deviceID: deviceA, claimedAt: claimedAt, file: file),
            in: store.container, beforeCheck: nil
        ) { document in
            document.pageCount = 2
            document.processingState = .done
        }
        let resultStatements = try resultRecording.statements()

        #expect(claim == .saved)
        #expect(result == .saved)
        #expect(try store.row(id).stateRaw == "done")
        for statements in [claimStatements, resultStatements] {
            #expect(statements.contains { $0.contains("UPDATE OR FAIL ZDOCUMENT SET") }, "\(statements)")
            expectNoBlobTable(statements)
        }
    }
}
