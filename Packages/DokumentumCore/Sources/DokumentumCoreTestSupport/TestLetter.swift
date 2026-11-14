import CoreGraphics
import CoreText
import DokumentumKit
import Foundation

/// A `SyntheticLetters` entry rendered in the test (#11, part 2): as a text PDF (real PDF text, drawn with CoreText)
/// or as an image-only page (a scan), at the letter's millimetres on its page size. Every line is drawn in Helvetica
/// at its font size, its top at the letter's `top`. Nothing is read from disk, and every value is invented.
public enum TestLetter {
    /// Points per millimetre.
    static let pointsPerMillimetre = 72 / 25.4

    /// A page to draw: lines in millimetres on a page of `width` × `height` millimetres.
    public struct Page: Sendable {
        public var lines: [SyntheticLetter.Line]
        public var width: Double
        public var height: Double

        public init(lines: [SyntheticLetter.Line], width: Double, height: Double) {
            self.lines = lines
            self.width = width
            self.height = height
        }

        public init(_ letter: SyntheticLetter) {
            self.init(lines: letter.lines, width: letter.pageWidth, height: letter.pageHeight)
        }
    }

    /// The letter as a one-page PDF with real text.
    public static func textPDF(_ letter: SyntheticLetter) -> Data {
        textPDF(Page(letter))
    }

    public static func textPDF(_ page: Page) -> Data {
        pdf(page) { context, _ in draw(page, in: context, scale: 1) }
    }

    /// The letter as a one-page PDF whose only content is an image of the page at `dpi` (grayscale): a scan, which
    /// the stage recognises.
    public static func imagePDF(_ letter: SyntheticLetter, dpi: Double = 300) -> Data {
        imagePDF(Page(letter), dpi: dpi)
    }

    public static func imagePDF(_ page: Page, dpi: Double = 300) -> Data {
        pdf(page) { context, box in
            if let image = pageImage(page, dpi: dpi) { context.draw(image, in: box) }
        }
    }

    /// The page image at `dpi`, black Helvetica on white, grayscale.
    public static func pageImage(_ page: Page, dpi: Double = 300) -> CGImage? {
        let scale = dpi / 72
        let width = Int((page.width * pointsPerMillimetre * scale).rounded())
        let height = Int((page.height * pointsPerMillimetre * scale).rounded())
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(page, in: context, scale: scale)
        return context.makeImage()
    }

    private static func pdf(_ letter: Page, page: (CGContext, CGRect) -> Void) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(
            x: 0, y: 0, width: letter.width * pointsPerMillimetre, height: letter.height * pointsPerMillimetre)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }
        context.beginPDFPage(nil)
        page(context, mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Draws every line at its place: `scale` device units per point, origin bottom left.
    private static func draw(_ letter: Page, in context: CGContext, scale: Double) {
        let pageHeight = letter.height * pointsPerMillimetre * scale
        for line in letter.lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, line.size * scale, nil)
            let attributed = NSAttributedString(
                string: line.text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        CGColor(gray: 0, alpha: 1),
                ])
            let top = line.top * pointsPerMillimetre * scale
            context.textPosition = CGPoint(
                x: line.x * pointsPerMillimetre * scale, y: pageHeight - top - CTFontGetAscent(font))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }
}
