import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// The due-date suggestion from a stored document's text (#12, part 2b; plan §5, T7): the earliest candidate that is
/// today or later and after the dismissed day (review B3), only for a processed document that is not in the trash; also
/// while it has a deadline, for review N9's comparison (the detail offers it only without one). Dismissals go through
/// `DocumentEditor`, so the tax notice's two candidates are offered one after the other and then none. In-memory
/// stores and fixed days; the SQL proof needs a store file.
@MainActor
struct DocumentTextLoaderTests {
    /// The corpus letters' `createdAt`: 2026-11-14 10:00 UTC.
    private static let createdAt = SyntheticLetters.createdAt
    private static let today = DeadlineDay(year: 2026, month: 11, day: 14)!

    private static func day(_ stored: String) throws -> DeadlineDay {
        try #require(DeadlineDay(storedValue: stored), "\(stored)")
    }

    /// A document with `text`, saved; returns its `instanceID`.
    @discardableResult
    private func insert(
        _ text: String, into container: ModelContainer, state: String = "done", deadline: String = "",
        dismissed: String = "", trashed: Bool = false
    ) throws -> UUID {
        let context = container.mainContext
        let document = Document(title: "Brief", createdAt: Self.createdAt)
        document.processingStateRaw = state
        context.insert(document)
        let stored = DocumentText(documentID: document.id, extractedText: text, createdAt: Self.createdAt)
        context.insert(stored)
        document.text = stored
        document.deadlineDay = deadline
        document.deadlineDismissedDay = dismissed
        if trashed { document.deletedAt = Self.createdAt }
        try context.save()
        return document.instanceID
    }

    private func suggestion(_ instanceID: UUID, in container: ModelContainer, today: DeadlineDay = today) async
        -> DueDateCandidate?
    {
        await DocumentTextLoader(container: container).deadlineSuggestion(instanceID: instanceID, today: today)
    }

    private static let taxNotice = SyntheticLetters.letter("steuerbescheid-zwei-fristen")!.text

    // MARK: The rule

