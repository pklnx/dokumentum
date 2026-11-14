import DokumentumCore
import DokumentumKit
import Foundation
import Testing

/// The store's values as library rows (plan of #3, part 2), including documents that point at tombstones:
/// the mapping follows the chain read only, as the repair's pass 1 would.
struct LibraryMappingTests {
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func summary(
        _ title: String, correspondent: MetadataSnapshot? = nil, type: MetadataSnapshot? = nil,
        tags: [MetadataSnapshot] = [], isInbox: Bool = true, deletedAt: Date? = nil
    ) -> DocumentSummary {
        DocumentSummary(
            instanceID: UUID(), documentID: UUID(), title: title, createdAt: base, modifiedAt: base,
            documentDate: base.addingTimeInterval(3600), isInbox: isInbox, deletedAt: deletedAt, pageCount: 2,
            fileSize: 10, originalFileName: "a.pdf", source: .file, processingState: .pending,
            correspondent: correspondent.map { MetadataReference(instanceID: $0.instanceID, name: $0.name) },
            documentType: type.map { MetadataReference(instanceID: $0.instanceID, name: $0.name) },
            tagInstanceIDs: Set(tags.map(\.instanceID)))
    }

    private static func record(
        _ kind: MetadataKind, _ name: String, id: UUID = UUID(), createdAt: Date = base, mergedInto: UUID? = nil,
        parent: UUID? = nil
    ) -> MetadataSnapshot {
        MetadataSnapshot(
            kind: kind, instanceID: UUID(), id: id, createdAt: createdAt, mergedAt: mergedInto == nil ? nil : base,
            name: name, parentInstanceID: parent, mergedIntoID: mergedInto)
    }

    /// The sidebar selections a snapshot offers for its metadata.
    private static func sidebarSelections(_ snapshot: LibrarySnapshot) -> [LibrarySelection] {
        snapshot.tags.map { .tag($0.instanceID) } + snapshot.correspondents.map { .correspondent($0.instanceID) }
            + snapshot.documentTypes.map { .documentType($0.instanceID) }
    }

    @Test func aRowCarriesTheSummarysFields() throws {
        let stadtwerke = Self.record(.correspondent, "Stadtwerke")
        let invoice = Self.record(.documentType, "Invoice")
        let tax = Self.record(.tag, "Tax")
        let trashedAt = Self.base.addingTimeInterval(60)
        let full = Self.summary("Strom", correspondent: stadtwerke, type: invoice, tags: [tax], isInbox: false)
        let bare = Self.summary("", deletedAt: trashedAt)
        let snapshot = LibraryMapping.snapshot(documents: [full, bare], metadata: [stadtwerke, invoice, tax])

        let row = try #require(snapshot.documents.first { $0.instanceID == full.instanceID })
        #expect(row.title == "Strom")
        #expect(row.documentDate == full.documentDate)
        #expect(row.createdAt == full.createdAt)
        #expect(!row.isInbox)
        #expect(row.deletedAt == nil)
        #expect(row.correspondent == LibraryDocument.Reference(instanceID: stadtwerke.instanceID, name: "Stadtwerke"))
        #expect(row.documentType == LibraryDocument.Reference(instanceID: invoice.instanceID, name: "Invoice"))
        #expect(row.tagIDs == [tax.instanceID])
        #expect(row.fileState == .unknown)
        #expect(row.deadline == nil)
        #expect(row.dismissedSuggestionDay == nil)

        // No correspondent, no type, no tags: the row has none, and the trash date comes along.
        let other = try #require(snapshot.documents.first { $0.instanceID == bare.instanceID })
        #expect(other.correspondent == nil)
        #expect(other.documentType == nil)
        #expect(other.tagIDs.isEmpty)
        #expect(other.deletedAt == trashedAt)
        #expect(snapshot.unlistedTagNames.isEmpty)
    }

