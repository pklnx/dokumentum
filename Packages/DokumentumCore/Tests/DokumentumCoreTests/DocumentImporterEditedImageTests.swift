import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// Edited photos become one document (#5, step 4, plan tests 7 and 8): pages in order with their edits, and
/// the duplicate hash of today's photo import (the coordinator's decision on #5: the original bytes of the
/// images that keep a page, each image once; the edits do not enter it). Every image is rendered in the test.
struct DocumentImporterEditedImageTests {
    static func importer(_ container: ModelContainer) -> DocumentImporter {
        DocumentImporterTests.importer(container)
    }

    static func documents(in container: ModelContainer) throws -> [Document] {
        try DocumentImporterTests.documents(in: container)
    }

    static let otherCorners = PageQuad(
        topLeft: CGPoint(x: 0.12, y: 0.10), topRight: CGPoint(x: 0.86, y: 0.12),
        bottomRight: CGPoint(x: 0.88, y: 0.88), bottomLeft: CGPoint(x: 0.10, y: 0.86))

    /// Test 7: three photographed pages, the middle one removed by the caller, the first cropped and turned
    /// once; an item that is no image is left out and counted.
    @Test func editedPhotosBecomeOneDocumentWithTheirEdits() async throws {
        let container = try TestSupport.makeContainer()
        let first = TestPage.photographed(corners: TestPage.tiltedCorners)
        let removed = TestPage.photographed(corners: Self.otherCorners)
        let third = TestPage.photographed(corners: Self.otherCorners, tinted: true)
        let junk = Data("kein Bild".utf8)
        let items = [
            EditedImage(
                data: first, edit: PageEdit(corners: TestPage.tiltedCorners, quarterTurns: 1, filter: .enhanced)),
            EditedImage(data: removed, pages: []),
            EditedImage(data: junk),
            EditedImage(data: third, edit: PageEdit(corners: Self.otherCorners, filter: .grayscale)),
        ]

        let result = await Self.importer(container).importEditedImages(
            items, title: "Photo 11.11.2026, 9:00", source: .image)

        let document = try #require(try Self.documents(in: container).first)
        #expect(try Self.documents(in: container).count == 1)
        #expect(result == ImageImportResult(outcome: .imported(instanceID: document.instanceID), leftOut: 1))
        #expect(document.source == .image)
        #expect(document.title == "Photo 11.11.2026, 9:00")
        #expect(document.originalFileName == "")
        #expect(document.pageCount == 2)
        #expect(document.processingState == .pending)
        #expect(document.contentHash == ContentHash.sha256(concatenating: [first, junk, third]))
        let pdf = try #require(document.file?.pdfData)
        let sizes = TestPDFReader.pageSizes(pdf)
        try #require(sizes.count == 2)
        #expect(sizes[0].width > sizes[0].height, "page 1 is landscape after one turn: \(sizes[0])")
        #expect(sizes[1].height > sizes[1].width, "page 2 is portrait: \(sizes[1])")
        let marker = try #require(TestPDFReader.color(pdf, page: 0, atFraction: CGPoint(x: 0.91, y: 0.13)))
        #expect(PageCleanupTests.isDark(marker, 60), "page 1's marker at the top right: \(marker)")
        let corner = try #require(TestPDFReader.color(pdf, page: 1, atFraction: CGPoint(x: 0.02, y: 0.98)))
        #expect(min(corner.0, corner.1, corner.2) >= 150, "page 2 cropped, no desk: \(corner)")
        let band = try #require(TestPDFReader.color(pdf, page: 1, atFraction: TestPixels.center(TestPage.redBand)))
        #expect(abs(band.0 - band.1) <= 3 && abs(band.1 - band.2) <= 3, "page 2 grey: \(band)")
    }

    /// The source passed is the document's.
    @Test func theSourceIsThePassedOne() async throws {
        let container = try TestSupport.makeContainer()

        _ = await Self.importer(container).importEditedImages(
            [EditedImage(data: TestImage.make(width: 400, height: 300))], title: "Scan", source: .scan)

        #expect(try Self.documents(in: container).first?.source == .scan)
    }

