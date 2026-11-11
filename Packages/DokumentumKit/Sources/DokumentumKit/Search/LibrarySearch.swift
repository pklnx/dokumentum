import Foundation

/// A filter chip of the search field (plan of #7, P3).
public enum SearchToken: Sendable, Hashable {
    /// The tag and every tag below it.
    case tag(UUID)
    case correspondent(UUID)
    case documentType(UUID)
    case inbox

    /// The sidebar selection with the same rule.
    public var selection: LibrarySelection {
        switch self {
        case .tag(let id): .tag(id)
        case .correspondent(let id): .correspondent(id)
        case .documentType(let id): .documentType(id)
        case .inbox: .inbox
        }
    }
}

/// Where the search looks (plan of #7, P2).
public enum SearchScope: Sendable, Hashable {
    /// The list selected in the sidebar.
    case selection
    /// All documents that are not trashed.
    case all
}

/// What the search field holds, and how it turns the index's matches into the list's rows (plan of #7,
/// Approach 4).
public struct LibrarySearch: Sendable, Hashable {
    public var text: String
    public var tokens: [SearchToken]
    public var scope: SearchScope

    /// The most suggestions offered at once.
    public static let suggestionLimit = 8

    public init(text: String = "", tokens: [SearchToken] = [], scope: SearchScope = .selection) {
        self.text = text
        self.tokens = tokens
        self.scope = scope
    }

    /// Whether the text has a term. A text of spaces and punctuation only has none.
    public var hasText: Bool { !SearchTokenizer.terms(of: text).isEmpty }

    /// No text and no tokens is no search.
    public var isActive: Bool { hasText || !tokens.isEmpty }

    /// The selection the search looks in: the sidebar's, or All Documents.
    public func scopeSelection(for selection: LibrarySelection) -> LibrarySelection {
        scope == .all ? .all : selection
    }

    /// The rows to list, in list order.
    /// - The scope alone decides trashed or not (Revision 1, B2): the Trash keeps only trashed documents, every
    ///   other scope only documents that are not trashed.
    /// - Each token must hold, with its selection's rule but without the trash guard
    ///   (`LibrarySelection.matchesIgnoringTrash`).
    /// - With a text, only `result`'s matches stay; with a text and no result yet, nothing does.
    /// - Not active: the selection's own list.
    public func apply(
        _ result: SearchResult?, to documents: [LibraryDocument], selection: LibrarySelection, tree: TagTree
    ) -> [LibraryDocument] {
        guard isActive else { return selection.filter(documents, in: tree) }
        let scoped = scopeSelection(for: selection).filter(documents, in: tree)
        let predicates = tokens.map { $0.selection.predicateIgnoringTrash(in: tree) }
        let matches: Set<UUID>? = hasText ? (result?.matches ?? []) : nil
        return scoped.filter { document in
            if let matches, !matches.contains(document.instanceID) { return false }
            return predicates.allSatisfy { $0(document) }
        }
    }

    /// The tokens offered for the text typed: tags (by display path), correspondents, types and the Inbox, whose
    /// name has a word that starts with each term of the text; tags first, each kind by name, at most
    /// `suggestionLimit`. Tokens already chosen are not offered, nor the Inbox when the search looks in the Trash
    /// (P3). No text, no suggestions.
    /// - Parameter inboxName: the Inbox's name as the app shows it (Kit has no strings of its own).
    public func suggestions(
        in snapshot: LibrarySnapshot, tree: TagTree, selection: LibrarySelection, inboxName: String
    ) -> [SearchToken] {
        let terms = SearchTokenizer.terms(of: text)
        guard !terms.isEmpty else { return [] }
        var cache = SearchNormalizer.Cache()
        func matches(_ name: String) -> Bool {
            let words = SearchTokenizer.words(of: name, cache: &cache)
            return terms.allSatisfy { term in
                term.forms.contains { form in words.contains { $0.hasPrefix(form) } }
            }
        }
        func byName(_ items: [(SearchToken, String, UUID)]) -> [SearchToken] {
            items.sorted { lhs, rhs in
                switch lhs.1.localizedStandardCompare(rhs.1) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.2.uuidString < rhs.2.uuidString
                }
            }.map(\.0)
        }
        let chosen = Set(tokens)
        var result: [SearchToken] = []
        let tags = snapshot.tags.map {
            (SearchToken.tag($0.instanceID), tree.displayPath(of: $0.instanceID), $0.instanceID)
        }
        result += byName(tags.filter { !chosen.contains($0.0) && matches($0.1) })
        result += byName(
            snapshot.correspondents.map { (SearchToken.correspondent($0.instanceID), $0.name, $0.instanceID) }
                .filter { !chosen.contains($0.0) && matches($0.1) })
        result += byName(
            snapshot.documentTypes.map { (SearchToken.documentType($0.instanceID), $0.name, $0.instanceID) }
                .filter { !chosen.contains($0.0) && matches($0.1) })
        if scopeSelection(for: selection) != .trash, !chosen.contains(.inbox), matches(inboxName) {
            result.append(.inbox)
        }
        return Array(result.prefix(Self.suggestionLimit))
    }
}
