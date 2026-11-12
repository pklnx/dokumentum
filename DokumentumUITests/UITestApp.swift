import ImageIO
import XCTest

/// Launches the app for a UI test and finds its elements by accessibility identifier, never by
/// localized text.
@MainActor
struct UITestApp {
    let app = XCUIApplication()

    /// The store a UI test launches with; both are in memory and never saved.
    enum Store {
        /// `-UITestSeed`: the sample documents, with the catalog's fixed `instanceID`s.
        case samples
        /// `-UITestEmptyStore`: an empty archive.
        case empty
        /// `-UITestLocalStore <name>`: a new, empty local store on disk in the app's temporary directory,
        /// never the archive's path.
        case localOnDisk(name: String)
    }

    /// `-UITestSeed`: the sample library in an in-memory store (the predecessor's argument; `-UITestEmptyStore`
    /// for an empty one). `-ApplePersistenceIgnoreState YES`: a development Mac keeps stale window
    /// state for the app's bundle ID, under which a build with a different root view type opens no
    /// window (plan of #3, T5).
    ///
    /// Every argument comes as a `-key value` pair. A bare `-UITestSeed` takes the next argument as its
    /// value, so in `-UITestSeed -ApplePersistenceIgnoreState YES` the `YES` is left over, macOS opens it
    /// as a document, and SwiftUI then opens no window at all (measured on macOS 27, #43).
    static func launchArguments(_ store: Store) -> [String] {
        let storeArguments =
            switch store {
            case .samples: ["-UITestSeed", "YES"]
            case .empty: ["-UITestEmptyStore", "YES"]
            case .localOnDisk(let name): ["-UITestLocalStore", name]
            }
        return storeArguments + ["-ApplePersistenceIgnoreState", "YES"]
    }

