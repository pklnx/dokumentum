import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Dokumentum

/// An importer that answers from a script by file name and records the names it was given, in order.
final class StubImporter: DocumentImporting {
    let outcomes: [String: ImportOutcome]
    private let calls = Mutex<[String]>([])

    init(_ outcomes: [String: ImportOutcome] = [:]) {
        self.outcomes = outcomes
    }

    var fileNames: [String] { calls.withLock { $0 } }

    func importFile(data: Data, fileName: String, contentType: UTType?, source: DocumentSource) async
        -> ImportOutcome
    {
        calls.withLock { $0.append(fileName) }
        return outcomes[fileName] ?? .failed(.storeFailed)
    }
}

/// A reader that returns fixed bytes, or fails for the URLs in `failing` (a file that cannot be downloaded).
struct StubReader: ImportFileReading {
    var data = Data("%PDF".utf8)
    var failing: Set<URL> = []

    func read(_ url: URL) async throws -> Data {
        if failing.contains(url) { throw CocoaError(.fileReadNoPermission) }
        return data
    }
}

/// A library whose snapshot the test sets.
@MainActor
private final class SnapshotSource: LibrarySource {
    var current: LibrarySnapshot
    let changes = AsyncStream<Void> { _ in }

    init(_ documents: [LibraryDocument]) {
        current = LibrarySnapshot(documents: documents)
    }

    func snapshot() -> LibrarySnapshot { current }

    nonisolated func loadPDF(instanceID: UUID) async -> PDFLoadState { .noDocument }
}

/// The window's imports (plan of #4, part 2): batch order, reader errors, the selection afterwards (PQ1), the
/// notice queue (PQ4), two windows on one importer, and the dropped files' copies.
@MainActor
struct ImportControllerTests {
    static let date = Date(timeIntervalSinceReferenceDate: 820_000_000)

    static func url(_ name: String) -> URL { URL(filePath: "/nonexistent/\(name)") }

    static func row(_ id: UUID, inbox: Bool = true, trashed: Bool = false) -> LibraryDocument {
        LibraryDocument(
            instanceID: id, title: "", documentDate: date, createdAt: date, isInbox: inbox,
            deletedAt: trashed ? date : nil)
    }

