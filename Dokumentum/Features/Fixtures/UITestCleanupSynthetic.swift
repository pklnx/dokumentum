#if DEBUG
    import CoreGraphics
    import CoreText
    import DokumentumCore
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// `-UITestCleanupSynthetic YES` (Debug builds only, #5, part 3): "Photos…" in the "+" menu opens the photo
    /// cleanup with two rendered "photographed" pages (`SyntheticPhotographedPage`) instead of the system's Photos
    /// picker, through `ImportController.importPhotos` like picked photos. So a UI test goes menu → cleanup →
    /// importer → Inbox without the Photos library. Honoured only with an in-memory store (`-UITestEmptyStore`,
    /// `-UITestSeed`), never into an archive on disk.
    enum UITestCleanupSynthetic {
        static let argument = "-UITestCleanupSynthetic"

        static func isRequested(arguments: [String], launchStore: LaunchStore) -> Bool {
            !launchStore.choice.isOnDisk && arguments.contains(argument)
        }

        /// The two photos, as Photos would hand them over.
        static var photos: [SyntheticPhoto] {
            [
                SyntheticPhoto(data: SyntheticPhotographedPage.make(lines: ["Musterbank", "Kontoauszug November"])),
                SyntheticPhoto(
                    data: SyntheticPhotographedPage.make(lines: ["Seite 2", "Saldo 1.234,56 EUR"], tilt: -0.05)),
            ]
        }
    }

    /// A photo the synthetic pick hands over.
    struct SyntheticPhoto: ImportPhotoItem {
        let data: Data?

        func loadData() async throws -> Data? { data }
    }

    /// A rendered "photo of a letter on a table": a white A4 page with a black marker at its top left, a red band
    /// at its top right and its lines, slightly turned, on a dark desk of 1200 × 1600 px, as JPEG. Nothing is read
    /// from disk, and it is no real document.
    enum SyntheticPhotographedPage {
        static let canvas = (width: 1200, height: 1600)

        /// - Parameter tilt: the page's turn in radians (counter-clockwise when positive).
        static func make(lines: [String], tilt: CGFloat = 0.06) -> Data {
            let (width, height) = canvas
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return Data() }
            context.setFillColor(CGColor(red: 0.19, green: 0.17, blue: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // The page: 760 × 1075 px (A4), centred, turned by `tilt`. CoreGraphics counts y from the bottom.
            let page = CGSize(width: 760, height: 1075)
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.rotate(by: tilt)
            context.translateBy(x: -page.width / 2, y: -page.height / 2)
            context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
            context.fill(CGRect(origin: .zero, size: page))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 46, y: page.height - 150, width: 106, height: 106))
            context.setFillColor(CGColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 1))
            context.fill(CGRect(x: 456, y: page.height - 120, width: 258, height: 64))
            let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
            for (index, line) in lines.enumerated() {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
                    ])
                context.textPosition = CGPoint(x: 70, y: page.height - 280 - CGFloat(index) * 70)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
            for bar in 0..<6 {
                context.fill(CGRect(x: 70, y: page.height - 520 - CGFloat(bar) * 70, width: 620, height: 22))
            }
            guard let image = context.makeImage() else { return Data() }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
            else { return Data() }
            CGImageDestinationAddImage(
                destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return Data() }
            return data as Data
        }
    }
#endif
