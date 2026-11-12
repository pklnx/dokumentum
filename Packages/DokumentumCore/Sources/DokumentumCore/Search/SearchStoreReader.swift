import DokumentumKit
import Foundation
import SwiftData

/// The indexer's reads of the store, each synchronous in the context it is given, so `SearchIndexerSQLTests` can
/// record their SQL (plan of #7, Approach 6 and 7). Never a blob: the metadata comes from the list query, the
/// texts from `DocumentText` rows by key.
enum SearchStoreReader {
    /// How many text rows one fetch reads by identifier (Revision 1, N3): with the 500,000-byte cap, at most
    /// 12.5 MB of text in memory at once.
    static let groupSize = 25

    /// One text row as the index needs it.
    struct TextRow {
        struct Owner: Equatable {
            var instanceID: UUID
            var createdAt: Date
        }

        var id: PersistentIdentifier
        var text: String
        /// The linked document; `nil` for a text that arrived before its document.
        var document: Owner?
    }

    /// The metadata of every document, trashed ones included, through the light list query (T3). Of copies
    /// sharing an `instanceID`, the oldest `createdAt` wins, the first read among equal dates, as
    /// `RowRecords.oldestFirst`.
    static func metadata(in context: ModelContext) throws -> [UUID: SearchFields] {
        let snapshot = try StoreLibrarySource.read(in: context)
        let tree = TagTree(snapshot.tags)
        var oldest: [UUID: LibraryDocument] = [:]
        for document in snapshot.documents {
            if let kept = oldest[document.instanceID], kept.createdAt <= document.createdAt { continue }
            oldest[document.instanceID] = document
        }
        return oldest.mapValues { SearchFields($0, tree: tree, unlistedTagNames: snapshot.unlistedTagNames) }
    }

    /// The identifiers of every text row, linked or not; no row is loaded.
    static func textIdentifiers(in context: ModelContext) throws -> [PersistentIdentifier] {
        try context.fetchIdentifiers(FetchDescriptor<DocumentText>())
    }

    /// The text rows of `ids` (at most `groupSize`), with their document prefetched. Rows deleted meanwhile are
    /// missing from the result.
    static func texts(_ ids: [PersistentIdentifier], in context: ModelContext) throws -> [TextRow] {
        guard !ids.isEmpty else { return [] }
        var descriptor = FetchDescriptor<DocumentText>(predicate: #Predicate { ids.contains($0.persistentModelID) })
        descriptor.relationshipKeyPathsForPrefetching = [\.document]
        return try context.fetch(descriptor).map { row in
            TextRow(
                id: row.persistentModelID, text: row.extractedText,
                document: row.document.map { TextRow.Owner(instanceID: $0.instanceID, createdAt: $0.createdAt) })
        }
    }

    /// The text rows that the documents `ids` link now.
    static func linkedTexts(ofDocuments ids: [PersistentIdentifier], in context: ModelContext) throws
        -> [PersistentIdentifier]
    {
        guard !ids.isEmpty else { return [] }
        let documents = try context.fetch(
            FetchDescriptor<Document>(predicate: #Predicate { ids.contains($0.persistentModelID) }))
        return documents.compactMap { $0.text?.persistentModelID }
    }
}
