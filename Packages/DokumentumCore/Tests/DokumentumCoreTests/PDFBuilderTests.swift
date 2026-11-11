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

    // MARK: Edited photos (#5, step 4)

    /// Plan test 9: one page at a time. Each page is decoded just before it is drawn, in order, never all
    /// first.
    @Test func editedPagesAreDecodedOneAtATimeInOrder() throws {
        let items = [
            EditedImage(data: TestImage.make(width: 400, height: 300), edit: PageEdit(quarterTurns: 1)),
            EditedImage(
                data: TestImage.makeTIFF(frames: Self.faxFrames), pages: [EditedPage(frame: 0), EditedPage(frame: 2)]),
        ]
        var events: [PDFBuilder.PageEvent] = []

        let result = try #require(PDFBuilder.makePDF(fromEditedImages: items, trace: { events.append($0) }))

        #expect(result.pageCount == 3)
        #expect(events == [.decoded(0), .drawn(0), .decoded(1), .drawn(1), .decoded(2), .drawn(2)])
    }

    /// The pages of edited images in their order, each with its edit; a frame of a TIFF the caller kept, a
    /// frame that does not exist and bytes that are no image are left out and counted.
    @Test func editedImagesGiveAPagePerKeptPageWithTheirEdits() throws {
        let items = [
            EditedImage(data: TestImage.make(width: 400, height: 300), edit: PageEdit(quarterTurns: 1)),
            EditedImage(data: Data("kein Bild".utf8)),
            EditedImage(
                data: TestImage.makeTIFF(frames: Self.faxFrames), pages: [EditedPage(frame: 2), EditedPage(frame: 7)]),
            EditedImage(data: TestImage.make(width: 640, height: 480), pages: []),
        ]

        let result = try #require(PDFBuilder.makePDF(fromEditedImages: items))

        #expect(result.pageCount == 2)
        #expect(result.leftOut == 2)
        #expect(
            TestPDFReader.pageSizes(result.data) == [CGSize(width: 595, height: 793), CGSize(width: 595, height: 595)])
        // The turned image's red band (its top) is now on the right.
        let right = try #require(TestPDFReader.color(result.data, page: 0, atFraction: CGPoint(x: 0.9, y: 0.5)))
        let left = try #require(TestPDFReader.color(result.data, page: 0, atFraction: CGPoint(x: 0.1, y: 0.5)))
        #expect(Self.isRed(right), "\(right)")
        #expect(Self.isWhite(left), "\(left)")
        #expect(PDFBuilder.makePDF(fromEditedImages: [EditedImage(data: Data("kein Bild".utf8))]) == nil)
    }

    /// Finding 4 of the plan review on #5: the photo is decoded large enough that the cropped page keeps
    /// 2400 px on its longer side when the photo has them, and its own size when it has fewer.
    @Test func aCroppedPageKeeps2400PixelsWhenThePhotoHasThem() throws {
        let canvas = CGSize(width: 3000, height: 4000)
        // An upright A4 page over 70 % of the photo's height (2800 px) and over 50 % (2000 px).
        let tall = PageQuad(
            topLeft: CGPoint(x: 0.17, y: 0.15), topRight: CGPoint(x: 0.83, y: 0.15),
            bottomRight: CGPoint(x: 0.83, y: 0.85), bottomLeft: CGPoint(x: 0.17, y: 0.85))
        let half = PageQuad(
            topLeft: CGPoint(x: 0.264, y: 0.25), topRight: CGPoint(x: 0.736, y: 0.25),
            bottomRight: CGPoint(x: 0.736, y: 0.75), bottomLeft: CGPoint(x: 0.264, y: 0.75))

        for (quad, expected) in [(tall, 2400), (half, 2000)] {
            let photo = TestPage.photographed(corners: quad, canvas: canvas)
            let source = try #require(ImageCoding.imageSource(for: photo))
            let page = try #require(PDFBuilder.editedPage(source, EditedPage(edit: PageEdit(corners: quad))))
            let longer = max(page.width, page.height)
            #expect(abs(longer - expected) <= expected / 100, "longer side \(longer), expected \(expected)")
        }
    }

    /// The decode size: `min(original, 2400 / extent of the quad)`; the full page as `makePDF(fromImageData:)`.
    @Test func theDecodeSizeFollowsTheQuad() {
        let photo = CGSize(width: 3024, height: 4032)
        #expect(PDFBuilder.decodeSize(for: .fullPage, of: photo) == 2400)
        #expect(PDFBuilder.decodeSize(for: .fullPage, of: CGSize(width: 640, height: 480)) == 640)
        #expect(PDFBuilder.decodeSize(for: .fullPage, of: nil) == 2400)
        let lowerHalf = PageQuad(
            topLeft: CGPoint(x: 0, y: 0.5), topRight: CGPoint(x: 1, y: 0.5), bottomRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 1))
        // The quad's box is 3024 × 2016 px at full size: 2400 / 3024 of 4032 is 3200.
        #expect(PDFBuilder.decodeSize(for: lowerHalf, of: photo) == 3200)
        let tiny = PageQuad(
            topLeft: CGPoint(x: 0.4, y: 0.4), topRight: CGPoint(x: 0.5, y: 0.4), bottomRight: CGPoint(x: 0.5, y: 0.5),
            bottomLeft: CGPoint(x: 0.4, y: 0.5))
        #expect(PDFBuilder.decodeSize(for: tiny, of: photo) == 4032, "never more than the original")
    }

    /// N1 of review 5865079459 on #118: a small crop of a photo above 25 MP is decoded at most at half its size (a
    /// 48 MP photo at 4000 × 3000 px), a 108 MP photo at a quarter, where ImageIO decodes without the full photo; a
    /// 24.5 MP photo (the iPhone's 24 MP) in full. Never below 2400 px, never above the original.
    @Test func theDecodeSizeIsCappedForASmallCropOfALargePhoto() {
        let tiny = PageQuad(
            topLeft: CGPoint(x: 0.4, y: 0.4), topRight: CGPoint(x: 0.5, y: 0.4), bottomRight: CGPoint(x: 0.5, y: 0.5),
            bottomLeft: CGPoint(x: 0.4, y: 0.5))
        #expect(PDFBuilder.decodeSize(for: tiny, of: CGSize(width: 8000, height: 6000)) == 4000)
        #expect(PDFBuilder.decodeSize(for: tiny, of: CGSize(width: 12000, height: 9000)) == 3000)
        #expect(PDFBuilder.decodeSize(for: tiny, of: CGSize(width: 5712, height: 4284)) == 5712)
        #expect(PDFBuilder.decodeSize(for: .fullPage, of: CGSize(width: 8000, height: 6000)) == 2400)
        #expect(PDFBuilder.decodeCap(for: CGSize(width: 40000, height: 30000)) == 5000, "an eighth at least")
    }

    /// N2 of review 5865079459 on #118: a page turned by 45° is decoded for its straightened size, not for its
    /// bounding box. On a 4800 × 4800 photo the diamond's box is 3840 px, its edges 2715 px; 2400 / 2715 of 4800 is
    /// 4243 (the box would give 3000, and the page only about 1700 px).
    @Test func theDecodeSizeOfATiltedPageFollowsItsEdgesNotItsBoundingBox() {
        let diamond = PageQuad(
            topLeft: CGPoint(x: 0.5, y: 0.1), topRight: CGPoint(x: 0.9, y: 0.5), bottomRight: CGPoint(x: 0.5, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.5))
        let size = PDFBuilder.decodeSize(for: diamond, of: CGSize(width: 4800, height: 4800))
        #expect(abs(size - 4243) <= 1, "\(size)")
    }

    /// The displayed size swaps width and height for orientation 6.
    @Test func theDisplayedSizeAppliesTheOrientation() throws {
        let photo = TestImage.make(width: 900, height: 1200, exifOrientation: 6)
        let source = try #require(ImageCoding.imageSource(for: photo))
        #expect(ImageCoding.displayedSize(of: source, at: 0) == CGSize(width: 900, height: 1200))
    }

    static func isRed(_ color: (Int, Int, Int)) -> Bool { color.0 > 200 && color.1 < 60 && color.2 < 60 }
    static func isWhite(_ color: (Int, Int, Int)) -> Bool { color.0 > 200 && color.1 > 200 && color.2 > 200 }
}
