import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import DokumentumCore

/// Images and photos become PDFs (plan of #4, part 3): the hash is the input's (T3), duplicates by that hash,
/// several photos in one document in their order, unreadable images. Every image is generated in the test.
struct DocumentImporterImageTests {
    static func importer(_ container: ModelContainer) -> DocumentImporter {
        DocumentImporterTests.importer(container)
    }

    static func documents(in container: ModelContainer) throws -> [Document] {
        try DocumentImporterTests.documents(in: container)
    }

    @Test func anImageFileBecomesAOnePagePDFWhoseHashIsTheImagesBytes() async throws {
        let container = try TestSupport.makeContainer()
        let saves = SaveCounter(container)
        let image = TestImage.make(width: 1200, height: 900)

        let outcome = await Self.importer(container).importFile(
            data: image, fileName: "Kassenbon.jpg", contentType: nil, source: .file)

        let document = try #require(try Self.documents(in: container).first)
        #expect(try Self.documents(in: container).count == 1)
        #expect(outcome == .imported(instanceID: document.instanceID))
        #expect(saves.count == 1, "document, file and text in one save")
        #expect(document.source == .image)
        #expect(document.title == "Kassenbon")
        #expect(document.originalFileName == "Kassenbon.jpg")
        #expect(document.isInbox)
        #expect(document.processingState == .pending)
        #expect(document.processingDeviceID == DocumentImporterTests.deviceID)
        let pdf = try #require(document.file?.pdfData)
        #expect(pdf.starts(with: Data("%PDF".utf8)), "the stored file is a PDF")
        #expect(document.pageCount == 1)
        #expect(document.fileSize == pdf.count)
        #expect(document.contentHash == ContentHash.sha256(image), "the hash of the image as received")
        #expect(document.contentHash != ContentHash.sha256(pdf), "never the built PDF's")
        #expect(document.text?.extractedText == "")
    }

    @Test func aSecondImportOfTheSameImageIsADuplicate() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let image = TestImage.make(width: 800, height: 600)
        let first = await importer.importFile(data: image, fileName: "Bon.jpg", contentType: nil, source: .file)
        guard case .imported(let id) = first else {
            Issue.record("not imported: \(first)")
            return
        }
        let saves = SaveCounter(container)

        let again = await importer.importFile(data: image, fileName: "Bon Kopie.jpg", contentType: .jpeg, source: .file)
        let asPhoto = await importer.importImages([image], fileName: "", title: "Photo", source: .image)

