import DokumentumKit
import Foundation

/// Everything the sidebar and the list show, as plain values (plan of #3, T1).
struct LibrarySnapshot: Sendable, Equatable {
    var documents: [LibraryDocument] = []
    var tags: [TagRecord] = []
    var correspondents: [LibraryDocument.Reference] = []
    var documentTypes: [LibraryDocument.Reference] = []

    static let empty = LibrarySnapshot()
}

/// What loading one document's PDF found. Part 2 of #3 maps the store's states onto it.
enum PDFLoadState: Sendable, Equatable {
    /// No document with that `instanceID` (deleted meanwhile).
    case noDocument
    /// The document has no file yet: it is still arriving by sync.
    case noFile
    /// The file record exists, but its data has not arrived yet.
    case noData
    case data(Data)
}

/// Where the library's values come from: fixtures in part 1 of #3, the store from part 2 on. The
/// views read it only through `LibraryModel`.
protocol LibrarySource: Sendable {
    /// The current values; cheap, without file data.
    @MainActor func snapshot() -> LibrarySnapshot
    /// Fires when the values may have changed; the model then reads `snapshot()` again and reloads
    /// the open document.
    var changes: AsyncStream<Void> { get }
    /// The PDF of one document. Runs off the main actor.
    func loadPDF(instanceID: UUID) async -> PDFLoadState
}

/// No documents at all: the source of a Release build until the store arrives (part 2 of #3), so a
/// Release build never contains fixtures.
struct EmptyLibrarySource: LibrarySource {
    let changes = AsyncStream<Void> { $0.finish() }

    @MainActor func snapshot() -> LibrarySnapshot { .empty }

    func loadPDF(instanceID: UUID) async -> PDFLoadState { .noDocument }
}

/// The source the app starts with: generated sample documents in Debug builds, nothing in Release
/// builds.
func librarySourceForThisBuild() -> any LibrarySource {
    #if DEBUG
        FixtureLibrarySource()
    #else
        EmptyLibrarySource()
    #endif
}
