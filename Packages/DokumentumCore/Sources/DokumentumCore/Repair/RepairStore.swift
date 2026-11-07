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
///
/// **The re-check read covers only what a pass writes** (`touched(by:in:)`): every metadata record (few, and
/// chains need them all), the documents its operations name or that reference a merge's loser (through the
/// loser's own `documents`), and the unlinked blobs it relinks. So the time from that read to the pass's save
/// grows with the pass, not with the archive. `RepairSQLTests` pins it.
///
/// Records sharing an `instanceID` (a copied record) keep the first one read, as `RepairPlan.apply` indexes
/// them, so a check and the write it allows meet the same record.
public enum RepairStore {
    /// The light snapshot of the store as `context` sees it.
    public static func snapshot(in context: ModelContext) throws -> RepairSnapshot {
        try read(in: context).snapshot
    }

    /// Every document and metadata record, and the unlinked blobs: what a run plans on.
    static func read(in context: ModelContext) throws -> (snapshot: RepairSnapshot, records: RepairRecords) {
        var reader = Reader()
        try reader.readMetadata(in: context)
        // Never `file`, `thumbnail` or `text`: prefetching them would load the blobs.
        var documents = FetchDescriptor<Document>()
        documents.relationshipKeyPathsForPrefetching = [\.correspondent, \.documentType, \.tags]
        for document in try context.fetch(documents) { reader.add(document) }
        for file in try context.fetch(FetchDescriptor<DocumentFile>(predicate: #Predicate { $0.document == nil })) {
            reader.add(file)
        }
        for thumbnail in try context.fetch(
            FetchDescriptor<DocumentThumbnail>(predicate: #Predicate { $0.document == nil }))
        {
            reader.add(thumbnail)
        }
        for text in try context.fetch(FetchDescriptor<DocumentText>(predicate: #Predicate { $0.document == nil })) {
            reader.add(text)
        }
        return (reader.snapshot, reader.records)
    }

    /// What `plan` writes: every metadata record, the documents its operations name or that reference a merge's
    /// loser, and the unlinked blobs it relinks. A blob linked meanwhile is not read, so its relink is skipped.
    static func touched(by plan: RepairPlan, in context: ModelContext) throws -> (
        snapshot: RepairSnapshot, records: RepairRecords
    ) {
        var reader = Reader()
        try reader.readMetadata(in: context)
        var named: Set<UUID> = []
        var losers: [(MetadataKind, UUID)] = []
        var blobs: Set<UUID> = []
        for operation in plan.operations {
            switch operation {
            case .repoint(.correspondent(let document), _, _), .repoint(.documentType(let document), _, _),
                .repoint(.tag(let document), _, _):
                named.insert(document)
            case .mergeMetadata(let kind, let loser, _):
                losers.append((kind, loser))
            case .relink(let blob, let document):
                named.insert(document)
                blobs.insert(blob)
            case .repoint(.parent, _, _), .makeRoot, .revive:
                break
            }
        }
        for document in try fetchDocuments(named, in: context) { reader.add(document) }
        for (kind, loser) in losers {
            let documents: [Document]? =
                switch kind {
                case .correspondent: reader.records.correspondents[loser]?.documents
                case .documentType: reader.records.documentTypes[loser]?.documents
                case .tag: reader.records.tags[loser]?.documents
                }
            for document in documents ?? [] { reader.add(document) }
        }
        if !blobs.isEmpty {
            let ids = Array(blobs)
            for file in try context.fetch(
                FetchDescriptor<DocumentFile>(
                    predicate: #Predicate { $0.document == nil && ids.contains($0.instanceID) }))
            {
                reader.add(file)
            }
            for thumbnail in try context.fetch(
                FetchDescriptor<DocumentThumbnail>(
                    predicate: #Predicate { $0.document == nil && ids.contains($0.instanceID) }))
            {
                reader.add(thumbnail)
            }
            for text in try context.fetch(
                FetchDescriptor<DocumentText>(
                    predicate: #Predicate { $0.document == nil && ids.contains($0.instanceID) }))
            {
                reader.add(text)
            }
        }
        return (reader.snapshot, reader.records)
    }

    /// The records `keys` name, linked blobs included, with every metadata record (rows refer to them).
    static func records(_ keys: Set<RowKey>, in context: ModelContext) throws -> RepairRecords {
        var reader = Reader()
        try reader.readMetadata(in: context)
        func ids(_ entity: RowKey.Entity) -> [UUID] { keys.filter { $0.entity == entity }.map(\.instanceID) }
        let blobDocuments = Set(ids(.document))
        for document in try fetchDocuments(blobDocuments, in: context) { reader.add(document) }
        let files = ids(.file)
        if !files.isEmpty {
            for file in try context.fetch(
                FetchDescriptor<DocumentFile>(predicate: #Predicate { files.contains($0.instanceID) }))
            {
                reader.add(file)
            }
        }
        let thumbnails = ids(.thumbnail)
        if !thumbnails.isEmpty {
            for thumbnail in try context.fetch(
                FetchDescriptor<DocumentThumbnail>(predicate: #Predicate { thumbnails.contains($0.instanceID) }))
            {
                reader.add(thumbnail)
            }
        }
        let texts = ids(.text)
        if !texts.isEmpty {
            for text in try context.fetch(
                FetchDescriptor<DocumentText>(predicate: #Predicate { texts.contains($0.instanceID) }))
            {
                reader.add(text)
            }
        }
        // A blob's document link may name a document no key names.
        let linked = Set(
            reader.records.files.values.compactMap { $0.document?.instanceID }
                + reader.records.thumbnails.values.compactMap { $0.document?.instanceID }
                + reader.records.texts.values.compactMap { $0.document?.instanceID })
        for document in try fetchDocuments(linked.subtracting(reader.records.documents.keys), in: context) {
            reader.add(document)
        }
        return reader.records
    }

    private static func fetchDocuments(_ instanceIDs: Set<UUID>, in context: ModelContext) throws -> [Document] {
        guard !instanceIDs.isEmpty else { return [] }
        let ids = Array(instanceIDs)
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { ids.contains($0.instanceID) })
        descriptor.relationshipKeyPathsForPrefetching = [\.correspondent, \.documentType, \.tags]
        return try context.fetch(descriptor)
    }

    /// Collects records and their snapshots, the first of an `instanceID` only.
    private struct Reader {
        var records = RepairRecords()
        var documents: [DocumentSnapshot] = []
        var metadata: [MetadataSnapshot] = []
        var blobs: [BlobSnapshot] = []

        var snapshot: RepairSnapshot { RepairSnapshot(documents: documents, metadata: metadata, blobs: blobs) }

        mutating func readMetadata(in context: ModelContext) throws {
            var tags = FetchDescriptor<Tag>()
            tags.relationshipKeyPathsForPrefetching = [\.parent]
            for tag in try context.fetch(tags) where records.tags[tag.instanceID] == nil {
                records.tags[tag.instanceID] = tag
                metadata.append(
                    MetadataSnapshot(
                        kind: .tag, instanceID: tag.instanceID, id: tag.id, createdAt: tag.createdAt,
                        mergedAt: tag.mergedAt, name: tag.name, parentInstanceID: tag.parent?.instanceID,
                        mergedIntoID: tag.mergedIntoID))
            }
            for record in try context.fetch(FetchDescriptor<Correspondent>())
            where records.correspondents[record.instanceID] == nil {
                records.correspondents[record.instanceID] = record
                metadata.append(
                    MetadataSnapshot(
                        kind: .correspondent, instanceID: record.instanceID, id: record.id,
                        createdAt: record.createdAt, mergedAt: record.mergedAt, name: record.name,
                        mergedIntoID: record.mergedIntoID))
            }
            for record in try context.fetch(FetchDescriptor<DocumentType>())
            where records.documentTypes[record.instanceID] == nil {
                records.documentTypes[record.instanceID] = record
                metadata.append(
                    MetadataSnapshot(
                        kind: .documentType, instanceID: record.instanceID, id: record.id,
                        createdAt: record.createdAt, mergedAt: record.mergedAt, name: record.name,
                        mergedIntoID: record.mergedIntoID))
            }
        }

        mutating func add(_ document: Document) {
            guard records.documents[document.instanceID] == nil else { return }
            records.documents[document.instanceID] = document
            var linked: Set<BlobKind> = []
            // `!= nil` reads the link from the document row; it does not fire the blob's fault.
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

        mutating func add(_ file: DocumentFile) {
            guard records.files[file.instanceID] == nil else { return }
            records.files[file.instanceID] = file
            blobs.append(blob(.file, file.instanceID, file.createdAt, file.documentID, file.document))
        }

        mutating func add(_ thumbnail: DocumentThumbnail) {
            guard records.thumbnails[thumbnail.instanceID] == nil else { return }
            records.thumbnails[thumbnail.instanceID] = thumbnail
            blobs.append(
                blob(.thumbnail, thumbnail.instanceID, thumbnail.createdAt, thumbnail.documentID, thumbnail.document))
        }

        mutating func add(_ text: DocumentText) {
            guard records.texts[text.instanceID] == nil else { return }
            records.texts[text.instanceID] = text
            blobs.append(blob(.text, text.instanceID, text.createdAt, text.documentID, text.document))
        }

        private func blob(
            _ kind: BlobKind, _ instanceID: UUID, _ createdAt: Date, _ documentID: UUID?, _ document: Document?
        )
            -> BlobSnapshot
        {
            BlobSnapshot(
                kind: kind, instanceID: instanceID, createdAt: createdAt, documentID: documentID,
                linkedDocumentInstanceID: document?.instanceID)
        }
    }
}
