import DokumentumKit
import Foundation
import PDFKit
import SwiftData
import UniformTypeIdentifiers

/// What an import source needs from the importer; the app's tests stub it.
public protocol DocumentImporting: Sendable {
    /// Imports one file whose bytes were already read. Never throws: every way it can end is an outcome.
    /// - Parameters:
    ///   - fileName: the file's name with its extension; it becomes the title (`importTitle`).
    ///   - contentType: the type a provider declared; `nil` takes it from the name's extension.
    func importFile(data: Data, fileName: String, contentType: UTType?, source: DocumentSource) async
        -> ImportOutcome
}

/// The one import pipeline (plan of #4, part 2). **One instance for the whole app**, created next to the
/// container in `DokumentumApp`, so every window and every later source (Photos, the share queue) goes
/// through the same actor.
///
/// **It only inserts.** A new `Document` with its `DocumentFile` and `DocumentText`, in one save, in a fresh
/// context. It never writes to an existing row: a duplicate is reported, not touched (SwiftData writes whole
/// rows and has no merge policy).
///
/// **Order of one import:** the type (PDF only in this part), not empty, the hash (off the actor), the first
/// duplicate check (a short-lived context), PDFKit's check (off the actor: it opens, is not locked, has a
/// page), then `commit`: one synchronous call that opens a fresh context, checks for a duplicate again,
/// inserts and saves. **No `await` while a context is in use** (plan review N3): the contexts live inside
/// synchronous calls only.
///
/// **Concurrent imports.** The awaits for hashing and PDFKit let other imports run meanwhile, so large files
/// do not wait for each other. The step that touches the store, `commit`, runs to its end on the actor
/// without a suspension, so two imports of the same bytes can never both pass its duplicate check: one
/// document, one duplicate. That second check is what holds it; the first only saves the PDFKit work.
public actor DocumentImporter: DocumentImporting {
    public let container: ModelContainer
    /// This device's `processingDeviceID` (`DeviceIdentity`): the importing device claims the document (T4).
    public let deviceID: String
    private let now: @Sendable () -> Date

    public init(container: ModelContainer, deviceID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.container = container
        self.deviceID = deviceID
        self.now = now
    }

    public func importFile(
        data: Data, fileName: String, contentType: UTType? = nil, source: DocumentSource = .file
    ) async -> ImportOutcome {
        let outcome = await run(data: data, fileName: fileName, contentType: contentType, source: source)
        switch outcome {
        case .imported:
            Log.importing.notice(
                "Imported: \(data.count, privacy: .public) bytes, \(fileName, privacy: .private)")
        case .duplicate(_, _, let isTrashed):
            Log.importing.notice(
                """
                Duplicate skipped: \(data.count, privacy: .public) bytes, trashed \(isTrashed, privacy: .public), \
                \(fileName, privacy: .private)
                """)
        case .failed(let failure):
            Log.importing.error(
                """
                Not imported: \(String(describing: failure), privacy: .public), \(data.count, privacy: .public) \
                bytes, \(fileName, privacy: .private)
                """)
        }
        return outcome
    }

    private func run(data: Data, fileName: String, contentType: UTType?, source: DocumentSource) async
        -> ImportOutcome
    {
        guard Self.isPDF(fileName: fileName, contentType: contentType) else { return .failed(.unsupportedType) }
        guard !data.isEmpty else { return .failed(.empty) }
        let hash = await Self.hash(data)
        do {
            let context = ModelContext(container)
            if let duplicate = try Self.existingDocument(withHash: hash, in: context) { return duplicate }
        } catch {
            Log.importing.error("Duplicate check failed: \(Log.code(of: error), privacy: .public)")
            return .failed(.storeFailed)
        }
        let pageCount: Int
        switch await Self.validate(data) {
        case .failure(let failure): return .failed(failure)
        case .success(let pages): pageCount = pages
        }
        if let hook = ProcessingEnvironment.current.importWillCommit { await hook() }
        return commit(data: data, hash: hash, fileName: fileName, source: source, pageCount: pageCount)
    }

    /// The second duplicate check, the insert and the one save, in a fresh context, without a suspension.
    private func commit(data: Data, hash: String, fileName: String, source: DocumentSource, pageCount: Int)
        -> ImportOutcome
    {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            if let duplicate = try Self.existingDocument(withHash: hash, in: context) { return duplicate }
        } catch {
            Log.importing.error("Duplicate check failed: \(Log.code(of: error), privacy: .public)")
            return .failed(.storeFailed)
        }
        let date = now()
        // `documentDate` stays the import time until step 10 detects it (PQ2); `isInbox` keeps its default.
        let document = Document(title: importTitle(fromFileName: fileName), createdAt: date)
        document.originalFileName = fileName
        document.source = source
        document.contentHash = hash
        document.fileSize = data.count
        document.pageCount = pageCount
        document.processingState = .pending
        document.processingDeviceID = deviceID
        document.processingClaimedAt = date
        let file = DocumentFile(documentID: document.id, pdfData: data, createdAt: date)
        let text = DocumentText(documentID: document.id, createdAt: date)
        context.insert(document)
        context.insert(file)
        context.insert(text)
        document.file = file
        document.text = text
        do {
            try context.save()
        } catch {
            context.rollback()
            Log.importing.error("Import not saved: \(Log.code(of: error), privacy: .public)")
            return .failed(.storeFailed)
        }
        return .imported(instanceID: document.instanceID)
    }

    /// Whether the file is a PDF: by the declared type, else by the name's extension.
    static func isPDF(fileName: String, contentType: UTType?) -> Bool {
        let type = contentType ?? UTType(filenameExtension: (fileName as NSString).pathExtension)
        return type?.conforms(to: .pdf) ?? false
    }

    @concurrent
    static func hash(_ data: Data) async -> String {
        ContentHash.sha256(data)
    }

    /// PDFKit's check: the PDF opens, is not locked by a password (PQ9) and has a page. Off the actor. A PDF
    /// without a page counts as unreadable: PDFKit on 27 does not open one (`aFileThatFailsInsertsNothing`).
    @concurrent
    static func validate(_ data: Data) async -> Result<Int, ImportFailure> {
        guard let document = PDFDocument(data: data) else { return .failure(.unreadablePDF) }
        if document.isLocked { return .failure(.passwordProtected) }
        guard document.pageCount > 0 else { return .failure(.unreadablePDF) }
        return .success(document.pageCount)
    }

    /// The document that already holds these bytes, trashed ones included (PQ3): the oldest with this
    /// `contentHash`. It reads only `Document` rows, never a file, thumbnail or text (`ImportSQLTests`):
    /// every document gets its hash at import, so the predecessor's fallback that hashed stored PDFs is gone.
    public static func existingDocument(withHash hash: String, in context: ModelContext) throws -> ImportOutcome? {
        var descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.contentHash == hash }, sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        guard let existing = try context.fetch(descriptor).first else { return nil }
        return .duplicate(of: existing.instanceID, title: existing.title, isTrashed: existing.deletedAt != nil)
    }
}
