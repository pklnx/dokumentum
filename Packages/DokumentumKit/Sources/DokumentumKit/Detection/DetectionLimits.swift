import Foundation

/// The numbers of sender and issue-date detection (plan of #11, Approach 2 and 3, review B1.4).
///
/// Positions are DIN 5008 millimetres, measured from the visible page's top-left edge against the page's **real
/// size** (`PageGeometry`, N-r4): a page within 3 % of A4, US Letter or US Legal is measured as it is; any other
/// page (a photo, an odd scan) is scaled to A4's width first.
public enum DetectionLimits {
    // MARK: Pages

    public static let millimetresPerPoint = 25.4 / 72
    /// Portrait sizes in millimetres (width, height).
    public static let a4 = (width: 210.0, height: 297.0)
    public static let usLetter = (width: 215.9, height: 279.4)
    public static let usLegal = (width: 215.9, height: 355.6)
    /// How far a page may differ from a standard size, per side, and still be measured as that size.
    public static let pageSizeTolerance = 0.03

    // MARK: The address field (DIN 5008)

    /// The address field's x-range, and the wider range a line's left edge may start in to count as a field line.
    public static let addressFieldX = 20.0...105.0
    public static let acceptedFieldX = 10.0...110.0
    /// The field's top and bottom: form A (27–72 mm) and form B (45–90 mm).
    public static let formA = AddressForm(top: 27, bottom: 72)
    public static let formB = AddressForm(top: 45, bottom: 90)
    /// The return-address zone is the field's top 5 mm, with 3 mm of slack on either side.
    public static let returnZoneHeight = 5.0
    public static let returnZoneTolerance = 3.0
    /// A return-address line is at most this fraction of the median height of the field lines below it.
    public static let returnLineHeightRatio = 0.8
    /// …and needs at least this many field lines below it (the recipient block).
    public static let returnLineMinimumLinesBelow = 2
    /// Without a return-address line, every line of this area counts as a recipient line: forms A and B together.
    public static let recipientArea = 27.0...90.0

    // MARK: Other zones

    /// The info-block column beside the address field: lines starting at or right of this x, down to `infoBlockBottom`.
    public static let infoBlockLeft = 125.0
    public static let infoBlockBottom = 100.0
    /// The footer: the lines in the page's last 47 mm (below 250 mm on A4), measured from the bottom edge so that
    /// US Letter, US Legal and scaled photos get the same footer depth.
    public static let footerHeight = 47.0
    /// Two lines belong to one column block while the vertical gap between them is below this many line heights.
    public static let blockGapLineHeights = 1.5

    // MARK: Cost

    /// The most lines of a page the detector reads (`PageLayout`); the top zone (above `topZoneBottom`) and the
    /// footer are kept, the middle is cut (N5).
    public static let maximumLines = 300
    public static let topZoneBottom = 100.0

    // MARK: Values

    /// A detected date lies from 1900-01-01 to this many days after the document's `createdAt`.
    public static let dateWindowDays = 31
    public static let earliestYear = ClassificationLimits.earliestYear
    /// A structural sender name: 2 to 80 characters, at most 8 words, a letter in it, no placeholder.
    public static let nameCharacters = 2...ClassificationLimits.correspondentCharacters
    public static let nameWords = 8

    /// The vertical extent of one DIN 5008 address form, in millimetres from the top edge.
    public struct AddressForm: Equatable, Sendable {
        public var top: Double
        public var bottom: Double

        /// Where a return-address line's top may lie: the field's top 5 mm, with the tolerance on either side.
        public var returnZone: ClosedRange<Double> {
            (top - DetectionLimits.returnZoneTolerance)...(top + DetectionLimits.returnZoneHeight
                + DetectionLimits.returnZoneTolerance)
        }
    }
}

/// How a page's normalised positions (0…1, origin top left) become millimetres from its top-left edge (N-r4).
public struct PageGeometry: Equatable, Sendable {
    /// The page's width and height in millimetres, as measured.
    public let width: Double
    public let height: Double
    /// Whether the page was within the tolerance of A4, US Letter or US Legal (else it is scaled to A4's width).
    public let isStandardSize: Bool

    /// The geometry of a visible page of `width` × `height` points. A page with no usable size is measured as A4.
    public init(width points: Double, height heightPoints: Double) {
        let width = points * DetectionLimits.millimetresPerPoint
        let height = heightPoints * DetectionLimits.millimetresPerPoint
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            self.width = DetectionLimits.a4.width
            self.height = DetectionLimits.a4.height
            isStandardSize = false
            return
        }
        let standard = [DetectionLimits.a4, DetectionLimits.usLetter, DetectionLimits.usLegal].contains { size in
            abs(width - size.width) <= size.width * DetectionLimits.pageSizeTolerance
                && abs(height - size.height) <= size.height * DetectionLimits.pageSizeTolerance
        }
        if standard {
            self.width = width
            self.height = height
        } else {
            let scale = DetectionLimits.a4.width / width
            self.width = DetectionLimits.a4.width
            self.height = height * scale
        }
        isStandardSize = standard
    }

    /// Where the footer starts, in millimetres from the top.
    public var footerTop: Double { height - DetectionLimits.footerHeight }

    /// A normalised box in millimetres.
    func millimetres(_ box: PageLayout.Box) -> MillimetreBox {
        MillimetreBox(
            minX: box.x * width, minY: box.y * height, maxX: (box.x + box.width) * width,
            maxY: (box.y + box.height) * height)
    }
}

/// A box in millimetres from the page's top-left edge.
struct MillimetreBox: Equatable, Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var height: Double { maxY - minY }
    var midY: Double { (minY + maxY) / 2 }

    func overlapsHorizontally(_ other: MillimetreBox) -> Bool {
        minX < other.maxX && other.minX < maxX
    }
}
