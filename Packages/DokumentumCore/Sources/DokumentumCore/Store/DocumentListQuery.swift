import DokumentumKit
import Foundation
import SwiftData

/// A correspondent, document type or tag as a list row shows it.
public struct MetadataReference: Hashable, Sendable {
    public var instanceID: UUID
    public var name: String

    public init(instanceID: UUID, name: String) {
        self.instanceID = instanceID
        self.name = name
    }
}

/// One row of a document list: a value without the extracted text and without the PDF or the thumbnail,
/// so code that shows a list cannot reach them without a separate fetch. Rows are keyed by `instanceID`:
/// `id` can repeat until step 16.
public struct DocumentSummary: Hashable, Sendable, Identifiable {
    public var instanceID: UUID
    public var documentID: UUID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var documentDate: Date
    public var isInbox: Bool
    /// Set while the document is in the trash.
    public var deletedAt: Date?
    public var pageCount: Int
    public var fileSize: Int
    public var originalFileName: String
    public var source: DocumentSource
    public var processingState: ProcessingState
    public var correspondent: MetadataReference?
    public var documentType: MetadataReference?
    /// The `instanceID`s of the document's tags.
    public var tagInstanceIDs: Set<UUID>

    public var id: UUID { instanceID }

    public init(
        instanceID: UUID,
        documentID: UUID,
        title: String,
        createdAt: Date,
        modifiedAt: Date,
        documentDate: Date,
        isInbox: Bool,
        deletedAt: Date?,
        pageCount: Int,
        fileSize: Int,
        originalFileName: String,
        source: DocumentSource,
        processingState: ProcessingState,
        correspondent: MetadataReference?,
        documentType: MetadataReference?,
        tagInstanceIDs: Set<UUID>
    ) {
        self.instanceID = instanceID
        self.documentID = documentID
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.documentDate = documentDate
        self.isInbox = isInbox
        self.deletedAt = deletedAt
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.originalFileName = originalFileName
        self.source = source
        self.processingState = processingState
        self.correspondent = correspondent
        self.documentType = documentType
        self.tagInstanceIDs = tagInstanceIDs
    }

    /// The list order: newest `documentDate` first, then newest `createdAt`, then the smaller
    /// `instanceID`, so the order is the same on every run and device.
    public static func listOrder(_ lhs: DocumentSummary, _ rhs: DocumentSummary) -> Bool {
        if lhs.documentDate != rhs.documentDate { return lhs.documentDate > rhs.documentDate }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.instanceID.uuidString < rhs.instanceID.uuidString
    }
}

/// The only list fetch of documents (plan.md, section 3.2, and #2's DW4): it reads the scalars a row shows
/// and the names of correspondent, type and tags, never `extractedText`, the PDF or the thumbnail.
public enum DocumentListQuery {
    /// Which documents a list shows.
    public enum Filter: Hashable, Sendable {
        /// Not trashed and in the inbox.
        case inbox
        /// Not trashed.
        case all
        /// Trashed only.
        case trash
    }

    /// The scalars a row shows. `extractedText` is not among them; `SchemaTests` and
    /// `DocumentListQueryTests` check that every other attribute a row needs is.
    public nonisolated(unsafe) static let fetchedProperties: [PartialKeyPath<Document>] = [
        \.id, \.instanceID, \.title, \.createdAt, \.modifiedAt, \.documentDate, \.isInbox, \.deletedAt,
        \.pageCount, \.fileSize, \.originalFileName, \.sourceRaw, \.processingStateRaw,
    ]

    /// The relationships a row shows. Never `file` or `thumbnail`.
    public nonisolated(unsafe) static let prefetchedRelationships: [PartialKeyPath<Document>] = [
        \.correspondent, \.documentType, \.tags,
    ]

    /// The descriptor of the list fetch for `filter`.
    public static func descriptor(_ filter: Filter) -> FetchDescriptor<Document> {
        var descriptor = FetchDescriptor<Document>(
            predicate: predicate(filter),
            sortBy: [SortDescriptor(\.documentDate, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.propertiesToFetch = fetchedProperties
        descriptor.relationshipKeyPathsForPrefetching = prefetchedRelationships
        return descriptor
    }

    /// The rows for `filter`, in `DocumentSummary.listOrder`.
    public static func fetch(_ filter: Filter, in context: ModelContext) throws -> [DocumentSummary] {
        try context.fetch(descriptor(filter)).map(summary(of:)).sorted(by: DocumentSummary.listOrder)
    }

    static func predicate(_ filter: Filter) -> Predicate<Document> {
        switch filter {
        case .inbox:
            return #Predicate<Document> { $0.deletedAt == nil && $0.isInbox }
        case .all:
            return #Predicate<Document> { $0.deletedAt == nil }
        case .trash:
            return #Predicate<Document> { $0.deletedAt != nil }
        }
    }

    /// Reads only `fetchedProperties` and `prefetchedRelationships`.
    static func summary(of document: Document) -> DocumentSummary {
        DocumentSummary(
            instanceID: document.instanceID,
            documentID: document.id,
            title: document.title,
            createdAt: document.createdAt,
            modifiedAt: document.modifiedAt,
            documentDate: document.documentDate,
            isInbox: document.isInbox,
            deletedAt: document.deletedAt,
            pageCount: document.pageCount,
            fileSize: document.fileSize,
            originalFileName: document.originalFileName,
            source: document.source,
            processingState: document.processingState,
            correspondent: document.correspondent.map { MetadataReference(instanceID: $0.instanceID, name: $0.name) },
            documentType: document.documentType.map { MetadataReference(instanceID: $0.instanceID, name: $0.name) },
            tagInstanceIDs: Set((document.tags ?? []).map(\.instanceID)))
    }
}