    @Test func aBatchKeepsItsOrderAndGoesOnAfterAFileThatCannotBeRead() async {
        let (a, c) = (UUID(), UUID())
        let importer = StubImporter(["a.pdf": .imported(instanceID: a), "c.pdf": .imported(instanceID: c)])
        let library = LibraryModel(source: SnapshotSource([Self.row(a), Self.row(c)]))
        let controller = ImportController(
            importer: importer, reader: StubReader(failing: [Self.url("b.pdf")]), library: library)

        let report = await controller.importFiles(["a.pdf", "b.pdf", "c.pdf"].map(Self.url))

        #expect(report.entries.map(\.fileName) == ["a.pdf", "b.pdf", "c.pdf"])
        #expect(
            report.entries.map(\.outcome) == [
                .imported(instanceID: a), .failed(.couldNotRead), .imported(instanceID: c),
            ])
        #expect(importer.fileNames == ["a.pdf", "c.pdf"], "the unread file never reaches the importer")
        #expect(controller.notices.shown != nil, "a failure is reported")
    }

    @Test func oneImportSelectsAndOpensItInTheInbox() async {
        let id = UUID()
        let source = SnapshotSource([])
        let library = LibraryModel(source: source)
        library.selection = .all
        // The importer's save is in the store before the controller reads it again.
        source.current = LibrarySnapshot(documents: [Self.row(id)])
        let controller = ImportController(
            importer: StubImporter(["a.pdf": .imported(instanceID: id)]), reader: StubReader(), library: library)

        await controller.importFiles([Self.url("a.pdf")])

        #expect(library.selection == .inbox)
        #expect(library.documents.map(\.instanceID) == [id], "the list shows the new document")
        #expect(library.selectedDocumentID == id)
        #expect(controller.notices.shown == nil, "nothing to report (PQ4)")
    }

    @Test func severalImportsShowTheInboxWithoutASelection() async {
        let (a, b) = (UUID(), UUID())
        let library = LibraryModel(source: SnapshotSource([Self.row(a), Self.row(b)]))
        library.selection = .all
        let controller = ImportController(
            importer: StubImporter(["a.pdf": .imported(instanceID: a), "b.pdf": .imported(instanceID: b)]),
            reader: StubReader(), library: library)

        await controller.importFiles([Self.url("a.pdf"), Self.url("b.pdf")])

        #expect(library.selection == .inbox)
        #expect(library.selectedDocumentID == nil)
    }

    @Test(arguments: [(true, false, LibrarySelection.inbox), (false, false, .all), (true, true, .trash)])
    func aSingleDuplicateSelectsTheExistingDocumentWhereItIs(inbox: Bool, trashed: Bool, list: LibrarySelection)
        async
    {
        let existing = UUID()
        let library = LibraryModel(source: SnapshotSource([Self.row(existing, inbox: inbox, trashed: trashed)]))
        library.selection = .documentType(UUID())
        let controller = ImportController(
            importer: StubImporter(["a.pdf": .duplicate(of: existing, title: "Alt", isTrashed: trashed)]),
            reader: StubReader(), library: library)

        await controller.importFiles([Self.url("a.pdf")])

        #expect(library.selection == list)
        #expect(library.selectedDocumentID == existing)
        #expect(controller.notices.shown != nil)
    }

    @Test func aNoticeWaitsWhileAnotherIsShown() async throws {
        let library = LibraryModel(source: SnapshotSource([]))
        let controller = ImportController(
            importer: StubImporter(["x.txt": .failed(.unsupportedType), "y.pdf": .failed(.passwordProtected)]),
            reader: StubReader(), library: library)

        await controller.importFiles([Self.url("x.txt")])
        let first = try #require(controller.notices.shown)
        await controller.importFiles([Self.url("y.pdf")])
        #expect(controller.notices.shown == first)
        #expect(controller.notices.waiting.count == 1)
        let second = try #require(controller.notices.waiting.first)
        #expect(first.message.contains("x.txt") && second.message.contains("y.pdf"))

        let next = controller.dismissNotice()
        #expect(controller.notices.shown == nil, "not in the same update as the dismissal")
        await next.value
        #expect(controller.notices.shown == second)
        #expect(controller.notices.waiting.isEmpty)
    }

    /// Two windows: two controllers on the app's one importer. The first import is held after its first
    /// duplicate check while the second window imports the same bytes; one document, one duplicate.
    @Test func twoWindowsOnOneImporterGiveOneDocumentAndOneDuplicate() async throws {
        let container = try makeInMemoryContainer()
        let importer = DocumentImporter(container: container, deviceID: "DEVICE-A")
        let reader = StubReader(data: SyntheticPDF.make(pages: [["Gleich"]]))
        let first = ImportController(
            importer: importer, reader: reader,
            library: LibraryModel(source: StoreLibrarySource(container: container)))
        let second = ImportController(
            importer: importer, reader: reader,
            library: LibraryModel(source: StoreLibrarySource(container: container)))
        let held = Checkpoint()
        defer { held.release() }
        let environment = ProcessingEnvironment(defaultsSuite: nil, importWillCommit: { await held.pass() })

        let firstRun = Task {
            await ProcessingEnvironment.$current.withValue(environment) {
                await first.importFiles([Self.url("Eins.pdf")])
            }
        }
        await held.reached()
        let secondReport = await second.importFiles([Self.url("Zwei.pdf")])
        held.release()
        let firstReport = await firstRun.value

        let documents = try container.mainContext.fetch(FetchDescriptor<Document>())
        #expect(documents.count == 1)
        let id = try #require(documents.first?.instanceID)
        #expect(secondReport.entries.map(\.outcome) == [.imported(instanceID: id)])
        #expect(firstReport.entries.map(\.outcome) == [.duplicate(of: id, title: "Zwei", isTrashed: false)])
    }

    @Test func aDroppedFileIsCopiedUnderItsNameAndTheCopyIsRemovedAfterTheImport() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DokumentumTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appending(path: "Rechnung März.pdf")
        let data = SyntheticPDF.make(pages: [["Rechnung"]])
        try data.write(to: original)

        let dropped = try ImportedFile(copying: original, into: folder.appending(path: "Dropped"))
        #expect(dropped.url.lastPathComponent == "Rechnung März.pdf")
        #expect(dropped.url != original)
        #expect(try Data(contentsOf: dropped.url) == data)

        let id = UUID()
        let importer = StubImporter(["Rechnung März.pdf": .imported(instanceID: id)])
        let controller = ImportController(
            importer: importer, reader: CoordinatedFileReader(), library: LibraryModel(source: SnapshotSource([])))
        let report = await controller.importDropped([dropped])

        #expect(report.entries.map(\.outcome) == [.imported(instanceID: id)])
        #expect(
            !FileManager.default.fileExists(atPath: dropped.url.deletingLastPathComponent().path(percentEncoded: false))
        )
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)), "the original stays")
    }

    @Test func theCoordinatedReaderReadsAFileAndFailsForAMissingOne() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DokumentumTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "a.pdf")
        try Data("bytes".utf8).write(to: file)

        #expect(try await CoordinatedFileReader().read(file) == Data("bytes".utf8))
        await #expect(throws: (any Error).self) {
            try await CoordinatedFileReader().read(folder.appending(path: "missing.pdf"))
        }
    }

    @Test func theSyntheticFilesAreTwoPDFsAndACopyOfTheFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DokumentumTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try UITestImportSynthetic.writeFiles(into: folder)

        #expect(
            urls.map(\.lastPathComponent) == [
                "Rechnung Stadtwerke.pdf", "Kontoauszug Oktober.pdf", "Rechnung Kopie.pdf",
            ])
        let bytes = try urls.map { try Data(contentsOf: $0) }
        #expect(bytes[0] == bytes[2])
        #expect(bytes[0] != bytes[1])
        #expect(
            !UITestImportSynthetic.isRequested(
                arguments: [UITestImportSynthetic.argument, "YES"],
                launchStore: LaunchStore(choice: .local, opened: .local)),
            "never into a store on disk")
        #expect(
            UITestImportSynthetic.isRequested(
                arguments: [UITestImportSynthetic.argument, "YES"],
                launchStore: LaunchStore(choice: .inMemory(seed: false), opened: .inMemory)))
    }
}
