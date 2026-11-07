import Foundation
import PDFKit
import Testing

@testable import Dokumentum

struct SyntheticPDFTests {
    @Test func pdfKitReadsThePagesAndTheirText() throws {
        let data = SyntheticPDF.make(pages: [
            ["Stadtwerke Musterstadt", "Electricity bill"], ["Page two"], ["Page three", "Last line"],
        ])
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 3)
        let first = try #require(document.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == SyntheticPDF.pageSize)
        #expect(first.string?.contains("Stadtwerke Musterstadt") == true)
        #expect(first.string?.contains("Electricity bill") == true)
        #expect(document.page(at: 1)?.string?.contains("Page two") == true)
        #expect(document.page(at: 2)?.string?.contains("Last line") == true)
        #expect(document.string?.contains("Page three") == true)
    }

    @Test func oneEmptyPageIsStillAPDF() throws {
        let document = try #require(PDFDocument(data: SyntheticPDF.make(pages: [[]])))
        #expect(document.pageCount == 1)
    }

    @Test func everyFixturePDFOpensWithItsPageCount() throws {
        for sample in FixtureCatalog.samples {
            guard case .pdf(let pages) = sample.file else { continue }
            let document = try #require(PDFDocument(data: SyntheticPDF.make(pages: pages)), "\(sample.document.title)")
            #expect(document.pageCount == pages.count)
        }
    }
}
