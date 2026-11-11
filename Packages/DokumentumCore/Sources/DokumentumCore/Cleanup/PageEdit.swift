import CoreGraphics
import Foundation

/// The four corners of a page in a photo (#5, step 4), normalised to 0…1 with the origin at the **top left**,
/// in the photo's displayed orientation (EXIF orientation applied). Normalised, so the same corners fit the
/// preview and the full-size page.
public struct PageQuad: Sendable, Hashable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    /// Every point is clamped to 0…1.
    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = Self.clamped(topLeft)
        self.topRight = Self.clamped(topRight)
        self.bottomRight = Self.clamped(bottomRight)
        self.bottomLeft = Self.clamped(bottomLeft)
    }

    /// The whole image: no perspective correction.
    public static let fullPage = PageQuad(
        topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1, y: 0), bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1))

    /// The corners in order: top left, top right, bottom right, bottom left.
    public var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Whether the four corners, in their order, make a convex quadrilateral without a straight or reflex
    /// angle (every turn has the same direction). A crossed or collapsed quad is not.
    public var isConvex: Bool {
        let points = points
        var sign: CGFloat = 0
        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            let c = points[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 1e-9 else { return false }
            if sign == 0 {
                sign = cross > 0 ? 1 : -1
            } else if (cross > 0 ? 1 : -1) != sign {
                return false
            }
        }
        return true
    }

    /// The area as a fraction of the image (shoelace formula), 0…1.
    public var area: CGFloat {
        let points = points
        var sum: CGFloat = 0
        for index in 0..<4 {
            let a = points[index]
            let b = points[(index + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// The smallest rectangle around the four corners, normalised.
    public var boundingBox: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 1) - minX, height: (ys.max() ?? 1) - minY)
    }

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}

/// The look of a cleaned page (P3).
public enum PageFilter: String, Sendable, CaseIterable {
    /// The photo's pixels as they are.
    case original
    /// Whitened paper, colours kept (`CIDocumentEnhancer`).
    case enhanced
    /// Saturation 0.
    case grayscale
    /// Enhanced, grey, then a threshold: only black and white.
    case blackAndWhite
}

/// How one photo becomes a page (#5, step 4). Applied in this order, in the photo's displayed coordinates:
/// perspective crop to `corners`, `filter`, then `quarterTurns` clockwise.
public struct PageEdit: Sendable, Hashable {
    public var corners: PageQuad
    /// Clockwise quarter turns, 0…3; other values are taken modulo 4.
    public var quarterTurns: Int {
        didSet { quarterTurns = Self.normalized(quarterTurns) }
    }
    public var filter: PageFilter

    public init(corners: PageQuad = .fullPage, quarterTurns: Int = 0, filter: PageFilter = .original) {
        self.corners = corners
        self.quarterTurns = Self.normalized(quarterTurns)
        self.filter = filter
    }

    /// No change: the page is the photo as today's photo import draws it.
    public static let identity = PageEdit()

    public var isIdentity: Bool { self == .identity }

    private static func normalized(_ turns: Int) -> Int { ((turns % 4) + 4) % 4 }
}

/// One image picked for the edited import, and the pages it gives, in order (#5, step 4). A photo gives one
/// page (`frame` 0); a multi-page TIFF can give a page per frame the user kept. An image whose `pages` is
/// empty (every page removed) is not in the document and not in its hash.
public struct EditedImage: Sendable, Hashable {
    /// The bytes exactly as received; the duplicate hash covers them once per image (finding 2 of the plan
    /// review on #5).
    public var data: Data
    public var pages: [EditedPage]

    public init(data: Data, pages: [EditedPage]) {
        self.data = data
        self.pages = pages
    }

    /// A photo with one page.
    public init(data: Data, edit: PageEdit = .identity) {
        self.init(data: data, pages: [EditedPage(frame: 0, edit: edit)])
    }
}

/// One page of an `EditedImage`: the image's frame (0 for anything but a multi-page TIFF) and its edit.
public struct EditedPage: Sendable, Hashable {
    public var frame: Int
    public var edit: PageEdit

    public init(frame: Int = 0, edit: PageEdit = .identity) {
        self.frame = frame
        self.edit = edit
    }
}
