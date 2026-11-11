import DokumentumKit
import Foundation
import PDFKit
import SwiftData
import UniformTypeIdentifiers

/// What an import source needs from the importer; the app's tests stub it.
public protocol DocumentImporting: Sendable {
    /// Imports one file whose bytes were already read: a PDF as it is, an image as a one-page PDF (part 3), a
    /// multi-page TIFF as a PDF with a page per frame (#90; GIF, APNG and HEIC with several images give their
    /// first).
    /// **PDF bytes are a PDF whatever the label** (#86): a sender can declare a PDF as an image, and the image
    /// path would keep only its first page. Never throws: every way it can end is an outcome.
    /// - Parameters:
    ///   - fileName: the file's name with its extension; it becomes the title (`importTitle`).
    ///   - contentType: the type a provider declared; `nil` takes it from the name's extension. Bytes that are
    ///     not a PDF go by it.
    ///   - source: the source of a PDF; an image is always `.image`.
    func importFile(data: Data, fileName: String, contentType: UTType?, source: DocumentSource) async
        -> ImportOutcome

    /// Imports images as one document, one page per image in their order (part 3): photos picked together. A
    /// multi-page TIFF gives a page per frame at its place (#90); other formats with several images their first.
    /// - Parameters:
    ///   - fileName: the `originalFileName` (empty for photos); the title when `title` is `nil`.
    ///   - title: the document's title, such as "Photo <date, time>" (PQ2); `nil` takes it from `fileName`.
    func importImages(_ items: [Data], fileName: String, title: String?, source: DocumentSource) async
        -> ImageImportResult

    /// Imports edited photos as one document (#5, step 4): a page per `EditedPage`, in order, each cleaned with
    /// its edit (`PageCleanup`). The duplicate hash is today's rule for photos: the original bytes of each
    /// image that keeps at least one page, once per image, in order; the edits do not enter it. So identity
    /// edits, and any other edits, of the same photos are a duplicate of `importImages` of them.
    /// - Parameters:
    ///   - title: the document's title, such as "Photo <date, time>"; `originalFileName` stays empty.
    func importEditedImages(_ items: [EditedImage], title: String, source: DocumentSource) async
        -> ImageImportResult
}

