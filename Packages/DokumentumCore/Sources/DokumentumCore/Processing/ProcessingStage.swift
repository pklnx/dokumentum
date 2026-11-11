import Foundation
import PDFKit

/// What the stages found in a document's PDF: the fields the result write sets when they differ.
public struct ProcessingResult: Equatable, Sendable {
    public var pageCount: Int

    public init(pageCount: Int) {
        self.pageCount = pageCount
    }
}

/// The work on one document's PDF (plan of #4, part 5): it runs off the main actor, with no context open, and
/// throws when the document cannot be processed. Step 3 has one stage, `InspectStage`; step 5 adds text, OCR, the
/// text layer and the thumbnail here. Tests pass their own.
public protocol ProcessingStage: Sendable {
    func process(pdfData: Data) async throws -> ProcessingResult
}

/// Step 3's one stage, "inspect": PDFKit opens the PDF and gives its page count.
public struct InspectStage: ProcessingStage {
    public enum Failure: Error, Equatable {
        /// PDFKit cannot open it, it is locked, or it has no page.
        case unreadablePDF
    }

    public init() {}

    @concurrent
    public func process(pdfData: Data) async throws -> ProcessingResult {
        guard let document = PDFDocument(data: pdfData), !document.isLocked, document.pageCount > 0 else {
            throw Failure.unreadablePDF
        }
        return ProcessingResult(pageCount: document.pageCount)
    }
}
