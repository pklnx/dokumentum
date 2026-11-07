import CoreGraphics
import DokumentumCoreTestSupport
import Foundation
import ImageIO
import Testing

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

    static func isRed(_ color: (Int, Int, Int)) -> Bool { color.0 > 200 && color.1 < 60 && color.2 < 60 }
    static func isWhite(_ color: (Int, Int, Int)) -> Bool { color.0 > 200 && color.1 > 200 && color.2 > 200 }
}