    /// Test 8 (today's rule): identity edits and other edits of the same photos are duplicates of
    /// `importImages` of them.
    @Test func theSamePhotosAreADuplicateWhateverTheEdits() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let photos = [TestPage.photographed(corners: TestPage.tiltedCorners), TestImage.make(width: 640, height: 480)]
        let plain = await importer.importImages(photos, fileName: "", title: "Photo", source: .image)
        guard case .imported(let id) = plain.outcome else {
            Issue.record("not imported: \(plain)")
            return
        }
        let duplicate = ImageImportResult(outcome: .duplicate(of: id, title: "Photo", isTrashed: false))

        let identity = await importer.importEditedImages(
            photos.map { EditedImage(data: $0) }, title: "x", source: .image)
        let edited = await importer.importEditedImages(
            [
                EditedImage(data: photos[0], edit: PageEdit(corners: TestPage.tiltedCorners, filter: .enhanced)),
                EditedImage(data: photos[1], edit: PageEdit(quarterTurns: 3, filter: .blackAndWhite)),
            ], title: "x", source: .image)

        #expect(identity == duplicate)
        #expect(edited == duplicate)
        #expect(try Self.documents(in: container).count == 1)
    }

    /// Test 8: a removed photo's bytes leave the hash, so the rest is a new document.
    @Test func aRemovedPhotoLeavesTheHash() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let photos = [TestImage.make(width: 400, height: 300), TestImage.make(width: 640, height: 480)]
        _ = await importer.importImages(photos, fileName: "", title: "Photo", source: .image)

        let result = await importer.importEditedImages(
            [EditedImage(data: photos[0]), EditedImage(data: photos[1], pages: [])], title: "Photo 2", source: .image)

        guard case .imported = result.outcome else {
            Issue.record("not a new document: \(result)")
            return
        }
        let documents = try Self.documents(in: container)
        #expect(documents.count == 2)
        #expect(documents.contains { $0.contentHash == ContentHash.sha256(photos[0]) && $0.pageCount == 1 })
    }

    /// Findings 1 and 2 of the plan review on #5: a multi-page TIFF expanded to a page per frame is hashed
    /// once, so it is a duplicate of `importImages` of the same file, with edits and with a frame removed.
    @Test func aTIFFExpandedToFramesIsHashedOnce() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)
        let tiff = TestImage.makeTIFF(frames: PDFBuilderTests.faxFrames)
        let plain = await importer.importImages([tiff], fileName: "", title: "Fax", source: .image)
        guard case .imported(let id) = plain.outcome else {
            Issue.record("not imported: \(plain)")
            return
        }
        #expect(try Self.documents(in: container).first?.pageCount == 3, "the fixture has three frames")

        let allFrames = await importer.importEditedImages(
            [
                EditedImage(
                    data: tiff,
                    pages: [
                        EditedPage(frame: 0, edit: PageEdit(quarterTurns: 1)), EditedPage(frame: 1),
                        EditedPage(frame: 2, edit: PageEdit(filter: .grayscale)),
                    ])
            ], title: "x", source: .image)
        let twoFrames = await importer.importEditedImages(
            [EditedImage(data: tiff, pages: [EditedPage(frame: 0), EditedPage(frame: 2)])], title: "x", source: .image)

        let duplicate = ImageImportResult(outcome: .duplicate(of: id, title: "Fax", isTrashed: false))
        #expect(allFrames == duplicate)
        #expect(twoFrames == duplicate)
        #expect(try Self.documents(in: container).count == 1)
    }

    /// Nothing to import: no image keeps a page, or every kept image is empty.
    @Test func noKeptPageFailsAsEmpty() async throws {
        let container = try TestSupport.makeContainer()
        let importer = Self.importer(container)

        let none = await importer.importEditedImages(
            [EditedImage(data: TestImage.make(width: 40, height: 30), pages: [])], title: "x", source: .image)
        let empty = await importer.importEditedImages([EditedImage(data: Data())], title: "x", source: .image)
        let unreadable = await importer.importEditedImages(
            [EditedImage(data: Data("kein Bild".utf8))], title: "x", source: .image)

        #expect(none == ImageImportResult(outcome: .failed(.empty)))
        #expect(empty == ImageImportResult(outcome: .failed(.empty)))
        #expect(unreadable == ImageImportResult(outcome: .failed(.unreadableImage)))
        #expect(try Self.documents(in: container).isEmpty)
    }
}
