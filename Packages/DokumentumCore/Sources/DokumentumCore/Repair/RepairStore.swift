import DokumentumKit
import Foundation
import SwiftData

/// The records of one read, by `instanceID`: the handles the repair's operations name. Only what the light
/// snapshot holds: every document and metadata record, and the unlinked blobs.
struct RepairRecords {
    var documents: [UUID: Document] = [:]
    var tags: [UUID: Tag] = [:]
    var correspondents: [UUID: Correspondent] = [:]
    var documentTypes: [UUID: DocumentType] = [:]
    var files: [UUID: DocumentFile] = [:]
    var thumbnails: [UUID: DocumentThumbnail] = [:]
    var texts: [UUID: DocumentText] = [:]
}

/// Reads the repair's snapshot from a store (plan of #2, part 3).
///
/// **The light form: no linked blob is loaded.** SwiftData selects every column of a fetched entity (measured
/// on #29), and a fetch of `DocumentText` reads its text. So linked blobs are never fetched: each document's
/// `linkedBlobs` comes from its own row (`file != nil` and so on, which does not fire the relationship's
/// fault), and only blobs without a document are fetched (`WHERE t0.ZDOCUMENT IS NULL`). They are rare: in
/// flight, or orphans. `RepairSQLTests` records the SQL of a run and checks it. The planner treats both forms
/// alike (`RepairPropertyTests` in DokumentumKit).
public enum RepairStore {
    /// The light snapshot of the store as `context` sees it.
    public static func snapshot(in context: ModelContext) throws -> RepairSnapshot {
        try read(in: context).snapshot
    }

    static func read(in context: ModelContext) throws -> (snapshot: RepairSnapshot, records: RepairRecords) {
        var records = RepairRecords()
        var metadata: [MetadataSnapshot] = []

        var tagDescriptor = FetchDescriptor<Tag>()
        tagDescriptor.relationshipKeyPathsForPrefetching = [\.parent]
        for tag in try context.fetch(tagDescriptor) {
            records.tags[tag.instanceID] = tag
            metadata.append(
                MetadataSnapshot(
                    kind: .tag, instanceID: tag.instanceID, id: tag.id, createdAt: tag.createdAt,
                    mergedAt: tag.mergedAt, name: tag.name, parentInstanceID: tag.parent?.instanceID,
                    mergedIntoID: tag.mergedIntoID))
        }
        for record in try context.fetch(FetchDescriptor<Correspondent>()) {
            records.correspondents[record.instanceID] = record
            metadata.append(
                MetadataSnapshot(
                    kind: .correspondent, instanceID: record.instanceID, id: record.id, createdAt: record.createdAt,
                    mergedAt: record.mergedAt, name: record.name, mergedIntoID: record.mergedIntoID))
        }
        for record in try context.fetch(FetchDescriptor<DocumentType>()) {
            records.documentTypes[record.instanceID] = record
            metadata.append(
                MetadataSnapshot(
                    kind: .documentType, instanceID: record.instanceID, id: record.id, createdAt: record.createdAt,
                    mergedAt: record.mergedAt, name: record.name, mergedIntoID: record.mergedIntoID))
        }

        // Never `file`, `thumbnail` or `text`: prefetching them would load the blobs.
        var documentDescriptor = FetchDescriptor<Document>()
        documentDescriptor.relationshipKeyPathsForPrefetching = [\.correspondent, \.documentType, \.tags]
        var documents: [DocumentSnapshot] = []
        for document in try context.fetch(documentDescriptor) {
            records.documents[document.instanceID] = document
            var linked: Set<BlobKind> = []
            if document.file != nil { linked.insert(.file) }
            if document.thumbnail != nil { linked.insert(.thumbnail) }
            if document.text != nil { linked.insert(.text) }
            documents.append(
                DocumentSnapshot(
                    instanceID: document.instanceID, id: document.id, createdAt: document.createdAt,
                    modifiedAt: document.modifiedAt, correspondent: document.correspondent?.instanceID,
                    documentType: document.documentType?.instanceID,
                    tags: Set((document.tags ?? []).map(\.instanceID)), sourceRaw: document.sourceRaw,
                    textSourceRaw: document.textSourceRaw, processingStateRaw: document.processingStateRaw,
                    linkedBlobs: linked))
        }

        var blobs: [BlobSnapshot] = []
        for file in try context.fetch(FetchDescriptor<DocumentFile>(predicate: #Predicate { $0.document == nil })) {
            records.files[file.instanceID] = file
            blobs.append(
                BlobSnapshot(
                    kind: .file, instanceID: file.instanceID, createdAt: file.createdAt, documentID: file.documentID))
        }
        for thumbnail in try context.fetch(
            FetchDescriptor<DocumentThumbnail>(predicate: #Predicate { $0.document == nil }))
        {
            records.thumbnails[thumbnail.instanceID] = thumbnail
            blobs.append(
                BlobSnapshot(
                    kind: .thumbnail, instanceID: thumbnail.instanceID, createdAt: thumbnail.createdAt,
                    documentID: thumbnail.documentID))
        }
        for text in try context.fetch(FetchDescriptor<DocumentText>(predicate: #Predicate { $0.document == nil })) {
            records.texts[text.instanceID] = text
            blobs.append(
                BlobSnapshot(
                    kind: .text, instanceID: text.instanceID, createdAt: text.createdAt, documentID: text.documentID))
        }
        return (RepairSnapshot(documents: documents, metadata: metadata, blobs: blobs), records)
    }
}
