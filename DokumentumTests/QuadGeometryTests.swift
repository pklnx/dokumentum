import CoreGraphics
import DokumentumCore
import Testing

@testable import Dokumentum

/// The cleanup sheet's geometry (#5, part 3, plan test 16; finding 5 of the plan review on #5): view points and
/// normalised corners through the aspect fit and the quarter turns.
struct QuadGeometryTests {
    static func isClose(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-9) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// A portrait photo in a square view is letterboxed left and right, a landscape one above and below; a point
    /// goes to the view and back unchanged.
    @Test(arguments: [
        (CGSize(width: 300, height: 400), CGRect(x: 50, y: 0, width: 300, height: 400)),
        (CGSize(width: 400, height: 300), CGRect(x: 0, y: 50, width: 400, height: 300)),
    ])
    func aPointGoesToTheViewAndBackForPortraitAndLandscape(image: CGSize, frame: CGRect) {
        let geometry = QuadGeometry(
            imageSize: image, quarterTurns: 0, bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(geometry.imageFrame == frame)
        let point = CGPoint(x: 0.25, y: 0.5)
        let view = geometry.viewPoint(for: point)
        #expect(Self.isClose(view, CGPoint(x: frame.minX + 0.25 * frame.width, y: frame.minY + 0.5 * frame.height)))
        #expect(Self.isClose(geometry.photoPoint(for: view), point))
        #expect(Self.isClose(geometry.viewPoint(for: .zero), frame.origin), "the photo's top left at the frame's")
    }

    /// Finding 5: with a quarter turn the photo shows turned clockwise, so its top left corner shows at the top
    /// right, and a drag there moves the photo's top left corner. The frame is landscape for a portrait photo.
    @Test func aQuarterTurnMapsTheHandlesThroughTheTurn() {
        let geometry = QuadGeometry(
            imageSize: CGSize(width: 300, height: 400), quarterTurns: 1,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(geometry.shownSize == CGSize(width: 400, height: 300))
        #expect(geometry.imageFrame == CGRect(x: 0, y: 50, width: 400, height: 300))

        #expect(Self.isClose(geometry.viewPoint(for: CGPoint(x: 0, y: 0)), CGPoint(x: 400, y: 50)))
        #expect(Self.isClose(geometry.viewPoint(for: CGPoint(x: 1, y: 1)), CGPoint(x: 0, y: 350)))
        #expect(QuadCorner.topLeft.shown(turnedBy: 1) == .topRight)
        #expect(QuadCorner.bottomLeft.shown(turnedBy: 1) == .topLeft)
        #expect(QuadCorner.topLeft.shown(turnedBy: 4) == .topLeft)

        // A drag to a quarter of the shown width and height is (0.25, 0.75) in the photo.
        let photo = geometry.photoPoint(for: CGPoint(x: 100, y: 125))
        #expect(Self.isClose(photo, CGPoint(x: 0.25, y: 0.75)))
        for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.4), CGPoint(x: 1, y: 0)] {
            for turns in 0..<4 {
                let turned = QuadGeometry(
                    imageSize: CGSize(width: 300, height: 400), quarterTurns: turns,
                    bounds: CGRect(x: 10, y: 20, width: 500, height: 300))
                #expect(Self.isClose(turned.photoPoint(for: turned.viewPoint(for: point)), point, 1e-6))
            }
        }
        #expect(Self.isClose(QuadGeometry.turned(CGPoint(x: 0.1, y: 0.2), by: 4), CGPoint(x: 0.1, y: 0.2)))
    }

    /// A drag past the photo's edge keeps the corner on the edge.
    @Test func aDragOutsideThePhotoIsClamped() {
        let geometry = QuadGeometry(
            imageSize: CGSize(width: 300, height: 400), quarterTurns: 0,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(geometry.photoPoint(for: CGPoint(x: -20, y: 500)) == CGPoint(x: 0, y: 1))
        #expect(geometry.photoPoint(for: CGPoint(x: 20, y: 200)) == CGPoint(x: 0, y: 0.5), "in the letterbox")
    }

    /// A move that makes the page cross itself is refused; a move goes through `PageQuad`'s `init`, which clamps
    /// (N3 of review 5865079459 on #118).
    @Test func aMoveThatIsNotConvexIsRefusedAndAMoveIsClamped() throws {
        #expect(QuadGeometry.moving(.topLeft, of: .fullPage, to: CGPoint(x: 0.9, y: 0.95)) == nil, "crossed")
        #expect(QuadGeometry.moving(.topLeft, of: .fullPage, to: CGPoint(x: 1, y: 1)) == nil, "collapsed")
        let moved = try #require(QuadGeometry.moving(.topRight, of: .fullPage, to: CGPoint(x: 1.3, y: 0.1)))
        #expect(moved.topRight == CGPoint(x: 1, y: 0.1))
        #expect(moved.topLeft == .zero && moved.bottomRight == CGPoint(x: 1, y: 1))
    }
}
