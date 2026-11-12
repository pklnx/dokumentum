import CoreGraphics
import Foundation
import PDFKit

/// A document's thumbnail (#6, T5): its first page, crop box and rotation applied, in colour on white, JPEG at
/// quality 0.7, 480 px on the long side (about 8 KB, probe P-g of the plan). Made once, at import
/// (`DocumentImporter`), and by processing only for documents the re-queue pass recorded (N3, `ProcessingQueue`).
/// The text layer does not change how a page looks, so a thumbnail is never made again.
public enum Thumbnail {
    /// The long side in pixels.
    public static let longSide = 480
    /// The JPEG quality.
    public static let quality: CGFloat = 0.7

    /// The thumbnail of `document`'s first page; `nil` when it cannot be rendered or encoded (the import then
    /// goes on without one). The caller keeps `document` alive while this runs (P-h).
    public static func make(from document: PDFDocument) -> Data? {
        guard !document.isLocked, let page = document.page(at: 0) else { return nil }
        return autoreleasepool {
            guard let image = render(page) else { return nil }
            return ImageCoding.jpegData(from: image, quality: quality)
        }
    }

    /// The thumbnail of the PDF in `data`; `nil` when it does not open or cannot be rendered.
    public static func make(fromPDF data: Data) -> Data? {
        guard let document = PDFDocument(data: data) else { return nil }
        return withExtendedLifetime(document) { make(from: document) }
    }

    /// `page` rendered in sRGB on white, crop box and rotation applied, `longSide` pixels on the long side.
    static func render(_ page: PDFPage, longSide: Int = longSide) -> CGImage? {
        guard let size = PageText.renderSize(of: page, longSide: longSide),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        context.interpolationQuality = .high
        var bounds = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { bounds = CGSize(width: bounds.height, height: bounds.width) }
        context.scaleBy(x: CGFloat(size.width) / bounds.width, y: CGFloat(size.height) / bounds.height)
        // `draw(with:to:)` applies the crop box's origin and the page's rotation (as `PageText.render`).
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
