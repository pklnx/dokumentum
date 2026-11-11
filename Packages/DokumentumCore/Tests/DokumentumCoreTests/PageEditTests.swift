import CoreGraphics
import Foundation
import Testing

@testable import DokumentumCore

/// The edit's value types (#5, step 4): corners clamped, convexity, area, turns modulo 4.
struct PageEditTests {
    @Test func cornersAreClampedToTheImage() {
        let quad = PageQuad(
            topLeft: CGPoint(x: -0.2, y: -1), topRight: CGPoint(x: 1.5, y: 0), bottomRight: CGPoint(x: 1, y: 2),
            bottomLeft: CGPoint(x: 0, y: 1))

        #expect(quad == .fullPage)
    }

    @Test func convexityAndArea() {
        #expect(PageQuad.fullPage.isConvex)
        #expect(PageQuad.fullPage.area == 1)
        #expect(PageQuad.fullPage.boundingBox == CGRect(x: 0, y: 0, width: 1, height: 1))
        let crossed = PageQuad(
            topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1, y: 1), bottomRight: CGPoint(x: 1, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1))
        #expect(!crossed.isConvex)
        let collapsed = PageQuad(
            topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 0.5, y: 0), bottomRight: CGPoint(x: 1, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1))
        #expect(!collapsed.isConvex, "a straight angle")
        let half = PageQuad(
            topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 0.5, y: 0), bottomRight: CGPoint(x: 0.5, y: 1),
            bottomLeft: CGPoint(x: 0, y: 1))
        #expect(half.isConvex)
        #expect(half.area == 0.5)
    }

    @Test func turnsAreTakenModuloFour() {
        #expect(PageEdit(quarterTurns: 5).quarterTurns == 1)
        #expect(PageEdit(quarterTurns: -1).quarterTurns == 3)
        var edit = PageEdit()
        edit.quarterTurns += 7
        #expect(edit.quarterTurns == 3)
        #expect(PageEdit(quarterTurns: 4).isIdentity)
        #expect(!PageEdit(filter: .enhanced).isIdentity)
    }
}
