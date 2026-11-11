import CoreGraphics
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import PDFKit
import Synchronization
import Testing

@testable import DokumentumCore

/// The text stage (#6, part 2) with a stub recogniser: which pages are recognised (T2), how they are rendered (T3),
/// the join with form feeds, `textSource`, progress, cancellation between pages, and the UTF-8 cap (T7, N6). The
/// real recogniser's configuration (T1) is checked here too; its recognition in `VisionRecognitionTests`.
struct TextExtractionTests {
    /// Lines with more than 16 non-whitespace characters: text pages.
    static let first = "Rechnung Nummer 2026-0042"
    static let third = "Zahlbar bis zum 15. Dezember"

    private func process(
        _ data: Data, recognizer: StubRecognizer = StubRecognizer(),
        progress: @escaping ProcessingProgress = { _, _ in }
    ) async throws -> ProcessingResult {
        try await DocumentStage(recognizer: recognizer).process(pdfData: data, progress: progress)
    }

    @Test func aTextPDFGivesItsOwnTextWithoutRecognition() async throws {
        let recognizer = StubRecognizer()

        let result = try await process(
            TestPDF.make(contents: [.text(Self.first), .text(Self.third)]), recognizer: recognizer)

        #expect(recognizer.count == 0)
        #expect(result.pageCount == 2)
        #expect(result.text == ExtractedText(pages: [Self.first, Self.third], source: .pdfText))
        #expect(result.text?.joined == "\(Self.first)\u{0C}\(Self.third)")
    }

    /// T3: every page without text is rendered at 2400 px on the long side (A4: 1696 × 2400), in grayscale.
    @Test func anImageOnlyPDFIsRecognisedPageByPageAt2400Pixels() async throws {
        let recognizer = StubRecognizer()

        let result = try await process(TestPDF.makeImageOnly(pages: [["One"], ["Two"]]), recognizer: recognizer)

        #expect(recognizer.count == 2)
        #expect(recognizer.imageSizes == [CGSize(width: 1696, height: 2400), CGSize(width: 1696, height: 2400)])
        #expect(result.text?.source == .vision)
        #expect(result.text?.joined == "Recognised 1\u{0C}Recognised 2")
    }

    @Test func aRenderedPageIsGrayscaleWithItsRotationApplied() throws {
        let document = try #require(PDFDocument(data: TestPDF.makeImageOnly(pages: [["Turned"]])))
        let page = try #require(document.page(at: 0))
        page.rotation = 90

        let image = try #require(PageText.render(page))

        #expect(image.width == 2400)
        #expect(image.height == 1696)
        #expect(image.colorSpace?.model == .monochrome)
    }

    @Test func mixedPagesRecogniseOnlyTheImagePagesInPageOrder() async throws {
        let recognizer = StubRecognizer { _ in ["Seite zwei", "zweite Zeile"] }

        let result = try await process(
            TestPDF.make(contents: [.text(Self.first), .image(["Seite zwei"]), .text(Self.third)]),
            recognizer: recognizer)

        #expect(recognizer.count == 1)
        #expect(result.text?.source == .vision, "one recognised page makes the source `.vision`")
        #expect(result.text?.joined == "\(Self.first)\u{0C}Seite zwei\nzweite Zeile\u{0C}\(Self.third)")
    }

    /// T2: 16 non-whitespace characters make a text page; 15 are recognised. Whitespace does not count.
    @Test(arguments: [
        ("ABCDEFGHIJKLMNO", false), ("ABCDEFGHIJKLMNOP", true), ("ABCDE FGHIJ KLMNO", false),
        ("ABCD EFGH IJKL MNOP", true),
        // Counted as characters (N-c of review 5866563252): 15 decomposed umlauts are 30 scalars but 15 characters.
        (String(repeating: "a\u{0308}", count: 15), false), (String(repeating: "a\u{0308}", count: 16), true),
    ])
    func sixteenNonWhitespaceCharactersMakeATextPage(line: String, isTextPage: Bool) async throws {
        let recognizer = StubRecognizer()

        let result = try await process(TestPDF.make(contents: [.text(line)]), recognizer: recognizer)

        #expect(PageText.isTextPage(line) == isTextPage)
        #expect(recognizer.count == (isTextPage ? 0 : 1))
        #expect(result.text?.source == (isTextPage ? .pdfText : .vision))
        #expect(result.text?.joined == (isTextPage ? line : "Recognised 1"))
    }

    /// Blank pages are recognised and give nothing: the source is `.vision` and the text empty, so `.none` keeps
    /// meaning "never extracted".
    @Test(arguments: [1, 3])
    func blankPagesGiveAnEmptyTextFromVision(pages: Int) async throws {
        let recognizer = StubRecognizer { _ in [] }

        let result = try await process(
            TestPDF.make(contents: Array(repeating: .blank, count: pages)), recognizer: recognizer)

        #expect(recognizer.count == pages)
        #expect(result.text?.source == .vision)
        #expect(result.text?.joined == "")
        #expect(result.text?.capped().text == "")
    }

