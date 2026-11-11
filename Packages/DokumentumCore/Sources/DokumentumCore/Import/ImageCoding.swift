import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image decoding and encoding for `PDFBuilder` (plan of #4, part 3). Ported from the predecessor's
/// `ImageCoding` (pklnx/document-archive `ec5c71d`, `DocumentArchive/Services/PDFBuilder.swift`), without the
/// sizes of the photo cleanup, which step 4 brings back with it. A multi-page TIFF is a page per frame (#90);
/// other formats with several images (GIF, APNG, HEIC collections) are their first image.
public enum ImageCoding {
    /// Decodes the first image in `data` with its EXIF orientation applied (a phone stores a portrait photo as
    /// landscape pixels and an orientation tag), scaled down so its longer side is at most `maxPixelSize`.
    /// Smaller images keep their size. `nil` when ImageIO cannot decode it, and `nil` for a PDF (`imageSource`).
    public static func orientedImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = imageSource(for: data) else { return nil }
        return orientedImage(from: source, at: 0, maxPixelSize: maxPixelSize)
    }

    /// An ImageIO source for `data`; `nil` when ImageIO cannot read it, and `nil` for a PDF: ImageIO decodes a
    /// PDF's first page as an image, and the image path never rasterizes a PDF, whatever reached it (#86, T3).
    /// A PDF stays a PDF only on the PDF path.
    static func imageSource(for data: Data) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .pdf) {
            return nil
        }
        return source
    }

    /// The pages `source` gives (#90): a TIFF, decided by ImageIO's type of the bytes and not by a label, gives
    /// one per frame ImageIO counts (it does not count a reduced-resolution preview or a frame it cannot
    /// read); every other image, including GIF, APNG and HEIC with several images, gives one.
    static func pageCount(of source: CGImageSource) -> Int {
        guard let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .tiff)
        else { return 1 }
        return max(CGImageSourceGetCount(source), 1)
    }

    /// Decodes image `index` of `source` like `orientedImage(from:maxPixelSize:)`, with that image's own
    /// orientation applied. `nil` when it cannot be decoded.
    static func orientedImage(from source: CGImageSource, at index: Int, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// The image as JPEG with `quality`, first scaled down to `maxPixelSize` on its longer side if it is
    /// larger.
    public static func jpegData(from image: CGImage, maxPixelSize: Int? = nil, quality: CGFloat) -> Data? {
        var image = image
        if let maxPixelSize, max(image.width, image.height) > maxPixelSize {
            image = scaled(image, maxPixelSize: maxPixelSize) ?? image
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The image scaled so its longer side is `maxPixelSize`, in sRGB.
    public static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let scale = CGFloat(maxPixelSize) / CGFloat(max(image.width, image.height, 1))
        let width = max(Int(CGFloat(image.width) * scale), 1)
        let height = max(Int(CGFloat(image.height) * scale), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
