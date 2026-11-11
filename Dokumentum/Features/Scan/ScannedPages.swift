import CoreGraphics
import DokumentumCore
import Foundation

#if os(iOS)
    import UIKit
    import VisionKit
#endif

/// The pages of one scan, upright (#5, part 2). The seam between VisionKit and the import: the camera's
/// `VNDocumentCameraScan` cannot be created in a test, so everything behind this protocol (encoding, import,
/// title, notice, selection) is tested with rendered pages, and the camera itself is the device check (M2).
protocol ScannedPages: Sendable {
    var pageCount: Int { get }
    /// The page at `index` (0-based), upright; `nil` when it cannot be read.
    func image(at index: Int) -> CGImage?
}

/// Encodes a scan's pages for the import (T4): JPEG at quality 0.9, the longer side at most 2400 px, one page
/// at a time, off the main actor. `PDFBuilder` compresses each page again at 0.72; PNG would hold 5–10 MB per
/// page for a long scan.
enum ScanEncoder {
    static let maxPixelSize = PDFBuilder.maxPixelSize
    static let quality: CGFloat = 0.9

    /// The pages as JPEG, in page order; a page that cannot be read or encoded is left out and counted.
    @concurrent
    static func jpegPages(_ scan: some ScannedPages) async -> (pages: [Data], unreadable: Int) {
        var pages: [Data] = []
        var unreadable = 0
        for index in 0..<scan.pageCount {
            // One page in memory at a time: the decoded page and its scaled copy go before the next.
            let data: Data? = autoreleasepool {
                scan.image(at: index).flatMap {
                    ImageCoding.jpegData(from: $0, maxPixelSize: maxPixelSize, quality: quality)
                }
            }
            if let data { pages.append(data) } else { unreadable += 1 }
        }
        return (pages, unreadable)
    }
}

#if os(iOS)
    /// The camera's scan (iOS). `VNDocumentCameraScan` is not `Sendable`: it is read only (`pageCount`,
    /// `imageOfPage(at:)`), and the scanner's coordinator hands it over once and never touches it again, so the
    /// encoder may read it off the main actor.
    struct CameraScan: ScannedPages, @unchecked Sendable {
        let scan: VNDocumentCameraScan

        var pageCount: Int { scan.pageCount }

        func image(at index: Int) -> CGImage? {
            ScannedImage.upright(scan.imageOfPage(at: index))
        }
    }

    enum ScannedImage {
        /// The pixels of `image` as it displays. VisionKit's pages are `.up`, so this is their `cgImage`; any other
        /// orientation (or an image without a `CGImage`) is drawn upright first, so it is never dropped silently
        /// (plan review of #5, finding 6).
        static func upright(_ image: UIImage) -> CGImage? {
            if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = true
            return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(at: .zero)
            }.cgImage
        }
    }
#endif
