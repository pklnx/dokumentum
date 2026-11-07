#if DEBUG
import CoreGraphics
import CoreText
import Foundation

/// Generated PDFs with real text pages, for sample documents in Debug builds and UI tests. Nothing is
/// read from disk. Drawn with CoreGraphics and CoreText as the predecessor's `UITestSeed.renderPage`,
/// but written as PDF pages, so the text can be selected and searched. #31's Sync lab reuses it.
enum SyntheticPDF {
    /// A4 in points.
    static let pageSize = CGSize(width: 595, height: 842)

    /// A PDF with one page per element of `pages`; each page shows its lines from the top.
    static func make(pages: [[String]]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let headline = CTFontCreateWithName("Helvetica-Bold" as CFString, 22, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(mediaBox)
            for (index, line) in lines.enumerated() {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): index == 0 ? headline : font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                    ])
                context.textPosition = CGPoint(x: 60, y: pageSize.height - 90 - CGFloat(index) * 30)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
#endif
