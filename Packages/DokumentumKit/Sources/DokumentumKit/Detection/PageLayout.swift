import Foundation

/// Where the text lines of one page are (plan of #11, Approach 1): the input of `SenderDetector`.
///
/// Boxes are normalised to the visible page (0…1, origin top left, crop box and rotation applied); the page's size in
/// points gives them millimetres (`PageGeometry`). Part 2 builds a layout from Vision's lines or from PDFKit's lines,
/// split at column gaps, so that both give one line per column. Plain numbers only, no CoreGraphics: it builds and
/// tests on Linux.
///
/// **The cap (N5):** a layout holds at most `DetectionLimits.maximumLines` lines. Every line of the top zone (above
/// `DetectionLimits.topZoneBottom`) and of the footer is kept first, then the middle in reading order; the kept lines
/// stay in their given order. When the top and footer alone exceed the cap, the top zone goes first.
public struct PageLayout: Equatable, Sendable {
    /// A normalised box: origin top left, all values 0…1 of the page's width or height.
    public struct Box: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Line: Equatable, Sendable {
        public var text: String
        public var box: Box

        public init(text: String, box: Box) {
            self.text = text
            self.box = box
        }
    }

    /// The visible page's size in points (crop box, after rotation).
    public let width: Double
    public let height: Double
    /// The lines, capped, in their given (reading) order.
    public let lines: [Line]

    public init(width: Double, height: Double, lines: [Line]) {
        self.width = width
        self.height = height
        self.lines = Self.capped(lines, geometry: PageGeometry(width: width, height: height))
    }

    public var geometry: PageGeometry { PageGeometry(width: width, height: height) }

    static func capped(_ lines: [Line], geometry: PageGeometry, limit: Int = DetectionLimits.maximumLines) -> [Line] {
        guard lines.count > limit else { return lines }
        var top: [Int] = []
        var footer: [Int] = []
        var middle: [Int] = []
        for (index, line) in lines.enumerated() {
            let box = geometry.millimetres(line.box)
            if box.minY < DetectionLimits.topZoneBottom {
                top.append(index)
            } else if box.midY > geometry.footerTop {
                footer.append(index)
            } else {
                middle.append(index)
            }
        }
        let kept = Set((top + footer + middle).prefix(limit))
        return lines.indices.filter(kept.contains).map { lines[$0] }
    }
}
