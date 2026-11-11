import Foundation

/// What a file's bytes are, whatever its name or declared type says (#86). A sender can label a PDF as an
/// image (a share item declared `public.png`, a PDF named `Vertrag.png`); taken by the label, ImageIO would
/// decode its first page and the import would keep that one page. Foundation only, so it is tested on Linux
/// and the share extension could use it without linking the archive.
public enum ImportContent {
    /// How far into the bytes the PDF header may lie: the tolerance PDF readers give it. ImageIO finds it up
    /// to 3 bytes in (a UTF-8 byte order mark), PDFKit much further (probe on #86), so "starts with" is not
    /// enough.
    public static let pdfHeaderWindow = 1024

    private static let pdfHeader = Data("%PDF-".utf8)

    /// Whether `data` is a PDF by its bytes: `%PDF-` lies within the first `pdfHeaderWindow` bytes (it starts at
    /// byte 1,019 at the latest). Whether the PDF opens is PDFKit's question, not this one's.
    public static func isPDF(_ data: Data) -> Bool {
        data.prefix(pdfHeaderWindow).range(of: pdfHeader) != nil
    }
}
