import CoreGraphics
import DokumentumKit
import Foundation
import PDFKit

/// Where the lines of one page are, for sender detection (plan of #11, Approach 1; review B2): the `PageLayout` of
/// the first page with text, which `DocumentStage` returns as `ProcessingResult.firstPageLayout`.
///
/// Boxes are normalised to the **visible page** (0…1, origin top left): the crop box, turned by the page's `/Rotate`
/// as a viewer shows it. The layout carries the visible page's size in points, so `SenderDetector` measures in
/// millimetres against the page's real size (N-r4).
/// - **A recognised page**: Vision's lines. The stage recognised the page rendered with its crop box and rotation
///   (`PageText.render`), so Vision's boxes (normalised to that image, origin bottom left) are only flipped. A line
///   without a box (a stub recogniser's) is left out.
/// - **A text page**: PDFKit's lines (`selectionsByLine()` of the crop box's selection). PDFKit joins two columns on
///   one baseline into one line only sometimes (the review's probe 2), so each line is **split at column gaps**: a
///   horizontal gap between two characters wider than twice the line's median character width (per-character
///   bounds from one-character selections), or a run of two or more spaces. After the split both sources give
///   one line per column.
///
/// Only one page is read; `PageLayout` caps the lines at 300, keeping the top and footer zones (N5).
public enum PageLayoutReader {
    /// A gap wider than this many median character widths splits a PDFKit line into columns.
    public static let columnGapCharacterWidths: CGFloat = 2

