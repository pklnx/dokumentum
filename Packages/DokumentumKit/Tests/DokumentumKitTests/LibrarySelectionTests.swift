import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

struct LibrarySelectionTests {
    private static func id(_ prefix: Int, _ number: Int) -> UUID {
        UUID(uuidString: String(format: "%08d-0000-4000-8000-%012d", prefix, number))!
    }

    // Tags: Auto › Golf › Werkstatt, Tax.
    static let auto = id(1, 1)
    static let golf = id(1, 2)
    static let werkstatt = id(1, 3)
    static let tax = id(1, 4)
    static let tree = TagTree([
        TagRecord(instanceID: auto, parentInstanceID: nil, name: "Auto"),
        TagRecord(instanceID: golf, parentInstanceID: auto, name: "Golf"),
        TagRecord(instanceID: werkstatt, parentInstanceID: golf, name: "Werkstatt"),
        TagRecord(instanceID: tax, parentInstanceID: nil, name: "Tax"),
    ])
    static let bank = LibraryDocument.Reference(instanceID: id(2, 1), name: "Musterbank AG")
    static let utility = LibraryDocument.Reference(instanceID: id(2, 2), name: "Stadtwerke Musterstadt")
    static let invoice = LibraryDocument.Reference(instanceID: id(3, 1), name: "Invoice")

