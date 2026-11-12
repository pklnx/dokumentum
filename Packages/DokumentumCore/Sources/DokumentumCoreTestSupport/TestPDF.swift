import CoreGraphics
import CoreText
import Foundation

/// PDFs generated in the test, never read from disk: the package's counterpart of the app's `SyntheticPDF`
/// (Debug app code, which the packages cannot import), with a password and a page-less variant for the
/// importer's failure cases.
public enum TestPDF {
    /// A PDF with one page per element of `pages`, each page showing its line. With `userPassword` it needs
    /// that password to open (PDFKit reads it as locked).
    public static func make(pages: [String], userPassword: String? = nil) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        var info: [CFString: Any] = [kCGPDFContextTitle: "Test"]
        if let userPassword {
            info[kCGPDFContextUserPassword] = userPassword
            info[kCGPDFContextOwnerPassword] = userPassword + "-owner"
        }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { return Data() }
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for line in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 60, y: 750)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// What one page of `make(contents:)` shows.
    public enum PageContent: Sendable {
        /// The line as real PDF text (Helvetica, 16 pt), as `make(pages:)` draws it.
        case text(String)
        /// The lines drawn into an image (150 dpi, grayscale, about 19 pt), the page's only content: a scan.
        case image([String])
        /// Nothing.
        case blank
    }

    /// An A4 PDF with one page per element of `contents`; `info` goes to the context (Info entries, passwords).
    public static func make(contents: [PageContent], info: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info.isEmpty ? nil : info as CFDictionary)
        else { return Data() }
        for content in contents {
            context.beginPDFPage(nil)
            switch content {
            case .text(let line):
                draw([line], in: context, top: 750, fontSize: 16, lineHeight: 24)
            case .image(let lines):
                if let image = pageImage(lines: lines) { context.draw(image, in: mediaBox) }
            case .blank:
                break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// An image-only PDF with one page per element of `pages`, each page an image of its lines (`PageContent.image`).
    public static func makeImageOnly(pages: [[String]]) -> Data {
        make(contents: pages.map { .image($0) })
    }

    /// An A4 page at 150 dpi (1240 × 1754 px), grayscale, with `lines` in black Helvetica of 40 px, one below the
    /// other from the top left.
    public static func pageImage(lines: [String]) -> CGImage? {
        let width = 1240
        let height = 1754
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, in: context, top: CGFloat(height) - 200, fontSize: 40, lineHeight: 70)
        return context.makeImage()
    }

    private static func draw(
        _ lines: [String], in context: CGContext, top: CGFloat, fontSize: CGFloat, lineHeight: CGFloat
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(
                string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: fontSize * 3, y: top - CGFloat(index) * lineHeight)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }

    /// A well-formed PDF whose page tree is empty (`/Count 0`): it opens, with no page. CoreGraphics cannot
    /// write one (a context closed without a page still gets one), so it is written out with its
    /// cross-reference table.
    public static func makeWithoutPages() -> Data {
        written([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [] /Count 0 >>",
        ])
    }

    /// One page of `makeRaw`: its content stream, its resources, and further keys of its page dictionary.
    public struct RawPage: Sendable {
        public var content: String
        public var resources: String
        public var keys: String

        public init(content: String, resources: String = "<< >>", keys: String = "") {
            self.content = content
            self.resources = resources
            self.keys = keys
        }

        /// A black bar across the upper part of an A4 page, drawn as a path: no text of its own, so the stage
        /// recognises the page.
        public static func bar(keys: String = "") -> RawPage {
            RawPage(content: "0 0 0 rg 72 700 300 24 re f", keys: keys)
        }

        public static let blank = RawPage(content: "")

        /// `line` as text in Helvetica, **without an embedded font program** (a standard Type 1 font, as many
        /// born-digital PDFs have it; P-m).
        public static func standardFontText(_ line: String, size: Int = 16) -> RawPage {
            RawPage(
                content: "BT /F1 \(size) Tf 60 700 Td (\(line)) Tj ET",
                resources: "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>")
        }
    }

    /// An A4 PDF written object by object, for the structures a `CGContext` never writes (#6, part 3's fixtures):
    /// object 1 is the catalog (with `catalogKeys` added), 2 the page tree, then `objects` in order (so the first is
    /// object 3, for `catalogKeys` or a page's keys to refer to), then the Info dictionary when given, then each
    /// page and its content stream. A stream object is given as its dictionary's keys and its data:
    /// `stream(_:_:)`.
    public static func makeRaw(
        pages: [RawPage], catalogKeys: String = "", objects: [String] = [], info: String? = nil
    ) -> Data {
        var bodies = ["", ""] + objects
        var infoNumber: Int?
        if let info {
            bodies.append(info)
            infoNumber = bodies.count
        }
        var kids: [String] = []
        for page in pages {
            let pageNumber = bodies.count + 1
            kids.append("\(pageNumber) 0 R")
            bodies.append(
                """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources \(page.resources) \
                /Contents \(pageNumber + 1) 0 R \(page.keys) >>
                """)
            bodies.append(stream("", page.content))
        }
        bodies[0] = "<< /Type /Catalog /Pages 2 0 R \(catalogKeys) >>"
        bodies[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>"
        return written(bodies, info: infoNumber)
    }

    /// A stream object's text for `makeRaw`: `keys` added to its dictionary, `/Length` set.
    public static func stream(_ keys: String, _ data: String) -> String {
        "<< \(keys) /Length \(data.utf8.count) >>\nstream\n\(data)\nendstream"
    }

    /// The objects numbered from 1, with their cross-reference table and a trailer naming object 1 as the root.
    private static func written(_ bodies: [String], info: Int? = nil) -> Data {
        var text = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
        let infoEntry = info.map { " /Info \($0) 0 R" } ?? ""
        text += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R\(infoEntry) >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }
}
