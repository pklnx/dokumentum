import CoreGraphics
import Foundation
import ImageIO

/// Builds a compact PDF from images (image files, photos), one page per image and one per frame of a
/// multi-page TIFF (plan of #4, part 3; #90). The images are scaled down and embedded as JPEG, so the files
/// stay small and sync quickly through iCloud.
/// Ported from the predecessor's `PDFBuilder` (pklnx/document-archive `ec5c71d`) without the photo cleanup
/// path (step 4 adds it).
public enum PDFBuilder {
    /// Page width in PDF points (A4 width). The height follows from the image's aspect ratio.
    public static let pageWidth: CGFloat = 595
    /// The longest side of an embedded image, in pixels.
    public static let maxPixelSize = 2400
    /// The JPEG quality of an embedded image.
    public static let jpegQuality: CGFloat = 0.72

    /// A built PDF.
    public struct Result: Sendable {
        public let data: Data
        /// The pages drawn: one per image, and one per frame of a multi-page TIFF, that could be decoded.
        public let pageCount: Int
        /// The images or TIFF frames that could not be decoded and were left out.
        public let leftOut: Int
    }

    /// One page per item of `items`, in their order, and for a multi-page TIFF one page per frame, in frame
    /// order at the item's place (#90); other formats with several images (GIF, APNG, HEIC) give their first
    /// image. Each page is decoded with its EXIF orientation only when it is drawn, so one full-size image is
    /// in memory at a time. An item or frame ImageIO cannot decode is left out and counted. `nil` when nothing
    /// could be decoded (or there is no item).
    public static func makePDF(fromImageData items: [Data]) -> Result? {
        // A page per (item, frame), in order. An item ImageIO cannot read keeps one page, left out when drawn.
        let pages = items.indices.flatMap { item in
            let frames = ImageCoding.imageSource(for: items[item]).map(ImageCoding.pageCount(of:)) ?? 1
            return (0..<frames).map { (item: item, frame: $0) }
        }
        // One source per item, shared by its frames (ImageIO finds a frame faster in a source it already has),
        // and only the current item's source alive.
        var current: (item: Int, source: CGImageSource?)?
        var leftOut = 0
        let built = makePDF(pageCount: pages.count) { index in
            let page = pages[index]
            if current?.item != page.item { current = (page.item, ImageCoding.imageSource(for: items[page.item])) }
            guard let source = current?.source,
                let image = ImageCoding.orientedImage(from: source, at: page.frame, maxPixelSize: maxPixelSize)
            else {
                leftOut += 1
                return nil
            }
            return image
        }
        return built.map { Result(data: $0.data, pageCount: $0.pageCount, leftOut: leftOut) }
    }

    /// Builds the PDF one page at a time: `page(i)` is asked for each page just before it is drawn. Pages for
    /// which `page` returns `nil` are left out; `nil` when no page was drawn.
    static func makePDF(pageCount: Int, page: (Int) -> CGImage?) -> (data: Data, pageCount: Int)? {
        guard pageCount > 0 else { return nil }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * 1.414)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var pagesDrawn = 0
        for index in 0..<pageCount {
            autoreleasepool {
                guard let original = page(index) else { return }
                let image = compressed(original) ?? original
                let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
                var pageBox = CGRect(x: 0, y: 0, width: pageWidth, height: (pageWidth * aspect).rounded())
                let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
                context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                context.interpolationQuality = .high
                context.draw(image, in: pageBox)
                context.endPDFPage()
                pagesDrawn += 1
            }
        }
        context.closePDF()
        return pagesDrawn > 0 ? (output as Data, pagesDrawn) : nil
    }

    /// The image scaled down and compressed as JPEG. Quartz copies JPEG data into the PDF when it draws such
    /// an image, instead of embedding it uncompressed.
    private static func compressed(_ image: CGImage) -> CGImage? {
        guard let jpeg = ImageCoding.jpegData(from: image, maxPixelSize: maxPixelSize, quality: jpegQuality),
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