    /// The visible page's size in points: the crop box, its sides swapped for a quarter turn.
    public static func visibleSize(of page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox).size
        return page.rotation % 180 != 0 ? CGSize(width: crop.height, height: crop.width) : crop
    }

    /// The layout of a recognised page from Vision's lines (boxes normalised to the rendered page, origin bottom
    /// left).
    public static func layout(recognized lines: [RecognizedLine], on page: PDFPage) -> PageLayout {
        let size = visibleSize(of: page)
        let placed = lines.compactMap { line -> PageLayout.Line? in
            let box = line.boundingBox
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, box.width > 0, box.height > 0 else { return nil }
            return PageLayout.Line(
                text: text,
                box: .init(
                    x: Double(box.minX), y: Double(1 - box.maxY), width: Double(box.width),
                    height: Double(box.height)))
        }
        return PageLayout(width: Double(size.width), height: Double(size.height), lines: placed)
    }

    /// The layout of a text page: PDFKit's lines, split at column gaps, in PDFKit's order.
    public static func layout(ofTextPage page: PDFPage) -> PageLayout {
        let size = visibleSize(of: page)
        let placement = Placement(page: page)
        var lines: [PageLayout.Line] = []
        let text = (page.string ?? "") as NSString
        if let selection = page.selection(for: page.bounds(for: .cropBox)) {
            for line in selection.selectionsByLine() {
                for segment in columns(of: line, on: page, text: text) {
                    guard let box = placement.normalised(segment.bounds) else { continue }
                    lines.append(PageLayout.Line(text: segment.text, box: box))
                }
            }
        }
        return PageLayout(width: Double(size.width), height: Double(size.height), lines: lines)
    }

    // MARK: The column-gap split

    /// One character of a PDFKit line: its UTF-16 unit in the page's text and its bounds in page space.
    struct Character {
        var unit: unichar
        var bounds: CGRect

        var isSpace: Bool {
            unit == 0x20 || unit == 0x09 || unit == 0xA0 || unit == 0x0A || unit == 0x0D
        }
    }

    /// A column of a line: its text, trimmed, and the union of its characters' bounds in page space.
    struct Segment: Equatable {
        var text: String
        var bounds: CGRect
    }

    /// The line's characters, in the order of the page's text, each with the bounds of its one-character selection.
    ///
    /// Not `PDFPage.characterBounds(at:)`: measured on macOS 27, its index does not count the line breaks that
    /// `page.string` and the selections' ranges hold, so from the second line on it gives another character's
    /// bounds (one more per line), and its boxes are the glyphs' ink, whose heights differ from letter to letter. A
    /// selection's bounds are the font's line box, so a line's height is its font size, as `SenderDetector` compares
    /// them (`PageLayoutReaderTests`).
    static func characters(of line: PDFSelection, on page: PDFPage, text: NSString) -> [Character] {
        var characters: [Character] = []
        for index in 0..<line.numberOfTextRanges(on: page) {
            let range = line.range(at: index, on: page)
            guard range.location != NSNotFound else { continue }
            for position in range.location..<min(range.location + range.length, text.length) {
                let unit = text.character(at: position)
                let bounds =
                    page.selection(for: NSRange(location: position, length: 1))?.bounds(for: page) ?? .zero
                characters.append(Character(unit: unit, bounds: bounds))
            }
        }
        return characters
    }

    static func columns(of line: PDFSelection, on page: PDFPage, text: NSString) -> [Segment] {
        split(characters(of: line, on: page, text: text))
    }

    /// Splits a line's characters at column gaps: a gap wider than `columnGapCharacterWidths` × the median width of
    /// its non-space characters between two of them, or two or more spaces in a row.
    static func split(_ characters: [Character]) -> [Segment] {
        let widths = characters.filter { !$0.isSpace && $0.bounds.width > 0 }.map(\.bounds.width).sorted()
        let median = widths.isEmpty ? 0 : widths[widths.count / 2]
        var segments: [[Character]] = [[]]
        var spaces = 0
        var previous: CGRect?
        for character in characters {
            if character.isSpace {
                spaces += 1
                if spaces == 2 { segments.append([]) }
                segments[segments.count - 1].append(character)
                continue
            }
            let placed = character.bounds.width > 0 || character.bounds.height > 0
            if placed, let before = previous, median > 0,
                character.bounds.minX - before.maxX > columnGapCharacterWidths * median, spaces < 2
            {
                segments.append([])
            }
            spaces = 0
            segments[segments.count - 1].append(character)
            if placed { previous = character.bounds }
        }
        return segments.compactMap(segment)
    }

    /// A segment's trimmed text and the union of its placed non-space characters' bounds; `nil` when it has none.
    private static func segment(_ characters: [Character]) -> Segment? {
        let units = characters.map(\.unit)
        let text = String(utf16CodeUnits: units, count: units.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let boxes = characters.filter { !$0.isSpace && ($0.bounds.width > 0 || $0.bounds.height > 0) }.map(\.bounds)
        guard !text.isEmpty, let first = boxes.first else { return nil }
        return Segment(text: text, bounds: boxes.dropFirst().reduce(first) { $0.union($1) })
    }

    // MARK: Page space to the visible page

    /// Maps page-space rectangles (PDF user space: the media box's coordinates, origin bottom left, unrotated) to
    /// the visible page, normalised with its origin top left.
    struct Placement {
        var crop: CGRect
        /// The page's rotation, clockwise, as a multiple of 90 in 0..<360.
        var rotation: Int

        init(page: PDFPage) {
            crop = page.bounds(for: .cropBox)
            rotation = ((page.rotation % 360) + 360) % 360
        }

        init(crop: CGRect, rotation: Int) {
            self.crop = crop
            self.rotation = ((rotation % 360) + 360) % 360
        }

        /// A page-space point as a fraction of the visible page from its top-left corner.
        func normalised(_ point: CGPoint) -> CGPoint {
            let (w, h) = (crop.width, crop.height)
            let x = point.x - crop.minX
            let y = point.y - crop.minY
            switch rotation {
            case 90: return CGPoint(x: y / h, y: x / w)
            case 180: return CGPoint(x: (w - x) / w, y: y / h)
            case 270: return CGPoint(x: (h - y) / h, y: (w - x) / w)
            default: return CGPoint(x: x / w, y: (h - y) / h)
            }
        }

        /// A page-space rectangle on the visible page, normalised and clipped to it; `nil` when it lies outside.
        func normalised(_ rect: CGRect) -> PageLayout.Box? {
            guard crop.width > 0, crop.height > 0 else { return nil }
            let corners = [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            ].map(normalised)
            let minX = max(0, corners.map(\.x).min() ?? 0)
            let maxX = min(1, corners.map(\.x).max() ?? 0)
            let minY = max(0, corners.map(\.y).min() ?? 0)
            let maxY = min(1, corners.map(\.y).max() ?? 0)
            guard maxX > minX, maxY > minY else { return nil }
            return PageLayout.Box(
                x: Double(minX), y: Double(minY), width: Double(maxX - minX), height: Double(maxY - minY))
        }
    }
}
