import Foundation
import SwiftData

// The check before a background writer's save (#56, moved here for #4, part 5): the repair (`RepairRun`) and the
// processing queue (`ProcessingQueue`) both follow one principle, **a background writer never writes over a row
// state it has not read**. Right before it saves, it reads its rows again in another context (`RowState.read`) and
// compares every field with what it read; if one differs, it writes nothing.

/// One record of the store, named by its entity and `instanceID`.
struct RowKey: Hashable, Sendable {
    enum Entity: String, Hashable, Sendable, CaseIterable {
        case document, tag, correspondent, documentType, file, thumbnail, text
    }

    let entity: Entity
    let instanceID: UUID
}

/// Every value of one row that a save can write, related records as `instanceID`s: what a writer read, and what the
/// store holds right before it saves (`RepairRun`, `ProcessingQueue`). `RowStateTests` checks against the schema that every
/// attribute and relationship is either here or named in `RowState.excluded` with its reason, so a new field
/// cannot be forgotten.
///
/// Why whole rows: a `ModelContext` whose row became stale writes back the **whole row** when it saves, not the
/// fields it changed (measured on #56: on the optimistic-locking conflict Core Data re-selects the row, and the
/// `UPDATE` then sets every field the stale object holds). So a writer checks every field of every row it writes.
enum RowState: Equatable, Sendable {
    struct DocumentRow: Equatable, Sendable {
        var id: UUID
        var instanceID: UUID
        var title: String
        var createdAt: Date
        var modifiedAt: Date
        var documentDate: Date
        var isInbox: Bool
        var pageCount: Int
        var fileSize: Int
        var textSourceRaw: String
        var processingStateRaw: String
        var processingDeviceID: String
        var processingClaimedAt: Date?
        var contentHash: String
        var originalFileName: String
        var sourceRaw: String
        var deletedAt: Date?
        var correspondent: UUID?
        var documentType: UUID?
        var tags: Set<UUID>
        /// The linked blobs, by identifier: read from the document row without loading the blob, so a link, an
        /// unlink or a swap saved by another context shows here (review A of #56, D2).
        var file: PersistentIdentifier?
        var thumbnail: PersistentIdentifier?
        var text: PersistentIdentifier?
    }

    struct TagRow: Equatable, Sendable {
        var id: UUID
        var instanceID: UUID
        var name: String
        var colorHex: String
        var createdAt: Date
        var mergedIntoID: UUID?
        var mergedAt: Date?
        var parent: UUID?
    }

    /// A correspondent or a document type.
    struct MetadataRow: Equatable, Sendable {
        var id: UUID
        var instanceID: UUID
        var name: String
        var createdAt: Date
        var mergedIntoID: UUID?
        var mergedAt: Date?
    }

    /// A file, thumbnail or text; `extractedText` only for a text.
    struct BlobRow: Equatable, Sendable {
        var id: UUID
        var instanceID: UUID
        var createdAt: Date
        var documentID: UUID?
        var document: UUID?
        var extractedText: String?
    }

    case document(DocumentRow)
    case tag(TagRow)
    case metadata(MetadataRow)
    case blob(BlobRow)

    /// What a row state leaves out, per entity, and why: to-many relationships are inverses whose other side is
    /// captured (`Document.correspondent`, `Document.tags`, `Tag.parent`), and the external-storage data is not
    /// compared (the repair only links an unlinked blob, whose data nothing writes; a stale write of it remains a
    /// residual). A blob link is captured on both sides: another save that links a blob the pass never read
    /// changes only the document's row as far as the pass can see.
    static let excluded: [String: Set<String>] = [
        "Document": [],
        "Tag": ["children", "documents"],
        "Correspondent": ["documents"],
        "DocumentType": ["documents"],
        "DocumentFile": ["pdfData"],
        "DocumentThumbnail": ["imageData"],
        "DocumentText": [],
    ]

    // MARK: Capture

    static func capture(_ document: Document) -> RowState {
        .document(
            DocumentRow(
                id: document.id, instanceID: document.instanceID, title: document.title, createdAt: document.createdAt,
                modifiedAt: document.modifiedAt, documentDate: document.documentDate, isInbox: document.isInbox,
                pageCount: document.pageCount, fileSize: document.fileSize, textSourceRaw: document.textSourceRaw,
                processingStateRaw: document.processingStateRaw, processingDeviceID: document.processingDeviceID,
                processingClaimedAt: document.processingClaimedAt, contentHash: document.contentHash,
                originalFileName: document.originalFileName, sourceRaw: document.sourceRaw,
                deletedAt: document.deletedAt, correspondent: document.correspondent?.instanceID,
                documentType: document.documentType?.instanceID, tags: Set((document.tags ?? []).map(\.instanceID)),
                file: document.file?.persistentModelID, thumbnail: document.thumbnail?.persistentModelID,
                text: document.text?.persistentModelID))
    }

