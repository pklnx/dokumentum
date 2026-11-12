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
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier)])
        if let token {
            descriptor.predicate = #Predicate { $0.token > token }
        }
        let transactions = try ModelContext(container).fetchHistory(descriptor)
        var changes: [TextChange] = []
        for transaction in transactions {
            for change in transaction.changes {
                if let mapped = Self.textChange(change) { changes.append(mapped) }
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
}
