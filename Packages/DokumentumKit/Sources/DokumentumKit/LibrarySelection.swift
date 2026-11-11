import Foundation

/// What the sidebar selects. Filters run in memory over the rows of one light list query, so no
/// selection needs a predicate of its own (plan of #3, T2).
public enum LibrarySelection: Sendable, Hashable {
    case inbox
    case all
    /// Used from part 4 of #3 on.
    case trash
    /// The tag and every tag below it.
    case tag(UUID)
    case correspondent(UUID)
    case documentType(UUID)

    /// Whether `document` belongs to this selection. Trashed documents match only `trash`.
    public func matches(_ document: LibraryDocument, in tree: TagTree) -> Bool {
        Matcher(self, tree: tree).matches(document)
    }

    /// Whether `document` meets this selection's rule whether it is trashed or not: the rule of `matches` without
    /// its trash guard, so a tag still includes its subtree. The search's filter tokens use it, because there the
    /// scope alone decides trashed or not (plan of #7, Revision 1, B2). `trash` matches trashed documents.
    public func matchesIgnoringTrash(_ document: LibraryDocument, in tree: TagTree) -> Bool {
        Matcher(self, tree: tree).matchesIgnoringTrash(document)
    }

    /// `matchesIgnoringTrash` with the subtree computed once, for filtering many documents.
    func predicateIgnoringTrash(in tree: TagTree) -> (LibraryDocument) -> Bool {
        let matcher = Matcher(self, tree: tree)
        return { matcher.matchesIgnoringTrash($0) }
    }

    /// The documents of this selection in list order (`LibraryDocument.listOrder`).
    public func filter(_ documents: [LibraryDocument], in tree: TagTree) -> [LibraryDocument] {
        let matcher = Matcher(self, tree: tree)
        return documents.filter(matcher.matches).sorted(by: LibraryDocument.listOrder)
    }

    /// The subtree is computed once per filter, not once per document.
    private struct Matcher {
        let selection: LibrarySelection
        let subtree: Set<UUID>

        init(_ selection: LibrarySelection, tree: TagTree) {
            self.selection = selection
            if case .tag(let id) = selection {
                subtree = tree.subtreeIDs(of: id)
            } else {
                subtree = []
            }
        }

        func matches(_ document: LibraryDocument) -> Bool {
            if case .trash = selection { return document.isTrashed }
            guard !document.isTrashed else { return false }
            return matchesIgnoringTrash(document)
        }

        func matchesIgnoringTrash(_ document: LibraryDocument) -> Bool {
            switch selection {
            case .inbox: return document.isInbox
            case .all: return true
            case .trash: return document.isTrashed
            case .tag: return !document.tagIDs.isDisjoint(with: subtree)
            case .correspondent(let id): return document.correspondent?.instanceID == id
            case .documentType(let id): return document.documentType?.instanceID == id
            }
        }
    }
}

/// The count of every sidebar row, from one pass over the documents.
public struct LibraryCounts: Sendable, Equatable {
    public private(set) var inbox = 0
    public private(set) var all = 0
    public private(set) var trash = 0
    public private(set) var tags: [UUID: Int] = [:]
    public private(set) var correspondents: [UUID: Int] = [:]
    public private(set) var documentTypes: [UUID: Int] = [:]

    public init() {}

    /// A tag counts each document once, also when it has the tag and a tag below it; a tag's count
    /// includes the documents of its subtree. Trashed documents count only for the trash.
    public init(_ documents: [LibraryDocument], tree: TagTree) {
        var ancestors: [UUID: [UUID]] = [:]
        for document in documents {
            if document.isTrashed {
                trash += 1
                continue
            }
            all += 1
            if document.isInbox { inbox += 1 }
            if let id = document.correspondent?.instanceID { correspondents[id, default: 0] += 1 }
            if let id = document.documentType?.instanceID { documentTypes[id, default: 0] += 1 }
            var counted: Set<UUID> = []
            for tag in document.tagIDs where tree.tags[tag] != nil {
                counted.insert(tag)
                if ancestors[tag] == nil { ancestors[tag] = tree.ancestors(of: tag) }
                counted.formUnion(ancestors[tag] ?? [])
            }
            for id in counted { tags[id, default: 0] += 1 }
        }
    }

    /// The count shown next to `selection`.
    public func count(for selection: LibrarySelection) -> Int {
        switch selection {
        case .inbox: inbox
        case .all: all
        case .trash: trash
        case .tag(let id): tags[id] ?? 0
        case .correspondent(let id): correspondents[id] ?? 0
        case .documentType(let id): documentTypes[id] ?? 0
        }
    }
}
