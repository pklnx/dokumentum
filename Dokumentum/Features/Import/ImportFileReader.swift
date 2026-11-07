import DokumentumKit
import Foundation

/// Reads a picked or dropped file; tests stub it.
protocol ImportFileReading: Sendable {
    /// The file's bytes, read off the main actor. Throws when the file cannot be read.
    func read(_ url: URL) async throws -> Data
}

/// Reads inside the URL's security-scoped access, through `NSFileCoordinator`: a coordinated read makes
/// iCloud Drive download a file that is not local yet before the accessor runs (plan review N5). An error,
/// from the coordinator or the read, ends as `ImportFailure.couldNotRead` in the controller; nothing waits
/// without end, because the coordinator returns its error instead of calling the accessor.
struct CoordinatedFileReader: ImportFileReading {
    @concurrent
    func read(_ url: URL) async throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, any Error> = .failure(ImportFailure.couldNotRead)
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            readURL in
            result = Result { try Data(contentsOf: readURL, options: .mappedIfSafe) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
