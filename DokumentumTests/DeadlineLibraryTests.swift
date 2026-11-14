import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

#if os(iOS)
    import UIKit
#endif

/// The Deadlines overview in the app (#12, part 2a): "today" from `AppDay` (`-UITestToday` in Debug), the sample
/// deadlines relative to it, the Deadlines list in its order with Q7's count from the lead time, Done taking a
/// document out of the list, and the day change. In-memory stores and fixed days only; never the real clock.
@MainActor
struct DeadlineLibraryTests {
    private nonisolated static let today = DeadlineDay(year: 2026, month: 11, day: 14)!
    private static let medicalInvoice = FixtureCatalog.documentID(2)
    private static let waterBill = FixtureCatalog.documentID(3)
    private static let accountStatement = FixtureCatalog.documentID(4)
    private static let carInsurance = FixtureCatalog.documentID(7)

    private static func day(_ offset: Int, from day: DeadlineDay = today) -> DeadlineDay {
        day.adding(days: offset)!
    }

    // MARK: AppDay

    @Test func appDayIsTheFixedDayOfUITestToday() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(AppDay.today(arguments: ["app", "-UITestToday", "2026-11-14"], now: now) == Self.today)
        #expect(
            AppDay.today(arguments: ["-UITestSeed", "YES", "-UITestToday", "2028-02-29", "-X", "Y"], now: now)
                == DeadlineDay(year: 2028, month: 2, day: 29))
    }

    /// Without the argument, or with a value that is not exactly a day, the system's day in the given zone.
    @Test func appDayIsTheSystemsDayOtherwise() throws {
        // 2026-11-27 03:00 in Berlin is 2026-11-26 21:00 in New York.
        let instant = Date(timeIntervalSince1970: 1_795_744_800)
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let berlinDay = DeadlineDay(year: 2026, month: 11, day: 27)
        #expect(AppDay.today(arguments: ["app"], now: instant, timeZone: berlin) == berlinDay)
        #expect(
            AppDay.today(arguments: ["app"], now: instant, timeZone: newYork)
                == DeadlineDay(year: 2026, month: 11, day: 26))
        for arguments in [
            ["-UITestToday", "2026-02-30"], ["-UITestToday", "2026-11-14T10:00"], ["-UITestToday", "14.11.2026"],
            ["-UITestToday"], ["-UITestToday", ""],
        ] {
            #expect(AppDay.today(arguments: arguments, now: instant, timeZone: berlin) == berlinDay, "\(arguments)")
        }
    }

    // MARK: Samples

    /// The seeded deadlines are relative to the day given (plan review B2): overdue by 2, due in 2, 10 and 30 (done);
    /// another day moves them all. Every other sample has none.
    @Test(arguments: [today, DeadlineDay(year: 2027, month: 3, day: 1)!])
    func theSeedersDeadlinesAreRelativeToToday(today: DeadlineDay) throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: today)
        let documents = try container.mainContext.fetch(FetchDescriptor<Document>())
        var deadlines: [UUID: DocumentDeadline] = [:]
        for document in documents { deadlines[document.instanceID] = document.deadline }
        #expect(deadlines[Self.medicalInvoice]?.day == Self.day(-2, from: today))
        #expect(deadlines[Self.waterBill]?.day == Self.day(2, from: today))
        #expect(deadlines[Self.accountStatement]?.day == Self.day(10, from: today))
        #expect(deadlines[Self.carInsurance]?.day == Self.day(30, from: today))
        #expect(deadlines[Self.medicalInvoice]?.label == "Pay")
        #expect(deadlines[Self.carInsurance]?.isDone == true)
        #expect(
            [Self.medicalInvoice, Self.waterBill, Self.accountStatement].allSatisfy { deadlines[$0]?.isDone == false })
        #expect(deadlines.count == 4)
        // The source without a store says the same.
        let rows = FixtureLibrarySource(today: today).snapshot().documents
        for row in rows {
            #expect(row.deadline == deadlines[row.instanceID], "\(row.title)")
        }
    }

    // MARK: The Deadlines list

    /// Deadlines lists the open deadlines by day, the overdue medical invoice first; the done car insurance is not
    /// there. The count is 2 with the default lead time of 3 days (overdue, and due in 2 days), not 3.
    @Test func theDeadlinesListIsOrderedAndCountsOverduePlusDueSoon() {
        let model = LibraryModel(source: FixtureLibrarySource(today: Self.today), today: { Self.today })
        model.selection = .upcoming
        #expect(model.documents.map(\.instanceID) == [Self.medicalInvoice, Self.waterBill, Self.accountStatement])
        #expect(model.counts.count(for: .upcoming) == 2)
        #expect(model.deadlineStatus(of: model.documents[0]) == .overdue(days: 2))
        #expect(model.deadlineStatus(of: model.documents[1]) == .upcoming(days: 2))
        // The other lists keep every document and their order.
        model.selection = .all
        #expect(model.documents.count == FixtureCatalog.samples(today: Self.today).count)
        #expect(model.documents.contains { $0.instanceID == Self.carInsurance })
    }

    /// The count's lead time comes through `deadlineLeadDays`, this device's reminder lead time in the app (#12, part 3;
    /// `ReminderAppTests.theCountFollowsTheLeadTime`).
    @Test func theCountsLeadTimeComesThroughTheSeam() {
        let longer = LibraryModel(
            source: FixtureLibrarySource(today: Self.today), today: { Self.today }, deadlineLeadDays: { 10 })
        #expect(longer.counts.count(for: .upcoming) == 3)
        let none = LibraryModel(
            source: FixtureLibrarySource(today: Self.today), today: { Self.today }, deadlineLeadDays: { 0 })
        #expect(none.counts.count(for: .upcoming) == 1)
    }

    /// "Mark as Done" in the Deadlines list: the document leaves the list and its selection, the count goes down, and
    /// All Documents still has it, done.
    @Test func markingDoneTakesTheDocumentOutOfTheList() throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: Self.today)
        let model = LibraryModel(source: StoreLibrarySource(container: container), today: { Self.today })
        model.selection = .upcoming
        model.selectedDocumentID = Self.waterBill
        #expect(model.selectedDocument?.openDeadline != nil)

        #expect(model.edit(.deadlineDone(true), of: Self.waterBill) == .saved)
        #expect(model.documents.map(\.instanceID) == [Self.medicalInvoice, Self.accountStatement])
        #expect(model.selectedDocumentID == nil)
        #expect(model.counts.count(for: .upcoming) == 1)
        model.selection = .all
        #expect(model.documents.first { $0.instanceID == Self.waterBill }?.deadline?.isDone == true)

        // Open again through the info panel's switch: back in the list.
        #expect(model.edit(.deadlineDone(false), of: Self.waterBill) == .saved)
        model.selection = .upcoming
        #expect(model.documents.map(\.instanceID) == [Self.medicalInvoice, Self.waterBill, Self.accountStatement])
    }

    /// The info panel's edits: "Add Deadline" puts the document into the list, a new day reorders it, and
    /// "Remove Deadline" takes it out again.
    @Test func addingMovingAndRemovingADeadlineUpdatesTheList() throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: Self.today)
        let model = LibraryModel(source: StoreLibrarySource(container: container), today: { Self.today })
        model.selection = .upcoming
        let electricityBill = FixtureCatalog.documentID(1)
        #expect(model.edit(.deadline(Self.day(7), label: ""), of: electricityBill) == .saved)
        #expect(
            model.documents.map(\.instanceID) == [
                Self.medicalInvoice, Self.waterBill, electricityBill, Self.accountStatement,
            ])
        #expect(model.counts.count(for: .upcoming) == 2)
        // Tomorrow: now the first and counted.
        #expect(model.edit(.deadline(Self.day(1), label: "Read"), of: electricityBill) == .saved)
        #expect(model.documents.map(\.instanceID).prefix(2) == [Self.medicalInvoice, electricityBill])
        #expect(model.counts.count(for: .upcoming) == 3)
        #expect(model.edit(.clearDeadline(dismissing: nil), of: electricityBill) == .saved)
        #expect(!model.documents.contains { $0.instanceID == electricityBill })
        #expect(model.counts.count(for: .upcoming) == 2)
    }

    /// Review N1 of #219: the info panel's label commit is a label-only edit. The library's snapshot is stale (a sync
    /// moved the water bill's deadline to day +5 and marked it done in the main context, and the library has not read
    /// again), and the label commit must not send the snapshot's day +2 back: the day stays +5, done stays, `setAt`
    /// stays the sync's.
    @Test func aLabelCommitOnAStaleSnapshotWritesOnlyTheLabel() throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: Self.today)
        let model = LibraryModel(source: StoreLibrarySource(container: container), today: { Self.today })
        model.selection = .upcoming
        #expect(model.snapshot.documents.first { $0.instanceID == Self.waterBill }?.deadline?.day == Self.day(2))

        // The "sync": another editor on the main context; the model does not read the library again.
        let synced = Date(timeIntervalSinceReferenceDate: 815_000_000)
        let sync = DocumentEditor(context: container.mainContext, now: { synced })
        #expect(try sync.apply(.deadlineDay(Self.day(5)), to: Self.waterBill) == .saved)
        #expect(try sync.apply(.deadlineDone(true), to: Self.waterBill) == .saved)
        #expect(model.snapshot.documents.first { $0.instanceID == Self.waterBill }?.deadline?.day == Self.day(2))

        var draft = TitleDraft()
        draft.show(Self.waterBill, title: "Pay")
        draft.text = "Zahlen"
        model.commitDeadlineLabel(&draft)

        let stored = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Document>()).first { $0.instanceID == Self.waterBill })
        #expect(stored.deadline?.day == Self.day(5))
        #expect(stored.deadlineLabel == "Zahlen")
        #expect(stored.deadlineSetAt == synced)
        #expect(stored.deadlineDoneAt == synced)
        #expect(!draft.isChanged)
    }

    /// Review N5 of #219: the bar shows an open deadline, but none for a document in the trash (its edits are refused
    /// there), a done deadline or none.
    @Test func theBarShowsNoDeadlineOfATrashedDocument() throws {
        let rows = FixtureLibrarySource(today: Self.today).snapshot().documents
        var water = try #require(rows.first { $0.instanceID == Self.waterBill })
        #expect(DeadlineBar.shownDeadline(of: water) == water.deadline)
        water.deletedAt = Date(timeIntervalSinceReferenceDate: 815_000_000)
        #expect(water.openDeadline != nil)
        #expect(DeadlineBar.shownDeadline(of: water) == nil)
        let car = try #require(rows.first { $0.instanceID == Self.carInsurance })
        #expect(car.deadline != nil)
        #expect(DeadlineBar.shownDeadline(of: car) == nil)
        let bill = try #require(rows.first { $0.instanceID == FixtureCatalog.documentID(1) })
        #expect(DeadlineBar.shownDeadline(of: bill) == nil)
        #expect(DeadlineBar.shownDeadline(of: nil) == nil)
    }

    // MARK: The day changes

    /// A box for a test's "today", which the model reads through its closure.
    @MainActor private final class Clock {
        var day: DeadlineDay
        init(_ day: DeadlineDay) { self.day = day }
    }

    /// At the next day the status and the count follow; the list stays (it shows every open deadline).
    @Test func aNewDayRecountsAndMovesTheStatus() {
        let clock = Clock(Self.today)
        let model = LibraryModel(source: FixtureLibrarySource(today: Self.today), today: { clock.day })
        model.selection = .upcoming
        #expect(model.counts.count(for: .upcoming) == 2)
        clock.day = Self.day(8)
        model.dayMayHaveChanged()
        #expect(model.today == Self.day(8))
        // The account statement (day +10) is due in 2 days now, the water bill overdue.
        #expect(model.counts.count(for: .upcoming) == 3)
        #expect(model.deadlineStatus(of: model.documents[1]) == .overdue(days: 6))
        #expect(model.documents.count == 3)
    }

    /// `observeDayChanges` follows each of its notifications on the center it is given (a private one, so no other
    /// test's notification reaches it): `NSCalendarDayChanged`, and on the iPhone the significant time change (review N4
    /// of #219).
    @Test(arguments: LibraryModel.dayChangeNotifications)
    func theModelFollowsTheDayChangeNotification(name: Notification.Name) async throws {
        let clock = Clock(Self.today)
        let model = LibraryModel(source: FixtureLibrarySource(today: Self.today), today: { clock.day })
        let center = NotificationCenter()
        let observing = Task { await model.observeDayChanges(center: center) }
        defer { observing.cancel() }
        clock.day = Self.day(1)
        // Posted again each round, so a post before the observer is registered cannot be lost.
        try await TestSupport.waitUntil("the model did not read the new day after \(name.rawValue)") {
            center.post(name: name, object: nil)
            return model.today == Self.day(1)
        }
    }

    #if os(iOS)
        @Test func theIPhoneAlsoFollowsTheSignificantTimeChange() {
            #expect(LibraryModel.dayChangeNotifications.contains(UIApplication.significantTimeChangeNotification))
        }
    #endif
}
