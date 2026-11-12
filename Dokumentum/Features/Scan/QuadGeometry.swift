import CoreGraphics
import DokumentumCore

/// One of a page's four corners, in `PageQuad`'s order (clockwise from the top left).
enum QuadCorner: Int, CaseIterable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft

    /// The corner's point in `quad`.
    func point(in quad: PageQuad) -> CGPoint {
        quad.points[rawValue]
    }

    /// Where this corner of the photo shows when the photo is shown turned `quarterTurns` clockwise: a quarter
    /// turn puts the top left at the top right.
    func shown(turnedBy quarterTurns: Int) -> QuadCorner {
        QuadCorner(rawValue: (rawValue + Self.normalized(quarterTurns)) % 4) ?? self
    }

    static func normalized(_ turns: Int) -> Int { ((turns % 4) + 4) % 4 }
}

/// The cleanup sheet's geometry (#5, part 3): the large page shows the whole photo **turned by the edit's quarter
/// turns** (what Save gives, finding 5 of the plan review on #5), fitted into the view with letterboxing; the
/// corners stay in the unturned photo's normalised coordinates (`PageQuad`, top left origin), as the edit applies
/// them. `QuadGeometry` maps between a point in the view and a normalised corner, through the fit and the turns.
struct QuadGeometry {
    /// The photo's displayed size (EXIF orientation applied), unturned, in pixels or any unit.
    let imageSize: CGSize
    let quarterTurns: Int
    /// The view's area the page is fitted into.
    let bounds: CGRect

    init(imageSize: CGSize, quarterTurns: Int, bounds: CGRect) {
        self.imageSize = imageSize
        self.quarterTurns = QuadCorner.normalized(quarterTurns)
        self.bounds = bounds
    }

    /// The photo's size as shown: width and height swapped for an odd number of turns.
    var shownSize: CGSize {
        quarterTurns % 2 == 0 ? imageSize : CGSize(width: imageSize.height, height: imageSize.width)
    }

    /// The shown photo's frame in the view: aspect fit, centred.
    var imageFrame: CGRect {
        let shown = shownSize
        guard shown.width > 0, shown.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: CGPoint(x: bounds.midX, y: bounds.midY), size: .zero)
        }
        let scale = min(bounds.width / shown.width, bounds.height / shown.height)
        let size = CGSize(width: shown.width * scale, height: shown.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2, y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    /// The view point where the normalised photo point `point` shows.
    func viewPoint(for point: CGPoint) -> CGPoint {
        let shown = Self.turned(point, by: quarterTurns)
        let frame = imageFrame
        return CGPoint(x: frame.minX + shown.x * frame.width, y: frame.minY + shown.y * frame.height)
    }

    /// The normalised photo point under the view point `point`, clamped to the photo: a drag past the photo's
    /// edge keeps the corner on the edge.
    func photoPoint(for point: CGPoint) -> CGPoint {
        let frame = imageFrame
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let shown = CGPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max((point.y - frame.minY) / frame.height, 0), 1))
        return Self.turned(shown, by: -quarterTurns)
    }

    /// A normalised point of an image turned `turns` quarters clockwise: (x, y) becomes (1 − y, x) per turn.
    static func turned(_ point: CGPoint, by turns: Int) -> CGPoint {
        var point = point
        for _ in 0..<QuadCorner.normalized(turns) {
            point = CGPoint(x: 1 - point.y, y: point.x)
        }
        return point
    }

    /// `quad` with `corner` at `point`, or `nil` when that quad is not convex (a crossed or collapsed page; the
    /// sheet keeps the last convex quad). The new quad goes through `PageQuad`'s `init`, which clamps every point to
    /// the photo (finding N3 of review 5865079459 on #118), never through its `var` corners.
    static func moving(_ corner: QuadCorner, of quad: PageQuad, to point: CGPoint) -> PageQuad? {
        var points = quad.points
        points[corner.rawValue] = point
        let moved = PageQuad(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
        return moved.isConvex ? moved : nil
    }
}