/// The one import pipeline (plan of #4, parts 2 and 3). **One instance for the whole app**, created next to
/// the container in `DokumentumApp`, so every window and every later source (Photos, the share queue) goes
/// through the same actor.
///
/// **It only inserts.** A new `Document` with its `DocumentFile` and `DocumentText`, in one save, in a fresh
/// context. It never writes to an existing row: a duplicate is reported, not touched (SwiftData writes whole
/// rows and has no merge policy).
///
/// **Order of one import:** the type (PDF or image: PDF bytes, `%PDF-` within the first KB, are a PDF whatever
/// the label, #86; anything else by its label), not empty, the hash (off the actor), the first duplicate
/// check (a short-lived context), for images building the PDF (`PDFBuilder`, off the actor), PDFKit's check
/// (off the actor: it opens, is not locked, has a page; bytes that only look like a PDF and do not open go on
/// as an image when their label says image, as before #86), then `commit`: one synchronous call that opens a
/// fresh context, checks for a duplicate again, inserts and saves. **No `await` while a context is in use**
/// (plan review N3): the contexts live inside synchronous calls only.
///
/// **Concurrent imports.** The awaits for hashing, building and PDFKit let other imports run meanwhile, so
/// large files do not wait for each other. The step that touches the store, `commit`, runs to its end on the
/// actor without a suspension, so two imports of the same bytes can never both pass its duplicate check: one
/// document, one duplicate. That second check is what holds it; the first only saves the work before it.
///
/// **Images (part 3, T3).** The hash is taken over the original bytes, never over the built PDF: an image
/// file's bytes; photos picked together, their bytes concatenated in selection order (the predecessor's
/// `PendingImport.make`). So the same image or the same selection is a duplicate the next time, and the same
/// photos in another order are not. An image that cannot be decoded is left out of the document and counted
/// (`ImageImportResult.leftOut`); the hash still covers its bytes.
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
        Self.log(outcome, items: 1, bytes: data.count, leftOut: 0, fileName: fileName)
        return outcome
    }

    public func importImages(
        _ items: [Data], fileName: String, title: String? = nil, source: DocumentSource = .image
    ) async -> ImageImportResult {
        let result = await runImages(items, fileName: fileName, title: title, source: source)
        Self.log(
            result.outcome, items: items.count, bytes: items.reduce(0) { $0 + $1.count }, leftOut: result.leftOut,
            fileName: fileName)
        return result
    }

    public func importEditedImages(_ items: [EditedImage], title: String, source: DocumentSource = .image) async
        -> ImageImportResult
    {
        let kept = items.filter { !$0.pages.isEmpty }
        let result = await runEditedImages(kept, title: title, source: source)
        Self.log(
            result.outcome, items: kept.count, bytes: kept.reduce(0) { $0 + $1.data.count },
            leftOut: result.leftOut, fileName: "")
        return result
    }

    private static func log(_ outcome: ImportOutcome, items: Int, bytes: Int, leftOut: Int, fileName: String) {
        switch outcome {
        case .imported:
            Log.importing.notice(
                """
                Imported: \(items, privacy: .public) items, \(leftOut, privacy: .public) left out, \
                \(bytes, privacy: .public) bytes, \(fileName, privacy: .private)
                """)
        case .duplicate(_, _, let isTrashed):
            Log.importing.notice(
                """
                Duplicate skipped: \(items, privacy: .public) items, \(bytes, privacy: .public) bytes, trashed \
                \(isTrashed, privacy: .public), \(fileName, privacy: .private)
                """)
        case .failed(let failure):
            Log.importing.error(
                """
                Not imported: \(String(describing: failure), privacy: .public), \(items, privacy: .public) items, \
                \(bytes, privacy: .public) bytes, \(fileName, privacy: .private)
                """)
        }
    }

    private func run(data: Data, fileName: String, contentType: UTType?, source: DocumentSource) async
        -> ImportOutcome
    {
        switch Self.kind(of: data, fileName: fileName, contentType: contentType) {
        case nil:
            return .failed(.unsupportedType)
        case .image?:
            return await runImages([data], fileName: fileName, title: nil, source: .image).outcome
        case .pdf?:
            break
        }
        guard !data.isEmpty else { return .failed(.empty) }
        let hash = await Self.hash(data)
        if let duplicate = firstDuplicateCheck(hash) { return duplicate }
        let pageCount: Int
        switch await Self.validate(data) {
        case .failure(.unreadablePDF) where Self.kind(fileName: fileName, contentType: contentType) == .image:
            // Bytes that look like a PDF but do not open as one, under an image label: an image with `%PDF-` in
            // its metadata. It goes on as an image, as before #86; a real PDF is never rasterized (`ImageCoding`).
            return await runImages([data], fileName: fileName, title: nil, source: .image).outcome
        case .failure(let failure): return .failed(failure)
        case .success(let pages): pageCount = pages
        }
        if let hook = ProcessingEnvironment.current.importWillCommit { await hook() }
        return commit(
            pdfData: data, hash: hash, title: importTitle(fromFileName: fileName), fileName: fileName,
            source: source, pageCount: pageCount)
    }

    /// Images to one PDF: the hash over the original bytes, the first duplicate check, the PDF built (that
    /// takes time, so the commit checks again), PDFKit's check of the built PDF, then `commit`.
    private func runImages(_ items: [Data], fileName: String, title: String?, source: DocumentSource) async
        -> ImageImportResult
    {
        guard items.contains(where: { !$0.isEmpty }) else { return ImageImportResult(outcome: .failed(.empty)) }
        let hash = await Self.hash(concatenating: items)
        if let duplicate = firstDuplicateCheck(hash) { return ImageImportResult(outcome: duplicate) }
        guard let built = await Self.buildPDF(items) else {
            return ImageImportResult(outcome: .failed(.unreadableImage))
        }
        let pageCount: Int
        switch await Self.validate(built.data) {
        case .failure: return ImageImportResult(outcome: .failed(.unreadableImage))
        case .success(let pages): pageCount = pages
        }
        if let hook = ProcessingEnvironment.current.importWillCommit { await hook() }
        let outcome = commit(
            pdfData: built.data, hash: hash, title: title ?? importTitle(fromFileName: fileName),
            fileName: fileName, source: source, pageCount: pageCount)
        // Left out counts only for the document saved here.
        guard case .imported = outcome else { return ImageImportResult(outcome: outcome) }
        return ImageImportResult(outcome: outcome, leftOut: built.leftOut)
    }

    /// Edited photos to one PDF, in the order of `runImages`: the hash over the kept images' original bytes
    /// (each image once, finding 2 of the plan review on #5), the first duplicate check, the PDF built with
    /// the edits, PDFKit's check, then `commit`. `items` are the images that keep a page.
    private func runEditedImages(_ items: [EditedImage], title: String, source: DocumentSource) async
        -> ImageImportResult
    {
        guard items.contains(where: { !$0.data.isEmpty }) else { return ImageImportResult(outcome: .failed(.empty)) }
        let hash = await Self.hash(concatenating: items.map(\.data))
        if let duplicate = firstDuplicateCheck(hash) { return ImageImportResult(outcome: duplicate) }
        guard let built = await Self.buildPDF(edited: items) else {
            return ImageImportResult(outcome: .failed(.unreadableImage))
        }
        let pageCount: Int
        switch await Self.validate(built.data) {
        case .failure: return ImageImportResult(outcome: .failed(.unreadableImage))
        case .success(let pages): pageCount = pages
        }
        if let hook = ProcessingEnvironment.current.importWillCommit { await hook() }
        let outcome = commit(
            pdfData: built.data, hash: hash, title: title, fileName: "", source: source, pageCount: pageCount)
        guard case .imported = outcome else { return ImageImportResult(outcome: outcome) }
        return ImageImportResult(outcome: outcome, leftOut: built.leftOut)
    }

    /// The duplicate check before the work, in a short-lived context: the existing document, a store failure,
    /// or `nil` to go on.
    private func firstDuplicateCheck(_ hash: String) -> ImportOutcome? {
        do {
            let context = ModelContext(container)
            return try Self.existingDocument(withHash: hash, in: context)
        } catch {
            Log.importing.error("Duplicate check failed: \(Log.code(of: error), privacy: .public)")
            return .failed(.storeFailed)
        }
    }

    /// The second duplicate check, the insert and the one save, in a fresh context, without a suspension.
    /// `hash` is the input's (T3), `pdfData` what is stored.
    private func commit(
        pdfData data: Data, hash: String, title: String, fileName: String, source: DocumentSource, pageCount: Int
    ) -> ImportOutcome {
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
        let document = Document(title: normalizedTitle(title), createdAt: date)
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

    /// What the importer does with a file of a type.
    enum Kind: Equatable {
        case pdf, image
    }

    /// PDF bytes are a PDF whatever the label (#86, T1): `ImportContent.isPDF`. Anything else by its label.
    static func kind(of data: Data, fileName: String, contentType: UTType?) -> Kind? {
        if ImportContent.isPDF(data) { return .pdf }
        return kind(fileName: fileName, contentType: contentType)
    }

    /// The label's kind: PDF or image by the declared type, else by the name's extension; `nil` for anything
    /// else.
    static func kind(fileName: String, contentType: UTType?) -> Kind? {
        guard let type = contentType ?? UTType(filenameExtension: (fileName as NSString).pathExtension) else {
            return nil
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return nil
    }

    @concurrent
    static func hash(_ data: Data) async -> String {
        ContentHash.sha256(data)
    }

    @concurrent
    static func hash(concatenating items: [Data]) async -> String {
        ContentHash.sha256(concatenating: items)
    }

    /// `PDFBuilder`, off the actor: decoding and compressing images takes time.
    @concurrent
    static func buildPDF(_ items: [Data]) async -> PDFBuilder.Result? {
        PDFBuilder.makePDF(fromImageData: items)
    }

    /// `PDFBuilder` for edited photos, off the actor.
    @concurrent
    static func buildPDF(edited items: [EditedImage]) async -> PDFBuilder.Result? {
        PDFBuilder.makePDF(fromEditedImages: items)
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
