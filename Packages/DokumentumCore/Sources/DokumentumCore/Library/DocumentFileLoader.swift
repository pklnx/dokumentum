import DokumentumKit
import Foundation
import SwiftData

/// Loads the PDF of one document, off the main actor (plan of #3, part 2): only the open document's file
/// is ever read, so a large PDF never loads on the main actor or with a list.
///
/// Each load uses a context of its own that ends with the load. A long-lived context would keep every PDF
/// it ever loaded registered, and could answer from its own stale copy of a document after another context
/// saved a file that arrived later.
public struct DocumentFileLoader: Sendable {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// What the store has for the document with `instanceID`: no such document, no file yet, a file whose
    /// data has not arrived yet, or the data.
    @concurrent
    public func load(instanceID: UUID) async -> PDFLoadState {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID })
        descriptor.fetchLimit = 1
        let document: Document?
        do {
            document = try context.fetch(descriptor).first
        } catch {
            Log.store.error("Could not fetch a document's file: \(Log.code(of: error), privacy: .public)")
            return .noDocument
        }
        guard let document else { return .noDocument }
        guard let file = document.file else { return .noFile }
        guard let data = file.pdfData, !data.isEmpty else { return .noData }
        return .data(data)
    }
}
