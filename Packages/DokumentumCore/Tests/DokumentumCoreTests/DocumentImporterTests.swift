import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// The import pipeline (plan of #4, part 2): what one import writes, duplicates (PQ3), concurrent imports,
/// and the failures that insert nothing.
struct DocumentImporterTests {
    static let importTime = Date(timeIntervalSinceReferenceDate: 820_000_000)
    static let deviceID = "DEVICE-A"

    static func importer(_ container: ModelContainer) -> DocumentImporter {
        DocumentImporter(container: container, deviceID: deviceID, now: { importTime })
    }

    static func documents(in container: ModelContainer) throws -> [Document] {
        try ModelContext(container).fetch(FetchDescriptor<Document>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    @Test func aPDFLandsInTheInboxWithItsFileAndTextInOneSave() async throws {
        let container = try TestSupport.makeContainer()
        let saves = SaveCounter(container)
        let data = TestPDF.make(pages: ["Stadtwerke", "Seite zwei"])

        let outcome = await Self.importer(container).importFile(
            data: data, fileName: "Stromrechnung März.pdf", contentType: nil, source: .file)

        let documents = try Self.documents(in: container)
        let document = try #require(documents.first)
        #expect(documents.count == 1)
        #expect(outcome == .imported(instanceID: document.instanceID))
        #expect(saves.count == 1, "document, file and text in one save")
        #expect(document.title == "Stromrechnung März")
        #expect(document.originalFileName == "Stromrechnung März.pdf")
        #expect(document.source == .file)
        #expect(document.contentHash == ContentHash.sha256(data))
        #expect(document.fileSize == data.count)
        #expect(document.pageCount == 2)
        #expect(document.isInbox)
        #expect(document.createdAt == Self.importTime)
        #expect(document.documentDate == Self.importTime, "the import date until step 10 (PQ2)")
        #expect(document.processingState == .pending)
        #expect(document.processingDeviceID == Self.deviceID)
        #expect(document.processingClaimedAt == Self.importTime)
        let file = try #require(document.file)
        #expect(file.pdfData == data)
        #expect(file.documentID == document.id)
        let text = try #require(document.text)
        #expect(text.extractedText == "")
        #expect(text.documentID == document.id)
        // Every field the importer does not set keeps its default.
        #expect(document.deletedAt == nil)
        #expect(document.textSourceRaw == "")
        #expect(document.correspondent == nil)
        #expect(document.documentType == nil)
        #expect(document.tags ?? [] == [])
        #expect(document.thumbnail == nil)
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<DocumentFile>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<DocumentText>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<DocumentThumbnail>()) == 0)
    }

    /// Image bytes, so the declared type decides (PDF bytes would be a PDF without it, #86).
    @Test func aDeclaredTypeCountsWithoutAnExtension() async throws {
        let container = try TestSupport.makeContainer()
        let outcome = await Self.importer(container).importFile(
            data: TestImage.make(width: 400, height: 300), fileName: "Bon", contentType: .jpeg, source: .file)
        guard case .imported = outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        let document = try #require(try Self.documents(in: container).first)
        #expect(document.title == "Bon")
        #expect(document.source == .image)
    }

    @Test func theSameBytesUnderAnotherNameAreADuplicateAndOneChangedByteIsNot() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let data = TestPDF.make(pages: ["Vertrag"])
        let first = await importer.importFile(data: data, fileName: "Vertrag.pdf", contentType: nil, source: .file)
        guard case .imported(let id) = first else {
            Issue.record("not imported: \(first)")
            return
        }
        let saves = SaveCounter(container)

        let again = await importer.importFile(data: data, fileName: "Kopie.pdf", contentType: nil, source: .file)
        #expect(again == .duplicate(of: id, title: "Vertrag", isTrashed: false))
        #expect(saves.count == 0, "a duplicate writes nothing")

