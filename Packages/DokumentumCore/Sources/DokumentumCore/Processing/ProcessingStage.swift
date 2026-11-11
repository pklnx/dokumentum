import Foundation
import PDFKit

/// What the stages found in a document's PDF: the fields the result write sets when they differ.
public struct ProcessingResult: Equatable, Sendable {
    public var pageCount: Int

    public init(pageCount: Int) {
        self.pageCount = pageCount
    }
}

/// What a stage reports as it goes: `completed` of `total` steps (pages). Each call tells the queue's stall
/// watchdog that the stage is alive (#97 point 3).
public typealias ProcessingProgress = @Sendable (_ completed: Int, _ total: Int) -> Void

/// The work on one document's PDF (plan of #4, part 5): it runs off the main actor, with no context open, and
/// throws when the document cannot be processed. Step 3 has one stage, `InspectStage`; step 5 adds text, OCR, the
/// text layer and the thumbnail here. Tests pass their own.
///
/// A stage reports `progress` at least once per page, and checks for cancellation between pages: the queue cancels
/// it after an interruption or when no progress came for the stall timeout (300 s), and never waits for a cancelled
/// stage before it moves on (`ProcessingQueue`).
public protocol ProcessingStage: Sendable {
    func process(pdfData: Data, progress: @escaping ProcessingProgress) async throws -> ProcessingResult
}

/// Step 3's one stage, "inspect": PDFKit opens the PDF and gives its page count.
public struct InspectStage: ProcessingStage {
    public enum Failure: Error, Equatable {
        /// PDFKit cannot open it, it is locked, or it has no page.
        case unreadablePDF
    }

    public init() {}

    @concurrent
    public func process(pdfData: Data, progress: @escaping ProcessingProgress) async throws -> ProcessingResult {
        guard let document = PDFDocument(data: pdfData), !document.isLocked, document.pageCount > 0 else {
            throw Failure.unreadablePDF
        }
        progress(document.pageCount, document.pageCount)
        return ProcessingResult(pageCount: document.pageCount)
    }
}
