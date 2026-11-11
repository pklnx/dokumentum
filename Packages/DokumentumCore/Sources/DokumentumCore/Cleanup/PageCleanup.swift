import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Applies a `PageEdit` to a decoded photo (#5, step 4): the perspective crop to the edit's corners
/// (`CIPerspectiveCorrection`), the filter, then the clockwise quarter turns. The image is in its displayed
/// orientation (`ImageCoding` applies the EXIF orientation when it decodes), and so are the corners.
public enum PageCleanup {
    /// One context for every page. `cacheIntermediates` off, so a long batch keeps no intermediate buffers
    /// (finding 6 of the plan review on #5).
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The edited page, or `image` itself for `PageEdit.identity`. `nil` when CoreImage cannot render it.
    public static func render(_ image: CGImage, edit: PageEdit) -> CGImage? {
        if edit.isIdentity { return image }
        var page = CIImage(cgImage: image)
        if edit.corners != .fullPage {
            page = perspectiveCorrected(page, to: edit.corners)
        }
        page = filtered(page, edit.filter)
        if edit.quarterTurns > 0 {
            page = page.oriented(orientation(forClockwiseTurns: edit.quarterTurns))
        }
        let extent = page.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        // Start at (0, 0) with whole pixels.
        page = page.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let size = CGRect(x: 0, y: 0, width: extent.width.rounded(), height: extent.height.rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.createCGImage(page, from: size, format: .RGBA8, colorSpace: space)
    }

    /// The quad's content, straightened to a rectangle. CoreImage counts y from the bottom, the quad from the
    /// top.
    static func perspectiveCorrected(_ image: CIImage, to quad: PageQuad) -> CIImage {
        let extent = image.extent
        func vector(_ point: CGPoint) -> CIVector {
            CIVector(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(vector(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(vector(quad.topRight), forKey: "inputTopRight")
        filter.setValue(vector(quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(vector(quad.bottomLeft), forKey: "inputBottomLeft")
        return filter.outputImage ?? image
    }

    /// The filter applied, with the input's extent kept.
    static func filtered(_ image: CIImage, _ filter: PageFilter) -> CIImage {
        let extent = image.extent
        let output: CIImage
        switch filter {
        case .original:
            return image
        case .enhanced:
            output = enhanced(image)
        case .grayscale:
            output = gray(image)
        case .blackAndWhite:
            output = threshold(gray(enhanced(image)))
        }
        return output.cropped(to: extent)
    }

    private static func enhanced(_ image: CIImage) -> CIImage {
        apply("CIDocumentEnhancer", to: image)
    }

    private static func gray(_ image: CIImage) -> CIImage {
        apply("CIColorControls", to: image, [kCIInputSaturationKey: 0])
    }

    private static func threshold(_ image: CIImage) -> CIImage {
        apply("CIColorThresholdOtsu", to: image)
    }

    private static func apply(_ name: String, to image: CIImage, _ parameters: [String: Any] = [:]) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        for (key, value) in parameters { filter.setValue(value, forKey: key) }
        return filter.outputImage ?? image
    }

    /// The orientation whose display transform turns an image `turns` quarters clockwise.
    static func orientation(forClockwiseTurns turns: Int) -> CGImagePropertyOrientation {
        switch ((turns % 4) + 4) % 4 {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
    }
}