    private static func day(_ number: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(number) * 86_400)
    }

    private static func document(
        _ number: Int, inbox: Bool = false, trashed: Bool = false, tags: Set<UUID> = [],
        correspondent: LibraryDocument.Reference? = nil, type: LibraryDocument.Reference? = nil,
        date: Int? = nil, created: Int? = nil
    ) -> LibraryDocument {
        LibraryDocument(
            instanceID: id(9, number), title: "Document \(number)", documentDate: day(date ?? number),
            createdAt: day(created ?? number), isInbox: inbox, deletedAt: trashed ? day(100) : nil,
            correspondent: correspondent, documentType: type, tagIDs: tags)
    }

    static let documents = [
        document(1, inbox: true, tags: [tax], correspondent: utility, type: invoice),
        document(2, tags: [auto], correspondent: bank),
        document(3, tags: [golf]),
        document(4, inbox: true, tags: [werkstatt, auto], correspondent: bank, type: invoice),
        document(5, inbox: true, trashed: true, tags: [tax, golf], correspondent: utility, type: invoice),
        document(6),
    ]

    private func numbers(_ selection: LibrarySelection) -> [Int] {
        selection.filter(Self.documents, in: Self.tree).map { Int($0.instanceID.uuidString.suffix(12))! }
    }

    @Test func eachSelectionFiltersItsDocumentsNewestFirst() {
        #expect(numbers(.inbox) == [4, 1])
        #expect(numbers(.all) == [6, 4, 3, 2, 1])
        #expect(numbers(.trash) == [5])
        #expect(numbers(.tag(Self.tax)) == [1])
        #expect(numbers(.correspondent(Self.bank.instanceID)) == [4, 2])
        #expect(numbers(.correspondent(Self.utility.instanceID)) == [1])
        #expect(numbers(.documentType(Self.invoice.instanceID)) == [4, 1])
        #expect(numbers(.tag(Self.id(1, 99))).isEmpty)
    }

    @Test func aTagIncludesItsWholeSubtree() {
        #expect(numbers(.tag(Self.auto)) == [4, 3, 2])
        #expect(numbers(.tag(Self.golf)) == [4, 3])
        #expect(numbers(.tag(Self.werkstatt)) == [4])
    }

    @Test func trashedDocumentsMatchOnlyTheTrash() {
        let trashed = Self.documents[4]
        #expect(trashed.isTrashed)
        let others: [LibrarySelection] = [
            .inbox, .all, .tag(Self.tax), .tag(Self.golf), .tag(Self.auto),
            .correspondent(Self.utility.instanceID), .documentType(Self.invoice.instanceID),
        ]
        for selection in others {
            #expect(!selection.matches(trashed, in: Self.tree), "\(selection)")
        }
        #expect(LibrarySelection.trash.matches(trashed, in: Self.tree))
        #expect(!LibrarySelection.trash.matches(Self.documents[0], in: Self.tree))
    }

    @Test func eachCountIsTheSizeOfItsFilter() {
        let counts = LibraryCounts(Self.documents, tree: Self.tree)
        var selections: [LibrarySelection] = [.inbox, .all, .trash]
        selections += Self.tree.tags.keys.map(LibrarySelection.tag)
        selections += [Self.bank, Self.utility].map { .correspondent($0.instanceID) }
        selections.append(.documentType(Self.invoice.instanceID))
        for selection in selections {
            #expect(counts.count(for: selection) == numbers(selection).count, "\(selection)")
        }
        #expect(counts.count(for: .inbox) == 2)
        #expect(counts.count(for: .all) == 5)
        #expect(counts.count(for: .trash) == 1)
        // Document 4 has Werkstatt and Auto: Auto counts it once.
        #expect(counts.count(for: .tag(Self.auto)) == 3)
        #expect(counts.count(for: .tag(Self.golf)) == 2)
        #expect(counts.count(for: .tag(Self.tax)) == 1)
    }

    @Test func countsFollowATagCycleWithoutHanging() {
        let a = Self.id(4, 1)
        let b = Self.id(4, 2)
        let tree = TagTree([
            TagRecord(instanceID: a, parentInstanceID: b, name: "A"),
            TagRecord(instanceID: b, parentInstanceID: a, name: "B"),
        ])
        let documents = [Self.document(1, tags: [a]), Self.document(2, tags: [a, b])]
        let counts = LibraryCounts(documents, tree: tree)
        #expect(counts.count(for: .tag(a)) == 2)
        #expect(counts.count(for: .tag(b)) == 2)
        #expect(LibrarySelection.tag(b).filter(documents, in: tree).count == 2)
    }

    @Test func theOrderBreaksTiesByCreatedAtThenInstanceIDUnderShuffles() {
        // Equal document dates; 10 and 11 also share createdAt, so instanceID decides.
        let tied = [
            Self.document(10, date: 1, created: 5), Self.document(11, date: 1, created: 5),
            Self.document(12, date: 1, created: 7), Self.document(13, date: 2, created: 1),
            Self.document(14, date: 1, created: 6),
        ]
        let expected = [13, 12, 14, 10, 11].map { Self.id(9, $0) }
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<50 {
            let shuffled = tied.shuffled(using: &generator)
            let sorted = LibrarySelection.all.filter(shuffled, in: Self.tree).map(\.instanceID)
            #expect(sorted == expected)
        }
    }

    // MARK: Deadlines (#12, part 2a)

    private static let today = DeadlineDay(year: 2026, month: 11, day: 14)!

    /// A document with a deadline `offset` days from `today`, done or not, titled "Document <number>" unless `title`
    /// is given.
    private static func withDeadline(
        _ number: Int, offset: Int, done: Bool = false, trashed: Bool = false, title: String? = nil, date: Int? = nil
    ) -> LibraryDocument {
        var document = document(number, trashed: trashed, date: date)
        if let title { document.title = title }
        document.deadline = DocumentDeadline(
            day: today.adding(days: offset)!, label: "Pay", doneAt: done ? day(1) : nil)
        return document
    }

    /// 20: overdue, 21: today, 22: in 3 days, 23: in 4 days, 24: done, 25: trashed, 26: none, 27: in 10 days.
    private static let deadlineDocuments = [
        withDeadline(23, offset: 4), withDeadline(20, offset: -2), withDeadline(24, offset: -5, done: true),
        withDeadline(22, offset: 3), withDeadline(25, offset: -1, trashed: true), document(26),
        withDeadline(21, offset: 0), withDeadline(27, offset: 10),
    ]

    private static func numbers(_ documents: [LibraryDocument]) -> [Int] {
        documents.map { Int($0.instanceID.uuidString.suffix(12))! }
    }

    /// Deadlines lists the open deadlines only: not a done one, not a trashed one, not a document without one.
    @Test func deadlinesListsOpenDeadlinesOnly() {
        let listed = LibrarySelection.upcoming.filter(Self.deadlineDocuments, in: Self.tree)
        #expect(Self.numbers(listed) == [20, 21, 22, 23, 27])
        for document in Self.deadlineDocuments {
            let open = document.deadline.map { !$0.isDone } ?? false
            #expect(
                LibrarySelection.upcoming.matches(document, in: Self.tree) == (open && !document.isTrashed),
                "\(document.title)")
        }
        // Every document of `documents` has no deadline.
        #expect(LibrarySelection.upcoming.filter(Self.documents, in: Self.tree).isEmpty)
    }

    /// By day, the overdue first; on one day by title, then by `instanceID`, whatever the input order.
    @Test func deadlinesAreOrderedByDayThenTitleThenInstanceID() {
        // 30–33 share a day; 31 and 33 also share a title, so instanceID decides. Their document dates run the other
        // way, so the list order (newest document first) would give another result.
        let documents = [
            Self.withDeadline(30, offset: 5, title: "Water", date: 1),
            Self.withDeadline(31, offset: 5, title: "Electricity", date: 2),
            Self.withDeadline(32, offset: 5, title: "Bank", date: 3),
            Self.withDeadline(33, offset: 5, title: "Electricity", date: 4),
            Self.withDeadline(34, offset: -3, title: "Zoo", date: 5),
            Self.withDeadline(35, offset: 6, title: "Apple", date: 6),
        ]
        let expected = [34, 32, 31, 33, 30, 35]
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<50 {
            let sorted = LibrarySelection.upcoming.filter(documents.shuffled(using: &generator), in: Self.tree)
            #expect(Self.numbers(sorted) == expected)
        }
    }

    /// Every other list keeps its order (newest document first) when documents have deadlines.
    @Test func theOtherListsKeepTheirOrder() {
        let all = LibrarySelection.all.filter(Self.deadlineDocuments, in: Self.tree)
        #expect(Self.numbers(all) == [27, 26, 24, 23, 22, 21, 20])
        #expect(all == Self.deadlineDocuments.filter { !$0.isTrashed }.sorted(by: LibraryDocument.listOrder))
    }

    /// The count (maintainer decision Q7): overdue plus due within the lead time. With 3 days a deadline in 3 days
    /// counts and one in 4 does not; with 0 the overdue one and today's. The list shows every open deadline anyway.
    @Test func theDeadlinesCountIsOverduePlusDueWithinTheLeadTime() {
        let documents = Self.deadlineDocuments
        let withThree = LibraryCounts(documents, tree: Self.tree, today: Self.today, deadlineLeadDays: 3)
        #expect(withThree.count(for: .upcoming) == 3)
        let withZero = LibraryCounts(documents, tree: Self.tree, today: Self.today, deadlineLeadDays: 0)
        #expect(withZero.count(for: .upcoming) == 2)
        let withTen = LibraryCounts(documents, tree: Self.tree, today: Self.today, deadlineLeadDays: 10)
        #expect(withTen.count(for: .upcoming) == 5)
        // The default is 3 days, until part 3 gives each device its own lead time.
        #expect(LibraryCounts.defaultDeadlineLeadDays == 3)
        #expect(LibraryCounts(documents, tree: Self.tree, today: Self.today) == withThree)
        // Without a day, no count; the list is the same.
        #expect(LibraryCounts(documents, tree: Self.tree).count(for: .upcoming) == 0)
        #expect(LibrarySelection.upcoming.filter(documents, in: Self.tree).count == 5)
        // The next day the deadline in 4 days is in 3.
        let tomorrow = LibraryCounts(
            documents, tree: Self.tree, today: Self.today.adding(days: 1)!, deadlineLeadDays: 3)
        #expect(tomorrow.count(for: .upcoming) == 4)
    }

    // MARK: VoiceOver

    private static let strings = LibraryDocument.AccessibilityStrings(
        date: { _ in "9 May 2026" },
        tags: { "tags: " + $0.joined(separator: " and ") },
        inInbox: "in inbox")

    @Test func theVoiceOverLabelReadsEveryPartInOrder() {
        let document = Self.documents[3]
        let label = document.accessibilityLabel(
            displayTitle: "Electricity bill", tagPaths: ["Auto", "Auto › Golf › Werkstatt"], strings: Self.strings)
        #expect(
            label
                == "Electricity bill, 9 May 2026, Musterbank AG, Invoice, "
                + "tags: Auto and Auto › Golf › Werkstatt, in inbox")
    }

    @Test func theVoiceOverLabelLeavesOutEmptyParts() {
        var document = Self.documents[5]
        #expect(
            document.accessibilityLabel(displayTitle: "Untitled document", tagPaths: [], strings: Self.strings)
                == "Untitled document, 9 May 2026")
        document.correspondent = LibraryDocument.Reference(instanceID: Self.id(2, 9), name: "  ")
        #expect(
            document.accessibilityLabel(displayTitle: "Letter", tagPaths: ["", " "], strings: Self.strings)
                == "Letter, 9 May 2026")
    }
}
