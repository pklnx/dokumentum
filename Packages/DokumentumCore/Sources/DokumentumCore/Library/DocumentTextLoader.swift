import DokumentumKit
import Foundation
import SwiftData

/// Reads one document's text and finds the due-date suggestion in it (#12, part 2b; plan §5, T7): on demand, for the
/// document open in the detail, off the main actor, in a context of its own that ends with the load. Nothing is
/// written: the detector runs again each time, on the synced text, so both devices compute the same suggestion, and a
/// document processed before this build gets one too.
///
/// **What it gives** is the text's suggestion by the dismissal rule (review B3,
/// `DueDateDetector.suggestion(among:today:dismissedThrough:)`): the earliest candidate that is today or later and after
/// `deadlineDismissedDay`, for a document that is processed (`done`) and not in the trash. It is given **also while the
/// document has a deadline**: the detail offers it only without one (`DueDateDetector.offers`), and "Remove Deadline"
/// compares the removed day with it, so removing a deadline right after adding the suggestion dismisses that day in the
/// same save instead of offering it again (review N9).
public struct DocumentTextLoader: Sendable {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// The suggestion for the document with `instanceID` on `today`; `nil` for none (no such document, in the trash,
    /// not processed, no text, no candidate left). A failed fetch is logged and gives none. A read whose task was
    /// cancelled after the fetch (the detail started a newer read) gives none without running the detector, so a burst
    /// of library reads cannot stack detector runs on a large text (#220, review N6).
    @concurrent
    public func deadlineSuggestion(instanceID: UUID, today: DeadlineDay) async -> DueDateCandidate? {
        guard let text = Self.read(instanceID: instanceID, in: container), !Task.isCancelled else { return nil }
        return text.suggestion(today: today)
    }

    /// The same, synchronously, in a new context of `container` (the SQL tests record one thread).
    public static func deadlineSuggestion(instanceID: UUID, today: DeadlineDay, in container: ModelContainer)
        -> DueDateCandidate?
    {
        read(instanceID: instanceID, in: container)?.suggestion(today: today)
    }

    /// What the detector needs of one document: its text, `createdAt` and dismissed day.
    struct Text {
        let text: String
        let createdAt: Date
        let dismissed: DeadlineDay?

        func suggestion(today: DeadlineDay) -> DueDateCandidate? {
            DueDateDetector.suggestion(
                among: DueDateDetector.candidates(in: text, createdAt: createdAt), today: today,
                dismissedThrough: dismissed)
        }
    }

    /// The document's text, for a processed document outside the trash; `nil` otherwise.
    static func read(instanceID: UUID, in container: ModelContainer) -> Text? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID })
        descriptor.fetchLimit = 1
        do {
            guard let document = try context.fetch(descriptor).first, document.deletedAt == nil,
                document.processingState == .done, let text = document.text?.extractedText, !text.isEmpty
            else { return nil }
            return Text(text: text, createdAt: document.createdAt, dismissed: document.dismissedSuggestionDay)
        } catch {
            Log.store.error("Could not read a document's text: \(Log.code(of: error), privacy: .public)")
            return nil
        }
    }
}