        let changed = Self.changingOneByte(data)
        #expect(changed.count == data.count && changed != data)
        let other = await importer.importFile(data: changed, fileName: "Vertrag.pdf", contentType: nil, source: .file)
        guard case .imported = other else {
            Issue.record("one changed byte is a new document: \(other)")
            return
        }
        #expect(try Self.documents(in: container).count == 2)
    }

    @Test func aDuplicateOfATrashedDocumentIsADuplicateAndStaysUntouched() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let data = TestPDF.make(pages: ["Alt"])
        _ = await importer.importFile(data: data, fileName: "Alt.pdf", contentType: nil, source: .file)
        let context = ModelContext(container)
        let trashed = try #require(try context.fetch(FetchDescriptor<Document>()).first)
        let deletedAt = Date(timeIntervalSinceReferenceDate: 830_000_000)
        trashed.deletedAt = deletedAt
        trashed.modifiedAt = deletedAt
        try context.save()

        let outcome = await importer.importFile(data: data, fileName: "Alt.pdf", contentType: nil, source: .file)

        #expect(outcome == .duplicate(of: trashed.instanceID, title: "Alt", isTrashed: true))
        let stored = try #require(try Self.documents(in: container).first)
        #expect(try Self.documents(in: container).count == 1)
        #expect(stored.deletedAt == deletedAt, "nothing is restored (PQ3)")
        #expect(stored.modifiedAt == deletedAt)
    }

    /// The first import waits after its first duplicate check (nothing in the store yet) while the second
    /// imports the same bytes completely; then the first commits. Its second check finds the new document.
    @Test func twoConcurrentImportsOfTheSameBytesGiveOneDocumentAndOneDuplicate() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let data = TestPDF.make(pages: ["Gleich"])
        let held = Checkpoint()
        defer { held.release() }

        let environment = ProcessingEnvironment(defaultsSuite: nil, importWillCommit: { await held.pass() })
        let first = Task {
            await ProcessingEnvironment.$current.withValue(environment) {
                await importer.importFile(data: data, fileName: "Eins.pdf", contentType: nil, source: .file)
            }
        }
        await held.reached()
        // No hook: it runs to its end while the first one is held.
        let second = await importer.importFile(data: data, fileName: "Zwei.pdf", contentType: nil, source: .file)
        held.release()
        let firstOutcome = await first.value

        let documents = try Self.documents(in: container)
        #expect(documents.count == 1)
        let document = try #require(documents.first)
        #expect(second == .imported(instanceID: document.instanceID))
        #expect(firstOutcome == .duplicate(of: document.instanceID, title: "Zwei", isTrashed: false))
    }

    @Test(arguments: [
        (TestCase.notAPDF, ImportFailure.unreadablePDF),
        (.wrongType, .unsupportedType),
        (.empty, .empty),
        (.noPages, .unreadablePDF),
        (.passwordProtected, .passwordProtected),
    ])
    func aFileThatFailsInsertsNothing(_ input: TestCase, failure: ImportFailure) async throws {
        let container = try TestSupport.makeContainer()
        let saves = SaveCounter(container)
        let outcome = await Self.importer(container).importFile(
            data: input.data, fileName: input.fileName, contentType: nil, source: .file)

        #expect(outcome == .failed(failure))
        #expect(saves.count == 0)
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Document>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DocumentFile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<DocumentText>()) == 0)
    }

    enum TestCase: Sendable, CustomTestStringConvertible {
        case notAPDF, wrongType, empty, noPages, passwordProtected

        var fileName: String { self == .wrongType ? "Notiz.txt" : "Datei.pdf" }

        var data: Data {
            switch self {
            case .notAPDF: Data("Kein PDF, nur Text.".utf8)
            case .wrongType: Data("Text".utf8)
            case .empty: Data()
            case .noPages: TestPDF.makeWithoutPages()
            case .passwordProtected: TestPDF.make(pages: ["Geheim"], userPassword: "geheim")
            }
        }

        var testDescription: String { "\(self)" }
    }

    /// The same PDF with one byte of its binary comment line (the second line, "%" and four or more bytes
    /// of 128 or more) changed: still a valid PDF, but other bytes.
    static func changingOneByte(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        guard let newline = bytes.firstIndex(of: 0x0A), bytes[newline + 1] == 0x25 else { return data }
        bytes[newline + 2] ^= 0x01
        return Data(bytes)
    }
}

/// Counts the saves of every context of one container (`ModelContext.didSave`), synchronously, as they
/// happen.
final class SaveCounter: Sendable {
    private let saves = Count()
    private let observer: NotificationToken

    init(_ container: ModelContainer) {
        let id = ObjectIdentifier(container)
        let saves = self.saves
        observer = NotificationToken(
            NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
                notification in
                guard let context = notification.object as? ModelContext, ObjectIdentifier(context.container) == id
                else { return }
                saves.value.withLock { $0 += 1 }
            })
    }

    var count: Int { saves.value.withLock { $0 } }

    final class Count: Sendable {
        let value = Mutex(0)
    }

    final class NotificationToken: @unchecked Sendable {
        let token: any NSObjectProtocol
        init(_ token: any NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
