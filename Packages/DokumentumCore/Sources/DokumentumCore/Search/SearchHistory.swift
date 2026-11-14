import Foundation
import SwiftData

/// What the persistent history says about the texts since a token (plan of #7, Approach 7, T2).
public enum TextChange: Sendable, Hashable {
    /// A `DocumentText` row inserted, or updated in `extractedText` or `document` (a text write, a relink): re-read
    /// it by its identifier.
    case upsert(PersistentIdentifier)
    /// A `Document` row updated in `text`: re-read the text it links now.
    case documentLink(PersistentIdentifier)
    /// A `DocumentText` row deleted.
    case delete(PersistentIdentifier)
}

/// What the persistent history says about a Spotlight item beyond its metadata (#13, plan §3, N1): the rows are
/// mapped to the documents they belong to by `SpotlightStoreReader`.
public enum SpotlightChange: Sendable, Hashable {
    /// A `DocumentText` row inserted, or updated in `extractedText` or `document`.
    case text(PersistentIdentifier)
    /// A `DocumentThumbnail` row inserted, or updated in `document`.
    case thumbnail(PersistentIdentifier)
    /// A `Document` row updated in `text` or `thumbnail` (a relink).
    case document(PersistentIdentifier)
}

/// The history the indexer reads; `StoreSearchHistory` in the app, a stub in tests (N5).
public protocol SearchHistoryReading: Sendable {
    /// The newest transaction's token; `nil` for a store without history.
    func newestToken() throws -> DefaultHistoryToken?
    /// The text changes after `token` (all history for `nil`), in order, and the newest token among them (`nil`
    /// when there was none). Throws `SwiftDataError.historyTokenExpired` when the history after `token` was
    /// deleted (P-c).
    func changes(since token: DefaultHistoryToken?) throws -> (changes: [TextChange], newest: DefaultHistoryToken?)
}

/// SwiftData's persistent history of one container, read in a fresh context per call. It records local saves,
/// the saves of another container on the same file (as the CloudKit mirroring writes) and relinks (P-a), and it
/// works for in-memory stores (P-b).
public struct StoreSearchHistory: SearchHistoryReading {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func newestToken() throws -> DefaultHistoryToken? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
        descriptor.fetchLimit = 1
        return try ModelContext(container).fetchHistory(descriptor).first?.token
    }

    public func changes(since token: DefaultHistoryToken?) throws -> (
        changes: [TextChange], newest: DefaultHistoryToken?
    ) {
        try mapped(since: token, Self.textChange)
    }

    /// The changes Spotlight's items depend on beyond the list query's metadata (#13, plan §3, N1), in order, and the
    /// newest token among them; throws as `changes(since:)`. One type with the search's mapping, so the two indexers
    /// read the same history the same way.
    public func spotlightChanges(since token: DefaultHistoryToken?) throws -> (
        changes: [SpotlightChange], newest: DefaultHistoryToken?
    ) {
        try mapped(since: token, Self.spotlightChange)
    }

    /// The history after `token` (all of it for `nil`), each change mapped by `map`.
    private func mapped<Change>(since token: DefaultHistoryToken?, _ map: (HistoryChange) -> Change?) throws -> (
        changes: [Change], newest: DefaultHistoryToken?
    ) {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier)])
        if let token {
            descriptor.predicate = #Predicate { $0.token > token }
        }
        let transactions = try ModelContext(container).fetchHistory(descriptor)
        var changes: [Change] = []
        for transaction in transactions {
            for change in transaction.changes {
                if let mapped = map(change) { changes.append(mapped) }
            }
        }
        return (changes, transactions.last?.token)
    }

    /// The text change one history change stands for, `nil` for anything the text field does not depend on.
    /// Inserted documents need nothing: the import inserts their text row in the same save, and a text that was
    /// there before is linked by an update of `DocumentText.document` (P-a).
    static func textChange(_ change: HistoryChange) -> TextChange? {
        switch change {
        case .insert(let insert as DefaultHistoryInsert<DocumentText>):
            return .upsert(insert.changedPersistentIdentifier)
        case .update(let update as DefaultHistoryUpdate<DocumentText>):
            let relevant: [AnyKeyPath] = [\DocumentText.extractedText, \DocumentText.document]
            guard update.updatedAttributes.contains(where: { relevant.contains($0 as AnyKeyPath) }) else {
                return nil
            }
            return .upsert(update.changedPersistentIdentifier)
        case .update(let update as DefaultHistoryUpdate<Document>):
            guard update.updatedAttributes.contains(where: { ($0 as AnyKeyPath) == \Document.text }) else {
                return nil
            }
            return .documentLink(update.changedPersistentIdentifier)
        case .delete(let delete as DefaultHistoryDelete<DocumentText>):
            return .delete(delete.changedPersistentIdentifier)
        default:
            return nil
        }
    }

    /// The Spotlight change one history change stands for (#13, plan §3), `nil` for anything an item does not depend on
    /// beyond the list query's metadata, which the fingerprints cover:
    /// - a `DocumentText` inserted, or updated in `extractedText` or `document`;
    /// - a `DocumentThumbnail` inserted, or updated in `document`;
    /// - a `Document` updated in `text` or `thumbnail` (a relink).
    static func spotlightChange(_ change: HistoryChange) -> SpotlightChange? {
        switch change {
        case .insert(let insert as DefaultHistoryInsert<DocumentText>):
            return .text(insert.changedPersistentIdentifier)
        case .update(let update as DefaultHistoryUpdate<DocumentText>):
            let relevant: [AnyKeyPath] = [\DocumentText.extractedText, \DocumentText.document]
            guard update.updatedAttributes.contains(where: { relevant.contains($0 as AnyKeyPath) }) else {
                return nil
            }
            return .text(update.changedPersistentIdentifier)
        case .insert(let insert as DefaultHistoryInsert<DocumentThumbnail>):
            return .thumbnail(insert.changedPersistentIdentifier)
        case .update(let update as DefaultHistoryUpdate<DocumentThumbnail>):
            guard update.updatedAttributes.contains(where: { ($0 as AnyKeyPath) == \DocumentThumbnail.document }) else {
                return nil
            }
            return .thumbnail(update.changedPersistentIdentifier)
        case .update(let update as DefaultHistoryUpdate<Document>):
            let relevant: [AnyKeyPath] = [\Document.text, \Document.thumbnail]
            guard update.updatedAttributes.contains(where: { relevant.contains($0 as AnyKeyPath) }) else {
                return nil
            }
            return .document(update.changedPersistentIdentifier)
        default:
            return nil
        }
    }
}
