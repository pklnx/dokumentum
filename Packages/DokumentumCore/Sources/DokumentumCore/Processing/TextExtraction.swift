import CoreGraphics
import DokumentumKit
import Foundation
import PDFKit

/// A document's text as the stage found it, page by page (#6, part 2), and where it came from.
public struct ExtractedText: Equatable, Sendable {
    /// Between two pages' texts: a form feed. The search (#7) relies on it to tell pages apart.
    public static let pageSeparator = "\u{0C}"
    /// The most `DocumentText.extractedText` holds, in UTF-8 bytes (T7, N6 of #6). A CloudKit record holds at most
    /// 1 MB of non-asset fields, and whether the mirror moves a large string to an asset is not verified.
    public static let byteLimit = 500_000

    /// Each page's text, in page order: the PDF's own text (trimmed) or the recognised lines joined by newlines. A
    /// form feed inside a page's text is a newline here, so `pageSeparator` only ever separates pages (#122 splits
    /// on it).
    public var pages: [String]
    /// `.pdfText` when every page had text of its own; `.vision` when at least one page was recognised, also when
    /// nothing was found. So `.none` keeps meaning "never extracted" (the re-queue pass relies on it).
    public var source: TextSource

    public init(pages: [String], source: TextSource) {
        self.pages = pages.map { $0.replacingOccurrences(of: Self.pageSeparator, with: "\n") }
        self.source = source
    }

    /// The pages joined with `pageSeparator`; `""` when no page has text (a blank document), so an empty text
    /// never holds separators only.
    public var joined: String {
        pages.allSatisfy(\.isEmpty) ? "" : pages.joined(separator: Self.pageSeparator)
    }

    /// The text to store: all pages when they fit in `limit` UTF-8 bytes; otherwise the most whole pages that fit
    /// (cut at a page boundary, without a trailing separator). When the first page with text does not fit whole
    /// (page 1, or a later one after blank pages), it is cut at its last whole character within the limit, never
    /// inside a UTF-8 sequence or a character (N6), after the separators of the blank pages before it, so the page
    /// numbers stay right.
    public func capped(toBytes limit: Int = byteLimit) -> (text: String, isCapped: Bool) {
        var kept = 0
        var bytes = 0
        for page in pages {
            let added = page.utf8.count + (kept == 0 ? 0 : Self.pageSeparator.utf8.count)
            guard bytes + added <= limit else { break }
            bytes += added
            kept += 1
        }
        if kept == pages.count { return (joined, false) }
        guard let first = pages.firstIndex(where: { !$0.isEmpty }) else { return ("", false) }
        // Whole pages up to and with the first page with text fit: cut at the last page boundary.
        if kept > first { return (pages.prefix(kept).joined(separator: Self.pageSeparator), true) }
        // The first page with text does not fit whole: cut it, after one separator per blank page before it.
        let separators = String(repeating: Self.pageSeparator, count: first)
        guard separators.utf8.count < limit else { return ("", true) }
        return (separators + Self.prefix(of: pages[first], bytes: limit - separators.utf8.count), true)
    }

    /// The longest prefix of `text` made of whole characters with at most `limit` UTF-8 bytes.
    static func prefix(of text: String, bytes limit: Int) -> String {
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard count + size <= limit else { break }
            count += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}

/// The rules of the text stage that do not depend on the recogniser (#6, part 2): which page has text of its own
/// (T2), and how a page without is rendered for recognition (T3).
public enum PageText {
    /// A page whose own text has at least this many non-whitespace characters is a text page (T2): fewer is a
    /// scanner's stamped page number or a stray invisible character, and the page is recognised.
    public static let minimumCharacters = 16
    /// The long side of a rendered page in pixels (T3): 3508 px recognised no better on the plan's probe (P-d).
    public static let renderLongSide = 2400

    /// The page's own text, trimmed, when it is a text page; `nil` when it must be recognised.
    public static func embeddedText(of page: PDFPage) -> String? {
        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return isTextPage(text) ? text : nil
    }

    /// Whether `text` has at least `minimumCharacters` non-whitespace characters, counted as `Character`s
    /// (grapheme clusters): a decomposed "ä" (a + U+0308) counts once, as a reader sees it.
    public static func isTextPage(_ text: String) -> Bool {
        var count = 0
        for character in text where !character.isWhitespace {
            count += 1
            if count >= minimumCharacters { return true }
        }
        return false
    }

    /// The pixel size of `page` rendered with its crop box and rotation at `longSide` on the long side.
    public static func renderSize(of page: PDFPage, longSide: Int = renderLongSide) -> (width: Int, height: Int)? {
        var bounds = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { bounds = CGSize(width: bounds.height, height: bounds.width) }
        let long = max(bounds.width, bounds.height)
        guard long > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(longSide) / long
        return (max(1, Int((bounds.width * scale).rounded())), max(1, Int((bounds.height * scale).rounded())))
    }

    /// `page` rendered in grayscale on white, crop box and rotation applied, `longSide` pixels on the long side
    /// (T3). The caller keeps the page's `PDFDocument` alive while this runs (P-h).
    public static func render(_ page: PDFPage, longSide: Int = renderLongSide) -> CGImage? {
        guard let size = renderSize(of: page, longSide: longSide),
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        var bounds = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { bounds = CGSize(width: bounds.height, height: bounds.width) }
        context.scaleBy(x: CGFloat(size.width) / bounds.width, y: CGFloat(size.height) / bounds.height)
        // `draw(with:to:)` applies the crop box's origin and the page's rotation (probe on #114).
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
