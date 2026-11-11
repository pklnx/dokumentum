import CoreGraphics
import DokumentumCoreTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DokumentumCore

/// Images become PDF pages (plan of #4, part 3): one page per image, 595 pt wide with the image's aspect, the
/// EXIF orientation applied, at most 2400 px, unreadable images left out and counted. Every image is
/// generated in the test (`TestImage`), never a real photo.
struct PDFBuilderTests {
    @Test func onePagePerImageInTheirOrderWithTheImagesAspect() throws {
        let landscape = TestImage.make(width: 1200, height: 900)
        let portrait = TestImage.make(width: 900, height: 1200, type: .png)
        let square = TestImage.make(width: 500, height: 500)

        let result = try #require(PDFBuilder.makePDF(fromImageData: [landscape, portrait, square]))

        #expect(result.pageCount == 3)
        #expect(result.leftOut == 0)
        #expect(
            TestPDFReader.pageSizes(result.data) == [
                CGSize(width: 595, height: 446), CGSize(width: 595, height: 793), CGSize(width: 595, height: 595),
            ])
    }

    /// A phone's portrait photo: landscape pixels with EXIF orientation 6. The page is portrait, and the red
    /// band that is the top of the picture is at the top of the page.
    @Test func aJPEGWithOrientation6GivesAnUprightPortraitPage() throws {
        let photo = TestImage.make(width: 900, height: 1200, exifOrientation: 6)
        let stored = try #require(CGImageSourceCreateWithData(photo as CFData, nil))
        let storedSize = try #require(CGImageSourceCreateImageAtIndex(stored, 0, nil))
        #expect(storedSize.width == 1200 && storedSize.height == 900, "stored as landscape pixels")

        let result = try #require(PDFBuilder.makePDF(fromImageData: [photo]))

        let size = try #require(TestPDFReader.pageSizes(result.data).first)
        #expect(size == CGSize(width: 595, height: 793), "a portrait page")
        let top = try #require(TestPDFReader.color(result.data, page: 0, atFraction: CGPoint(x: 0.5, y: 0.1)))
        let bottom = try #require(TestPDFReader.color(result.data, page: 0, atFraction: CGPoint(x: 0.5, y: 0.9)))
        let left = try #require(TestPDFReader.color(result.data, page: 0, atFraction: CGPoint(x: 0.1, y: 0.5)))
        #expect(Self.isRed(top), "the top of the page is the top of the photo: \(top)")
        #expect(Self.isWhite(bottom), "\(bottom)")
        #expect(Self.isWhite(left), "\(left)")
    }

    @Test func anUnreadableItemIsLeftOutAndCounted() throws {
        let image = TestImage.make(width: 400, height: 300)

        let result = try #require(
            PDFBuilder.makePDF(fromImageData: [Data("kein Bild".utf8), image, Data(), image]))

        #expect(result.pageCount == 2)
        #expect(result.leftOut == 2)
        #expect(TestPDFReader.pageSizes(result.data).count == 2)
    }

    @Test func noReadableItemGivesNil() {
        #expect(PDFBuilder.makePDF(fromImageData: []) == nil)
        #expect(PDFBuilder.makePDF(fromImageData: [Data("kein Bild".utf8)]) == nil)
    }

    /// ImageIO decodes a PDF's first page as an image; the image path never does (#86, T3).
    @Test func aPDFIsNeverAPage() {
        let pdf = TestPDF.make(pages: ["Vertrag", "Seite 2"])

        #expect(ImageCoding.orientedImage(from: pdf, maxPixelSize: PDFBuilder.maxPixelSize) == nil)
        #expect(PDFBuilder.makePDF(fromImageData: [pdf]) == nil)
    }

    /// The longest side of a decoded image is at most 2400 px; smaller images keep their size.
    @Test func aLargeImageIsScaledTo2400PixelsAndASmallOneKeepsItsSize() throws {
        let large = try #require(
            ImageCoding.orientedImage(
                from: TestImage.make(width: 4000, height: 3000), maxPixelSize: PDFBuilder.maxPixelSize))
        #expect(max(large.width, large.height) == 2400)
        let small = try #require(
            ImageCoding.orientedImage(
                from: TestImage.make(width: 640, height: 480), maxPixelSize: PDFBuilder.maxPixelSize))
        #expect(small.width == 640 && small.height == 480)
    }

    /// A fax or scanner TIFF's frames, as #90 uses them: landscape, portrait stored with orientation 6, square.
    static let faxFrames = [
        TestImage.Frame(width: 1200, height: 900), TestImage.Frame(width: 900, height: 1200, exifOrientation: 6),
        TestImage.Frame(width: 500, height: 500),
    ]
    static let faxPageSizes = [
        CGSize(width: 595, height: 446), CGSize(width: 595, height: 793), CGSize(width: 595, height: 595),
    ]

    /// Every frame of a multi-page TIFF becomes a page, in frame order, each with its own orientation (#90).
    @Test func aMultiPageTIFFGivesAPagePerFrameInTheirOrder() throws {
        let tiff = TestImage.makeTIFF(frames: Self.faxFrames)

        let result = try #require(PDFBuilder.makePDF(fromImageData: [tiff]))

        #expect(result.pageCount == 3)
        #expect(result.leftOut == 0)
        #expect(TestPDFReader.pageSizes(result.data) == Self.faxPageSizes)
        let top = try #require(TestPDFReader.color(result.data, page: 1, atFraction: CGPoint(x: 0.5, y: 0.1)))
        let bottom = try #require(TestPDFReader.color(result.data, page: 1, atFraction: CGPoint(x: 0.5, y: 0.9)))
        #expect(Self.isRed(top), "frame 2 upright: its top at the top of the page: \(top)")
        #expect(Self.isWhite(bottom), "\(bottom)")
    }

    /// A TIFF's frames take the TIFF's place among other images.
    @Test func aTIFFAmongImagesKeepsTheOrder() throws {
        let items = [
            TestImage.make(width: 640, height: 480), TestImage.makeTIFF(frames: Self.faxFrames),
            TestImage.make(width: 500, height: 700, type: .png),
        ]

        let result = try #require(PDFBuilder.makePDF(fromImageData: items))

        #expect(result.pageCount == 5)
        #expect(result.leftOut == 0)
        #expect(
            TestPDFReader.pageSizes(result.data)
                == [CGSize(width: 595, height: 446)] + Self.faxPageSizes + [CGSize(width: 595, height: 833)])
    }

    /// Only a TIFF is split (#90, T1): a GIF, an APNG and a HEIC with three images each stay one page. Pins the
    /// decision; the fixture must really hold three images, or the pin would hold for nothing. HEIC only where
    /// ImageIO can encode it.
    @Test(arguments: [UTType.gif, .png] + (TestImage.canEncodeHEIC ? [.heic] : []))
    func onlyATIFFIsSplitIntoPages(type: UTType) throws {
        let frames = Array(repeating: TestImage.Frame(width: 300, height: 200), count: 3)
        let data = TestImage.make(type: type, frames: frames)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        try #require(CGImageSourceGetCount(source) == 3, "the fixture has three images")

        let result = try #require(PDFBuilder.makePDF(fromImageData: [data]))

        #expect(result.pageCount == 1)
        #expect(result.leftOut == 0)
        #expect(TestPDFReader.pageSizes(result.data) == [CGSize(width: 595, height: 397)])
    }

    /// No cap on the frames (#90, T2).
    @Test func aTIFFWithManyFramesKeepsEveryFrame() throws {
        let tiff = TestImage.makeTIFF(frames: Array(repeating: TestImage.Frame(width: 16, height: 16), count: 200))

        let result = try #require(PDFBuilder.makePDF(fromImageData: [tiff]))

        #expect(result.pageCount == 200)
        #expect(result.leftOut == 0)
        #expect(TestPDFReader.pageSizes(result.data).count == 200)
    }

    static func isRed(_ color: (Int, Int, Int)) -> Bool { color.0 > 200 && color.1 < 60 && color.2 < 60 }
    static func isWhite(_ color: (Int, Int, Int)) -> Bool { color.0 > 200 && color.1 > 200 && color.2 > 200 }
}