    /// The language of this run: `TEST_RUNNER_DOKUMENTUM_UI_LANGUAGE=de` on the `xcodebuild` command
    /// line gives the German screenshots. Empty: the system's language.
    static var language: String? {
        ProcessInfo.processInfo.environment["DOKUMENTUM_UI_LANGUAGE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The Dynamic Type size of this run on the iPhone: `TEST_RUNNER_DOKUMENTUM_UI_CONTENT_SIZE=XXXL` gives the
    /// screenshots at that size (plan of #3, part 5). The name of a `UIContentSizeCategory` without its prefix
    /// (`XXXL`, `AccessibilityXXXL`); empty: the simulator's setting.
    static var contentSize: String? {
        ProcessInfo.processInfo.environment["DOKUMENTUM_UI_CONTENT_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The appearance of this run on the Mac, set for the app alone; the system's setting stays as it is.
    /// `TEST_RUNNER_DOKUMENTUM_UI_APPEARANCE=light`: through `-NSRequiresAquaSystemAppearance YES` (plan of #82, T1).
    /// `TEST_RUNNER_DOKUMENTUM_UI_APPEARANCE=dark`: through the app's `-UITestAppearance dark` (Debug builds, #82).
    /// Empty: the system's appearance. The screenshot and audit names then end with `light` or `dark`.
    static var appearance: String? {
        ProcessInfo.processInfo.environment["DOKUMENTUM_UI_APPEARANCE"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// - Parameter extraArguments: more `-key value` pairs, such as `-UITestImportSynthetic YES`.
    func launch(_ store: Store = .samples, extraArguments: [String] = []) {
        var arguments = Self.launchArguments(store) + extraArguments
        if let language = Self.language {
            arguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        }
        if let contentSize = Self.contentSize {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(contentSize)"]
        }
        #if os(macOS)
            switch Self.appearance {
            case "light": arguments += ["-NSRequiresAquaSystemAppearance", "YES"]
            case "dark": arguments += ["-UITestAppearance", "dark"]
            default: break
            }
        #endif
        app.launchArguments = arguments
        app.launch()
    }

    /// The first element with this identifier: an identifier on a sidebar row can match more than one
    /// element (measured on iOS in the plan of #3).
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Taps on iOS, clicks on macOS.
    func activate(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = element(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(identifier) did not appear", file: file, line: line)
        #if os(macOS)
            element.click()
        #else
            element.tap()
        #endif
    }

    /// A screenshot of the app's window only, kept with the result. Never `XCUIScreen.main`: on the
    /// Mac that is the whole desktop, with other apps' windows.
    func attachWindowScreenshot(_ name: String, to testCase: XCTestCase) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = Self.attachmentName(name)
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    /// `<name>[-<content size>][-<appearance>][-<language>]`, as the evidence files are named.
    static func attachmentName(_ name: String) -> String {
        [name, contentSize?.lowercased(), appearance?.lowercased(), language].compactMap { $0 }.joined(separator: "-")
    }

    /// The prefixes of the app's own accessibility identifiers (`AccessibilityID`, `DokumentumApp.rootIdentifier`).
    static let appIdentifierPrefixes = [
        "sidebar", "documentList", "documentDetail", "documentInfo", "import.", "trash.", "debug.", "dokumentum.",
        "search.", "syncStatus.",
    ]

    /// An audit issue on one of the app's own elements that the audit reports although the element is right
    /// (#82). It matches the exact identifier, the audit type and the issue's description (`compactDescription`,
    /// in English in every language of the run); any other issue on the same element still fails.
    struct AcceptedAuditIssue {
        let identifier: String
        let auditType: XCUIAccessibilityAuditType
        let description: String
        /// Why it is accepted, with the measurement; repeated in `docs/development/index.md` ("Library UI").
        let reason: String

        @MainActor
        func matches(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
            issue.element?.identifier == identifier && issue.auditType == auditType
                && issue.compactDescription == description
        }
    }

    #if os(macOS)
        /// The Mac's accepted issues (plan of #82, T2). Each is still listed in the audit's attachment, marked
        /// `ACCEPTED`; one the audit did not report in a run is listed as `ACCEPTED, not reported`, without failing,
        /// because the audit is not fully stable (review of #74, 5849597239).
        static let acceptedAuditIssues = [
            AcceptedAuditIssue(
                identifier: "sidebar.syncOff", auditType: .contrast, description: "Contrast failed",
                reason:
                    "text on the .bar material; lowest measured contrast 7.34:1 light (#74) and 10.35:1 dark (#82), "
                    + "on window PNGs. The bar is translucent, so the values depend on what lies behind the window. "
                    + "The audit fails text over the material whatever its contrast."),
            AcceptedAuditIssue(
                identifier: "import.menu", auditType: .action, description: "Action is missing",
                reason:
                    "the AppKit toolbar menu button of a SwiftUI Menu; none of the 13 SwiftUI variants tried passes "
                    + "(#82). VoiceOver opening the menu: not verified, #3 Done-when."),
        ]
    #else
        static let acceptedAuditIssues: [AcceptedAuditIssue] = []
    #endif

    /// Runs the system's accessibility audit on what is shown now (plan of #3, T12). An issue on an element with
    /// one of the app's own identifiers fails the test, unless it is one of `acceptedAuditIssues`; the others
    /// (system controls, elements without an identifier) are listed in a text attachment named `audit-<name>`, for
    /// the PR body, and do not fail it.
    func auditAccessibility(_ name: String, in testCase: XCTestCase, file: StaticString = #filePath, line: UInt = #line)
    {
        var listed: [String] = []
        var reported = Set<Int>()
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                let identifier = issue.element?.identifier ?? ""
                let description =
                    "\(issue.auditType.rawValue) \(issue.compactDescription) | id: \(identifier) | label: \(issue.element?.label ?? "")"
                guard Self.appIdentifierPrefixes.contains(where: { identifier.hasPrefix($0) }) else {
                    listed.append(description)
                    return true
                }
                if let index = Self.acceptedAuditIssues.firstIndex(where: { $0.matches(issue) }) {
                    reported.insert(index)
                    listed.append("ACCEPTED (\(Self.acceptedAuditIssues[index].reason)) " + description)
                    return true
                }
                listed.append("FAIL " + description)
                return false
            }
        } catch {
            XCTFail("accessibility audit \(name): \(error)", file: file, line: line)
        }
        for (index, accepted) in Self.acceptedAuditIssues.enumerated() where !reported.contains(index) {
            listed.append(
                "ACCEPTED, not reported: \(accepted.auditType.rawValue) \(accepted.description) | id: \(accepted.identifier)"
            )
        }
        let attachment = XCTAttachment(string: listed.isEmpty ? "no issues" : listed.joined(separator: "\n"))
        attachment.name = Self.attachmentName("audit-" + name)
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    #if os(macOS)
        /// Measures the text contrast of the element with this identifier from its own screenshot, never the screen's
        /// (#89): the background is the most common pixel, the text the pixel farthest from it in relative luminance,
        /// and the ratio is WCAG's. The audit cannot be this check: in light it fails regular-weight text whatever its
        /// colour (plan of #89, finding 2). The PNG is decoded at its native pixel size and drawn 1:1 into sRGB, so a
        /// 2× display or a display profile does not blur or shift the stems (plan review N1). At least
        /// `minimumPixels` pixels must reach the ratio, so one stray pixel cannot pass (N2). The measurement is printed
        /// and attached as `contrast-<identifier>`; on a failure the element's screenshot is attached too.
        @discardableResult
        func assertTextContrast(
            _ identifier: String, atLeast minimum: Double = 4.5, minimumPixels: Int = 10, in testCase: XCTestCase,
            file: StaticString = #filePath, line: UInt = #line
        ) -> TextContrast? {
            let element = element(identifier)
            guard element.waitForExistence(timeout: 20) else {
                XCTFail("\(identifier) did not appear", file: file, line: line)
                return nil
            }
            let screenshot = element.screenshot()
            guard let contrast = TextContrast(png: screenshot.pngRepresentation, minimum: minimum) else {
                XCTFail("\(identifier): the screenshot could not be measured", file: file, line: line)
                return nil
            }
            let summary =
                "CONTRAST \(Self.attachmentName(identifier)): \(contrast.description), "
                + "\(contrast.pixelsReachingMinimum) px ≥ \(minimum):1"
            print(summary)
            let measurement = XCTAttachment(string: summary)
            measurement.name = Self.attachmentName("contrast-" + identifier)
            measurement.lifetime = .keepAlways
            testCase.add(measurement)
            if contrast.pixelsReachingMinimum < minimumPixels {
                let image = XCTAttachment(screenshot: screenshot)
                image.name = Self.attachmentName("contrast-failed-" + identifier)
                image.lifetime = .keepAlways
                testCase.add(image)
                XCTFail(
                    "\(identifier): \(contrast.description); only \(contrast.pixelsReachingMinimum) px reach "
                        + "\(minimum):1, \(minimumPixels) needed",
                    file: file, line: line)
            }
            return contrast
        }
    #endif
}

extension UITestApp {
    /// How many pixels of two rows' leading `width` × `height` pt differ by more than 0.15 in relative luminance
    /// (#6, part 4: a thumbnail against the placeholder), and the thumbnail's area in pixels at the screenshots'
    /// scale. Each PNG is drawn 1:1 into sRGB; `pointWidths` are the elements' widths in points, for the scale.
    static func leadingBandDifference(
        _ first: XCUIScreenshot, _ second: XCUIScreenshot, width: CGFloat, height: CGFloat,
        pointWidths: (CGFloat, CGFloat)
    ) -> (differing: Int, thumbnailArea: Int)? {
        guard let a = Pixels(png: first.pngRepresentation), let b = Pixels(png: second.pngRepresentation),
            pointWidths.0 > 0, pointWidths.1 > 0
        else { return nil }
        let scale = CGFloat(a.width) / pointWidths.0
        guard abs(CGFloat(b.width) / pointWidths.1 - scale) < 0.01 else { return nil }
        let bandWidth = min(Int(width * scale), a.width, b.width)
        let bandHeight = min(Int(height * scale), a.height, b.height)
        var differing = 0
        for y in 0..<bandHeight {
            for x in 0..<bandWidth where abs(a.luminance(x, y) - b.luminance(x, y)) > 0.15 {
                differing += 1
            }
        }
        // The thumbnail is 40 × 56 pt.
        return (differing, Int(40 * scale * 56 * scale))
    }

    /// A PNG's pixels in sRGB, top row first.
    struct Pixels {
        let width: Int
        let height: Int
        private let bytes: [UInt8]

        init?(png: Data) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let sRGB = CGColorSpace(name: CGColorSpace.sRGB), image.width > 0, image.height > 0
            else { return nil }
            width = image.width
            height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn else { return nil }
            bytes = pixels
        }

        /// WCAG 2 relative luminance of the pixel at `x`, `y` (from the top left).
        func luminance(_ x: Int, _ y: Int) -> Double {
            let index = (y * width + x) * 4
            func linear(_ component: UInt8) -> Double {
                let value = Double(component) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(bytes[index]) + 0.7152 * linear(bytes[index + 1]) + 0.0722 * linear(bytes[index + 2])
        }
    }
}

#if os(macOS)
    /// The text contrast of a PNG of one text element (`UITestApp.assertTextContrast`).
    struct TextContrast: CustomStringConvertible {
        /// sRGB, 0xRRGGBB.
        let background: UInt32
        let text: UInt32
        /// WCAG 2 contrast ratio of `text` on `background`.
        let ratio: Double
        /// The pixels whose ratio on the background reaches the minimum.
        let pixelsReachingMinimum: Int

        var description: String {
            String(format: "#%06x on #%06x, %.2f:1", text, background, ratio)
        }

        init?(png: Data, minimum: Double) {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
            else { return nil }
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            var counts: [UInt32: Int] = [:]
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let rgb = UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2])
                counts[rgb, default: 0] += 1
            }
            // The most common colour; on a tie the lower value, so the result does not depend on the order.
            let mostCommon = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            guard let background = mostCommon?.key else { return nil }
            let backgroundLuminance = Self.luminance(background)
            var text = background
            var farthest = 0.0
            var reaching = 0
            for (rgb, count) in counts {
                let luminance = Self.luminance(rgb)
                let distance = abs(luminance - backgroundLuminance)
                if distance > farthest {
                    farthest = distance
                    text = rgb
                }
                if Self.ratio(luminance, backgroundLuminance) >= minimum {
                    reaching += count
                }
            }
            self.background = background
            self.text = text
            self.ratio = Self.ratio(Self.luminance(text), backgroundLuminance)
            self.pixelsReachingMinimum = reaching
        }

        /// WCAG 2 relative luminance of an sRGB colour.
        static func luminance(_ rgb: UInt32) -> Double {
            func linear(_ component: UInt32) -> Double {
                let value = Double(component & 0xff) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb >> 16) + 0.7152 * linear(rgb >> 8) + 0.0722 * linear(rgb)
        }

        static func ratio(_ first: Double, _ second: Double) -> Double {
            (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }
    }
#endif
