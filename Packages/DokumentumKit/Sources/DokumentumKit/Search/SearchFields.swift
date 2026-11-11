import Foundation

/// The metadata of one document the search finds it by (plan of #7, Approach 2): title, correspondent and type
/// names, and each tag's display path, so a document tagged "Steuer › 2024" is found by "steuer". Equal fields
/// need no new tokenising: `SearchIndex.setMetadata` compares them.
public struct SearchFields: Sendable, Hashable {
    public var title: String
    public var correspondent: String
    public var documentType: String
    /// Sorted, so the same tags in another order are the same fields.
    public var tagPaths: [String]

    public init(title: String, correspondent: String = "", documentType: String = "", tagPaths: [String] = []) {
        self.title = title
        self.correspondent = correspondent
        self.documentType = documentType
        self.tagPaths = tagPaths.sorted()
    }

    /// The fields of a library row. A tag the tree does not have is indexed by its name from
    /// `unlistedTagNames` (a tombstone the sidebar does not list, as the row shows it); a tag in neither is left
    /// out.
    public init(_ document: LibraryDocument, tree: TagTree, unlistedTagNames: [UUID: String] = [:]) {
        let paths = document.tagIDs.compactMap { id -> String? in
            if tree.tags[id] != nil { return tree.displayPath(of: id) }
            return unlistedTagNames[id]
        }
        self.init(
            title: document.title, correspondent: document.correspondent?.name ?? "",
            documentType: document.documentType?.name ?? "", tagPaths: paths)
    }

    /// Each field on its own, so a hyphen at the end of one never joins it to the next.
    var parts: [String] { [title, correspondent, documentType] + tagPaths }
}
