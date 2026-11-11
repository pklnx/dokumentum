import CoreGraphics
import Foundation
import ImageIO

/// Builds a compact PDF from images (image files, photos), one page per image and one per frame of a
/// multi-page TIFF (plan of #4, part 3; #90). The images are scaled down and embedded as JPEG, so the files
/// stay small and sync quickly through iCloud.
/// Ported from the predecessor's `PDFBuilder` (pklnx/document-archive `ec5c71d`); the photo cleanup path,
/// `makePDF(fromEditedImages:)`, is step 4's (#5).
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

    /// The edited photos (#5, step 4): one page per `EditedPage`, in order, each decoded only when it is drawn
    /// and cleaned with its edit (`PageCleanup`), so one full-size page is in memory at a time. A page whose
    /// image or frame cannot be decoded, or whose edit cannot be rendered, is left out and counted. `nil` when
    /// no page was drawn.
    public static func makePDF(fromEditedImages items: [EditedImage]) -> Result? {
        makePDF(fromEditedImages: items, trace: nil)
    }

    /// What `makePDF(fromEditedImages:trace:)` does, for the test that pins one page at a time.
    enum PageEvent: Equatable {
        case decoded(Int)
        case drawn(Int)
    }

    static func makePDF(fromEditedImages items: [EditedImage], trace: ((PageEvent) -> Void)?) -> Result? {
        let pages = items.indices.flatMap { item in items[item].pages.map { (item: item, page: $0) } }
        var current: (item: Int, source: CGImageSource?)?
        var leftOut = 0
        let built = makePDF(
            pageCount: pages.count,
            page: { index in
                let page = pages[index]
                if current?.item != page.item {
                    current = (page.item, ImageCoding.imageSource(for: items[page.item].data))
                }
                trace?(.decoded(index))
                guard let source = current?.source, let image = editedPage(source, page.page) else {
                    leftOut += 1
                    return nil
                }
                return image
            },
            drawn: { trace?(.drawn($0)) })
        return built.map { Result(data: $0.data, pageCount: $0.pageCount, leftOut: leftOut) }
    }

    /// One edited page: frame `page.frame` of `source`, decoded large enough that the cropped page keeps up to
    /// `maxPixelSize` on its longer side (finding 4 of the plan review on #5), cleaned, and scaled down to at
    /// most `maxPixelSize`. `nil` when the frame does not exist or cannot be decoded or rendered.
    static func editedPage(_ source: CGImageSource, _ page: EditedPage) -> CGImage? {
        guard page.frame >= 0, page.frame < ImageCoding.pageCount(of: source) else { return nil }
        let size = decodeSize(for: page.edit.corners, of: ImageCoding.displayedSize(of: source, at: page.frame))
        guard let image = ImageCoding.orientedImage(from: source, at: page.frame, maxPixelSize: size),
            let edited = PageCleanup.render(image, edit: page.edit)
        else { return nil }
        guard max(edited.width, edited.height) > maxPixelSize else { return edited }
        return ImageCoding.scaled(edited, maxPixelSize: maxPixelSize)
    }

    /// The longest side a page is decoded at for its crop, and the most pixels (finding N1 of review 5865079459 on
    /// #118): a small crop of a 48 MP photo would otherwise decode the whole photo, about 195 MB as RGBA. At the cap
    /// a page stays near 24 MP (about 96 MB as RGBA) while it is cleaned; the crop then has fewer than 2400 px.
    static let maxDecodePixelSize = 6000
    static let maxDecodePixels: CGFloat = 24_000_000

    /// The longer side to decode an image of `size` (displayed) at, so that the page inside `quad` keeps
    /// `maxPixelSize` on its longer side once it is straightened: `min(original, maxPixelSize / extent)`, capped at
    /// `maxDecodePixelSize` and `maxDecodePixels`. The extent is the straightened page's, the longer of the quad's
    /// opposite edges (`CIPerspectiveCorrection` gives about that size), not its bounding box: a tilted page's box is
    /// larger than the page (finding N2 of review 5865079459). The full page gives `maxPixelSize`, as
    /// `makePDF(fromImageData:)`; an unknown size too.
    static func decodeSize(for quad: PageQuad, of size: CGSize?) -> Int {
        guard let size, size.width >= 1, size.height >= 1 else { return maxPixelSize }
        let longer = max(size.width, size.height)
        let shorter = min(size.width, size.height)
        let extent = straightenedExtent(of: quad, in: size)
        let cap = min(CGFloat(maxDecodePixelSize), (maxDecodePixels * longer / shorter).squareRoot().rounded(.down))
        let needed =
            extent >= 1 ? (CGFloat(maxPixelSize) * longer / extent).rounded(.up) : longer
        let decode = min(longer, max(min(needed, cap), CGFloat(maxPixelSize)))
        return Int(decode.rounded(.up))
    }

    /// The longer side, in pixels of an image of `size`, of the page `quad` straightens to: the longest of its four
    /// edges' horizontal and vertical counterparts (top and bottom for the width, left and right for the height).
    static func straightenedExtent(of quad: PageQuad, in size: CGSize) -> CGFloat {
        func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot((b.x - a.x) * size.width, (b.y - a.y) * size.height)
        }
        let width = max(length(quad.topLeft, quad.topRight), length(quad.bottomLeft, quad.bottomRight))
        let height = max(length(quad.topLeft, quad.bottomLeft), length(quad.topRight, quad.bottomRight))
        return max(width, height)
    }

    /// Builds the PDF one page at a time: `page(i)` is asked for each page just before it is drawn. Pages for
    /// which `page` returns `nil` are left out; `nil` when no page was drawn. `drawn(i)` follows each page drawn.
    static func makePDF(pageCount: Int, page: (Int) -> CGImage?, drawn: (Int) -> Void = { _ in }) -> (
        data: Data, pageCount: Int
    )? {
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
                drawn(index)
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