        #expect(again == .duplicate(of: id, title: "Bon", isTrashed: false))
        #expect(asPhoto == ImageImportResult(outcome: .duplicate(of: id, title: "Bon", isTrashed: false)))
        #expect(saves.count == 0, "a duplicate writes nothing")
        #expect(try Self.documents(in: container).count == 1)
    }

    @Test func threePhotosGiveOneThreePageDocumentInTheirOrder() async throws {
        let container = try TestSupport.makeContainer()
        let photos = [
            TestImage.make(width: 1200, height: 900),
            TestImage.make(width: 900, height: 1200, exifOrientation: 6),
            TestImage.make(width: 600, height: 600, type: .png),
        ]

        let result = await Self.importer(container).importImages(
            photos, fileName: "", title: "Photo 7.11.2026, 20:15", source: .image)

        let document = try #require(try Self.documents(in: container).first)
        #expect(try Self.documents(in: container).count == 1)
        #expect(result == ImageImportResult(outcome: .imported(instanceID: document.instanceID), leftOut: 0))
        #expect(document.title == "Photo 7.11.2026, 20:15")
        #expect(document.originalFileName == "")
        #expect(document.source == .image)
        #expect(document.pageCount == 3)
        #expect(document.contentHash == ContentHash.sha256(photos.reduce(Data(), +)), "the photos joined in order")
        let pdf = try #require(document.file?.pdfData)
        #expect(
            TestPDFReader.pageSizes(pdf) == [
                CGSize(width: 595, height: 446), CGSize(width: 595, height: 793), CGSize(width: 595, height: 595),
            ], "the pages in selection order")
    }

    /// The documented consequence of the hash rule (T3, PQ5): the same photos in another order are another
    /// selection, so another document; the same order again is a duplicate.
    @Test func theSamePhotosInAnotherOrderAreNotADuplicate() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let (a, b, c) = (
            TestImage.make(width: 300, height: 200, shade: 250), TestImage.make(width: 300, height: 200, shade: 240),
            TestImage.make(width: 300, height: 200, shade: 230)
        )

        let first = await importer.importImages([a, b, c], fileName: "", title: "Eins", source: .image)
        let reordered = await importer.importImages([c, a, b], fileName: "", title: "Zwei", source: .image)
        let again = await importer.importImages([a, b, c], fileName: "", title: "Drei", source: .image)

        guard case .imported(let id) = first.outcome, case .imported = reordered.outcome else {
            Issue.record("not imported: \(first), \(reordered)")
            return
        }
        #expect(again.outcome == .duplicate(of: id, title: "Eins", isTrashed: false))
        #expect(try Self.documents(in: container).map(\.title) == ["Eins", "Zwei"])
    }

    @Test func anUnreadablePhotoIsLeftOutCountedAndStillInTheHash() async throws {
        let container = try TestSupport.makeContainer()
        let photos = [TestImage.make(width: 400, height: 300), Data("kein Bild".utf8)]

        let result = await Self.importer(container).importImages(photos, fileName: "", title: "Foto", source: .image)

        let document = try #require(try Self.documents(in: container).first)
        #expect(result == ImageImportResult(outcome: .imported(instanceID: document.instanceID), leftOut: 1))
        #expect(document.pageCount == 1)
        #expect(document.contentHash == ContentHash.sha256(photos.reduce(Data(), +)))
    }

    /// The image path never rasterizes a PDF (#86, T3): Photos goes there without a type check. Alone it fails;
    /// among photos it is left out and counted, and its bytes stay in the hash.
    @Test func aPDFAmongPhotosIsNeverRasterized() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let saves = SaveCounter(container)
        let pdf = TestPDF.make(pages: ["Vertrag", "Seite 2", "Seite 3"])

        let alone = await importer.importImages([pdf], fileName: "", title: "Foto", source: .image)

        #expect(alone == ImageImportResult(outcome: .failed(.unreadableImage)))
        #expect(saves.count == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Document>()) == 0)

        let photo = TestImage.make(width: 400, height: 300)
        let mixed = await importer.importImages([photo, pdf], fileName: "", title: "Foto", source: .image)

        let document = try #require(try Self.documents(in: container).first, "not imported: \(mixed)")
        #expect(mixed == ImageImportResult(outcome: .imported(instanceID: document.instanceID), leftOut: 1))
        #expect(document.pageCount == 1)
        #expect(document.contentHash == ContentHash.sha256(photo + pdf), "the PDF's bytes stay in the hash")
    }

    @Test(arguments: [
        ("Kaputt.jpg", Data("kein Bild".utf8), ImportFailure.unreadableImage),
        ("Leer.png", Data(), .empty),
        ("Notiz.txt", Data("Text".utf8), .unsupportedType),
    ])
    func anImageThatFailsInsertsNothing(fileName: String, data: Data, failure: ImportFailure) async throws {
        let container = try TestSupport.makeContainer()
        let saves = SaveCounter(container)

        let outcome = await Self.importer(container).importFile(
            data: data, fileName: fileName, contentType: nil, source: .file)
        let photos = await Self.importer(container).importImages(
            [Data("kein Bild".utf8)], fileName: "", title: "Foto", source: .image)

        #expect(outcome == .failed(failure))
        #expect(photos == ImageImportResult(outcome: .failed(.unreadableImage)))
        #expect(saves.count == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Document>()) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DocumentFile>()) == 0)
    }

    /// Building takes time, so the commit checks again: the first import is held after its PDF was built while
    /// the second imports the same image completely. One document, one duplicate.
    @Test func twoConcurrentImportsOfTheSameImageGiveOneDocumentAndOneDuplicate() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let image = TestImage.make(width: 640, height: 480)
        let held = Checkpoint()
        defer { held.release() }

        let environment = ProcessingEnvironment(defaultsSuite: nil, importWillCommit: { await held.pass() })
        let first = Task {
            await ProcessingEnvironment.$current.withValue(environment) {
                await importer.importImages([image], fileName: "", title: "Eins", source: .image)
            }
        }
        await held.reached()
        let second = await importer.importFile(data: image, fileName: "Zwei.jpg", contentType: nil, source: .file)
        held.release()
        let firstResult = await first.value

        let document = try #require(try Self.documents(in: container).first)
        #expect(try Self.documents(in: container).count == 1)
        #expect(second == .imported(instanceID: document.instanceID))
        #expect(
            firstResult
                == ImageImportResult(outcome: .duplicate(of: document.instanceID, title: "Zwei", isTrashed: false)))
    }

    /// A multi-page TIFF through Files, ⌘O or drop (no type) and through the share queue (a declared type) is one
    /// document with a page per frame (#90); the hash is still the file's bytes, so the same TIFF again is a
    /// duplicate.
    @Test(arguments: [("Fax.tiff", nil), ("Fax", UTType.tiff)] as [(String, UTType?)])
    func aMultiPageTIFFFileBecomesOneDocumentWithAPagePerFrame(fileName: String, contentType: UTType?) async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let saves = SaveCounter(container)
        let tiff = TestImage.makeTIFF(frames: PDFBuilderTests.faxFrames)

        let outcome = await importer.importFile(data: tiff, fileName: fileName, contentType: contentType, source: .file)

        let document = try #require(try Self.documents(in: container).first)
        #expect(try Self.documents(in: container).count == 1)
        #expect(outcome == .imported(instanceID: document.instanceID))
        #expect(saves.count == 1)
        #expect(document.source == .image)
        #expect(document.title == "Fax")
        #expect(document.pageCount == 3)
        #expect(document.contentHash == ContentHash.sha256(tiff), "the hash of the TIFF as received")
        let pdf = try #require(document.file?.pdfData)
        #expect(TestPDFReader.pageSizes(pdf) == PDFBuilderTests.faxPageSizes)

        let again = await importer.importFile(data: tiff, fileName: fileName, contentType: contentType, source: .file)

        #expect(again == .duplicate(of: document.instanceID, title: "Fax", isTrashed: false))
        #expect(try Self.documents(in: container).count == 1)
    }

    /// A TIFF picked in Photos together with a photo: its frames follow the photo (#90).
    @Test func aTIFFAmongPhotosGivesAPagePerFrame() async throws {
        let container = try TestSupport.makeContainer()
        let photos = [TestImage.make(width: 640, height: 480), TestImage.makeTIFF(frames: PDFBuilderTests.faxFrames)]

        let result = await Self.importer(container).importImages(photos, fileName: "", title: "Foto", source: .image)

        let document = try #require(try Self.documents(in: container).first)
        #expect(result == ImageImportResult(outcome: .imported(instanceID: document.instanceID), leftOut: 0))
        #expect(document.pageCount == 4)
        #expect(document.contentHash == ContentHash.sha256(photos.reduce(Data(), +)))
        let pdf = try #require(document.file?.pdfData)
        #expect(TestPDFReader.pageSizes(pdf) == [CGSize(width: 595, height: 446)] + PDFBuilderTests.faxPageSizes)
    }

    /// A HEIC photo, the iPhone's format, where ImageIO can encode one to test with (not on every system).
    @Test(.enabled(if: TestImage.canEncodeHEIC, "ImageIO cannot encode HEIC here"))
    func aHEICPhotoBecomesAPortraitPage() async throws {
        let container = try TestSupport.makeContainer()
        let photo = TestImage.make(width: 900, height: 1200, type: .heic, exifOrientation: 6)

        let result = await Self.importer(container).importImages([photo], fileName: "", title: "HEIC", source: .image)

        let document = try #require(try Self.documents(in: container).first)
        #expect(result.outcome == .imported(instanceID: document.instanceID))
        #expect(document.contentHash == ContentHash.sha256(photo))
        let pdf = try #require(document.file?.pdfData)
        #expect(TestPDFReader.pageSizes(pdf) == [CGSize(width: 595, height: 793)])
    }
}