    static func capture(_ tag: Tag) -> RowState {
        .tag(
            TagRow(
                id: tag.id, instanceID: tag.instanceID, name: tag.name, colorHex: tag.colorHex,
                createdAt: tag.createdAt,
                mergedIntoID: tag.mergedIntoID, mergedAt: tag.mergedAt, parent: tag.parent?.instanceID))
    }

    static func capture(_ record: Correspondent) -> RowState {
        .metadata(
            MetadataRow(
                id: record.id, instanceID: record.instanceID, name: record.name, createdAt: record.createdAt,
                mergedIntoID: record.mergedIntoID, mergedAt: record.mergedAt))
    }

    static func capture(_ record: DocumentType) -> RowState {
        .metadata(
            MetadataRow(
                id: record.id, instanceID: record.instanceID, name: record.name, createdAt: record.createdAt,
                mergedIntoID: record.mergedIntoID, mergedAt: record.mergedAt))
    }

    static func capture(_ file: DocumentFile) -> RowState {
        .blob(
            BlobRow(
                id: file.id, instanceID: file.instanceID, createdAt: file.createdAt, documentID: file.documentID,
                document: file.document?.instanceID))
    }

    static func capture(_ thumbnail: DocumentThumbnail) -> RowState {
        .blob(
            BlobRow(
                id: thumbnail.id, instanceID: thumbnail.instanceID, createdAt: thumbnail.createdAt,
                documentID: thumbnail.documentID, document: thumbnail.document?.instanceID))
    }

    static func capture(_ text: DocumentText) -> RowState {
        .blob(
            BlobRow(
                id: text.id, instanceID: text.instanceID, createdAt: text.createdAt, documentID: text.documentID,
                document: text.document?.instanceID, extractedText: text.extractedText))
    }

    /// The state of every record in `records`.
    static func capture(_ records: RowRecords) -> [RowKey: RowState] {
        var states: [RowKey: RowState] = [:]
        for (id, record) in records.documents { states[RowKey(entity: .document, instanceID: id)] = capture(record) }
        for (id, record) in records.tags { states[RowKey(entity: .tag, instanceID: id)] = capture(record) }
        for (id, record) in records.correspondents {
            states[RowKey(entity: .correspondent, instanceID: id)] = capture(record)
        }
        for (id, record) in records.documentTypes {
            states[RowKey(entity: .documentType, instanceID: id)] = capture(record)
        }
        for (id, record) in records.files { states[RowKey(entity: .file, instanceID: id)] = capture(record) }
        for (id, record) in records.thumbnails { states[RowKey(entity: .thumbnail, instanceID: id)] = capture(record) }
        for (id, record) in records.texts { states[RowKey(entity: .text, instanceID: id)] = capture(record) }
        return states
    }

    /// The current state of `keys` in the store, read through a new context. Blobs are read only while unlinked:
    /// no background writer writes a linked blob's row, and a blob linked meanwhile reads as absent. A document's
    /// links to its blobs are part of its own row, read without loading them.
    static func read(_ keys: Set<RowKey>, in container: ModelContainer) throws -> [RowKey: RowState] {
        try capture(RowRecords.read(keys, in: ModelContext(container)))
    }
}

/// Records by `instanceID`: the handles the repair's operations name, and what `RowState.read` captures. Records
/// sharing an `instanceID` (a copied record) keep the first one read, as `RepairPlan.apply` indexes them, so a
/// check and the write it allows meet the same record.
struct RowRecords {
    var documents: [UUID: Document] = [:]
    var tags: [UUID: Tag] = [:]
    var correspondents: [UUID: Correspondent] = [:]
    var documentTypes: [UUID: DocumentType] = [:]
    var files: [UUID: DocumentFile] = [:]
    var thumbnails: [UUID: DocumentThumbnail] = [:]
    var texts: [UUID: DocumentText] = [:]

