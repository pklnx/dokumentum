import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The light list query (#2, DW4): the rows the list shows, and nothing large.
@MainActor
struct DocumentListQueryTests {
    private static let day: TimeInterval = 86_400
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func theDescriptorNeverPrefetchesALargeRecord() {
        for filter in [DocumentListQuery.Filter.inbox, .all, .trash] {
            let prefetched = DocumentListQuery.descriptor(filter).relationshipKeyPathsForPrefetching
            #expect(prefetched == [\Document.correspondent, \Document.documentType, \Document.tags])
            for large: PartialKeyPath<Document> in [\.file, \.thumbnail, \.text] {
                #expect(!prefetched.contains(large))
            }
        }
    }

    /// A row value has no field for the text, the PDF or the thumbnail, so list code cannot reach them.
    @Test func aSummaryHasNoLargeField() {
        let summary = DocumentSummary(
            instanceID: UUID(), documentID: UUID(), title: "", createdAt: .now, modifiedAt: .now, documentDate: .now,
            isInbox: true, deletedAt: nil, pageCount: 0, fileSize: 0, originalFileName: "", source: .file,
            processingState: .pending, correspondent: nil, documentType: nil, tagInstanceIDs: [])
        let labels = Set(Mirror(reflecting: summary).children.compactMap(\.label))
        for forbidden in ["extractedText", "text", "pdfData", "imageData", "file", "thumbnail"] {
            #expect(!labels.contains(forbidden), "\(forbidden)")
        }
        // 16, and the deadline and the dismissed day of #12 (plain values, no large field).
        #expect(labels.count == 18)
    }

    private struct Fixture {
        let container: ModelContainer
        let inbox: Document
        let filed: Document
        let trashed: Document
        let withoutRecords: Document
        let correspondent: Correspondent
        let type: DocumentType
        let tags: [DokumentumCore.Tag]
    }

    private func fixture() throws -> Fixture {
        let container = try TestSupport.makeContainer()
        let context = ModelContext(container)
        let correspondent = Correspondent(name: "Stadtwerke")
        let type = DocumentType(name: "Rechnung")
        let tags = [DokumentumCore.Tag(name: "Haus"), DokumentumCore.Tag(name: "Strom")]
        let inbox = Document(title: "Strom", createdAt: Self.base)
        inbox.documentDate = Self.base.addingTimeInterval(3 * Self.day)
        inbox.pageCount = 2
        inbox.fileSize = 1234
        inbox.originalFileName = "strom.pdf"
        inbox.source = .scan
        inbox.processingState = .done
        // A deadline with a later build's suffix (#12, part 2a): the row reads the day by the read rule.
        (inbox.deadlineDay, inbox.deadlineLabel, inbox.deadlineSetAt) = ("2026-11-27T14:00", "Pay", Self.base)
        inbox.deadlineDismissedDay = "2026-11-20"
        let filed = Document(title: "Vertrag", createdAt: Self.base)
        filed.documentDate = Self.base.addingTimeInterval(2 * Self.day)
        filed.isInbox = false
        let trashed = Document(title: "Alt", createdAt: Self.base)
        trashed.deletedAt = Self.base.addingTimeInterval(9 * Self.day)
        // No file, thumbnail or text yet: still downloading.
        let withoutRecords = Document(title: "Unterwegs", createdAt: Self.base)
        withoutRecords.documentDate = Self.base.addingTimeInterval(1 * Self.day)
        for model in [correspondent, type, tags[0], tags[1], inbox, filed, trashed, withoutRecords]
            as [any PersistentModel]
        {
            context.insert(model)
        }
        inbox.correspondent = correspondent
        inbox.documentType = type
        inbox.tags = tags
        for document in [inbox, filed, trashed] {
            let file = DocumentFile(documentID: document.id, pdfData: Data([1, 2, 3]))
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: Data([4]))
            let text = DocumentText(documentID: document.id, extractedText: "Text")
            context.insert(file)
            context.insert(thumbnail)
            context.insert(text)
            document.file = file
            document.thumbnail = thumbnail
            document.text = text
        }
        try context.save()
        return Fixture(
            container: container, inbox: inbox, filed: filed, trashed: trashed, withoutRecords: withoutRecords,
            correspondent: correspondent, type: type, tags: tags)
    }

    @Test func theRowsCarryTheDocumentsValues() throws {
        let fixture = try fixture()
        let rows = try DocumentListQuery.fetch(.inbox, in: ModelContext(fixture.container))
        let row = try #require(rows.first { $0.instanceID == fixture.inbox.instanceID })
        #expect(
            row
                == DocumentSummary(
                    instanceID: fixture.inbox.instanceID, documentID: fixture.inbox.id, title: "Strom",
                    createdAt: Self.base, modifiedAt: Self.base,
                    documentDate: Self.base.addingTimeInterval(3 * Self.day),
                    isInbox: true, deletedAt: nil, pageCount: 2, fileSize: 1234, originalFileName: "strom.pdf",
                    source: .scan, processingState: .done,
                    correspondent: MetadataReference(instanceID: fixture.correspondent.instanceID, name: "Stadtwerke"),
                    documentType: MetadataReference(instanceID: fixture.type.instanceID, name: "Rechnung"),
                    tagInstanceIDs: Set(fixture.tags.map(\.instanceID)),
                    deadline: DocumentDeadline(
                        day: try #require(DeadlineDay(storedValue: "2026-11-27")), label: "Pay", setAt: Self.base),
                    dismissedSuggestionDay: DeadlineDay(storedValue: "2026-11-20")))
        // A document without a deadline has none.
        let filed = try DocumentListQuery.fetch(.all, in: ModelContext(fixture.container)).first {
            $0.instanceID == fixture.filed.instanceID
        }
        #expect(filed?.deadline == nil)
        #expect(filed?.dismissedSuggestionDay == nil)
        #expect(row.id == fixture.inbox.instanceID, "rows are keyed by instanceID, never by the shared id")
    }

    @Test func eachFilterListsItsDocumentsInListOrder() throws {
        let fixture = try fixture()
        let context = ModelContext(fixture.container)
        #expect(
            try DocumentListQuery.fetch(.inbox, in: context).map(\.instanceID) == [
                fixture.inbox.instanceID, fixture.withoutRecords.instanceID,
            ])
        #expect(
            try DocumentListQuery.fetch(.all, in: context).map(\.instanceID) == [
                fixture.inbox.instanceID, fixture.filed.instanceID, fixture.withoutRecords.instanceID,
            ])
        let trash = try DocumentListQuery.fetch(.trash, in: context)
        #expect(trash.map(\.instanceID) == [fixture.trashed.instanceID])
        #expect(trash.first?.deletedAt == Self.base.addingTimeInterval(9 * Self.day))
    }

    /// A document whose file, thumbnail and text have not arrived still lists ("still downloading").
    @Test func aDocumentWithoutItsRecordsStillLists() throws {
        let fixture = try fixture()
        #expect(fixture.withoutRecords.file == nil && fixture.withoutRecords.text == nil)
        let rows = try DocumentListQuery.fetch(.all, in: ModelContext(fixture.container))
        #expect(rows.contains { $0.instanceID == fixture.withoutRecords.instanceID })
    }

    /// Equal dates fall back to the smaller `instanceID`, whatever the insertion order.
    @Test func tiesAreBrokenByInstanceID() throws {
        for _ in 0..<5 {
            let container = try TestSupport.makeContainer()
            let context = ModelContext(container)
            let documents = (0..<6).map { _ in Document(title: "Same", createdAt: Self.base) }
            for document in documents.shuffled() {
                document.documentDate = Self.base
                context.insert(document)
            }
            try context.save()
            let rows = try DocumentListQuery.fetch(.all, in: ModelContext(container))
            #expect(rows.map(\.instanceID.uuidString) == documents.map(\.instanceID.uuidString).sorted())
        }
    }
}
