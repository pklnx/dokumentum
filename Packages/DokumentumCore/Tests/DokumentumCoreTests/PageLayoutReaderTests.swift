import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import Testing

@testable import DokumentumCore

/// The layout of the first page with text (#11, part 2; plan Approach 1, Tests part 2): boxes normalised to the
/// visible page (crop box and rotation applied), Vision's boxes flipped, PDFKit lines split at column gaps, only the
/// first page with text read, and the cap keeping the footer.
struct PageLayoutReaderTests {
    static let helvetica = "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >>"

    /// A page with one line of Helvetica text at (150, 600) in page space, and `keys` in its page dictionary.
    static func page(keys: String) throws -> (PDFDocument, PDFPage) {
        let data = TestPDF.makeRaw(pages: [
            .init(content: "BT /F1 16 Tf 150 600 Td (Hallo Welt Probe) Tj ET", resources: helvetica, keys: keys)
        ])
        let document = try #require(PDFDocument(data: data))
        return (document, try #require(document.page(at: 0)))
    }

    /// Where the ink is on the page as `PageText.render` draws it (the visible page: crop box and rotation applied,
    /// as a viewer shows it), normalised with the origin top left: an oracle independent of the reader's mapping.
    static func ink(of page: PDFPage) throws -> CGRect {
        let image = try #require(PageText.render(page, longSide: 1200))
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        var (minX, minY, maxX, maxY) = (width, height, -1, -1)
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] < 128 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        #expect(maxX >= 0, "no ink")
        // The bitmap's first row is the top of the image.
        return CGRect(
            x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
    }

    static func expect(
        _ box: PageLayout.Box, contains ink: CGRect, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let slack = 0.01
        #expect(
            box.x - slack <= ink.minX && ink.maxX <= box.x + box.width + slack, "\(box) \(ink)",
            sourceLocation: sourceLocation)
        #expect(
            box.y - slack <= ink.minY && ink.maxY <= box.y + box.height + slack, "\(box) \(ink)",
            sourceLocation: sourceLocation)
        #expect(
            box.x <= ink.midX && ink.midX <= box.x + box.width && box.y <= ink.midY && ink.midY <= box.y + box.height,
            "\(box) \(ink)", sourceLocation: sourceLocation)
    }

    // MARK: Crop box and rotation

    @Test func aTextLineIsPlacedOnTheVisiblePageWithItsCropBox() throws {
        let (document, page) = try Self.page(keys: "/CropBox [100 100 500 700]")
        defer { withExtendedLifetime(document) {} }
        let layout = PageLayoutReader.layout(ofTextPage: page)

        #expect(layout.width == 400)
        #expect(layout.height == 600)
        let line = try #require(layout.lines.only)
        #expect(line.text == "Hallo Welt Probe")
        // 50 pt right of the crop box's left edge, the baseline 100 pt below its top.
        #expect(abs(line.box.x - 50.0 / 400) < 0.01, "\(line.box)")
        #expect(line.box.y < 100.0 / 600 && line.box.y + line.box.height > 100.0 / 600, "\(line.box)")
        Self.expect(line.box, contains: try Self.ink(of: page))
    }

    @Test(arguments: [90, 180, 270])
    func aTextLineIsPlacedOnTheVisiblePageOfARotatedPage(rotation: Int) throws {
        let (document, page) = try Self.page(keys: "/CropBox [100 100 500 700] /Rotate \(rotation)")
        defer { withExtendedLifetime(document) {} }
        let layout = PageLayoutReader.layout(ofTextPage: page)

        #expect(layout.width == (rotation == 180 ? 400 : 600))
        #expect(layout.height == (rotation == 180 ? 600 : 400))
        let line = try #require(layout.lines.only)
        Self.expect(line.box, contains: try Self.ink(of: page))
    }

    @Test func visionBoxesAreFlippedToTheTopLeft() throws {
        let (document, page) = try Self.page(keys: "/Rotate 90")
        defer { withExtendedLifetime(document) {} }
        let lines = [
            RecognizedLine(text: "Oben", boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05)),
            RecognizedLine(text: "Ohne Box"),
            RecognizedLine(text: "  ", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
        ]
        let layout = PageLayoutReader.layout(recognized: lines, on: page)

        #expect(layout.width == 842, "the visible page of a quarter turn")
        #expect(layout.height == 595)
        let line = try #require(layout.lines.only, "a line without a box or text is left out")
        #expect(line.text == "Oben")
        #expect(abs(line.box.y - 0.15) < 1e-9)
        #expect(abs(line.box.x - 0.1) < 1e-9)
        #expect(abs(line.box.height - 0.05) < 1e-9)
    }

    // MARK: Column gaps (B2)

    /// The review's probe-2 letter as a text PDF: PDFKit joins the recipient's line and the info block's line on one
    /// baseline, and the footer's three columns; after the split each is a line of its own.
    @Test func theProbeTwoLetterSplitsIntoColumns() throws {
        let letter = try #require(SyntheticLetters.letter("probe2-bank-known"))
        let document = try #require(PDFDocument(data: TestLetter.textPDF(letter)))
        let page = try #require(document.page(at: 0))
        let pdfKitLines = try #require(page.selection(for: page.bounds(for: .cropBox))).selectionsByLine()
            .compactMap(\.string)
        #expect(
            pdfKitLines.contains { $0.contains("Max Mustermann") && $0.contains("Kundennummer") },
            "PDFKit joined the columns here (else this test proves nothing): \(pdfKitLines)")

        let texts = PageLayoutReader.layout(ofTextPage: page).lines.map(\.text)

        for column in [
            "Max Mustermann", "Kundennummer: 4711", "Musterweg 2", "Datum: 13.11.2026", "Muster Versand GmbH",
            "Geschäftsführer: Erika Beispiel", "Bankverbindung", "Commerzbank AG",
            "IBAN DE12 3456 7890 1234 5678 90",
        ] {
            #expect(texts.contains(column), "\(column) not a line of its own: \(texts)")
        }
    }

    @Test func aGapOrTwoSpacesSplitsAndOneSpaceDoesNot() {
        func characters(_ text: String, from x: CGFloat) -> [PageLayoutReader.Character] {
            text.utf16.enumerated().map { index, unit in
                .init(unit: unit, bounds: CGRect(x: x + CGFloat(index) * 5, y: 0, width: 5, height: 10))
            }
        }
        let gap = characters("Max Muster", from: 0) + characters("Kunde", from: 50 + 11)
        #expect(PageLayoutReader.split(gap).map(\.text) == ["Max Muster", "Kunde"])
        let near = characters("Max Muster", from: 0) + characters("Kunde", from: 50 + 9)
        #expect(PageLayoutReader.split(near).map(\.text) == ["Max MusterKunde"])
        #expect(PageLayoutReader.split(characters("Links  Rechts", from: 0)).map(\.text) == ["Links", "Rechts"])
        #expect(PageLayoutReader.split(characters("Links Rechts", from: 0)).map(\.text) == ["Links Rechts"])
    }

    // MARK: One page, the cap

    /// Only the first page with text is read: a 20-page PDF with a blank first page gives page 2's lines.
    @Test func onlyTheFirstPageWithTextIsRead() async throws {
        let contents: [TestPDF.PageContent] = [.blank] + (2...20).map { .text("Seite \($0) mit eigenem Text") }
        // The blank page is recognised and holds no line.
        let result = try await DocumentStage(recognizer: StubRecognizer { _ in [] }).process(
            pdfData: TestPDF.make(contents: contents)
        ) { _, _ in }

        #expect(result.pageCount == 20)
        let layout = try #require(result.firstPageLayout)
        #expect(layout.lines.map(\.text) == ["Seite 2 mit eigenem Text"])
    }

    /// A dense page (4 columns of 100 lines in the middle) keeps its letterhead and footer under the cap (N5).
    @Test func theCapKeepsTheTopAndTheFooterOfADensePage() throws {
        var lines = [SyntheticLetter.Line("Muster Versand GmbH", x: 20, top: 15, size: 12)]
        for column in 0..<4 {
            for row in 0..<100 {
                lines.append(
                    .init("Zeile \(column)-\(row)", x: 20 + Double(column) * 45, top: 105 + Double(row) * 1.4, size: 3))
            }
        }
        lines.append(.init("Muster Versand GmbH · Musterstraße 1 · 12345 Musterstadt", x: 20, top: 280, size: 7))
        let document = try #require(
            PDFDocument(data: TestLetter.textPDF(TestLetter.Page(lines: lines, width: 210, height: 297))))
        let page = try #require(document.page(at: 0))

        let texts = PageLayoutReader.layout(ofTextPage: page).lines.map(\.text)

        #expect(texts.count == DetectionLimits.maximumLines)
        #expect(texts.first == "Muster Versand GmbH")
        #expect(texts.contains("Muster Versand GmbH · Musterstraße 1 · 12345 Musterstadt"), "\(texts.suffix(3))")
    }
}

extension Array {
    /// The one element, or `nil` when there are none or several.
    fileprivate var only: Element? { count == 1 ? first : nil }
}
