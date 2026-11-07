#if DEBUG
    import CoreGraphics
    import CoreText
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// A generated photo for UI tests (plan of #4, part 3): a portrait receipt stored the way a phone stores a
    /// portrait photo, as landscape pixels with EXIF orientation 6. Imported, it must become an upright
    /// portrait page. Nothing is read from disk, and it is no real photo.
    enum SyntheticImage {
        /// The receipt as it displays, in pixels.
        static let displayedSize = (width: 900, height: 1200)

        /// A JPEG of `lines` on white below a dark blue band, upright when displayed; stored turned a quarter
        /// to the left with orientation 6.
        static func makePortraitPhoto(lines: [String]) -> Data {
            let (width, height) = displayedSize
            guard
                let upright = bitmap(
                    width: width, height: height,
                    draw: { context in
                        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1))
                        context.fill(CGRect(x: 0, y: height - 160, width: width, height: 160))
                        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 52, nil)
                        for (index, line) in lines.enumerated() {
                            let attributed = NSAttributedString(
                                string: line,
                                attributes: [
                                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                                        CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                ])
                            context.textPosition = CGPoint(x: 70, y: CGFloat(height - 280 - index * 90))
                            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                        }
                    }),
                let stored = bitmap(
                    width: height, height: width,
                    draw: { context in
                        context.translateBy(x: CGFloat(height), y: 0)
                        context.rotate(by: .pi / 2)
                        context.draw(upright, in: CGRect(x: 0, y: 0, width: width, height: height))
                    })
            else { return Data() }
            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
            else { return Data() }
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.9,
            ]
            CGImageDestinationAddImage(destination, stored, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return Data() }
            return data as Data
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
#endif
