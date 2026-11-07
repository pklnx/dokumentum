import Foundation
import SwiftData

/// One record of the store, named by its entity and `instanceID`.
struct RowKey: Hashable, Sendable {
    enum Entity: String, Hashable, Sendable, CaseIterable {
        case document, tag, correspondent, documentType, file, thumbnail, text
    }

    let entity: Entity
    let instanceID: UUID
}

/// Every value of one row that a save can write, related records as `instanceID`s: what a pass read, and what the
/// store holds right before the pass saves (`RepairRun`). `RowStateTests` checks against the schema that every
/// attribute and relationship is either here or named in `RowState.excluded` with its reason, so a new field
/// cannot be forgotten.
///
/// Why whole rows: a `ModelContext` whose row became stale writes back the **whole row** when it saves, not the
/// fields it changed (measured on #56: on the optimistic-locking conflict Core Data re-selects the row, and the
/// `UPDATE` then sets every field the stale object holds). So a pass checks every field of every row it writes.
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
    /// captured (`Document.correspondent`, `Document.tags`, `Tag.parent`, the blob's `document`), the document's
    /// to-one blob links are captured on the blob's side, and the external-storage data is not compared (the
    /// repair only links an unlinked blob, whose data nothing writes; a stale write of it remains a residual).
    static let excluded: [String: Set<String>] = [
        "Document": ["file", "thumbnail", "text"],
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
                documentType: document.documentType?.instanceID, tags: Set((document.tags ?? []).map(\.instanceID))))
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
    static func capture(_ records: RepairRecords) -> [RowKey: RowState] {
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
    /// the repair writes no other blob, and a blob linked meanwhile reads as absent.
    static func read(_ keys: Set<RowKey>, in container: ModelContainer) throws -> [RowKey: RowState] {
        try capture(RepairStore.records(keys, in: ModelContext(container)))
    }
}
