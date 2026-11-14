import DokumentumKit
import Foundation
import SwiftData

/// The Spotlight indexer's reads of the store (#13, plan §3), each synchronous in the context it is given, so
/// `SpotlightIndexerSQLTests` can record their SQL. The metadata comes from the light list query, never a blob; texts
/// and thumbnails are read by key, through the copy that is kept.
enum SpotlightStoreReader {
    /// How many documents one fetch of texts and thumbnails reads (as `SearchStoreReader.groupSize`): with the
    /// 500,000-byte text cap, at most 12.5 MB of text in memory at once.
    static let groupSize = 25

    /// What an item gets beyond the metadata.
    struct Contents: Sendable, Equatable {
        var text: String
        var thumbnail: Data?
    }

    /// Every document that is not in the trash, through the light list query (`StoreLibrarySource.read`'s fetches and
    /// mapping: no text, no blob). Of copies sharing an `instanceID`, the oldest `createdAt` wins, the first read among
    /// equal dates, as `RowRecords.oldestFirst` (T2); a document whose kept copy is trashed is not live.
    static func documents(in context: ModelContext) throws -> [UUID: SpotlightDocument] {
        let summaries =
            try DocumentListQuery.fetch(.all, in: context) + DocumentListQuery.fetch(.trash, in: context)
        let snapshot = LibraryMapping.snapshot(
            documents: summaries, metadata: try StoreLibrarySource.metadata(in: context))
        let tree = TagTree(snapshot.tags)
        var kept: [UUID: (row: LibraryDocument, modifiedAt: Date)] = [:]
        // `LibraryMapping.snapshot` maps the summaries one to one, in order. The oldest copy is chosen before the trash
        // filter below (#222's review B, N7). Copies with equal `createdAt` keep the first in this order (`.all`, then
        // `.trash`, each in list order), while `contents(of:)` keeps the first `RowRecords.fetchDocuments` returns, so for
        // such a tie the metadata and the text could come from different copies: the tie rule `SearchStoreReader.metadata`
        // has too (#226 review, N4). Copies exist only until step 16's dedupe.
        for (row, summary) in zip(snapshot.documents, summaries) {
            if let existing = kept[row.instanceID], existing.row.createdAt <= row.createdAt { continue }
            kept[row.instanceID] = (row, summary.modifiedAt)
        }
        var documents: [UUID: SpotlightDocument] = [:]
        for (id, entry) in kept where !entry.row.isTrashed {
            let fields = SearchFields(entry.row, tree: tree, unlistedTagNames: snapshot.unlistedTagNames)
            documents[id] = SpotlightDocument(
                instanceID: id, title: entry.row.title, correspondent: fields.correspondent,
                documentType: fields.documentType, tagPaths: fields.tagPaths, documentDate: entry.row.documentDate,
                createdAt: entry.row.createdAt, modifiedAt: entry.modifiedAt, isInbox: entry.row.isInbox)
        }
        return documents
    }

    /// The documents the history's changes belong to now, by `instanceID`: a text or thumbnail row by its link, a
    /// document row by itself. Rows that are gone or unlinked name nothing. Read by key, in groups.
    static func documentIDs(for changes: [SpotlightChange], in context: ModelContext) throws -> Set<UUID> {
        var texts: [PersistentIdentifier] = []
        var thumbnails: [PersistentIdentifier] = []
        var documents: [PersistentIdentifier] = []
        for change in changes {
            switch change {
            case .text(let id): texts.append(id)
            case .thumbnail(let id): thumbnails.append(id)
            case .document(let id): documents.append(id)
            }
        }
        var result: Set<UUID> = []
        for ids in groups(unique(texts)) {
            var descriptor = FetchDescriptor<DocumentText>(predicate: #Predicate { ids.contains($0.persistentModelID) })
            descriptor.relationshipKeyPathsForPrefetching = [\.document]
            for row in try context.fetch(descriptor) {
                if let document = row.document { result.insert(document.instanceID) }
            }
        }
        for ids in groups(unique(thumbnails)) {
            var descriptor = FetchDescriptor<DocumentThumbnail>(
                predicate: #Predicate { ids.contains($0.persistentModelID) })
            descriptor.relationshipKeyPathsForPrefetching = [\.document]
            for row in try context.fetch(descriptor) {
                if let document = row.document { result.insert(document.instanceID) }
            }
        }
        for ids in groups(unique(documents)) {
            let descriptor = FetchDescriptor<Document>(predicate: #Predicate { ids.contains($0.persistentModelID) })
            for document in try context.fetch(descriptor) { result.insert(document.instanceID) }
        }
        return result
    }

    /// The text and thumbnail of each of `ids` (at most `groupSize`) as the kept copy holds them **now**, read through
    /// its own relationships, by key (never cached per text row: when the kept copy goes, the next read gives the
    /// other copy's). A document that is gone is missing from the result.
    static func contents(of ids: [UUID], in context: ModelContext) throws -> [UUID: Contents] {
        var result: [UUID: Contents] = [:]
        for document in try RowRecords.fetchDocuments(Set(ids), in: context) where result[document.instanceID] == nil {
            result[document.instanceID] = Contents(
                text: document.text?.extractedText ?? "", thumbnail: document.thumbnail?.imageData)
        }
        return result
    }

    private static func unique(_ ids: [PersistentIdentifier]) -> [PersistentIdentifier] {
        var seen: Set<PersistentIdentifier> = []
        return ids.filter { seen.insert($0).inserted }
    }

    private static func groups(_ ids: [PersistentIdentifier]) -> [[PersistentIdentifier]] {
        stride(from: 0, to: ids.count, by: groupSize).map { Array(ids[$0..<min($0 + groupSize, ids.count)]) }
    }
}