    // `add` keeps the first record of an `instanceID` and says whether this one was added.
    mutating func add(_ document: Document) -> Bool { Self.add(document, document.instanceID, to: &documents) }
    mutating func add(_ tag: Tag) -> Bool { Self.add(tag, tag.instanceID, to: &tags) }
    mutating func add(_ record: Correspondent) -> Bool { Self.add(record, record.instanceID, to: &correspondents) }
    mutating func add(_ record: DocumentType) -> Bool { Self.add(record, record.instanceID, to: &documentTypes) }
    mutating func add(_ file: DocumentFile) -> Bool { Self.add(file, file.instanceID, to: &files) }
    mutating func add(_ thumbnail: DocumentThumbnail) -> Bool {
        Self.add(thumbnail, thumbnail.instanceID, to: &thumbnails)
    }
    mutating func add(_ text: DocumentText) -> Bool { Self.add(text, text.instanceID, to: &texts) }

    private static func add<T>(_ record: T, _ id: UUID, to records: inout [UUID: T]) -> Bool {
        guard records[id] == nil else { return false }
        records[id] = record
        return true
    }

    /// Every tag (with its parent), correspondent and document type, in this order: chains need them all, and they
    /// are few.
    static func fetchMetadata(in context: ModelContext) throws -> (
        tags: [Tag], correspondents: [Correspondent], documentTypes: [DocumentType]
    ) {
        var tags = FetchDescriptor<Tag>()
        tags.relationshipKeyPathsForPrefetching = [\.parent]
        return (
            try context.fetch(tags), try context.fetch(FetchDescriptor<Correspondent>()),
            try context.fetch(FetchDescriptor<DocumentType>())
        )
    }

    /// The documents with these `instanceID`s, with their metadata but never `file`, `thumbnail` or `text`:
    /// prefetching them would load the blobs. In `oldestFirst` order.
    static func fetchDocuments(_ instanceIDs: Set<UUID>, in context: ModelContext) throws -> [Document] {
        guard !instanceIDs.isEmpty else { return [] }
        let ids = Array(instanceIDs)
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { ids.contains($0.instanceID) })
        descriptor.relationshipKeyPathsForPrefetching = [\.correspondent, \.documentType, \.tags]
        return oldestFirst(try context.fetch(descriptor))
    }

    /// **The one rule for documents sharing an `instanceID`** (a copied record): every reader keeps the first of
    /// this order, the oldest `createdAt`, and among equal dates the first the store returned. The repair's plan
    /// (`RepairStore.read`), its apply and check (`fetchDocuments`, `RowState.read`) and the processing queue's scan
    /// and fetches (`ProcessingQueue`) all use it, so a plan, its write and the check before the save meet the same
    /// row (review A of #96, N2; review B, B-D1). Sorted in memory after the fetch, so the SQL that `RepairSQLTests`
    /// pins stays as it is.
    static func oldestFirst(_ documents: [Document]) -> [Document] {
        documents.enumerated().sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map(\.element)
    }

    /// The records `keys` name, with every metadata record. Blobs only while unlinked (`#Predicate { $0.document ==
    /// nil }`), so the check before a save loads no linked blob either.
    static func read(_ keys: Set<RowKey>, in context: ModelContext) throws -> RowRecords {
        var records = RowRecords()
        let metadata = try fetchMetadata(in: context)
        for tag in metadata.tags { _ = records.add(tag) }
        for record in metadata.correspondents { _ = records.add(record) }
        for record in metadata.documentTypes { _ = records.add(record) }
        func ids(_ entity: RowKey.Entity) -> [UUID] { keys.filter { $0.entity == entity }.map(\.instanceID) }
        for document in try fetchDocuments(Set(ids(.document)), in: context) { _ = records.add(document) }
        let files = ids(.file)
        if !files.isEmpty {
            for file in try context.fetch(
                FetchDescriptor<DocumentFile>(
                    predicate: #Predicate { $0.document == nil && files.contains($0.instanceID) }))
            {
                _ = records.add(file)
            }
        }
        let thumbnails = ids(.thumbnail)
        if !thumbnails.isEmpty {
            for thumbnail in try context.fetch(
                FetchDescriptor<DocumentThumbnail>(
                    predicate: #Predicate { $0.document == nil && thumbnails.contains($0.instanceID) }))
            {
                _ = records.add(thumbnail)
            }
        }
        let texts = ids(.text)
        if !texts.isEmpty {
            for text in try context.fetch(
                FetchDescriptor<DocumentText>(
                    predicate: #Predicate { $0.document == nil && texts.contains($0.instanceID) }))
            {
                _ = records.add(text)
            }
        }
        return records
    }
}
