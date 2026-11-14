import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// Editing a document's deadline (#12, part 2a; plan §6): a new day is a new deadline (`deadlineSetAt` now,
/// `deadlineDoneAt` cleared); a label edit and a done toggle write only their own field and never the stored day
/// (review N8); removing it empties the four deadline fields and may dismiss a day; dismissing a suggestion (#12, part
/// 2b) writes only the dismissed day; and `deadlineDismissedDay` is only ever raised (`max(stored, new)`, re-review N3). The editor's usual rules hold: the same value writes nothing,
/// `touch()`, one save, a trashed or gone document is refused, a failed save is rolled back.
@MainActor
struct DocumentEditorDeadlineTests {
    private static let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let setAt = Date(timeIntervalSinceReferenceDate: 805_000_000)
    private static let doneAt = Date(timeIntervalSinceReferenceDate: 806_000_000)
    private static let edited = Date(timeIntervalSinceReferenceDate: 810_000_000)

    private static func day(_ stored: String) throws -> DeadlineDay {
        try #require(DeadlineDay(storedValue: stored), "\(stored)")
    }

    /// The five deadline fields as stored, `modifiedAt`, and every other field a deadline edit must not touch.
    private struct Fields: Equatable {
        var day: String
        var label: String
        var setAt: Date?
        var doneAt: Date?
        var dismissed: String
        var modifiedAt: Date
        var others: [String]

        init(_ document: Document) {
            day = document.deadlineDay
            label = document.deadlineLabel
            setAt = document.deadlineSetAt
            doneAt = document.deadlineDoneAt
            dismissed = document.deadlineDismissedDay
            modifiedAt = document.modifiedAt
            others = [
                document.title, "\(document.documentDate)", "\(document.isInbox)", "\(document.createdAt)",
                document.processingStateRaw, document.instanceID.uuidString,
                "\(String(describing: document.deletedAt))",
            ]
        }
    }

    @MainActor private struct Library {
        let container: ModelContainer
        let editor: DocumentEditor
        let document: Document
        /// Counts the container's saves.
        let saves: TestSignal
        let observer: any NSObjectProtocol

        var context: ModelContext { container.mainContext }

