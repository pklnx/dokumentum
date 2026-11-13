import DokumentumCore
import DokumentumKit
import Foundation
import PDFKit
import SwiftData
import Testing

@testable import Dokumentum

/// Detection end to end in the app (#11, part 2): `ImportController` imports a `SyntheticLetters` entry as a text
/// PDF (`SyntheticPDF.makeLetter`) through the real importer, the queue runs with the real stage and no classifier
/// (the `done` path), and the document has the letter's correspondent and date. In-memory store; the queue is run
/// by the test, as no scheduler runs on such a store.
@MainActor
struct DetectionImportTests {
    @Test func anImportedLetterGetsItsCorrespondentAndDate() async throws {
        let container = try makeInMemoryContainer()
        let letter = try #require(SyntheticLetters.letter("din-a-stadtwerke"))
        let deviceID = "DEVICE-A"
        let suite = "DokumentumTests-DetectionImport-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let controller = ImportController(
            importer: DocumentImporter(container: container, deviceID: deviceID),
            reader: StubReader(data: SyntheticPDF.makeLetter(letter)),
            library: LibraryModel(source: StoreLibrarySource(container: container)))

        let imported = await controller.importFiles([URL(filePath: "/letters/din-a-stadtwerke.pdf")])
        #expect(imported.imported.count == 1)
        let report = await ProcessingQueue(
            container: container, deviceID: deviceID, failures: ProcessingFailures(defaultsSuite: suite)
        ).run()

        #expect(report.done == 1)
        #expect(report.detectedCorrespondents == 1)
        #expect(report.detectedDates == 1)
        let document = try #require(try ModelContext(container).fetch(FetchDescriptor<Document>()).first)
        #expect(document.correspondent?.name == "Stadtwerke Musterstadt GmbH")
        let day = Calendar.current.dateComponents([.year, .month, .day], from: document.documentDate)
        #expect(day == DateComponents(year: 2026, month: 11, day: 13))
        #expect(document.modifiedAt == document.createdAt, "no touch()")
    }

    @Test func theLetterPDFHasTheLettersTextAtItsPageSize() throws {
        let letter = try #require(SyntheticLetters.letter("din-b-us-legal"))
        let page = try #require(PDFDocument(data: SyntheticPDF.makeLetter(letter))?.page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        #expect(abs(size.width - 612) < 0.5)
        #expect(abs(size.height - 1008) < 0.5)
        #expect(page.string?.contains("Stadtbibliothek Musterstadt · Postfach 5 55") == true)
    }

    /// The argument is honoured only with `-UITestLocalStore` on a store on disk, and only for a known letter.
    @Test func theImportArgumentNeedsALocalStoreOnDisk() {
        let local = LaunchStore(choice: .local, opened: .local)
        let memory = LaunchStore(choice: .inMemory(seed: false), opened: .inMemory)
        let withStore = ["-UITestLocalStore", "Smoke", "-UITestImportLetter", "din-a-stadtwerke"]

        #expect(UITestImportLetter.letter(arguments: withStore, launchStore: local)?.id == "din-a-stadtwerke")
        #expect(UITestImportLetter.letter(arguments: withStore, launchStore: memory) == nil)
        #expect(
            UITestImportLetter.letter(arguments: ["-UITestImportLetter", "din-a-stadtwerke"], launchStore: local)
                == nil, "the archive's own store")
        #expect(
            UITestImportLetter.letter(
                arguments: ["-UITestLocalStore", "Smoke", "-UITestImportLetter", "unknown"], launchStore: local) == nil)
        #expect(UITestImportLetter.letter(arguments: ["-UITestLocalStore", "Smoke"], launchStore: local) == nil)
    }
}
