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

    /// A well-formed PDF whose page tree is empty (`/Count 0`): it opens, with no page. CoreGraphics cannot
    /// write one (a context closed without a page still gets one), so it is written out with its
    /// cross-reference table.
    public static func makeWithoutPages() -> Data {
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n",
        ]
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for object in objects {
            offsets.append(text.utf8.count)
            text += object
        }
        let xref = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }
}
