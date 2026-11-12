import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import SwiftData
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Dokumentum

/// An importer that answers from a script by file name and records the names it was given, in order.
final class StubImporter: DocumentImporting {
    let outcomes: [String: ImportOutcome]
    /// The answer to `importImages`.
    let imagesResult: ImageImportResult
    private let calls = Mutex<[String]>([])
    private let imageCalls = Mutex<[(items: [Data], title: String?, source: DocumentSource)]>([])
    private let editedCalls = Mutex<[(items: [EditedImage], title: String, source: DocumentSource)]>([])
    /// Called at the start of each `importImages`, before it answers (a test reads the controller's state there).
    let onImportImages: (@Sendable () async -> Void)?

    init(
        _ outcomes: [String: ImportOutcome] = [:],
        images: ImageImportResult = ImageImportResult(outcome: .failed(.storeFailed)),
        onImportImages: (@Sendable () async -> Void)? = nil
    ) {
        self.outcomes = outcomes
        self.imagesResult = images
        self.onImportImages = onImportImages
    }

    var fileNames: [String] { calls.withLock { $0 } }
    /// The items, titles and sources `importImages` was given, per call.
    var imageImports: [(items: [Data], title: String?, source: DocumentSource)] { imageCalls.withLock { $0 } }
    /// The edited images, titles and sources `importEditedImages` was given, per call (#5, part 3).
    var editedImports: [(items: [EditedImage], title: String, source: DocumentSource)] {
        editedCalls.withLock { $0 }
    }

    func importImages(_ items: [Data], fileName: String, title: String?, source: DocumentSource) async
        -> ImageImportResult
    {
        imageCalls.withLock { $0.append((items, title, source)) }
        await onImportImages?()
        return imagesResult
    }

    /// The cleanup's edited import (#5, part 3) answers like `importImages`.
    func importEditedImages(_ items: [EditedImage], title: String, source: DocumentSource) async
        -> ImageImportResult
    {
        editedCalls.withLock { $0.append((items, title, source)) }
        return imagesResult
    }

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

/// A photo from the picker: its bytes, nothing (not handed over), or an error.
struct StubPhoto: ImportPhotoItem {
    var data: Data?
    var fails = false

    func loadData() async throws -> Data? {
        if fails { throw CocoaError(.fileReadUnknown) }
        return data
    }
}

/// A library whose snapshot the test sets.
@MainActor
final class SnapshotSource: LibrarySource {
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

    /// Photos picked together (#5, part 3, plan test 17): they open the cleanup, a page per photo in selection
    /// order, and nothing is imported until Save; Save imports the kept pages as one edited import, titled with the
    /// time, which opens (PQ1).
    @Test func photosOpenTheCleanupAndSaveImportsThemTogetherWithAPhotoTitle() async throws {
        let id = UUID()
        let importer = StubImporter(images: ImageImportResult(outcome: .imported(instanceID: id)))
        let library = LibraryModel(source: SnapshotSource([Self.row(id)]))
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: library, detector: StubPageDetector(),
            now: { Self.date })
        let bytes = ["eins", "zwei", "drei"].map(CleanupPhotos.photo)

        let picked = await controller.importPhotos(bytes.map { StubPhoto(data: $0) })

        #expect(picked.entries.isEmpty, "nothing imported before Save")
        #expect(importer.imageImports.isEmpty && importer.editedImports.isEmpty)
        let cleanup = try #require(controller.cleanup)
        #expect(cleanup.pages.map(\.image) == [0, 1, 2])
        #expect(cleanup.images == bytes)

        // Save closes the sheet first and imports once it is gone (the sheet's onDismiss).
        controller.closeCleanupForSave()
        #expect(controller.cleanup == nil)
        #expect(controller.isSavingPhotos, "“Saving photos…” while the import runs")
        #expect(importer.editedImports.isEmpty, "nothing imported while the sheet closes")
        let report = await controller.importSavedCleanup()
        #expect(!controller.isSavingPhotos)
        #expect(await controller.importSavedCleanup().entries.isEmpty, "imported once")

        let call = try #require(importer.editedImports.first)
        #expect(importer.editedImports.count == 1)
        #expect(importer.imageImports.isEmpty, "not the unedited import")
        #expect(call.items.map(\.data) == bytes)
        #expect(call.title == ImportController.photoTitle(at: Self.date))
        #expect(call.source == .image)
        #expect(report.entries.map(\.outcome) == [.imported(instanceID: id)])
        #expect(controller.cleanup == nil)
        #expect(library.selection == .inbox)
        #expect(library.selectedDocumentID == id, "one new document opens (PQ1)")
        #expect(controller.notices.shown == nil, "nothing to report (PQ4)")
    }

