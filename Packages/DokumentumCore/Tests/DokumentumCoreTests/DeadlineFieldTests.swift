import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The deadline fields of schema V3 (#12, part 1) read through `Document.deadline` and
/// `Document.dismissedSuggestionDay`. **The read rule:** only the first ten characters are read, a value that does
/// not read as a day reads as none, and reading never rewrites the stored string, so a later build's value survives
/// this build (review N8 of #12's plan).
@MainActor
struct DeadlineFieldTests {
    private static let setAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let doneAt = Date(timeIntervalSinceReferenceDate: 800_086_400)

    private static func day(_ stored: String) throws -> DeadlineDay {
        try #require(DeadlineDay(storedValue: stored))
    }

    @Test func aStoredDayReadsAsTheDeadlineWithItsFields() throws {
        let document = Document(title: "Wasserrechnung")
        (document.deadlineDay, document.deadlineLabel) = ("2026-11-27", "Pay")
        (document.deadlineSetAt, document.deadlineDoneAt) = (Self.setAt, Self.doneAt)
        let deadline = try #require(document.deadline)
        #expect(deadline.day == (try Self.day("2026-11-27")))
        #expect([deadline.day.year, deadline.day.month, deadline.day.day] as [Int] == [2026, 11, 27])
        #expect(deadline.label == "Pay")
        #expect(deadline.setAt == Self.setAt)
        #expect(deadline.doneAt == Self.doneAt)
        #expect(deadline.isDone)
        document.deadlineDoneAt = nil
        #expect(document.deadline?.isDone == false)
    }

    /// A new document has no deadline and no dismissed suggestion: every field reads its default.
    @Test func aNewDocumentHasNoDeadline() {
        let document = Document(title: "Neu")
        #expect(document.deadline == nil)
        #expect(document.dismissedSuggestionDay == nil)
        #expect([document.deadlineDay, document.deadlineLabel, document.deadlineDismissedDay] == ["", "", ""])
        #expect(document.deadlineSetAt == nil && document.deadlineDoneAt == nil)
    }

    /// A later build's suffix (a time) is ignored when reading, and the stored string keeps it.
    @Test func aLaterBuildsSuffixReadsAsTheDayAndStaysStored() throws {
        let document = Document(title: "Termin")
        document.deadlineDay = "2026-11-27T14:00"
        document.deadlineDismissedDay = "2026-12-15T09:30"
        #expect(document.deadline?.day == (try Self.day("2026-11-27")))
        #expect(document.dismissedSuggestionDay == (try Self.day("2026-12-15")))
        #expect(document.deadlineDay == "2026-11-27T14:00")
        #expect(document.deadlineDismissedDay == "2026-12-15T09:30")
    }

    /// A value that is not a day reads as no deadline (a label alone is no deadline either) and is not replaced.
    @Test func anUnreadableValueReadsAsNoneAndIsNotRewritten() {
        for stored in ["garbage", "2026-02-30", "27.11.2026", "2026-11-2"] {
            let document = Document(title: "Unlesbar")
            document.deadlineDay = stored
            document.deadlineLabel = "Pay"
            document.deadlineDismissedDay = stored
            #expect(document.deadline == nil, "\(stored)")
            #expect(document.dismissedSuggestionDay == nil, "\(stored)")
            #expect(document.deadlineDay == stored, "\(stored)")
            #expect(document.deadlineDismissedDay == stored, "\(stored)")
        }
    }

    /// Reading the deadline of a saved document changes nothing in its context, and an unrelated edit, a save and
    /// a reopen keep every deadline field as it was stored: a suffix, an unreadable value and a label included.
    @Test func readingWritesNothingAndTheStoredValuesSurviveAnEditAndAReopen() throws {
        let url = try TestSupport.makeTemporaryDirectory().appending(path: "Deadline.store")
        let stored: [(day: String, dismissed: String)] = [
            ("2026-11-27T14:00", "2026-12-15"), ("2026-02-30", "garbage"), ("", "2027-01-31T23:59"),
        ]
        var ids: [UUID] = []
        do {
            let container = try TestSupport.makeContainerOnDisk(at: url)
            let context = ModelContext(container)
            for (index, values) in stored.enumerated() {
                let document = Document(title: "Dokument \(index)")
                (document.deadlineDay, document.deadlineDismissedDay) = values
                document.deadlineLabel = "Label \(index)"
                document.deadlineSetAt = Self.setAt
                context.insert(document)
                ids.append(document.instanceID)
            }
            try context.save()

            let again = ModelContext(container)
            let documents = try again.fetch(FetchDescriptor<Document>())
            #expect(documents.count == 3)
            for document in documents {
                _ = document.deadline
                _ = document.dismissedSuggestionDay
            }
            #expect(!again.hasChanges, "reading a deadline writes nothing")
            for document in documents {
                document.title += " bearbeitet"
                document.touch()
            }
            try again.save()
        }
        let reopened = ModelContext(try TestSupport.makeContainerOnDisk(at: url))
        for (index, values) in stored.enumerated() {
            let instance = ids[index]
            let document = try #require(
                try reopened.fetch(FetchDescriptor<Document>()).first { $0.instanceID == instance })
            #expect(document.title == "Dokument \(index) bearbeitet")
            #expect(document.deadlineDay == values.day, "\(index)")
            #expect(document.deadlineDismissedDay == values.dismissed, "\(index)")
            #expect(document.deadlineLabel == "Label \(index)")
            #expect(document.deadlineSetAt == Self.setAt)
            #expect(document.deadlineDoneAt == nil)
        }
        let readable = try #require(
            try reopened.fetch(FetchDescriptor<Document>()).first { $0.instanceID == ids[0] })
        #expect(readable.deadline?.day == (try Self.day("2026-11-27")))
        #expect(readable.dismissedSuggestionDay == (try Self.day("2026-12-15")))
    }
}