    /// The earliest candidate today or later: a past one is skipped, the kind comes with it.
    @Test func theEarliestCandidateTodayOrLater() async throws {
        let container = try TestSupport.makeContainer()
        let id = try insert("Frist: 10.11.2026\n" + Self.taxNotice, into: container)
        #expect(
            await suggestion(id, in: container) == DueDateCandidate(day: try Self.day("2026-11-27"), kind: .payment))
        #expect(
            await suggestion(id, in: container, today: try Self.day("2026-11-28"))
                == DueDateCandidate(day: try Self.day("2026-12-15"), kind: .deadline))
        #expect(await suggestion(id, in: container, today: try Self.day("2026-12-16")) == nil, "every day has passed")
    }

    /// The tax notice (B3): one dismissal offers the later candidate, a second leaves none. With `!=` in place of `>`
    /// the third load would offer the first one again.
    @Test func theTaxNoticeDismissedTwiceOffersNothing() async throws {
        let container = try TestSupport.makeContainer()
        let id = try insert(Self.taxNotice, into: container)
        let editor = DocumentEditor(context: container.mainContext)
        var offered: [DeadlineDay] = []
        for _ in 0..<3 {
            guard let next = await suggestion(id, in: container) else { break }
            offered.append(next.day)
            #expect(try editor.apply(.dismissDeadlineSuggestion(next.day), to: id) == .saved)
        }
        #expect(offered == [try Self.day("2026-11-27"), try Self.day("2026-12-15")])
        #expect(await suggestion(id, in: container) == nil)
    }

    /// After a dismissal a later day is offered (a new scan that names one), an earlier one is not.
    @Test func aLaterDayAfterADismissalIsOfferedAnEarlierOneIsNot() async throws {
        let container = try TestSupport.makeContainer()
        let later = try insert("Zahlbar bis 04.12.2026", into: container, dismissed: "2026-11-27")
        let earlier = try insert("Zahlbar bis 20.11.2026", into: container, dismissed: "2026-11-27")
        let same = try insert("Zahlbar bis 27.11.2026", into: container, dismissed: "2026-11-27")
        #expect(await suggestion(later, in: container)?.day == (try Self.day("2026-12-04")))
        #expect(await suggestion(earlier, in: container) == nil)
        #expect(await suggestion(same, in: container) == nil)
    }

    // MARK: Which documents

    /// None before processing is done, in the trash, without text or without a document; with a deadline the text's
    /// suggestion is still read (N9), and `DueDateDetector.offers` keeps the detail from offering it.
    @Test func onlyProcessedDocumentsOutsideTheTrash() async throws {
        let container = try TestSupport.makeContainer()
        for state in ["pending", "processing", "classify", "failed"] {
            let id = try insert(Self.taxNotice, into: container, state: state)
            #expect(await suggestion(id, in: container) == nil, "\(state)")
        }
        #expect(await suggestion(try insert(Self.taxNotice, into: container, trashed: true), in: container) == nil)
        #expect(await suggestion(try insert("", into: container), in: container) == nil)
        #expect(await suggestion(UUID(), in: container) == nil)
        let withDeadline = try insert(Self.taxNotice, into: container, deadline: "2026-11-27")
        #expect(await suggestion(withDeadline, in: container)?.day == (try Self.day("2026-11-27")))
    }

    /// Nothing is written: the loader saves no context and changes no field.
    @Test func theLoaderWritesNothing() async throws {
        let container = try TestSupport.makeContainer()
        let id = try insert(Self.taxNotice, into: container)
        let saves = TestSignal()
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
            notification in
            guard let saved = notification.object as? ModelContext, saved.container === container else { return }
            saves.fire()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(await suggestion(id, in: container) != nil)
        #expect(saves.count == 0)
        let document = try #require(try container.mainContext.fetch(FetchDescriptor<Document>()).first)
        #expect(document.deadlineDay.isEmpty && document.deadlineDismissedDay.isEmpty)
    }

    // MARK: SQL

    /// What the loader reads: the one document by `instanceID` and its text row by key, never the file, the thumbnail
    /// or another document's text. Runs under `swift test` only (`SQLLog.isReadable`).
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func onlyThatDocumentAndItsTextAreRead() throws {
        let container = try TestSupport.makeContainerOnDisk()
        try insert("Zahlbar bis 27.11.2026", into: container)
        let id = try insert(Self.taxNotice, into: container)
        try insert("Frist: 04.12.2026", into: container)

        let recording = try SQLLog.Recording()
        let found = DocumentTextLoader.deadlineSuggestion(instanceID: id, today: Self.today, in: container)
        let statements = try recording.statements()

        #expect(found?.day == DeadlineDay(year: 2026, month: 11, day: 27))
        let documentReads = statements.filter { $0.contains("FROM ZDOCUMENT t0") }
        #expect(documentReads.count == 1, "\(statements)")
        // The condition, not the column list, names `instanceID`: a fetch of every document fails here.
        let conditions = documentReads.map { read in
            read.range(of: " WHERE ").map { String(read[$0.upperBound...]) } ?? ""
        }
        #expect(conditions.allSatisfy { $0.contains("ZINSTANCEID") }, "not by instanceID: \(documentReads)")
        let textReads = statements.filter { SQLLog.statement($0, names: "ZDOCUMENTTEXT") }
        #expect(textReads.count == 1, "\(textReads)")
        #expect(textReads.allSatisfy { $0.contains("WHERE  t0.Z_PK IN  (?)") }, "not by key: \(textReads)")
        for statement in statements {
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTFILE"), "\(statement)")
            #expect(!SQLLog.statement(statement, names: "ZDOCUMENTTHUMBNAIL"), "\(statement)")
        }
    }
}
