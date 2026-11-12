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

    /// The result write with the text (#6, part 2): it reads the text row by key, in the write and in the check
    /// before the save, and no other blob table.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theResultWriteReadsTheTextByKeyAndNoOtherBlob() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store)
        let file = try #require(try store.fileIdentifier(of: id))

        let recording = try SQLLog.Recording()
        let result = ProcessingQueue.write(
            .result, id,
            expecting: .init(stateRaw: "pending", deviceID: deviceA, claimedAt: processingStart, file: file),
            in: store.container, checksText: true, beforeCheck: nil
        ) { document in
            document.textSource = .vision
            document.text?.extractedText = "recognised"
            document.processingState = .done
        }
        let statements = try recording.statements()

        #expect(result == .saved)
        #expect(try store.text(of: id) == (.vision, "recognised"))
        let textReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTTEXT") && $0.contains("SELECT") }
        #expect(textReads.count >= 2, "the write's fault and the check's re-read: \(textReads)")
        #expect(
            textReads.allSatisfy { $0.contains("t0.Z_PK = ?") || $0.contains("t0.Z_PK IN  (?)") },
            "not by key: \(textReads)")
        #expect(statements.contains { $0.contains("UPDATE OR FAIL ZDOCUMENTTEXT SET") }, "\(statements)")
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTFILE"), "\(statement)")
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTHUMBNAIL"), "\(statement)")
        }
    }

    /// The result write with a text layer (#6, part 3): it reads the file row by key, in the write and in the check
    /// before the save, writes its data, and reads no thumbnail.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theResultWriteWithALayerReadsTheFileByKeyAndNoThumbnail() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store)
        let file = try #require(try store.fileIdentifier(of: id))
        let layered = TestPDF.makeImageOnly(pages: [["layered"]])

        let recording = try SQLLog.Recording()
        let result = ProcessingQueue.write(
            .result, id,
            expecting: .init(stateRaw: "pending", deviceID: deviceA, claimedAt: processingStart, file: file),
            in: store.container, checksText: true, checksFile: true, beforeCheck: nil
        ) { document in
            document.file?.pdfData = layered
            document.fileSize = layered.count
            document.processingState = .done
        }
        let statements = try recording.statements()

        #expect(result == .saved)
        #expect(try store.pdfData(of: id) == layered)
        let fileReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTFILE") && $0.contains("SELECT") }
        #expect(fileReads.count >= 2, "the write's fault and the check's re-read: \(fileReads)")
        #expect(
            fileReads.allSatisfy { $0.contains("t0.Z_PK = ?") || $0.contains("t0.Z_PK IN  (?)") },
            "not by key: \(fileReads)")
        #expect(statements.contains { $0.contains("UPDATE OR FAIL ZDOCUMENTFILE SET") }, "\(statements)")
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTHUMBNAIL"), "\(statement)")
        }
    }

    /// The re-queue pass's scan reads only `Document` rows; its writes no blob table.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theReQueuePassReadsNoBlobTable() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        _ = try seed(store)
        let pass = ProcessingRequeue(defaultsSuite: store.failures(deviceA).defaultsSuite)

        let recording = try SQLLog.Recording()
        let report = pass.run(in: store.container, deviceID: deviceA, now: processingStart)
        let statements = try recording.statements()

        #expect(report.requeued == 1, "the one `done` document")
        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "\(statements)")
        expectNoBlobTable(statements)
    }

    // MARK: Classification (#8, part 1)

    /// The classification step reads the text row once, by key, and the metadata rows; never a file or a thumbnail.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theClassificationReadsTheTextByKeyAndNoFileOrThumbnail() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store)
        try store.insertMetadata(.correspondent, "Stadtwerke")
        try store.insertMetadata(.tag, "Strom")

        let recording = try SQLLog.Recording()
        let input = ProcessingQueue.readClassificationInput(of: id, in: store.container)
        let statements = try recording.statements()

        #expect(input?.extractedText == "text 0")
        #expect(input?.known.correspondents == ["Stadtwerke"])
        let textReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTTEXT") }
        #expect(textReads.count == 1, "\(textReads)")
        #expect(textReads.allSatisfy { $0.contains("WHERE  t0.Z_PK IN  (?)") }, "not by key: \(textReads)")
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTFILE"), "\(statement)")
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTHUMBNAIL"), "\(statement)")
        }
    }

    /// The classification's result write, with its fetch, re-check, metadata lookup, re-read and save, reads no
    /// blob table (the text record is compared by the identifier on the document row).
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theClassificationWriteReadsNoBlobTable() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insertClassify()
        try store.insertMetadata(.tag, "Strom")
        let text = try #require(
            try ProcessingStore.fetch(id, in: ModelContext(store.container))?.text?.persistentModelID)
        let held = ProcessingQueue.Held(
            stateRaw: "classify", deviceID: deviceA, claimedAt: processingStart, file: nil, checksFile: false,
            text: text)
        let suggestion = SuggestionRules.check(billSuggestion, text: billText, now: processingStart)

        let recording = try SQLLog.Recording()
        let outcome = ProcessingQueue.writeClassification(
            id, expecting: held, suggestion: suggestion, now: processingStart, calendar: testCalendar,
            in: store.container, beforeCheck: nil)
        let statements = try recording.statements()

        #expect(outcome == .saved)
        expectNoBlobTable(statements)
    }
}