    /// The deadline and the dismissed day (#12, part 2a) come along unchanged, done or open, so the Deadlines list,
    /// its count and the detail read them from the row.
    @Test func aRowCarriesTheDeadline() throws {
        let day = try #require(DeadlineDay(storedValue: "2026-11-27"))
        let dismissed = try #require(DeadlineDay(storedValue: "2026-11-20"))
        var open = Self.summary("Wasser")
        open.deadline = DocumentDeadline(day: day, label: "Pay", setAt: Self.base)
        open.dismissedSuggestionDay = dismissed
        var done = Self.summary("Versicherung")
        done.deadline = DocumentDeadline(day: day, setAt: Self.base, doneAt: Self.base.addingTimeInterval(60))
        let snapshot = LibraryMapping.snapshot(documents: [open, done], metadata: [])
        let openRow = try #require(snapshot.documents.first { $0.instanceID == open.instanceID })
        #expect(openRow.deadline == open.deadline)
        #expect(openRow.dismissedSuggestionDay == dismissed)
        #expect(openRow.openDeadline == open.deadline)
        let doneRow = try #require(snapshot.documents.first { $0.instanceID == done.instanceID })
        #expect(doneRow.deadline == done.deadline)
        #expect(doneRow.openDeadline == nil)
    }

    @Test func tombstonesAreLeftOutOfTheSidebar() {
        let live = Self.record(.correspondent, "Stadtwerke")
        let tombstone = Self.record(.correspondent, "stadtwerke", mergedInto: live.id)
        let type = Self.record(.documentType, "Invoice")
        let typeTombstone = Self.record(.documentType, "invoice", mergedInto: type.id)
        let tag = Self.record(.tag, "Tax")
        let tagTombstone = Self.record(.tag, "tax", mergedInto: tag.id)
        let snapshot = LibraryMapping.snapshot(
            documents: [], metadata: [live, tombstone, type, typeTombstone, tag, tagTombstone])
        #expect(snapshot.correspondents.map(\.instanceID) == [live.instanceID])
        #expect(snapshot.documentTypes.map(\.instanceID) == [type.instanceID])
        #expect(snapshot.tags.map(\.instanceID) == [tag.instanceID])
    }

    @Test func referencesToMergedTombstonesListUnderTheLiveRecords() throws {
        let stadtwerke = Self.record(.correspondent, "Stadtwerke Musterstadt")
        // Two steps: an older merge into a record that was merged again later.
        let middle = Self.record(.correspondent, "Stadtwerke M.", mergedInto: stadtwerke.id)
        let merged = Self.record(.correspondent, "stadtwerke", mergedInto: middle.id)
        let invoice = Self.record(.documentType, "Invoice")
        let invoiceTombstone = Self.record(.documentType, "Rechnung", mergedInto: invoice.id)
        let tax = Self.record(.tag, "Tax")
        let taxTombstone = Self.record(.tag, "tax", mergedInto: tax.id)
        let document = Self.summary("Strom", correspondent: merged, type: invoiceTombstone, tags: [taxTombstone])
        let snapshot = LibraryMapping.snapshot(
            documents: [document], metadata: [merged, middle, stadtwerke, invoice, invoiceTombstone, tax, taxTombstone])

        let row = try #require(snapshot.documents.first)
        #expect(
            row.correspondent == LibraryDocument.Reference(instanceID: stadtwerke.instanceID, name: stadtwerke.name))
        #expect(row.documentType == LibraryDocument.Reference(instanceID: invoice.instanceID, name: "Invoice"))
        #expect(row.tagIDs == [tax.instanceID])
        #expect(snapshot.unlistedTagNames.isEmpty)

