import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images generated in the test with CoreGraphics and ImageIO, never real photos (plan of #4, part 3). Each
/// shows, upright, a red band over the top quarter on white, so a test can tell where the top of a page is.
public enum TestImage {
    /// An image that **displays** `width` × `height` pixels, encoded as `type`.
    /// - Parameters:
    ///   - exifOrientation: 1 stores the pixels as they display. 6 stores them turned a quarter to the left,
    ///     `height` × `width`, with the EXIF orientation 6 that tells a reader to turn them back: how a phone
    ///     stores a portrait photo.
    ///   - shade: the grey of the white area, 0…255; another shade gives other bytes with the same look.
    /// - Returns: empty `Data` when ImageIO cannot encode `type` on this system.
    public static func make(
        width: Int, height: Int, type: UTType = .jpeg, exifOrientation: Int = 1, shade: Int = 255
    ) -> Data {
        guard let upright = draw(width: width, height: height, shade: shade) else { return Data() }
        let stored: CGImage?
        if exifOrientation == 6 {
            // Stored = displayed turned a quarter counter-clockwise; orientation 6 turns it clockwise again.
            stored = bitmap(width: height, height: width) { context in
                context.translateBy(x: CGFloat(height), y: 0)
                context.rotate(by: .pi / 2)
                context.draw(upright, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        } else {
            stored = upright
        }
        guard let stored else { return Data() }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, type.identifier as CFString, 1, nil)
        else { return Data() }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: exifOrientation, kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(destination, stored, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    /// Whether ImageIO can write HEIC here (the iOS simulator and some Macs cannot).
    public static var canEncodeHEIC: Bool {
        !make(width: 64, height: 48, type: .heic).isEmpty
    }

    private static func draw(width: Int, height: Int, shade: Int) -> CGImage? {
        bitmap(width: width, height: height) { context in
            let grey = CGFloat(shade) / 255
            context.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            // CoreGraphics counts y from the bottom: the top quarter.
            context.fill(CGRect(x: 0, y: height * 3 / 4, width: width, height: height - height * 3 / 4))
        }
    }

    private static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        draw(context)
        return context.makeImage()
    }
}

/// Reads a built PDF back with CoreGraphics, for tests: page sizes and the colour at a point of a page.
public enum TestPDFReader {
    /// The media box size of every page, in order.
    public static func pageSizes(_ data: Data) -> [CGSize] {
        guard let document = document(data) else { return [] }
        return (0..<document.numberOfPages).compactMap { document.page(at: $0 + 1)?.getBoxRect(.mediaBox).size }
    }

    /// The colour (red, green, blue, 0…255) of page `index` (from 0) at `point`, given in fractions of the page
    /// from its top left corner.
    public static func color(_ data: Data, page index: Int, atFraction point: CGPoint) -> (Int, Int, Int)? {
        guard let page = document(data)?.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let width = max(Int(box.width), 1)
        let height = max(Int(box.height), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let pixels = context.data else { return nil }
        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        // The bitmap's memory starts with the top row.
        let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
        let offset = y * width * 4 + x * 4
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    private static func document(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }
}