    /// T1: `.accurate`, German then English, language correction on.
    @Test func theRecogniserAsksForAccurateGermanAndEnglishWithLanguageCorrection() {
        let request = VisionTextRecognizer.makeRequest()

        #expect(request.recognitionLevel == .accurate)
        #expect(
            request.recognitionLanguages.map(\.minimalIdentifier) == ["de-DE", "en-US"]
                || request.recognitionLanguages.map(\.maximalIdentifier) == ["de-Latn-DE", "en-Latn-US"],
            "\(request.recognitionLanguages)")
        #expect(request.usesLanguageCorrection)
    }

    @Test func progressComesBeforeTheFirstAndAfterEveryPage() async throws {
        let reports = Mutex<[[Int]]>([])

        _ = try await process(TestPDF.make(contents: [.text(Self.first), .blank, .image(["x"])])) { done, total in
            reports.withLock { $0.append([done, total]) }
        }

        #expect(reports.withLock { $0 } == [[0, 3], [1, 3], [2, 3], [3, 3]])
    }

    /// Cancellation between pages: a stage cancelled while it recognises page 1 stops after it.
    @Test func aCancelledStageStopsAfterItsCurrentPage() async throws {
        let checkpoint = Checkpoint()
        defer { checkpoint.release() }
        let recognizer = StubRecognizer(checkpoint: checkpoint)
        let ended = TestSignal()
        let data = TestPDF.makeImageOnly(pages: [["1"], ["2"], ["3"]])
        let stage = Task {
            defer { ended.fire() }
            return try await DocumentStage(recognizer: recognizer).process(pdfData: data) { _, _ in }
        }

        await checkpoint.reached()
        stage.cancel()
        checkpoint.release()

        #expect(await ended.wait())
        await #expect(throws: CancellationError.self) { try await stage.value }
        #expect(recognizer.count == 1)
    }

    @Test func anUnreadableLockedOrPagelessPDFThrows() async throws {
        for data in [
            Data("not a pdf".utf8), TestPDF.make(pages: ["Locked"], userPassword: "secret"), TestPDF.makeWithoutPages(),
        ] {
            await #expect(throws: DocumentStage.Failure.unreadablePDF) { try await process(data) }
        }
    }

    // MARK: The cap (T7, N6)

    @Test func theCapIsHalfAMillionUTF8Bytes() {
        #expect(ExtractedText.byteLimit == 500_000)
        let fits = ExtractedText(
            pages: [String(repeating: "a", count: 250_000), String(repeating: "b", count: 249_999)], source: .vision)
        #expect(fits.joined.utf8.count == 500_000)
        #expect(fits.capped() == (fits.joined, false))
        let over = ExtractedText(
            pages: [String(repeating: "a", count: 250_000), String(repeating: "b", count: 250_000)], source: .vision)
        #expect(over.capped() == (String(repeating: "a", count: 250_000), true))
    }

    /// Over the cap the text is cut at the last page boundary below it, without a trailing separator.
    @Test func overTheCapTheTextIsCutAtAPageBoundary() {
        let text = ExtractedText(pages: ["aaaa", "bbbb", "cccc"], source: .vision)

        #expect(text.capped(toBytes: 14) == ("aaaa\u{0C}bbbb\u{0C}cccc", false))
        #expect(text.capped(toBytes: 13) == ("aaaa\u{0C}bbbb", true))
        #expect(text.capped(toBytes: 9) == ("aaaa\u{0C}bbbb", true))
        #expect(text.capped(toBytes: 8) == ("aaaa", true))
        #expect(text.capped(toBytes: 4) == ("aaaa", true))
    }

    /// A first page alone over the cap is cut at its last whole character within it, never inside a UTF-8
    /// sequence or a grapheme.
    @Test func aFirstPageOverTheCapIsCutAtACharacterBoundary() {
        let text = ExtractedText(pages: ["Straße München", "two"], source: .vision)

        // "Straß" is 6 bytes ("ß" is two): a cap of 5 keeps "Stra", one of 6 "Straß".
        #expect(text.capped(toBytes: 5) == ("Stra", true))
        #expect(text.capped(toBytes: 6) == ("Straß", true))
        let flag = ExtractedText(pages: ["ab🇩🇪cd"], source: .vision)
        // The flag is one character of 8 bytes.
        #expect(flag.capped(toBytes: 9) == ("ab", true))
        #expect(flag.capped(toBytes: 10) == ("ab🇩🇪", true))
        for limit in 0...12 {
            let (cut, _) = flag.capped(toBytes: limit)
            #expect(cut.utf8.count <= limit)
            #expect(String(decoding: Array(cut.utf8), as: UTF8.self) == cut)
        }
    }

    /// N-b of review 5866563252: blank pages before a first page with text that is alone over the cap keep their
    /// separators, and that page is cut at a character boundary, instead of storing "".
    @Test func blankPagesBeforeAPageOverTheCapKeepTheirSeparatorsAndThePageIsCut() {
        let text = ExtractedText(pages: ["", "ääää", "b"], source: .vision)

        #expect(text.capped(toBytes: 5) == ("\u{0C}ää", true))
        #expect(text.capped(toBytes: 6) == ("\u{0C}ää", true))
        #expect(text.capped(toBytes: 9) == ("\u{0C}ääää", true))
        #expect(text.capped(toBytes: 1) == ("", true))
        let two = ExtractedText(pages: ["", "", "abc"], source: .vision)
        #expect(two.capped(toBytes: 4) == ("\u{0C}\u{0C}ab", true))
        #expect(ExtractedText(pages: ["", ""], source: .vision).capped(toBytes: 0) == ("", false))
    }

    /// N-a of review 5866563252: a form feed inside one page's text becomes a newline, so the stored text's form
    /// feeds are exactly the page boundaries (#122 splits on them).
    @Test func aFormFeedInsideAPageBecomesANewline() async throws {
        let text = ExtractedText(pages: ["one\u{0C}two", "three"], source: .pdfText)
        #expect(text.pages == ["one\ntwo", "three"])
        #expect(text.joined == "one\ntwo\u{0C}three")

        let result = try await process(
            TestPDF.makeImageOnly(pages: [["x"], ["y"]]), recognizer: StubRecognizer { ["line\u{0C}\($0)"] })
        let joined = try #require(result.text?.joined)
        #expect(joined == "line\n1\u{0C}line\n2")
        #expect(joined.split(separator: "\u{0C}", omittingEmptySubsequences: false).count == 2)
    }
}