        /// The document as the store holds it, read in a new context, not the edited object.
        func stored() throws -> Fields {
            let instanceID = document.instanceID
            let read = try #require(
                try ModelContext(container).fetch(FetchDescriptor<Document>()).first { $0.instanceID == instanceID })
            return Fields(read)
        }
    }

    /// A document with the given deadline fields, saved.
    private func makeLibrary(
        container: ModelContainer? = nil, day: String = "", label: String = "", setAt: Date? = nil,
        doneAt: Date? = nil, dismissed: String = ""
    ) throws -> Library {
        let container = try container ?? TestSupport.makeContainer()
        let document = Document(title: "Wasserrechnung", createdAt: Self.created)
        document.processingStateRaw = "done"
        container.mainContext.insert(document)
        (document.deadlineDay, document.deadlineLabel) = (day, label)
        (document.deadlineSetAt, document.deadlineDoneAt) = (setAt, doneAt)
        document.deadlineDismissedDay = dismissed
        try container.mainContext.save()
        let saves = TestSignal()
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { notification in
            guard let saved = notification.object as? ModelContext, saved.container === container else { return }
            saves.fire()
        }
        return Library(
            container: container, editor: DocumentEditor(context: container.mainContext, now: { Self.edited }),
            document: document, saves: saves, observer: observer)
    }

    // MARK: Setting a day

    /// A first deadline: the day, the label (trimmed), `setAt` now, with one save and `touch()`.
    @Test func aFirstDeadlineSetsDayLabelAndSetAt() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        var expected = Fields(library.document)
        let outcome = try library.editor.apply(
            .deadline(try Self.day("2026-11-27"), label: "  Pay \n"), to: library.document.instanceID)
        #expect(outcome == .saved)
        (expected.day, expected.label, expected.setAt, expected.modifiedAt) = (
            "2026-11-27", "Pay", Self.edited, Self.edited
        )
        #expect(try library.stored() == expected)
        #expect(library.saves.count == 1)
        #expect(!library.context.hasChanges)
        #expect(library.document.deadline?.isDone == false)
    }

    /// A different day is a new deadline: `setAt` moves to now and a done deadline is open again, in the same save.
    @Test func aNewDaySetsSetAtAndClearsDone() throws {
        let library = try makeLibrary(day: "2026-11-27", label: "Pay", setAt: Self.setAt, doneAt: Self.doneAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        var expected = Fields(library.document)
        let outcome = try library.editor.apply(
            .deadline(try Self.day("2026-12-04"), label: "Pay"), to: library.document.instanceID)
        #expect(outcome == .saved)
        (expected.day, expected.setAt, expected.doneAt, expected.modifiedAt) = (
            "2026-12-04", Self.edited, nil, Self.edited
        )
        #expect(try library.stored() == expected)
        #expect(library.saves.count == 1)
    }

    /// A label edit on the day the document reads, and a done toggle, never rewrite the stored day: a later build's
    /// suffix stays byte for byte (review N8). Neither moves `setAt`.
    @Test func labelAndDoneEditsKeepTheStoredDayByteForByte() throws {
        let stored = "2026-11-27T14:00"
        let library = try makeLibrary(day: stored, label: "Pay", setAt: Self.setAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        var expected = Fields(library.document)

        #expect(
            try library.editor.apply(.deadline(try Self.day("2026-11-27"), label: "Zahlen"), to: instanceID) == .saved)
        (expected.label, expected.modifiedAt) = ("Zahlen", Self.edited)
        #expect(try library.stored() == expected)

        #expect(try library.editor.apply(.deadlineDone(true), to: instanceID) == .saved)
        expected.doneAt = Self.edited
        #expect(try library.stored() == expected)

        #expect(try library.editor.apply(.deadlineDone(false), to: instanceID) == .saved)
        expected.doneAt = nil
        #expect(try library.stored() == expected)
        #expect(try library.stored().day == stored)
        #expect(try library.stored().setAt == Self.setAt)
        #expect(library.saves.count == 3)
    }

    // MARK: Day-only and label-only edits (review N1 of #219)

    /// The info panel's label field sends `.deadlineLabel`, which carries no day. When the panel's snapshot is stale
    /// (sync merged a new day, done, into the main context before the library read again), the label edit still writes
    /// only the label: never the old day back, never `setAt`, never clearing `doneAt`.
    @Test func aLabelEditWithAStaleSnapshotWritesOnlyTheLabel() throws {
        // The store already holds the synced 2026-12-04, done; the panel still shows 2026-11-27, open.
        let library = try makeLibrary(day: "2026-12-04", label: "Pay", setAt: Self.setAt, doneAt: Self.doneAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        var expected = Fields(library.document)
        #expect(try library.editor.apply(.deadlineLabel(" Zahlen "), to: library.document.instanceID) == .saved)
        (expected.label, expected.modifiedAt) = ("Zahlen", Self.edited)
        #expect(try library.stored() == expected)
        #expect(try library.stored().day == "2026-12-04")
        #expect(try library.stored().setAt == Self.setAt)
        #expect(try library.stored().doneAt == Self.doneAt)
        #expect(try library.editor.apply(.deadlineLabel("Zahlen"), to: library.document.instanceID) == .unchanged)
        #expect(library.saves.count == 1)
    }

    /// The date picker sends `.deadlineDay`, which carries no label: a new day is a new deadline (`setAt` now, done
    /// cleared) and keeps the stored label, also one a sync wrote after the panel read it; the day it already reads
    /// writes nothing.
    @Test func aDayEditKeepsTheStoredLabel() throws {
        let library = try makeLibrary(day: "2026-11-27T14:00", label: "Synced", setAt: Self.setAt, doneAt: Self.doneAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        var expected = Fields(library.document)
        #expect(try library.editor.apply(.deadlineDay(try Self.day("2026-11-27")), to: instanceID) == .unchanged)
        #expect(try library.stored() == expected)
        #expect(try library.editor.apply(.deadlineDay(try Self.day("2026-12-04")), to: instanceID) == .saved)
        (expected.day, expected.setAt, expected.doneAt, expected.modifiedAt) = (
            "2026-12-04", Self.edited, nil, Self.edited
        )
        #expect(try library.stored() == expected)
        #expect(library.saves.count == 1)

        // Without a deadline: a label alone is refused; a day gives a deadline with an empty label.
        let empty = try makeLibrary(container: library.container)
        defer { NotificationCenter.default.removeObserver(empty.observer) }
        #expect(try empty.editor.apply(.deadlineLabel("Pay"), to: empty.document.instanceID) == .noDeadline)
        #expect(empty.saves.count == 0)
        #expect(
            try empty.editor.apply(.deadlineDay(try Self.day("2026-12-04")), to: empty.document.instanceID) == .saved)
        #expect(try empty.stored().day == "2026-12-04")
        #expect(try empty.stored().label == "")
        #expect(try empty.stored().setAt == Self.edited)
    }

    /// The value a document already has writes nothing and does not save.
    @Test func theSameValueWritesNothing() throws {
        let library = try makeLibrary(day: "2026-11-27", label: "Pay", setAt: Self.setAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        let before = Fields(library.document)
        let unchanged: [DocumentEditor.Change] = [
            .deadline(try Self.day("2026-11-27"), label: "Pay"), .deadline(try Self.day("2026-11-27"), label: " Pay "),
            .deadlineDone(false),
        ]
        for change in unchanged {
            #expect(try library.editor.apply(change, to: instanceID) == .unchanged, "\(change)")
        }
        #expect(try library.editor.apply(.deadlineDone(true), to: instanceID) == .saved)
        #expect(try library.editor.apply(.deadlineDone(true), to: instanceID) == .unchanged)
        #expect(library.saves.count == 1)

        // No deadline at all: removing it changes nothing, and nothing can be marked done.
        let empty = try makeLibrary(container: library.container)
        defer { NotificationCenter.default.removeObserver(empty.observer) }
        let emptyBefore = Fields(empty.document)
        #expect(try empty.editor.apply(.clearDeadline(dismissing: nil), to: empty.document.instanceID) == .unchanged)
        #expect(try empty.editor.apply(.deadlineDone(true), to: empty.document.instanceID) == .noDeadline)
        #expect(try empty.stored() == emptyBefore)
        #expect(empty.saves.count == 0)
        #expect(before.day == "2026-11-27")
    }

    // MARK: Removing

    /// Remove empties the four deadline fields with one save and leaves the dismissed day alone without a day to
    /// dismiss.
    @Test func removingEmptiesTheFourDeadlineFields() throws {
        let library = try makeLibrary(
            day: "2026-11-27T14:00", label: "Pay", setAt: Self.setAt, doneAt: Self.doneAt, dismissed: "2026-11-20")
        defer { NotificationCenter.default.removeObserver(library.observer) }
        var expected = Fields(library.document)
        #expect(try library.editor.apply(.clearDeadline(dismissing: nil), to: library.document.instanceID) == .saved)
        (expected.day, expected.label, expected.setAt, expected.doneAt, expected.modifiedAt) = (
            "", "", nil, nil, Self.edited
        )
        #expect(try library.stored() == expected)
        #expect(library.document.deadline == nil)
        #expect(library.saves.count == 1)
    }

    /// The `max` rule on `deadlineDismissedDay` (re-review N3): a removal that dismisses a later day raises it, one
    /// with an earlier or the same day keeps the stored value byte for byte, and a stored value that does not read as
    /// a day counts as none.
    @Test func removingWithADayOnlyEverRaisesTheDismissedDay() throws {
        let library = try makeLibrary(day: "2026-11-27", label: "Pay", setAt: Self.setAt, dismissed: "2026-12-01")
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID

        // An earlier day: the deadline goes, the dismissed day stays.
        #expect(
            try library.editor.apply(.clearDeadline(dismissing: try Self.day("2026-11-27")), to: instanceID) == .saved)
        #expect(try library.stored().dismissed == "2026-12-01")
        #expect(try library.stored().day == "")

        // Nothing left to remove and an earlier day: nothing is written.
        #expect(
            try library.editor.apply(.clearDeadline(dismissing: try Self.day("2026-11-30")), to: instanceID)
                == .unchanged)
        #expect(library.saves.count == 1)

        // A later day raises it, also without a deadline to remove.
        #expect(
            try library.editor.apply(.clearDeadline(dismissing: try Self.day("2026-12-15")), to: instanceID) == .saved)
        #expect(try library.stored().dismissed == "2026-12-15")
        #expect(library.saves.count == 2)

        // The same day as a stored value with a later build's suffix: kept as it is.
        let suffixed = try makeLibrary(container: library.container, day: "2026-11-27", dismissed: "2026-12-15T09:30")
        defer { NotificationCenter.default.removeObserver(suffixed.observer) }
        let suffixedID = suffixed.document.instanceID
        #expect(
            try suffixed.editor.apply(.clearDeadline(dismissing: try Self.day("2026-12-15")), to: suffixedID) == .saved)
        #expect(try suffixed.stored().dismissed == "2026-12-15T09:30")

        // A stored value that is not a day: any day replaces it.
        let unreadable = try makeLibrary(container: library.container, day: "2026-11-27", dismissed: "garbage")
        defer { NotificationCenter.default.removeObserver(unreadable.observer) }
        let unreadableID = unreadable.document.instanceID
        #expect(
            try unreadable.editor.apply(.clearDeadline(dismissing: try Self.day("2026-11-27")), to: unreadableID)
                == .saved)
        #expect(try unreadable.stored().dismissed == "2026-11-27")
    }

    // MARK: Dismissing a suggestion (#12, part 2b)

    /// Dismiss writes only `deadlineDismissedDay`, with one save and `touch()`; the deadline fields stay as they are.
    @Test func dismissingASuggestionWritesOnlyTheDismissedDay() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        var expected = Fields(library.document)
        #expect(
            try library.editor.apply(
                .dismissDeadlineSuggestion(try Self.day("2026-11-27")), to: library.document.instanceID)
                == .saved)
        (expected.dismissed, expected.modifiedAt) = ("2026-11-27", Self.edited)
        #expect(try library.stored() == expected)
        #expect(library.saves.count == 1)
        #expect(!library.context.hasChanges)
        #expect(library.document.dismissedSuggestionDay == (try Self.day("2026-11-27")))
    }

    /// The `max` rule (re-review N3): a later day raises the dismissed day; an earlier or the same day writes nothing
    /// and does not save, so two devices dismissing at once, or a dismissal racing N9's removal, never lower it. A
    /// stored value with a later build's suffix stays byte for byte; one that is not a day counts as none.
    @Test func dismissingOnlyEverRaisesTheDismissedDay() throws {
        let library = try makeLibrary(dismissed: "2026-12-15")
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        for earlier in ["2026-11-27", "2026-12-14", "2026-12-15"] {
            #expect(
                try library.editor.apply(.dismissDeadlineSuggestion(try Self.day(earlier)), to: instanceID)
                    == .unchanged, "\(earlier)")
        }
        #expect(try library.stored().dismissed == "2026-12-15")
        #expect(library.saves.count == 0)
        #expect(
            try library.editor.apply(.dismissDeadlineSuggestion(try Self.day("2027-01-04")), to: instanceID) == .saved)
        #expect(try library.stored().dismissed == "2027-01-04")
        #expect(library.saves.count == 1)

        let suffixed = try makeLibrary(container: library.container, dismissed: "2026-12-15T09:30")
        defer { NotificationCenter.default.removeObserver(suffixed.observer) }
        #expect(
            try suffixed.editor.apply(
                .dismissDeadlineSuggestion(try Self.day("2026-12-15")), to: suffixed.document.instanceID)
                == .unchanged)
        #expect(try suffixed.stored().dismissed == "2026-12-15T09:30")

        let unreadable = try makeLibrary(container: library.container, dismissed: "garbage")
        defer { NotificationCenter.default.removeObserver(unreadable.observer) }
        #expect(
            try unreadable.editor.apply(
                .dismissDeadlineSuggestion(try Self.day("2026-11-27")), to: unreadable.document.instanceID) == .saved)
        #expect(try unreadable.stored().dismissed == "2026-11-27")
    }

    /// Two devices dismiss at once (re-review N3): the earlier dismissal arrives after the later one and lowers nothing.
    @Test func aLateEarlierDismissalFromAnotherContextLowersNothing() throws {
        let library = try makeLibrary()
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        // The other device's later dismissal, saved through a second context of the same store.
        let other = DocumentEditor(context: ModelContext(library.container), now: { Self.edited })
        #expect(try other.apply(.dismissDeadlineSuggestion(try Self.day("2026-12-15")), to: instanceID) == .saved)
        // This device's editor, dismissing the earlier day afterwards, reads the stored later one first.
        let fresh = DocumentEditor(context: ModelContext(library.container), now: { Self.edited })
        #expect(try fresh.apply(.dismissDeadlineSuggestion(try Self.day("2026-11-27")), to: instanceID) == .unchanged)
        #expect(try library.stored().dismissed == "2026-12-15")
    }

    @Test func theMaxRuleComparesDays() throws {
        let day = try Self.day("2026-12-01")
        #expect(DocumentEditor.raises("", to: day))
        #expect(DocumentEditor.raises("garbage", to: day))
        #expect(DocumentEditor.raises("2026-11-30", to: day))
        #expect(!DocumentEditor.raises("2026-12-01", to: day))
        #expect(!DocumentEditor.raises("2026-12-01T09:30", to: day))
        #expect(!DocumentEditor.raises("2027-01-01", to: day))
    }

    // MARK: Refused and failed

    @Test func aTrashedDocumentsDeadlineIsNotEdited() throws {
        let library = try makeLibrary(day: "2026-11-27", label: "Pay", setAt: Self.setAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        library.document.deletedAt = Self.edited
        try library.context.save()
        let before = Fields(library.document)
        let savesBefore = library.saves.count
        let changes: [DocumentEditor.Change] = [
            .deadline(try Self.day("2026-12-04"), label: "Pay"), .deadline(try Self.day("2026-11-27"), label: "Neu"),
            .deadlineDone(true), .clearDeadline(dismissing: nil),
            .clearDeadline(dismissing: try Self.day("2027-01-01")), .deadlineDay(try Self.day("2026-12-04")),
            .deadlineLabel("Neu"), .dismissDeadlineSuggestion(try Self.day("2027-01-01")),
        ]
        for change in changes {
            #expect(try library.editor.apply(change, to: library.document.instanceID) == .trashed, "\(change)")
        }
        #expect(try library.editor.apply(.deadlineDone(true), to: UUID()) == .noDocument)
        #expect(Fields(library.document) == before)
        #expect(library.saves.count == savesBefore)
    }

    private struct SaveFailed: Error {}

    /// A failed save is rolled back: the deadline keeps its committed fields and nothing stays pending.
    @Test func aFailedDeadlineSaveIsRolledBack() throws {
        let library = try makeLibrary(day: "2026-11-27", label: "Pay", setAt: Self.setAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let before = Fields(library.document)
        let failing = DocumentEditor(context: library.context, now: { Self.edited }, save: { _ in throw SaveFailed() })
        let instanceID = library.document.instanceID
        #expect(throws: SaveFailed.self) {
            try failing.apply(.deadline(try Self.day("2026-12-04"), label: "Neu"), to: instanceID)
        }
        #expect(throws: SaveFailed.self) { try failing.apply(.deadlineDone(true), to: instanceID) }
        #expect(throws: SaveFailed.self) {
            try failing.apply(.clearDeadline(dismissing: try Self.day("2027-01-01")), to: instanceID)
        }
        #expect(throws: SaveFailed.self) {
            try failing.apply(.dismissDeadlineSuggestion(try Self.day("2027-01-01")), to: instanceID)
        }
        #expect(!library.context.hasChanges)
        #expect(Fields(library.document) == before)
        #expect(try library.stored() == before)
    }

    // MARK: SQL

    /// The SQL of a label edit, a done toggle and a dismissal (#12, part 2b): one `UPDATE ZDOCUMENT` each, of its own
    /// column, `modifiedAt` and Core Data's optimistic-locking counter; never `ZDEADLINEDAY` (review N8). Runs under `swift test` on macOS only
    /// (`SQLLog`).
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func labelAndDoneEditsUpdateOnlyTheirColumns() throws {
        let library = try makeLibrary(
            container: TestSupport.makeContainerOnDisk(), day: "2026-11-27T14:00", label: "Pay", setAt: Self.setAt)
        defer { NotificationCenter.default.removeObserver(library.observer) }
        let instanceID = library.document.instanceID
        // A clock that moves with each edit, so every edit has a new `modifiedAt` to write.
        var clock = Self.edited
        let editor = DocumentEditor(
            context: library.context,
            now: {
                clock.addTimeInterval(60)
                return clock
            })
        let cases: [(DocumentEditor.Change, Set<String>)] = [
            (.deadline(try Self.day("2026-11-27"), label: "Zahlen"), ["ZDEADLINELABEL", "ZMODIFIEDAT", "Z_OPT"]),
            (.deadlineDone(true), ["ZDEADLINEDONEAT", "ZMODIFIEDAT", "Z_OPT"]),
            (.deadlineLabel("Pay"), ["ZDEADLINELABEL", "ZMODIFIEDAT", "Z_OPT"]),
            (
                .dismissDeadlineSuggestion(try Self.day("2026-12-01")),
                ["ZDEADLINEDISMISSEDDAY", "ZMODIFIEDAT", "Z_OPT"]
            ),
        ]
        for (change, columns) in cases {
            let recording = try SQLLog.Recording()
            #expect(try editor.apply(change, to: instanceID) == .saved)
            let updates = try recording.statements().filter { $0.hasPrefix("UPDATE ") }
            #expect(updates.count == 1, "\(updates)")
            let update = try #require(updates.first)
            #expect(SQLLog.statement(update, names: "ZDOCUMENT"), "\(update)")
            let set = try #require(update.range(of: " SET ")).upperBound
            let end = try #require(update.range(of: " WHERE ")).lowerBound
            let written = update[set..<end].split(separator: ",").map {
                $0.split(separator: "=")[0].trimmingCharacters(in: .whitespaces)
            }
            #expect(Set(written) == columns, "\(change): \(update)")
        }
    }
}
