import CoreGraphics
import CoreImage
import DokumentumCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rendered test pages for the page cleanup (#5, step 4): drawn in the test, never a real photo or camera.
///
/// A page has A4's aspect (840 × 1188) and, from its top left: a black marker square, a red band at the top
/// right, and grey text bars across the middle. `photographed` warps it onto a dark "desk" at known corners,
/// like a photo of a letter on a table.
public enum TestPage {
    public static let width = 840
    public static let height = 1188

    /// Where things are, as fractions of the page from its top left (x, y, width, height).
    public static let marker = CGRect(x: 0.06, y: 0.04, width: 0.14, height: 0.10)
    public static let redBand = CGRect(x: 0.60, y: 0.05, width: 0.34, height: 0.06)
    public static let textBars = (0..<6).map {
        CGRect(x: 0.10, y: 0.30 + CGFloat($0) * 0.08, width: 0.80, height: 0.025)
    }
    /// A point on the paper with nothing drawn on it, near the left and near the right edge.
    public static let paperLeft = CGPoint(x: 0.08, y: 0.85)
    public static let paperRight = CGPoint(x: 0.92, y: 0.85)

    /// The desk's colour.
    public static let desk: (Int, Int, Int) = (48, 44, 40)
    /// The tinted paper: a warm tint with a shadow gradient from left to right.
    public static let tintedLeft: (Int, Int, Int) = (222, 212, 186)
    public static let tintedRight: (Int, Int, Int) = (188, 180, 156)

    /// The page, upright. `tinted` gives the warm paper with a shadow gradient instead of white.
    public static func make(tinted: Bool = false) -> CGImage {
        bitmap(width: width, height: height) { context in
            let (w, h) = (CGFloat(width), CGFloat(height))
            if tinted {
                let colors = [color(tintedLeft), color(tintedRight)] as CFArray
                let space = CGColorSpace(name: CGColorSpace.sRGB)
                let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            } else {
                context.setFillColor(color((255, 255, 255)))
                context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            // CoreGraphics counts y from the bottom; the rects from the top.
            func fill(_ rect: CGRect, _ rgb: (Int, Int, Int)) {
                context.setFillColor(color(rgb))
                context.fill(
                    CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h))
            }
            fill(marker, (0, 0, 0))
            fill(redBand, (220, 30, 30))
            for bar in textBars { fill(bar, (90, 90, 90)) }
        }
    }

    /// The page "photographed": warped onto a dark desk of `canvas` pixels so its corners land at `corners`
    /// (normalised, top left origin), encoded as JPEG (quality 0.92).
    /// - Parameter exifOrientation: 1 stores the pixels as they display; 6 stores them turned a quarter to the
    ///   left with the orientation tag that turns them back, as a phone stores a portrait photo.
    public static func photographed(
        corners: PageQuad, canvas: CGSize = CGSize(width: 1200, height: 1600), exifOrientation: Int = 1,
        tinted: Bool = false
    ) -> Data {
        let displayed = photographedImage(corners: corners, canvas: canvas, tinted: tinted)
        return encode(displayed, exifOrientation: exifOrientation)
    }

    /// The desk alone, no page.
    public static func emptyDesk(canvas: CGSize = CGSize(width: 1200, height: 1600)) -> Data {
        let image = bitmap(width: Int(canvas.width), height: Int(canvas.height)) { context in
            context.setFillColor(color(desk))
            context.fill(CGRect(origin: .zero, size: canvas))
        }
        return encode(image, exifOrientation: 1)
    }

    /// Corners of a slightly turned page that covers about 45 % of a 3 : 4 photo (1200 × 1600), with about A4's
    /// aspect there (756 × 1072 px at the edges).
    public static let tiltedCorners = PageQuad(
        topLeft: CGPoint(x: 0.17, y: 0.16), topRight: CGPoint(x: 0.80, y: 0.13),
        bottomRight: CGPoint(x: 0.84, y: 0.80), bottomLeft: CGPoint(x: 0.14, y: 0.83))

    /// The displayed pixels of `photographed`.
    public static func photographedImage(corners: PageQuad, canvas: CGSize, tinted: Bool = false) -> CGImage {
        let page = CIImage(cgImage: make(tinted: tinted))
        func vector(_ point: CGPoint) -> CIVector {
            CIVector(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
        }
        let warp = CIFilter(name: "CIPerspectiveTransform")!
        warp.setValue(page, forKey: kCIInputImageKey)
        warp.setValue(vector(corners.topLeft), forKey: "inputTopLeft")
        warp.setValue(vector(corners.topRight), forKey: "inputTopRight")
        warp.setValue(vector(corners.bottomRight), forKey: "inputBottomRight")
        warp.setValue(vector(corners.bottomLeft), forKey: "inputBottomLeft")
        let frame = CGRect(origin: .zero, size: canvas)
        let background = CIImage(color: CIColor(cgColor: color(desk))).cropped(to: frame)
        let composed = warp.outputImage!.composited(over: background).cropped(to: frame)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(
            composed, from: frame, format: .RGBA8, colorSpace: space)!
    }

    private static func encode(_ displayed: CGImage, exifOrientation: Int) -> Data {
        var stored = displayed
        if exifOrientation == 6 {
            // Stored = displayed turned a quarter counter-clockwise; orientation 6 turns it clockwise again.
            let (width, height) = (displayed.width, displayed.height)
            stored = bitmap(width: height, height: width) { context in
                context.translateBy(x: CGFloat(height), y: 0)
                context.rotate(by: .pi / 2)
                context.draw(displayed, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: exifOrientation, kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        CGImageDestinationAddImage(destination, stored, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func color(_ rgb: (Int, Int, Int)) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat(rgb.0) / 255, CGFloat(rgb.1) / 255, CGFloat(rgb.2) / 255, 1])!
    }

    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }
}

/// Reads pixels of a `CGImage` in sRGB, for tests.
public enum TestPixels {
    /// The colour (red, green, blue, 0…255) at `point`, given in fractions of the image from its top left.
    public static func rgb(of image: CGImage, atFraction point: CGPoint) -> (Int, Int, Int) {
        let (width, height) = (image.width, image.height)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        // The bitmap's memory starts with the top row.
        let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = y * width * 4 + x * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    /// The centre of `rect` (fractions).
    public static func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}
