import Foundation

/// Everything the sidebar and the list show, as plain values (plan of #3, T1): fixtures in Debug tests,
/// the store from part 2 of #3 on.
public struct LibrarySnapshot: Sendable, Equatable {
    /// Every document, trashed ones included; `LibrarySelection` filters them.
    public var documents: [LibraryDocument]
    /// The live tags: the sidebar lists exactly these.
    public var tags: [TagRecord]
    /// The live correspondents: the sidebar lists exactly these.
    public var correspondents: [LibraryDocument.Reference]
    /// The live document types: the sidebar lists exactly these.
    public var documentTypes: [LibraryDocument.Reference]
    /// Tags that documents refer to but the sidebar does not list: tombstones whose `mergedIntoID` chain
    /// ends at no live tag here. A row shows them by name; no sidebar entry matches them (plan of #3,
    /// part 2, "References to tombstones").
    public var unlistedTagNames: [UUID: String]

    public init(
        documents: [LibraryDocument] = [], tags: [TagRecord] = [], correspondents: [LibraryDocument.Reference] = [],
        documentTypes: [LibraryDocument.Reference] = [], unlistedTagNames: [UUID: String] = [:]
    ) {
        self.documents = documents
        self.tags = tags
        self.correspondents = correspondents
        self.documentTypes = documentTypes
        self.unlistedTagNames = unlistedTagNames
    }

    public static let empty = LibrarySnapshot()
}

/// What loading one document's PDF found.
public enum PDFLoadState: Sendable, Equatable {
    /// No document with that `instanceID` (deleted meanwhile).
    case noDocument
    /// The document has no file yet: it is still arriving by sync.
    case noFile
    /// The file record exists, but its data has not arrived yet.
    case noData
    case data(Data)
}
