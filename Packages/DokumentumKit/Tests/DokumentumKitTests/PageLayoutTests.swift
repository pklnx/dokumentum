import DokumentumKit
import Foundation
import Testing

/// The page geometry in DIN 5008 millimetres (N-r4) and the layout's line cap (N5) of #11, part 1.
struct PageLayoutTests {
    // MARK: Geometry

    @Test func standardPagesAreMeasuredAsTheyAre() {
        let a4 = PageGeometry(width: 595.28, height: 841.89)
        #expect(a4.isStandardSize)
        #expect(abs(a4.width - 210) < 0.01 && abs(a4.height - 297) < 0.01)
        #expect(abs(a4.footerTop - 250) < 0.01, "the footer starts at 250 mm on A4")
        let letter = PageGeometry(width: 612, height: 792)
        #expect(letter.isStandardSize)
        #expect(abs(letter.height - 279.4) < 0.01)
        let legal = PageGeometry(width: 612, height: 1008)
        #expect(legal.isStandardSize)
        #expect(abs(legal.height - 355.6) < 0.01)
        let nearA4 = PageGeometry(width: 595.28 * 1.025, height: 841.89 * 0.975)
        #expect(nearA4.isStandardSize, "within 3 %")
        #expect(abs(nearA4.width - 210 * 1.025) < 0.01)
    }

    @Test func theFooterIsMeasuredFromTheBottomEdge() {
        #expect(abs(PageGeometry(width: 612, height: 792).footerTop - 232.4) < 0.01, "US Letter")
        #expect(abs(PageGeometry(width: 612, height: 1008).footerTop - 308.6) < 0.01, "US Legal")
        // On US Legal, a body line at 260 mm is not footer: its company name is no sender.
        let lines = [
            SyntheticLetter.Line("Max Mustermann", x: 25, top: 40, size: 11),
            SyntheticLetter.Line("Musterweg 2", x: 25, top: 45, size: 11),
            SyntheticLetter.Line("Ihre Bestellung bei Beispiel GmbH", x: 25, top: 260, size: 11),
        ]
        let legal = SyntheticLetters.layout(lines, width: 215.9, height: 355.6)
        #expect(SenderDetector.detect(in: legal, known: SenderDetectorTests.records(["Max Mustermann"])) == nil)
        let a4 = SyntheticLetters.layout(lines)
        #expect(
            SenderDetector.detect(in: a4, known: SenderDetectorTests.records(["Max Mustermann"]))
                == .name("Ihre Bestellung bei Beispiel GmbH"), "the same line is footer on A4")
    }

    @Test func otherPagesAreScaledToA4sWidth() {
        let photo = PageGeometry(width: 1000, height: 1500)
        #expect(!photo.isStandardSize)
        #expect(abs(photo.width - 210) < 0.001)
        #expect(abs(photo.height - 315) < 0.001)
        let offA4 = PageGeometry(width: 595.28 * 1.04, height: 841.89)
        #expect(!offA4.isStandardSize, "4 % off")
        let landscape = PageGeometry(width: 841.89, height: 595.28)
        #expect(!landscape.isStandardSize)
        #expect(abs(landscape.width - 210) < 0.001)
    }

    @Test func aPageWithoutASizeIsMeasuredAsA4() {
        for (width, height) in [(0.0, 0.0), (-1.0, 800.0), (Double.nan, 800.0), (Double.infinity, 800.0)] {
            let geometry = PageGeometry(width: width, height: height)
            #expect(geometry.width == 210 && geometry.height == 297)
        }
    }

    // MARK: The cap

    private func line(_ index: Int, top: Double) -> PageLayout.Line {
        PageLayout.Line(text: "Zeile \(index)", box: .init(x: 0.1, y: top / 297, width: 0.3, height: 3 / 297))
    }

    @Test func aLayoutBelowTheCapKeepsEveryLine() {
        let lines = (0..<DetectionLimits.maximumLines).map { line($0, top: 120 + Double($0) * 0.1) }
        #expect(PageLayout(width: 595.28, height: 841.89, lines: lines).lines == lines)
    }

    @Test func theCapKeepsTheTopAndTheFooterAndCutsTheMiddle() {
        // 40 lines at the top, 300 in the middle, 30 in the footer, in reading order.
        let top = (0..<40).map { line($0, top: 10 + Double($0) * 2) }
        let middle = (0..<300).map { line(100 + $0, top: 105 + Double($0) * 0.4) }
        let footer = (0..<30).map { line(1000 + $0, top: 260 + Double($0) * 1) }
        let layout = PageLayout(width: 595.28, height: 841.89, lines: top + middle + footer)
        #expect(layout.lines.count == DetectionLimits.maximumLines)
        #expect(layout.lines == top + middle.prefix(230) + footer, "the middle is cut, the order kept")
    }

    @Test func whenTheTopAndFooterExceedTheCapTheTopGoesFirst() {
        let top = (0..<250).map { line($0, top: 10 + Double($0) * 0.3) }
        let footer = (0..<100).map { line(1000 + $0, top: 255 + Double($0) * 0.3) }
        let layout = PageLayout(width: 595.28, height: 841.89, lines: top + footer)
        #expect(layout.lines == top + footer.prefix(50))
    }

    @Test func theDetectorReadsTheFooterOfADensePage() {
        // A page of 400 lines whose sender stands only in the footer: the cap keeps it.
        var lines = [
            SyntheticLetter.Line("Max Mustermann", x: 25, top: 40, size: 11),
            SyntheticLetter.Line("Musterweg 2", x: 25, top: 45, size: 11),
        ]
        for index in 0..<400 {
            lines.append(.init("Position \(index)", x: 25, top: 100 + Double(index) * 0.35, size: 7))
        }
        lines.append(.init("Muster Versand GmbH · Hafenstraße 9 · 20457 Hamburg", x: 25, top: 285, size: 7))
        let layout = SyntheticLetters.layout(lines)
        #expect(layout.lines.count == DetectionLimits.maximumLines)
        let known = SenderDetectorTests.records(["Max Mustermann"])
        #expect(SenderDetector.detect(in: layout, known: known) == .name("Muster Versand GmbH"))
    }
}