        let tree = TagTree(snapshot.tags)
        for selection in [
            LibrarySelection.correspondent(stadtwerke.instanceID), .documentType(invoice.instanceID),
            .tag(tax.instanceID),
        ] {
            #expect(selection.matches(row, in: tree), "\(selection)")
        }
        let counts = LibraryCounts(snapshot.documents, tree: tree)
        #expect(counts.count(for: .correspondent(stadtwerke.instanceID)) == 1)
        #expect(counts.count(for: .tag(tax.instanceID)) == 1)
    }

    @Test func aChainWithoutALiveEndShowsTheTombstoneAndMatchesNoSidebarEntry() throws {
        let other = Self.record(.correspondent, "Musterbank AG")
        let lost = Self.record(.correspondent, "Stadtwerke", mergedInto: UUID())
        let lostType = Self.record(.documentType, "Rechnung", mergedInto: UUID())
        let lostTag = Self.record(.tag, "Steuer", mergedInto: UUID())
        let tag = Self.record(.tag, "Tax")
        let document = Self.summary("Strom", correspondent: lost, type: lostType, tags: [lostTag])
        let snapshot = LibraryMapping.snapshot(documents: [document], metadata: [other, lost, lostType, lostTag, tag])

        let row = try #require(snapshot.documents.first)
        #expect(row.correspondent == LibraryDocument.Reference(instanceID: lost.instanceID, name: "Stadtwerke"))
        #expect(row.documentType == LibraryDocument.Reference(instanceID: lostType.instanceID, name: "Rechnung"))
        #expect(row.tagIDs == [lostTag.instanceID])
        #expect(snapshot.unlistedTagNames == [lostTag.instanceID: "Steuer"])

        let tree = TagTree(snapshot.tags)
        #expect(tree.tags[lostTag.instanceID] == nil)
        for selection in Self.sidebarSelections(snapshot) {
            #expect(!selection.matches(row, in: tree), "\(selection)")
        }
        #expect(LibrarySelection.inbox.matches(row, in: tree))
        #expect(LibrarySelection.all.matches(row, in: tree))
    }

    /// Pass 2 merges by name, so a loop needs two devices merging both ways; it must still end.
    @Test func aLoopingChainEndsAndMatchesNoSidebarEntry() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = Self.record(.tag, "Haus", id: firstID, mergedInto: secondID)
        let second = Self.record(.tag, "haus", id: secondID, mergedInto: firstID)
        let document = Self.summary("Strom", tags: [first])
        let snapshot = LibraryMapping.snapshot(documents: [document], metadata: [first, second])
        let row = try #require(snapshot.documents.first)
        #expect(row.tagIDs == [first.instanceID])
        #expect(snapshot.tags.isEmpty)
        #expect(snapshot.unlistedTagNames == [first.instanceID: "Haus"])
    }

    /// Before step 16 several records can share the target `id`: the chain goes to the live one that comes
    /// first in `keeperOrder` (oldest `createdAt`, then the smaller `instanceID`), whatever the input order.
    @Test(arguments: 0..<20)
    func aSharedTargetIDResolvesToTheKeeperOrderMinimum(seed: UInt64) throws {
        let sharedID = UUID()
        let newer = Self.record(
            .correspondent, "Stadtwerke (newer)", id: sharedID, createdAt: Self.base.addingTimeInterval(10))
        let oldest = Self.record(.correspondent, "Stadtwerke (oldest)", id: sharedID, createdAt: Self.base)
        let oldTombstone = Self.record(
            .correspondent, "Stadtwerke (merged)", id: sharedID, createdAt: Self.base.addingTimeInterval(-10),
            mergedInto: UUID())
        let tombstone = Self.record(.correspondent, "stadtwerke", mergedInto: sharedID)
        var generator = SeededGenerator(seed: seed)
        let metadata = [newer, oldest, oldTombstone, tombstone].shuffled(using: &generator)
        let snapshot = LibraryMapping.snapshot(
            documents: [Self.summary("Strom", correspondent: tombstone)], metadata: metadata)
        let row = try #require(snapshot.documents.first)
        #expect(row.correspondent?.instanceID == oldest.instanceID)
        #expect(row.correspondent?.name == "Stadtwerke (oldest)")
    }

    @Test func aTagUnderAMergedParentNestsUnderTheLiveParent() {
        let auto = Self.record(.tag, "Auto")
        let autoTombstone = Self.record(.tag, "auto", mergedInto: auto.id)
        let golf = Self.record(.tag, "Golf", parent: autoTombstone.instanceID)
        let orphan = Self.record(.tag, "Polo", parent: UUID())
        let snapshot = LibraryMapping.snapshot(documents: [], metadata: [auto, autoTombstone, golf, orphan])
        let tree = TagTree(snapshot.tags)
        #expect(tree.displayPath(of: golf.instanceID) == "Auto › Golf")
        #expect(tree.roots.contains(orphan.instanceID))
    }
}

/// A deterministic generator for shuffles (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
