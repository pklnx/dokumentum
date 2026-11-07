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
}

/// The store's library: Debug and Release builds alike. In a Debug build the store of a `-UITestSeed`
/// launch holds the sample documents (`FixtureSeeder`).
extension StoreLibrarySource: LibrarySource {}