    /// A photo Photos cannot hand over, or one that is no image, is not in the cleanup and is counted, after
    /// Save, with the ones the importer could not decode.
    @Test func aPhotoThatIsNotHandedOverOrNotAnImageIsLeftOutAndCounted() async throws {
        let id = UUID()
        let importer = StubImporter(images: ImageImportResult(outcome: .imported(instanceID: id), leftOut: 1))
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([Self.row(id)])),
            detector: StubPageDetector())
        let (first, last) = (CleanupPhotos.photo("eins"), CleanupPhotos.photo("vier"))

        await controller.importPhotos([
            StubPhoto(data: first), StubPhoto(data: nil), StubPhoto(fails: true),
            StubPhoto(data: Data("kein Bild".utf8)), StubPhoto(data: last),
        ])
        #expect(controller.cleanup?.images.count == 3, "the bytes handed over")
        #expect(controller.cleanup?.pages.map(\.image) == [0, 2], "a page for each image")
        let report = await controller.saveCleanup()

        #expect(importer.editedImports.first?.items.map(\.data) == [first, last])
        #expect(report.entries.map(\.leftOut) == [4])
        let notice = try #require(controller.notices.shown)
        #expect(notice.message == String(localized: "\(4) photos could not be read and were left out."))
    }

    /// Review 5867292360, finding 3: a Save whose sheet never reported its dismissal is imported when the next pick
    /// opens, before that pick's cleanup, and never by the next sheet's dismissal (here after its Cancel).
    @Test func aSaveWhoseSheetDidNotReportItsDismissalIsImportedBeforeTheNextPick() async throws {
        let id = UUID()
        let importer = StubImporter(images: ImageImportResult(outcome: .imported(instanceID: id)))
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([Self.row(id)])),
            detector: StubPageDetector())
        let (first, second) = (CleanupPhotos.photo("eins"), CleanupPhotos.photo("zwei"))

        await controller.importPhotos([StubPhoto(data: first)])
        controller.closeCleanupForSave()
        #expect(importer.editedImports.isEmpty, "no dismissal reported yet")

        await controller.importPhotos([StubPhoto(data: second)])
        #expect(importer.editedImports.map { $0.items.map(\.data) } == [[first]], "the first Save, before the new pick")
        #expect(controller.cleanup?.images == [second])

        controller.cancelCleanup()
        await controller.importSavedCleanup()
        #expect(importer.editedImports.count == 1, "the second sheet's Cancel imports nothing")
    }

    @Test func noPhotoHandedOverIsOneFailureAndOpensNoCleanup() async throws {
        let importer = StubImporter()
        let controller = ImportController(
            importer: importer, reader: StubReader(), library: LibraryModel(source: SnapshotSource([])),
            detector: StubPageDetector(), now: { Self.date })

        let report = await controller.importPhotos([StubPhoto(data: nil), StubPhoto(fails: true)])

        #expect(controller.cleanup == nil)
        #expect(importer.imageImports.isEmpty && importer.editedImports.isEmpty)
        #expect(report.entries.map(\.outcome) == [.failed(.couldNotRead)])
        #expect(report.entries.map(\.fileName) == [ImportController.photoTitle(at: Self.date)])
        #expect(controller.notices.shown != nil)
        #expect(await controller.importPhotos([]).entries.isEmpty, "an empty pick is no batch")
    }

    /// Photos handed over that are no images: one failure, no cleanup.
    @Test func noReadablePhotoIsOneFailureAndOpensNoCleanup() async throws {
        let controller = ImportController(
            importer: StubImporter(), reader: StubReader(), library: LibraryModel(source: SnapshotSource([])),
            detector: StubPageDetector(), now: { Self.date })

        let report = await controller.importPhotos([StubPhoto(data: Data("kein Bild".utf8))])

        #expect(controller.cleanup == nil)
        #expect(report.entries.map(\.outcome) == [.failed(.unreadableImage)])
        #expect(controller.notices.shown != nil)
    }

    /// The files picker, ⌘O and a drop accept images as well as PDFs (part 3).
    @Test func thePickerAcceptsPDFsAndImages() {
        #expect(ImportController.importableTypes == [.pdf, .image])
    }

    @Test func theSyntheticFilesAreTwoPDFsAPortraitPhotoAndACopyOfTheFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DokumentumTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try UITestImportSynthetic.writeFiles(into: folder)

        #expect(
            urls.map(\.lastPathComponent) == [
                "Rechnung Stadtwerke.pdf", "Kontoauszug Oktober.pdf", "Kassenbon Bäckerei.jpg", "Rechnung Kopie.pdf",
            ])
        let bytes = try urls.map { try Data(contentsOf: $0) }
        #expect(bytes[0] == bytes[3])
        #expect(bytes[0] != bytes[1])
        // The photo is stored as landscape pixels with orientation 6 and becomes a portrait page.
        let page = try #require(PDFBuilder.makePDF(fromImageData: [bytes[2]]))
        let size = try #require(PDFDocument(data: page.data)?.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(size.height > size.width, "a portrait page: \(size)")
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
