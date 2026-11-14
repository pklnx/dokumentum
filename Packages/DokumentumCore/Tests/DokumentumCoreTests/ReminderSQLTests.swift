import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// `ReminderStoreReader` (#12, part 3; plan §9): every document with a deadline day, open or done, in the trash or not,
/// with its title; a day that does not read is none; and in SQL, the document rows are read and never a text, PDF or
/// thumbnail table (SwiftData also reads the tag links of the fetched rows, a join of keys only, as for the list).
struct ReminderSQLTests {
    static let otherTables = DocumentListQuerySQLTests.largeTables

    /// Four documents with a deadline (open, done, trashed, an unreadable day) and one without.
    static func seed(_ container: ModelContainer) throws -> (open: UUID, done: UUID, trashed: UUID) {
        let context = ModelContext(container)
        func document(_ title: String, day: String, done: Bool = false, trashed: Bool = false) -> Document {
            let document = Document(title: title)
            document.deadlineDay = day
            document.deadlineLabel = "Pay"
            document.deadlineSetAt = Date(timeIntervalSince1970: 1_793_000_000)
            if done { document.deadlineDoneAt = Date(timeIntervalSince1970: 1_793_100_000) }
            if trashed { document.deletedAt = Date(timeIntervalSince1970: 1_793_200_000) }
            context.insert(document)
            let text = DocumentText(documentID: document.id, extractedText: String(repeating: "x", count: 1_000))
            context.insert(text)
            document.text = text
            return document
        }
        let open = document("Water bill", day: "2026-11-27")
        let done = document("Car insurance", day: "2026-12-01T09:00", done: true)
        let trashed = document("Old bill", day: "2026-11-30", trashed: true)
        _ = document("Garbage", day: "2026-02-30")
        let none = Document(title: "No deadline")
        context.insert(none)
        let tag = DokumentumCore.Tag(name: "Haus")
        context.insert(tag)
        open.tags = [tag]
        try context.save()
        return (open.instanceID, done.instanceID, trashed.instanceID)
    }

    @Test func theReaderGivesEveryDeadlineWithItsState() async throws {
        let container = try TestSupport.makeContainer()
        let ids = try Self.seed(container)
        let read = try await ReminderStoreReader(container: container).read()
        #expect(read.count == 3)
        let open = try #require(read.first { $0.instanceID == ids.open })
        #expect(open.title == "Water bill")
        #expect(open.deadline.day == DeadlineDay(year: 2026, month: 11, day: 27))
        #expect(open.deadline.label == "Pay")
        #expect(open.deadline.setAt == Date(timeIntervalSince1970: 1_793_000_000))
        #expect(open.isOpen)
        let done = try #require(read.first { $0.instanceID == ids.done })
        #expect(done.deadline.day == DeadlineDay(year: 2026, month: 12, day: 1), "the read rule: ten characters")
        #expect(!done.isOpen)
        let trashed = try #require(read.first { $0.instanceID == ids.trashed })
        #expect(trashed.isTrashed && !trashed.isOpen)
    }

    /// Copies sharing an `instanceID` (review A N3 of #222): the oldest `createdAt` stands for them, as in every other
    /// reader (`RowRecords.oldestFirst`), whatever order the store gives. A done copy older than an open one: one done
    /// deadline, no reminder. Two open copies with other titles: one deadline with the oldest copy's title.
    @Test(arguments: [false, true])
    func copiesSharingAnInstanceIDReadAsTheOldest(newestFirst: Bool) async throws {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let doneID = UUID()
        let openID = UUID()
        func copy(_ instanceID: UUID, _ title: String, createdAt: TimeInterval, done: Bool) {
            let document = Document(title: title, createdAt: Date(timeIntervalSince1970: createdAt))
            document.instanceID = instanceID
            document.deadlineDay = "2026-11-27"
            if done { document.deadlineDoneAt = Date(timeIntervalSince1970: 1_793_100_000) }
            context.insert(document)
        }
        let copies: [(UUID, String, TimeInterval, Bool)] = [
            (doneID, "Old done", 1_790_000_000, true), (doneID, "New open", 1_791_000_000, false),
            (openID, "Alt", 1_790_000_000, false), (openID, "Neu", 1_791_000_000, false),
        ]
        for (instanceID, title, createdAt, done) in newestFirst ? copies.reversed() : copies {
            copy(instanceID, title, createdAt: createdAt, done: done)
        }
        try context.save()

        let read = try await ReminderStoreReader(container: container).read()
        #expect(read.count == 2)
        let done = try #require(read.first { $0.instanceID == doneID })
        #expect(done.title == "Old done")
        #expect(!done.isOpen)
        let open = try #require(read.first { $0.instanceID == openID })
        #expect(open.title == "Alt")
    }

    /// Synchronous on purpose: `SQLLog` records the statements of one thread.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func theReaderReadsNoLargeTable() throws {
        let container = try TestSupport.makeContainerOnDisk()
        _ = try Self.seed(container)
        let recording = try SQLLog.Recording()
        let read = try ReminderStoreReader.read(in: container)
        _ = read.map { ($0.title, $0.deadline.label, $0.isTrashed) }
        let statements = try recording.statements()
        #expect(read.count == 3)
        #expect(statements.contains { $0.contains("FROM ZDOCUMENT t0") }, "no SELECT on ZDOCUMENT: \(statements)")
        for statement in statements {
            for table in Self.otherTables {
                #expect(!SQLLog.statement(statement, names: table), "\(statement)")
            }
        }
    }
}
