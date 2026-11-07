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

/// A reproducible random order for the shuffle test (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
