#if DEBUG
    import CoreGraphics
    import CoreText
    import DokumentumCore
    import Foundation

    /// `-UITestScanSynthetic YES` (Debug builds only, #5, part 2): "Scan…" is in the "+" menu, also in the
    /// simulator, and instead of opening the camera it hands `ImportController.importScan` two rendered pages
    /// (`SyntheticScanPages.uiTest`). So a UI test goes menu → controller → importer → Inbox without a camera.
    /// Honoured only with an in-memory store (`-UITestEmptyStore`, `-UITestSeed`), never into an archive on disk,
    /// and only on the iPhone: the Mac has no "Scan…".
    enum UITestScanSynthetic {
        static let argument = "-UITestScanSynthetic"

        static func isRequested(arguments: [String], launchStore: LaunchStore) -> Bool {
            !launchStore.choice.isOnDisk && arguments.contains(argument)
        }
    }

    /// A scan of rendered pages: each page is an A4 sheet at 1240 × 1754 px (150 dpi) with its lines in black on
    /// white below a dark band. Nothing is read from disk, and it is no real document.
    struct SyntheticScanPages: ScannedPages {
        let pages: [[String]]

        static let uiTest = SyntheticScanPages(pages: [
            ["Stadtwerke Musterstadt", "Abschlag November", "Betrag 62,00 EUR"],
            ["Seite 2", "Zählerstand 12345"],
        ])

        static let size = (width: 1240, height: 1754)

        var pageCount: Int { pages.count }

        func image(at index: Int) -> CGImage? {
            guard pages.indices.contains(index) else { return nil }
            let (width, height) = Self.size
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 180, width: width, height: 180))
            let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
            for (line, text) in pages[index].enumerated() {
                let attributed = NSAttributedString(
                    string: text,
                    attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                            CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                    ])
                context.textPosition = CGPoint(x: 100, y: CGFloat(height - 320 - line * 90))
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            return context.makeImage()
        }
    }
#endif
