import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

/// The due-date suggestion in the detail (#12, part 2b; plan §5, maintainer decision Q2): the electricity bill's text
/// says "Zahlbar bis <today + 14>"; the model offers it while the document has no deadline; "Add Deadline" writes the
/// day and the kind's name, "Dismiss" writes the dismissed day and offers nothing more, and "Remove Deadline" right after
/// adding it dismisses it in the same save (review N9). In-memory stores and fixed days only; never the real clock.
@MainActor
struct DeadlineSuggestionTests {
    private nonisolated static let today = DeadlineDay(year: 2026, month: 11, day: 14)!
    private static let electricityBill = FixtureCatalog.documentID(1)
    private static let golfInspection = FixtureCatalog.documentID(8)

    private static func day(_ offset: Int, from day: DeadlineDay = today) -> DeadlineDay {
        day.adding(days: offset)!
    }

    /// The bill's suggestion: a payment due 14 days after today.
    private static func billSuggestion(today: DeadlineDay = today) -> DueDateCandidate {
        DueDateCandidate(day: day(FixtureCatalog.electricityBillDueDays, from: today), kind: .payment)
    }

    /// The seeded store's library with the electricity bill open, its suggestion read.
    private func openBill() async throws -> (ModelContainer, LibraryModel) {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: Self.today)
        let model = LibraryModel(source: StoreLibrarySource(container: container), today: { Self.today })
        model.selection = .all
        model.selectedDocumentID = Self.electricityBill
        await model.loadDeadlineSuggestion()
        return (container, model)
    }

    /// The document as the store holds it, read in a new context.
    private func stored(_ instanceID: UUID, in container: ModelContainer) throws -> Document {
        try #require(
            try ModelContext(container).fetch(FetchDescriptor<Document>()).first { $0.instanceID == instanceID })
    }

    // MARK: The bill's text

    /// The bill's text is relative to the day given (plan review B2), in the seeded store and in the fixture source,
    /// and the loader of each finds that day.
    @Test(arguments: [today, DeadlineDay(year: 2027, month: 3, day: 1)!])
    func theBillsTextSaysPayableTwoWeeksFromToday(today: DeadlineDay) async throws {
        let due = Self.day(14, from: today)
        let line = String(format: "Zahlbar bis %02d.%02d.%04d", due.day, due.month, due.year)
        #expect(FixtureCatalog.electricityBillDueLine(today: today) == line)

        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: today)
        let bill = try stored(Self.electricityBill, in: container)
        #expect(bill.text?.extractedText.contains(line) == true)
        #expect(bill.deadline == nil)
        let store = StoreLibrarySource(container: container)
        #expect(
            await store.loadDeadlineSuggestion(instanceID: Self.electricityBill, today: today)
                == Self.billSuggestion(today: today))
        #expect(
            await FixtureLibrarySource(today: today).loadDeadlineSuggestion(
                instanceID: Self.electricityBill, today: today)
                == Self.billSuggestion(today: today))
        // No other sample names a due date.
        for sample in FixtureCatalog.samples(today: today) where sample.document.instanceID != Self.electricityBill {
            #expect(
                await store.loadDeadlineSuggestion(instanceID: sample.document.instanceID, today: today) == nil,
                "\(sample.document.title)")
        }
    }

    // MARK: Offered

    /// The bill's suggestion is offered while it has no deadline; the open document's only.
    @Test func theSuggestionIsOfferedWithoutADeadline() async throws {
        let (_, model) = try await openBill()
        #expect(model.deadlineSuggestion == Self.billSuggestion())
        #expect(model.deadlineSuggestionKey.instanceID == Self.electricityBill)
        // Another document: the bill's suggestion is not shown for it, and the new read finds none.
        model.selectedDocumentID = Self.golfInspection
        #expect(model.deadlineSuggestion == nil)
        await model.loadDeadlineSuggestion()
        #expect(model.loadedSuggestion == .init(instanceID: Self.golfInspection, candidate: nil))
        #expect(model.deadlineSuggestion == nil)
    }

    /// With a deadline the text's suggestion is still read (for N9), but not offered.
    @Test func noSuggestionIsOfferedWithADeadline() async throws {
        let (_, model) = try await openBill()
        #expect(model.edit(.deadline(Self.day(30), label: ""), of: Self.electricityBill) == .saved)
        await model.loadDeadlineSuggestion()
        #expect(model.loadedSuggestion?.candidate == Self.billSuggestion())
        #expect(model.deadlineSuggestion == nil)
        #expect(model.edit(.deadlineDone(true), of: Self.electricityBill) == .saved)
        #expect(model.deadlineSuggestion == nil, "a done deadline is a deadline")
    }

    // MARK: Add and Dismiss

    /// "Add Deadline" writes the day and the kind's name as the label, through the editor; the bill then is in Deadlines
    /// and the suggestion is gone.
    @Test func addWritesTheDayAndTheKindsLabel() async throws {
        let (container, model) = try await openBill()
        let suggestion = try #require(model.deadlineSuggestion)
        #expect(model.addSuggestedDeadline(suggestion, to: Self.electricityBill) == .saved)
        let bill = try stored(Self.electricityBill, in: container)
        #expect(bill.deadline?.day == Self.billSuggestion().day)
        #expect(bill.deadlineLabel == DeadlineText.kindName(.payment))
        #expect(bill.deadlineSetAt != nil)
        #expect(bill.deadlineDismissedDay.isEmpty)
        #expect(model.deadlineSuggestion == nil)
        model.selection = .upcoming
        #expect(model.documents.contains { $0.instanceID == Self.electricityBill })
    }

    /// The info panel's "Add Deadline" takes the suggestion when one is offered, else 7 days ahead with no label.
    @Test func theInfoPanelsAddTakesTheSuggestion() async throws {
        let (container, model) = try await openBill()
        #expect(model.addDeadline(to: Self.electricityBill) == .saved)
        #expect(try stored(Self.electricityBill, in: container).deadline?.day == Self.billSuggestion().day)
        #expect(try stored(Self.electricityBill, in: container).deadlineLabel == DeadlineText.kindName(.payment))

        model.selectedDocumentID = Self.golfInspection
        await model.loadDeadlineSuggestion()
        #expect(model.addDeadline(to: Self.golfInspection) == .saved)
        #expect(try stored(Self.golfInspection, in: container).deadline?.day == Self.day(7))
        #expect(try stored(Self.golfInspection, in: container).deadlineLabel == "")
    }

    /// "Dismiss" writes the day as dismissed, which syncs, and nothing is offered after it: the text has no later day.
    @Test func dismissWritesTheDay() async throws {
        let (container, model) = try await openBill()
        let suggestion = try #require(model.deadlineSuggestion)
        #expect(await model.dismissDeadlineSuggestion(suggestion, of: Self.electricityBill) == .saved)
        let bill = try stored(Self.electricityBill, in: container)
        #expect(bill.deadlineDismissedDay == suggestion.day.storedValue)
        #expect(bill.deadline == nil)
        #expect(model.deadlineSuggestion == nil)
        #expect(model.loadedSuggestion == .init(instanceID: Self.electricityBill, candidate: nil))
    }

    /// A dismissal hides the suggestion at once, from the library's values, before the text is read again.
    @Test func aDismissalHidesTheSuggestionBeforeTheNextRead() async throws {
        let (_, model) = try await openBill()
        let suggestion = try #require(model.deadlineSuggestion)
        #expect(model.edit(.dismissDeadlineSuggestion(suggestion.day), of: Self.electricityBill) == .saved)
        #expect(model.loadedSuggestion?.candidate == suggestion, "not read again yet")
        #expect(model.deadlineSuggestion == nil)
    }

    // MARK: N9

    /// "Remove Deadline" right after "Add Deadline" does not offer the same suggestion again: the removal dismisses its
    /// day in the same save. A deadline on another day is removed without a dismissal, and the suggestion is back.
    @Test func removingRightAfterAddingDoesNotOfferItAgain() async throws {
        let (container, model) = try await openBill()
        let suggestion = try #require(model.deadlineSuggestion)
        #expect(model.addSuggestedDeadline(suggestion, to: Self.electricityBill) == .saved)
        await model.loadDeadlineSuggestion()
        #expect(model.removeDeadline(of: Self.electricityBill) == .saved)
        await model.loadDeadlineSuggestion()
        let bill = try stored(Self.electricityBill, in: container)
        #expect(bill.deadline == nil)
        #expect(bill.deadlineDismissedDay == suggestion.day.storedValue)
        #expect(model.deadlineSuggestion == nil)

        // Another document whose deadline is not the text's suggestion: removed, nothing dismissed.
        let (other, otherModel) = try await openBill()
        #expect(otherModel.edit(.deadline(Self.day(30), label: "Pay"), of: Self.electricityBill) == .saved)
        await otherModel.loadDeadlineSuggestion()
        #expect(otherModel.removeDeadline(of: Self.electricityBill) == .saved)
        await otherModel.loadDeadlineSuggestion()
        #expect(try stored(Self.electricityBill, in: other).deadlineDismissedDay.isEmpty)
        #expect(otherModel.deadlineSuggestion == suggestion)
    }
}
