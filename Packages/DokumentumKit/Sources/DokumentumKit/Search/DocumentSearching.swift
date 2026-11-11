import Foundation

/// How far the index is (plan of #7, P5): while texts are being indexed, results cover the metadata of every
/// document and the texts indexed so far.
public enum SearchIndexState: Sendable, Hashable {
    /// `indexed` of `total` texts are in the index.
    case building(indexed: Int, total: Int)
    case ready
}

/// The answer to one query.
public struct SearchResult: Sendable, Equatable {
    /// The `instanceID`s of the documents that match every term, trashed ones included. Order and filtering are
    /// the library's (`LibrarySearch.apply`).
    public var matches: Set<UUID>
    /// The index's state when it answered.
    public var state: SearchIndexState

    public init(matches: Set<UUID>, state: SearchIndexState) {
        self.matches = matches
        self.state = state
    }
}

/// What the library asks the search (plan of #7, Approach 1). The in-memory indexer (part 2) conforms; a SQLite
/// FTS5 index would conform unchanged (T13).
public protocol DocumentSearching: Sendable {
    /// The documents that match every term of `text` (`SearchTokenizer.terms(of:)`).
    func search(_ text: String) async -> SearchResult
    /// A new stream for each call, one per subscriber, keeping only the newest state: it yields after every
    /// applied change, build batch and rebuild (Revision 1, B3). Ends when the subscriber stops iterating.
    func updates() -> AsyncStream<SearchIndexState>
    var state: SearchIndexState { get async }
}
