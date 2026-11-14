import CoreGraphics
import DokumentumCore
import DokumentumKit
import Foundation

/// Where the library's values come from: the store from part 2 of #3 on (`StoreLibrarySource`), fixtures
/// in Debug unit tests (`FixtureLibrarySource`). The views read it only through `LibraryModel`.
/// `LibrarySnapshot` and `PDFLoadState` are Kit values, so Core can produce them.
protocol LibrarySource: Sendable {
    /// The current values; cheap, without file data.
    @MainActor func snapshot() -> LibrarySnapshot
    /// Fires when the values may have changed; the model then reads `snapshot()` again and reloads
    /// the open document.
    var changes: AsyncStream<Void> { get }
    /// The PDF of one document. Runs off the main actor.
    func loadPDF(instanceID: UUID) async -> PDFLoadState
    /// The thumbnail of one document's list row (#6, part 4), decoded off the main actor; `nil` while it has none.
    func loadThumbnail(instanceID: UUID) async -> CGImage?
    /// Writes edits to the documents (plan of #3, part 3); `nil` for a source that cannot be edited.
    @MainActor var editor: DocumentEditor? { get }
    /// Reads and saves the matching rules of tags, correspondents and types (#10, part 2); `nil` for a source that
    /// cannot be edited.
    @MainActor var ruleEditor: MatchingRuleEditor? { get }
}

extension LibrarySource {
    @MainActor var editor: DocumentEditor? { nil }
    @MainActor var ruleEditor: MatchingRuleEditor? { nil }
    func loadThumbnail(instanceID: UUID) async -> CGImage? { nil }
}

/// The store's library: Debug and Release builds alike. In a Debug build the store of a `-UITestSeed`
/// launch holds the sample documents (`FixtureSeeder`).
/// Edits go through `DocumentEditor` in the main context, which the library reads; its save fires `changes`.
extension StoreLibrarySource: LibrarySource {
    @MainActor var editor: DocumentEditor? {
        #if DEBUG
            if UITestFailingSaves.isRequested(for: container, arguments: ProcessInfo.processInfo.arguments) {
                return UITestFailingSaves.editor(for: container)
            }
        #endif
        return DocumentEditor(context: container.mainContext)
    }

    /// In the main context, which the library reads, as `editor`.
    @MainActor var ruleEditor: MatchingRuleEditor? {
        MatchingRuleEditor(context: container.mainContext)
    }
}
