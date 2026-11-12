import CoreGraphics
import DokumentumKit
import Foundation
import PDFKit

/// What the stages found in a document's PDF: the fields the result write sets when they differ.
public struct ProcessingResult: Equatable, Sendable {
    public var pageCount: Int
    /// The document's text and its source; `nil` leaves the text record and `textSource` as they are (a test's
    /// stage that only counts pages).
    public var text: ExtractedText?
    /// The PDF with the invisible text layer (#6, part 3), which replaces the stored file; `nil` keeps the stored
    /// bytes as they are.
    public var layeredPDF: Data?
    /// The thumbnail to insert when the document has none (`Thumbnail`): set by the queue, only for a document the
    /// re-queue pass recorded for the backfill (#6, part 4, N3); `nil` otherwise.
    public var thumbnail: Data?

    public init(pageCount: Int, text: ExtractedText? = nil, layeredPDF: Data? = nil, thumbnail: Data? = nil) {
        self.pageCount = pageCount
        self.text = text
        self.layeredPDF = layeredPDF
        self.thumbnail = thumbnail
    }
}

/// What a stage reports as it goes: `completed` of `total` steps (pages). Each call tells the queue's stall
/// watchdog that the stage is alive (#97 point 3).
public typealias ProcessingProgress = @Sendable (_ completed: Int, _ total: Int) -> Void

/// The work on one document's PDF (plan of #4, part 5): it runs off the main actor, with no context open, and
/// throws when the document cannot be processed. The app's stage is `DocumentStage`; tests pass their own.
///
/// A stage reports `progress` at least once per page, and checks for cancellation between pages: the queue cancels
/// it after an interruption or when no progress came for the stall timeout (300 s), and never waits for a cancelled
/// stage before it moves on (`ProcessingQueue`).
public protocol ProcessingStage: Sendable {
    func process(pdfData: Data, progress: @escaping ProcessingProgress) async throws -> ProcessingResult
}

/// The app's stage (#6, part 2): PDFKit opens the PDF (unreadable, locked or page-less throws, as step 3's inspect
/// did) and each page gives its text:
/// - a page whose own text has at least 16 non-whitespace characters is a text page (T2), its text trimmed;
/// - every other page is rendered in grayscale at 2400 px on the long side (T3) and recognised (T1,
///   `VisionTextRecognizer`), its lines joined by newlines.
///
/// The text is the pages' texts in page order, joined with a form feed (`ExtractedText`); the source is `.pdfText`
/// when every page was a text page, else `.vision`, also when nothing was found. When pages were recognised, the
/// stage then builds the invisible text layer (`TextLayer`, part 3): a PDF that passes its rules and its guard is
/// returned as `layeredPDF`; otherwise the stored bytes stay as they are, and the reason is logged.
///
/// Before each page the stage checks for cancellation, after it reports progress (page k of n; during the layer's
/// redraw and guard, n of n per page). One page image is alive at a time (an autorelease pool per render), and the
/// `PDFDocument` is kept alive for the whole stage, because PDFKit cannot draw a page whose document was released
/// (P-h).
public struct DocumentStage: ProcessingStage {
    public enum Failure: Error, Equatable {
        /// PDFKit cannot open it, it is locked, or it has no page.
        case unreadablePDF
        /// A page that needs recognition could not be rendered.
        case renderFailed
    }

    public let recognizer: any TextRecognizing
    public let textLayer: TextLayer

    public init(recognizer: any TextRecognizing = VisionTextRecognizer(), textLayer: TextLayer = TextLayer()) {
        self.recognizer = recognizer
        self.textLayer = textLayer
    }

    @concurrent
    public func process(pdfData: Data, progress: @escaping ProcessingProgress) async throws -> ProcessingResult {
        guard let document = PDFDocument(data: pdfData), !document.isLocked, document.pageCount > 0 else {
            throw Failure.unreadablePDF
        }
        // Held to the end: a page is drawn only while its document lives (P-h).
        defer { withExtendedLifetime(document) {} }
        let total = document.pageCount
        progress(0, total)
        var pages: [String] = []
        var recognised = false
        var recognisedLines: [Int: [RecognizedLine]] = [:]
        for index in 0..<total {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw Failure.unreadablePDF }
            if let text = PageText.embeddedText(of: page) {
                pages.append(text)
            } else {
                // The image goes when the page is recognised: one page image at a time.
                let image = autoreleasepool { PageText.render(page) }
                guard let image else { throw Failure.renderFailed }
                let lines = try await recognizer.recognizeText(in: image)
                pages.append(lines.map(\.text).joined(separator: "\n"))
                recognisedLines[index] = lines
                recognised = true
            }
            progress(index + 1, total)
        }
        var layered: Data?
        if recognised {
            try Task.checkCancellation()
            // Progress during the redraw and the guard too, so a large rewrite never looks like a stall (N1).
            switch textLayer.apply(
                to: pdfData, document: document, lines: recognisedLines,
                progress: {
                    progress(total, total)
                })
            {
            case .layered(let data):
                layered = data
            case .kept(.cancelled):
                throw CancellationError()
            case .kept(let reason):
                Log.processing.notice("No text layer; the file is kept as it is: \(reason.code, privacy: .public)")
            }
        }
        return ProcessingResult(
            pageCount: total, text: ExtractedText(pages: pages, source: recognised ? .vision : .pdfText),
            layeredPDF: layered)
    }
}
