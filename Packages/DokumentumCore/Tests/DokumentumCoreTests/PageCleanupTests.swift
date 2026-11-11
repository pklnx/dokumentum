import CoreGraphics
import DokumentumCoreTestSupport
import Foundation
import ImageIO
import Testing

@testable import DokumentumCore

/// The page cleanup (#5, step 4, plan tests 3–6) on rendered pages: crop, EXIF orientation, turns, filters.
struct PageCleanupTests {
    static let canvas = CGSize(width: 1200, height: 1600)

    static func isDark(_ rgb: (Int, Int, Int), _ limit: Int = 40) -> Bool {
        rgb.0 <= limit && rgb.1 <= limit && rgb.2 <= limit
    }

    static func isRed(_ rgb: (Int, Int, Int)) -> Bool { rgb.0 - rgb.1 >= 100 && rgb.0 - rgb.2 >= 100 }

    static let cornerSamples = [
        CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.98, y: 0.02), CGPoint(x: 0.98, y: 0.98), CGPoint(x: 0.02, y: 0.98),
    ]

    /// Asserts an upright cleaned page: no desk at the corners, the marker at the top left, the red band at the
    /// top right, A4's aspect within 4 %.
    static func expectUprightPage(_ page: CGImage, sourceLocation: SourceLocation = #_sourceLocation) {
        for point in cornerSamples {
            let rgb = TestPixels.rgb(of: page, atFraction: point)
            #expect(
                min(rgb.0, rgb.1, rgb.2) >= 240, "paper, no desk, at \(point): \(rgb)", sourceLocation: sourceLocation)
        }
        let marker = TestPixels.rgb(of: page, atFraction: TestPixels.center(TestPage.marker))
        #expect(isDark(marker), "the marker at the top left: \(marker)", sourceLocation: sourceLocation)
        let band = TestPixels.rgb(of: page, atFraction: TestPixels.center(TestPage.redBand))
        #expect(isRed(band), "the red band at the top right: \(band)", sourceLocation: sourceLocation)
        let aspect = CGFloat(page.height) / CGFloat(page.width)
        #expect(abs(aspect / 1.414 - 1) <= 0.04, "aspect \(aspect)", sourceLocation: sourceLocation)
    }

    /// Test 3: the perspective crop to the page's corners leaves no desk, and the page is upright.
    @Test func theCropStraightensThePageAndLeavesNoDesk() throws {
        let photo = try #require(
            ImageCoding.orientedImage(
                from: TestPage.photographed(corners: TestPage.tiltedCorners, canvas: Self.canvas), maxPixelSize: 4000))

        let page = try #require(PageCleanup.render(photo, edit: PageEdit(corners: TestPage.tiltedCorners)))

        Self.expectUprightPage(page)
    }

    /// Test 4: a photo stored with EXIF orientation 6 (landscape pixels, a phone's portrait photo) gives the
    /// same upright page: the corners are in the displayed orientation, which decoding applies.
    @Test func aPhotoWithOrientation6GivesTheSameUprightPage() throws {
        let data = TestPage.photographed(corners: TestPage.tiltedCorners, canvas: Self.canvas, exifOrientation: 6)
        let source = try #require(ImageCoding.imageSource(for: data))
        let stored = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(stored.width == 1600 && stored.height == 1200, "stored as landscape pixels")

        let page = try #require(
            PDFBuilder.editedPage(source, EditedPage(edit: PageEdit(corners: TestPage.tiltedCorners))))

        Self.expectUprightPage(page)
    }

    /// Test 5: one clockwise turn puts the marker at the top right and swaps width and height; four turns are
    /// the identity.
    @Test func aClockwiseTurnPutsTheMarkerTopRight() throws {
        let upright = TestPage.make()

        let turned = try #require(PageCleanup.render(upright, edit: PageEdit(quarterTurns: 1)))

        #expect(turned.width == upright.height && turned.height == upright.width)
        // The marker's centre (0.13, 0.09) turned clockwise: (1 - 0.09, 0.13).
        let marker = TestPixels.rgb(of: turned, atFraction: CGPoint(x: 0.91, y: 0.13))
        #expect(Self.isDark(marker), "marker top right: \(marker)")
        let topLeft = TestPixels.rgb(of: turned, atFraction: CGPoint(x: 0.09, y: 0.13))
        #expect(!Self.isDark(topLeft), "not top left: \(topLeft)")

        #expect(PageEdit(quarterTurns: 4) == .identity)
        let twice = try #require(PageCleanup.render(upright, edit: PageEdit(quarterTurns: 2)))
        let twiceMore = try #require(PageCleanup.render(twice, edit: PageEdit(quarterTurns: 2)))
        #expect(twiceMore.width == upright.width && twiceMore.height == upright.height)
        #expect(Self.isDark(TestPixels.rgb(of: twiceMore, atFraction: TestPixels.center(TestPage.marker))))
    }

    /// Test 6: the filters on the tinted paper with a shadow gradient.
    @Test func grayscaleHasNoColour() throws {
        let page = try #require(PageCleanup.render(TestPage.make(tinted: true), edit: PageEdit(filter: .grayscale)))

        for point in Self.samples {
            let rgb = TestPixels.rgb(of: page, atFraction: point)
            #expect(abs(rgb.0 - rgb.1) <= 1 && abs(rgb.1 - rgb.2) <= 1, "grey at \(point): \(rgb)")
        }
    }

    @Test func enhancedWhitensThePaperAndKeepsColours() throws {
        let page = try #require(PageCleanup.render(TestPage.make(tinted: true), edit: PageEdit(filter: .enhanced)))

        for point in [TestPage.paperLeft, TestPage.paperRight] {
            let rgb = TestPixels.rgb(of: page, atFraction: point)
            #expect(min(rgb.0, rgb.1, rgb.2) >= 245, "white paper at \(point): \(rgb)")
        }
        let band = TestPixels.rgb(of: page, atFraction: TestPixels.center(TestPage.redBand))
        #expect(band.0 - band.1 >= 100, "the band stays red: \(band)")
        #expect(Self.isDark(TestPixels.rgb(of: page, atFraction: TestPixels.center(TestPage.marker))))
    }

    @Test func blackAndWhiteHasOnlyBlackAndWhite() throws {
        let page = try #require(
            PageCleanup.render(TestPage.make(tinted: true), edit: PageEdit(filter: .blackAndWhite)))

        for point in Self.samples {
            let rgb = TestPixels.rgb(of: page, atFraction: point)
            #expect([rgb.0, rgb.1, rgb.2].allSatisfy { $0 <= 10 || $0 >= 245 }, "black or white at \(point): \(rgb)")
        }
        for point in [TestPage.paperLeft, TestPage.paperRight] {
            #expect(TestPixels.rgb(of: page, atFraction: point).0 >= 245, "paper white")
        }
        for rect in [TestPage.marker, TestPage.textBars[0], TestPage.textBars[5]] {
            #expect(Self.isDark(TestPixels.rgb(of: page, atFraction: TestPixels.center(rect)), 10), "black: \(rect)")
        }
    }

    /// `original` through CoreImage (two half turns, so the edit is not the identity shortcut) keeps the
    /// colours within 1.
    @Test func originalKeepsThePixels() throws {
        let tinted = TestPage.make(tinted: true)
        let edit = PageEdit(quarterTurns: 2, filter: .original)

        let once = try #require(PageCleanup.render(tinted, edit: edit))
        let page = try #require(PageCleanup.render(once, edit: edit))

        for point in Self.samples {
            let before = TestPixels.rgb(of: tinted, atFraction: point)
            let after = TestPixels.rgb(of: page, atFraction: point)
            #expect(
                abs(before.0 - after.0) <= 1 && abs(before.1 - after.1) <= 1 && abs(before.2 - after.2) <= 1,
                "\(point): \(before) → \(after)")
        }
        #expect(PageCleanup.render(tinted, edit: .identity) === tinted, "the identity edit is the image itself")
    }

    /// Paper left and right, the marker, the band, a text bar.
    static let samples = [
        TestPage.paperLeft, TestPage.paperRight, TestPixels.center(TestPage.marker),
        TestPixels.center(TestPage.redBand), TestPixels.center(TestPage.textBars[0]),
    ]
}
