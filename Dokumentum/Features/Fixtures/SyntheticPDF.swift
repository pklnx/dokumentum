#if DEBUG
    import CoreGraphics
    import CoreText
    import DokumentumKit
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

        /// A `SyntheticLetters` entry (#11) as a one-page text PDF at its millimetres on its page size: every line in
        /// Helvetica at its font size, its top at the letter's `top`. The app's counterpart of the packages'
        /// `TestLetter`, which Debug app code cannot import.
        static func makeLetter(_ letter: SyntheticLetter) -> Data {
            let pointsPerMillimetre = 72 / 25.4
            let data = NSMutableData()
            var mediaBox = CGRect(
                x: 0, y: 0, width: letter.pageWidth * pointsPerMillimetre,
                height: letter.pageHeight * pointsPerMillimetre)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
            else { return Data() }
            context.beginPDFPage(nil)
            for line in letter.lines {
                let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
                let attributed = NSAttributedString(
                    string: line.text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                    ])
                context.textPosition = CGPoint(
                    x: line.x * pointsPerMillimetre,
                    y: mediaBox.height - line.top * pointsPerMillimetre - CTFontGetAscent(font))
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
    }
#endif
