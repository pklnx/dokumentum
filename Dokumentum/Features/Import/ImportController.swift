import DokumentumCore
import DokumentumKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The imports of one window (plan of #4, parts 2 and 3), like `LibraryModel` one per window: it reads each
/// picked or dropped file (PDF or image) off the main actor, or loads the photos picked in Photos and opens their
/// cleanup (#5, part 3), hands the bytes to the app's one `DocumentImporter`, collects the batch's outcomes in
/// input order, then selects the result (PQ1) and queues the notice (PQ4).
@MainActor @Observable
final class ImportController {
    let importer: any DocumentImporting
    let reader: any ImportFileReading
    let library: LibraryModel

    /// The window's notices: one shown, the others waiting.
    private(set) var notices = ImportNoticeQueue()
    /// Whether the files picker is open (the "+" menu and ⌘O open it).
    var isPickingFiles = false
    /// Whether the Photos picker is open (the "+" menu opens it, part 3).
    var isPickingPhotos = false
    /// Whether the document camera is open (the "+" menu's "Scan…" on the iPhone, #5, part 2).
    var isScanning = false
    /// Whether a scan is being encoded and imported: a long scan takes a moment after the camera closes, and the
    /// window shows that it is being saved (plan review of #5, finding 6).
    private(set) var isSavingScan = false
    /// The photo cleanup of the photos just picked (#5, part 3); `nil` when none is open.
    var cleanup: PhotoCleanupModel?
    /// The cleanup Save closed, until its pages are imported.
    private(set) var savedCleanup: PhotoCleanupModel?
    /// Whether the cleaned photos are being imported, after Save closed the cleanup.
    private(set) var isSavingPhotos = false
    /// Finds the page in each photo of a cleanup.
    let detector: any PageCornerDetecting
    /// The time a photo document's title names.
    private let now: () -> Date

    /// What the files picker, ⌘O and a drop accept: PDFs and images (part 3).
    static let importableTypes: [UTType] = [.pdf, .image]

    init(
        importer: any DocumentImporting, reader: any ImportFileReading = CoordinatedFileReader(),
        library: LibraryModel, detector: any PageCornerDetecting = VisionPageCornerDetector(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.importer = importer
        self.reader = reader
        self.library = library
        self.detector = detector
        self.now = now
    }

    /// Imports `urls` one after another, in their order; a file that cannot be read is a `.failed` outcome
    /// and the batch goes on.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> ImportReport {
        var report = ImportReport()
        for url in urls {
            let fileName = url.lastPathComponent
            let outcome: ImportOutcome
            do {
                let data = try await reader.read(url)
                outcome = await importer.importFile(data: data, fileName: fileName, contentType: nil, source: .file)
            } catch {
                Log.importing.error(
                    "File not read: \(Log.code(of: error), privacy: .public) \(fileName, privacy: .private)")
                outcome = .failed(.couldNotRead)
            }
            report.add(fileName: fileName, outcome: outcome)
        }
        finish(report)
        return report
    }

    /// Opens the cleanup for photos picked together (#5, part 3, P2): a page per photo in selection order (PQ5),
    /// a page per frame of a multi-page TIFF (T8). Nothing is imported until its Save (`saveCleanup`). A photo
    /// Photos cannot hand over (not downloaded, an error), or one that is no image, is left out and counted in the
    /// notice after Save; when none arrives the pick is one failure, and when none can be read one failure too, and
    /// no cleanup opens.
    /// - Returns: the report of a pick that failed; empty when the cleanup opened.
    @discardableResult
    func importPhotos(_ items: [any ImportPhotoItem]) async -> ImportReport {
        var report = ImportReport()
        guard !items.isEmpty, cleanup == nil else { return report }
        var loaded: [Data] = []
        for item in items {
            do {
                if let data = try await item.loadData() {
                    loaded.append(data)
                } else {
                    Log.importing.error("Photo not handed over: no data")
                }
            } catch {
                Log.importing.error("Photo not handed over: \(Log.code(of: error), privacy: .public)")
            }
        }
        let notHandedOver = items.count - loaded.count
        guard !loaded.isEmpty else {
            report.add(fileName: Self.photoTitle(at: now()), outcome: .failed(.couldNotRead))
            finish(report)
            return report
        }
        let sources = await PhotoCleanupModel.pageSources(of: loaded)
        guard !sources.pages.isEmpty else {
            Log.importing.error("Photos not imported: none of \(loaded.count, privacy: .public) can be read")
            report.add(fileName: Self.photoTitle(at: now()), outcome: .failed(.unreadableImage))
            finish(report)
            return report
        }
        let model = PhotoCleanupModel(
            images: loaded, pages: sources.pages, leftOut: notHandedOver + sources.unreadable, detector: detector)
        cleanup = model
        model.start()
        return report
    }

    /// The cleanup's Save: it closes, its detection stops (a page still waiting keeps the edit it has), and its kept
    /// pages are imported as one document titled "Photo <date, time>" (PQ2), which opens (PQ1). The duplicate
    /// check is the photo import's (P7).
    @discardableResult
    func saveCleanup() async -> ImportReport {
        closeCleanupForSave()
        return await importSavedCleanup()
    }

    /// Save's first half: the cleanup closes and its detection stops; its pages wait in `savedCleanup`. The sheet
    /// imports them once it is gone (`importSavedCleanup` from its `onDismiss`): a document opened while the sheet
    /// still animates out is not shown on the iPhone (measured in the UI test, #112).
    func closeCleanupForSave() {
        guard let model = cleanup else { return }
        model.stop()
        cleanup = nil
        savedCleanup = model
        isSavingPhotos = !model.editedImages.isEmpty
    }

    /// Save's second half: imports the pages of the cleanup Save closed, if any.
    @discardableResult
    func importSavedCleanup() async -> ImportReport {
        var report = ImportReport()
        guard let model = savedCleanup else { return report }
        savedCleanup = nil
        defer { isSavingPhotos = false }
        let images = model.editedImages
        guard !images.isEmpty else { return report }
        let title = Self.photoTitle(at: now())
        let result = await importer.importEditedImages(images, title: title, source: .image)
        let leftOut = if case .imported = result.outcome { result.leftOut + model.leftOut } else { 0 }
        report.add(fileName: title, outcome: result.outcome, leftOut: leftOut)
        finish(report)
        return report
    }

    /// The cleanup's Cancel: it closes, nothing is imported and nothing is shown.
    func cancelCleanup() {
        cleanup?.stop()
        cleanup = nil
    }

    /// Imports a scan as one document (#5, part 2), a page per scanned page in order, titled "Scan <date, time>",
    /// with the source `.scan`. It becomes an Inbox document pending processing like any photo import, and opens
    /// (PQ1). A page that cannot be read is left out and counted in the notice; when none can be read, the scan
    /// is one failure. A scan without pages imports nothing and shows nothing.
    @discardableResult
    func importScan(_ scan: some ScannedPages) async -> ImportReport {
        isScanning = false
        var report = ImportReport()
        guard scan.pageCount > 0 else { return report }
        isSavingScan = true
        defer { isSavingScan = false }
        let title = Self.scanTitle(at: now())
        let encoded = await ScanEncoder.jpegPages(scan)
        if encoded.pages.isEmpty {
            Log.importing.error("Scan not imported: none of \(scan.pageCount, privacy: .public) pages could be read")
            report.add(fileName: title, outcome: .failed(.couldNotRead))
        } else {
            let result = await importer.importImages(encoded.pages, fileName: "", title: title, source: .scan)
            let leftOut = if case .imported = result.outcome { result.leftOut + encoded.unreadable } else { 0 }
            report.add(fileName: title, outcome: result.outcome, leftOut: leftOut)
        }
        finish(report, strings: .scan)
        return report
    }

    /// The document camera failed (VisionKit's `didFailWithError`): it closes, nothing is imported, and the
    /// notice says so.
    func scanFailed(_ error: any Error) {
        Log.importing.error("Scan failed: \(Log.code(of: error), privacy: .public)")
        isScanning = false
        notices.add(ImportNotice(title: String(localized: "Scanning failed"), message: ""))
    }

    /// "Scan <date, time>" in the app's language (P4).
    static func scanTitle(at date: Date) -> String {
        let time = date.formatted(date: .numeric, time: .shortened)
        return String(localized: "Scan \(time)")
    }

    /// "Photo <date, time>" in the app's language (PQ2).
    static func photoTitle(at date: Date) -> String {
        let time = date.formatted(date: .numeric, time: .shortened)
        return String(localized: "Photo \(time)")
    }

    /// Imports dropped files like picked ones, then removes their temporary copies.
    @discardableResult
    func importDropped(_ files: [ImportedFile]) async -> ImportReport {
        defer { for file in files { file.remove() } }
        return await importFiles(files.map(\.url))
    }

    /// PQ1: after something was imported the library shows the Inbox; one new document is selected and
    /// opened; one duplicate alone selects the existing document where it is (Inbox, All Documents or Trash);
    /// several are not selected. Then the notice (PQ4).
    private func finish(_ report: ImportReport, strings: ImportNoticeStrings = .app) {
        guard !report.entries.isEmpty else { return }
        // Read now, not at the next change event: the new document must be in the list to be selected.
        library.reload()
        switch report.documentToOpen {
        case .new(let id):
            library.selection = .inbox
            library.selectedDocumentID = id
        case .existing(let id):
            if let document = library.snapshot.documents.first(where: { $0.instanceID == id }) {
                library.selection = document.isTrashed ? .trash : document.isInbox ? .inbox : .all
                library.selectedDocumentID = id
            }
        case nil:
            if !report.imported.isEmpty { library.selection = .inbox }
        }
        notices.add(report.notice(strings))
    }

    /// The share queue's runs (part 4): their notices, like any other import's (PQ4), but nothing is selected or
    /// opened, also for one document (PQ12); the Inbox lists the new documents.
    func showShareQueueReports(_ reports: [ImportReport]) {
        for report in reports { notices.add(report.notice(.app)) }
    }

    /// The shown notice was dismissed; the next waiting one follows in a later update (presenting it in the
    /// same update as the dismissal would be lost).
    /// - Returns: the task that shows it; tests await it.
    @discardableResult
    func dismissNotice() -> Task<Void, Never> {
        notices.dismissShown()
        return Task { self.notices.showNext() }
    }
}

extension ImportNoticeStrings {
    /// The catalog's words (English and German; PQ10).
    static let app = ImportNoticeStrings(
        alreadyInArchive: { String(localized: "Already in the archive") },
        importedDuplicatesSkipped: { count in String(localized: "\(count) imported, duplicates skipped") },
        partlyFailed: { String(localized: "Import partly failed") },
        failed: { String(localized: "Import failed") },
        duplicatesHeading: { count in
            count == 1
                ? String(localized: "This file is already in the archive and was skipped:")
                : String(localized: "\(count) files are already in the archive and were skipped:")
        },
        duplicateLine: { fileName, title, isTrashed in
            let title = displayTitle(title, fallback: String(localized: "Untitled document"))
            return isTrashed
                ? String(localized: "• \(fileName) → “\(title)” (in the Trash)")
                : String(localized: "• \(fileName) → “\(title)”")
        },
        failureLine: { fileName, failure in
            switch failure {
            case .unsupportedType:
                String(localized: "“\(fileName)” is not a PDF or an image and was not imported.")
            case .empty: String(localized: "“\(fileName)” is empty and was not imported.")
            case .unreadablePDF: String(localized: "“\(fileName)” is damaged or not a PDF and was not imported.")
            case .passwordProtected: String(localized: "“\(fileName)” is password-protected and was not imported.")
            case .couldNotRead: String(localized: "“\(fileName)” could not be read and was not imported.")
            case .unreadableImage:
                String(localized: "“\(fileName)” is damaged or not an image and was not imported.")
            case .storeFailed: String(localized: "“\(fileName)” could not be saved in the archive.")
            }
        },
        leftOutLine: { count in
            count == 1
                ? String(localized: "One photo could not be read and was left out.")
                : String(localized: "\(count) photos could not be read and were left out.")
        })
}

extension ImportNoticeStrings {
    /// A scan's notice: the app's words, with pages instead of photos left out (#5, part 2).
    static let scan: ImportNoticeStrings = {
        var strings = ImportNoticeStrings.app
        strings.leftOutLine = { count in
            count == 1
                ? String(localized: "One page could not be read and was left out.")
                : String(localized: "\(count) pages could not be read and were left out.")
        }
        return strings
    }()
}
