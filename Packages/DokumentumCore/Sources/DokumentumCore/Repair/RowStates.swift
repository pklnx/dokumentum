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

/// Every value of one row that a save can write, related records as `instanceID`s: what a pass read, what it
/// wrote, and what another save left in the store (`ConcurrentSaveWatcher`). `RowStateTests` checks against the
/// schema that every attribute and relationship is either here or named in `RowState.excluded` with its reason,
/// so a new field cannot be forgotten.
///
/// Why: a `ModelContext` whose row became stale writes back the **whole row** when it saves, not the fields it
/// changed (measured on #56: on the optimistic-locking conflict Core Data re-selects the row, and the `UPDATE`
/// then sets every field the stale object holds). A pass that meets another save therefore compares, and
/// restores, whole rows.
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
    /// to-one blob links are captured on the blob's side, and the external-storage data is never loaded by the
    /// repair (an unlinked blob's data is never written by anything; a stale write of it remains a residual).
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

    /// The current state of `keys` in the store, read through a new context.
    static func read(_ keys: Set<RowKey>, in container: ModelContainer) throws -> [RowKey: RowState] {
        try capture(RepairStore.records(keys, in: ModelContext(container)))
    }

    // MARK: Restore

    /// Writes `state` into the record `key` names in `records`, every captured field. `MissingRecord` if the
    /// record or a record it refers to is not among them.
    static func restore(_ state: RowState, to key: RowKey, in records: RepairRecords) throws {
        func record<T>(_ table: [UUID: T], _ id: UUID) throws -> T {
            guard let value = table[id] else { throw MergeApplier.MissingRecord(instanceID: id) }
            return value
        }
        switch (key.entity, state) {
        case (.document, .document(let row)):
            let document = try record(records.documents, key.instanceID)
            document.title = row.title
            document.modifiedAt = row.modifiedAt
            document.documentDate = row.documentDate
            document.isInbox = row.isInbox
            document.pageCount = row.pageCount
            document.fileSize = row.fileSize
            document.textSourceRaw = row.textSourceRaw
            document.processingStateRaw = row.processingStateRaw
            document.processingDeviceID = row.processingDeviceID
            document.processingClaimedAt = row.processingClaimedAt
            document.contentHash = row.contentHash
            document.originalFileName = row.originalFileName
            document.sourceRaw = row.sourceRaw
            document.deletedAt = row.deletedAt
            document.correspondent = try row.correspondent.map { try record(records.correspondents, $0) }
            document.documentType = try row.documentType.map { try record(records.documentTypes, $0) }
            document.tags = try row.tags.map { try record(records.tags, $0) }
        case (.tag, .tag(let row)):
            let tag = try record(records.tags, key.instanceID)
            (tag.name, tag.colorHex, tag.mergedIntoID, tag.mergedAt) = (
                row.name, row.colorHex, row.mergedIntoID, row.mergedAt
            )
            tag.parent = try row.parent.map { try record(records.tags, $0) }
        case (.correspondent, .metadata(let row)):
            let correspondent = try record(records.correspondents, key.instanceID)
            (correspondent.name, correspondent.mergedIntoID, correspondent.mergedAt) =
                (row.name, row.mergedIntoID, row.mergedAt)
        case (.documentType, .metadata(let row)):
            let type = try record(records.documentTypes, key.instanceID)
            (type.name, type.mergedIntoID, type.mergedAt) = (row.name, row.mergedIntoID, row.mergedAt)
        case (.file, .blob(let row)):
            try record(records.files, key.instanceID).document = try row.document.map {
                try record(records.documents, $0)
            }
        case (.thumbnail, .blob(let row)):
            try record(records.thumbnails, key.instanceID).document = try row.document.map {
                try record(records.documents, $0)
            }
        case (.text, .blob(let row)):
            let text = try record(records.texts, key.instanceID)
            text.extractedText = row.extractedText ?? text.extractedText
            text.document = try row.document.map { try record(records.documents, $0) }
        default:
            throw MergeApplier.MissingRecord(instanceID: key.instanceID)
        }
    }

    /// The `id`, `instanceID`, `createdAt` and `documentID` fields are set at insert and never changed, so a
    /// restore leaves them alone; they stay in the row so a comparison sees every field.
    static let neverWritten: Set<String> = ["id", "instanceID", "createdAt", "documentID"]
}
