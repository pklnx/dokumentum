import CoreGraphics
import DokumentumCoreTestSupport
import Foundation
import Testing

@testable import DokumentumCore

/// Page corners found by Vision (#5, step 4, plan tests 1 and 2) on rendered pages, never a real photo. The
/// tests assert accuracy, not which request answered: on the iOS simulator the segmentation request returns
/// the whole image with confidence 0, and the rectangle request answers (T1).
struct PageCornerDetectorTests {
    static let canvas = CGSize(width: 1200, height: 1600)

    static func displayed(_ data: Data) throws -> CGImage {
        try #require(ImageCoding.orientedImage(from: data, maxPixelSize: 4000))
    }

    /// Test 1: each corner within 1.5 % of the longer side (24 px), in the order TL, TR, BR, BL from the top.
    @Test func findsThePagesCornersInTopLeftCoordinates() async throws {
        let image = try Self.displayed(TestPage.photographed(corners: TestPage.tiltedCorners, canvas: Self.canvas))

        let detection = try #require(await VisionPageCornerDetector().detect(in: image))

        let tolerance = 0.015 * max(Self.canvas.width, Self.canvas.height)
        for (found, expected) in zip(detection.quad.points, TestPage.tiltedCorners.points) {
            let dx = (found.x - expected.x) * Self.canvas.width
            let dy = (found.y - expected.y) * Self.canvas.height
            #expect(
                (dx * dx + dy * dy).squareRoot() <= tolerance,
                "found \(found), expected \(expected), via \(detection.source)")
        }
        #expect(detection.confidence >= VisionPageCornerDetector.minimumConfidence)
    }

    /// The segmentation request itself (T1), on macOS only: the simulator's does not work, and a virtual Mac's
    /// may answer with confidence 0, so the test is skipped (cancelled with the reason) then.
    @Test func theSegmentationRequestFindsThePageWhereItWorks() throws {
        #if os(macOS)
            let image = try Self.displayed(
                TestPage.photographed(corners: TestPage.tiltedCorners, canvas: Self.canvas))
            let segmented = try #require(VisionPageCornerDetector.segmentation(in: image))
            // Skipped, not failed, where the request does not work (the simulator's answer, maybe a VM's).
            guard segmented.confidence > 0 else {
                try Test.cancel("Vision's segmentation gives confidence 0 here (as in a VM)")
            }
            #expect(VisionPageCornerDetector.accepts(segmented))
            #expect(VisionPageCornerDetector.detectNow(in: image)?.source == .documentSegmentation)
        #endif
    }

    /// Test 2: a desk without a page gives `nil`: the segmentation request returns the whole image with
    /// confidence 0, which the threshold rejects (T2).
    @Test func aDeskWithoutAPageGivesNil() async throws {
        let image = try Self.displayed(TestPage.emptyDesk(canvas: Self.canvas))

        #expect(await VisionPageCornerDetector().detect(in: image) == nil)
    }

    /// Test 2: a page smaller than 10 % of the image gives `nil`, though Vision finds it.
    @Test func aPageSmallerThanATenthOfTheImageGivesNil() async throws {
        let small = PageQuad(
            topLeft: CGPoint(x: 0.40, y: 0.40), topRight: CGPoint(x: 0.62, y: 0.40),
            bottomRight: CGPoint(x: 0.62, y: 0.62), bottomLeft: CGPoint(x: 0.40, y: 0.62))
        let image = try Self.displayed(TestPage.photographed(corners: small, canvas: Self.canvas))
        let found = VisionPageCornerDetector.rectangle(in: image)
        try #require(found.map { $0.confidence >= 0.5 && $0.quad.isConvex } == true, "Vision finds the small page")

        #expect(await VisionPageCornerDetector().detect(in: image) == nil)
    }

    /// T2 on its own: confidence, convexity and area.
    @Test func acceptanceNeedsConfidenceConvexityAndArea() {
        let page = TestPage.tiltedCorners
        let crossed = PageQuad(
            topLeft: page.topLeft, topRight: page.bottomRight, bottomRight: page.topRight, bottomLeft: page.bottomLeft)
        func detection(_ quad: PageQuad, _ confidence: Float) -> PageCornerDetection {
            PageCornerDetection(quad: quad, confidence: confidence, source: .rectangles)
        }

        #expect(VisionPageCornerDetector.accepts(detection(page, 0.5)))
        #expect(!VisionPageCornerDetector.accepts(detection(page, 0.49)))
        #expect(!VisionPageCornerDetector.accepts(detection(crossed, 1)))
        #expect(!VisionPageCornerDetector.accepts(detection(.fullPage, 0)))
    }
}
