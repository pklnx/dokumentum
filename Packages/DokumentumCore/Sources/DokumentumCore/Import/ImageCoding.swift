import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image decoding and encoding for `PDFBuilder` (plan of #4, part 3). Ported from the predecessor's
/// `ImageCoding` (pklnx/document-archive `ec5c71d`, `DocumentArchive/Services/PDFBuilder.swift`), without the
/// sizes of the photo cleanup, which step 4 brings back with it.
public enum ImageCoding {
    /// Decodes the first image in `data` with its EXIF orientation applied (a phone stores a portrait photo as
    /// landscape pixels and an orientation tag), scaled down so its longer side is at most `maxPixelSize`.
    /// Smaller images keep their size. `nil` when ImageIO cannot decode it.
    public static func orientedImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
