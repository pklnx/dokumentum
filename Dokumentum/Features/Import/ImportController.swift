import DokumentumCore
import DokumentumKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The imports of one window (plan of #4, parts 2 and 3), like `LibraryModel` one per window: it reads each
/// picked or dropped file (PDF or image) off the main actor, or loads the photos picked in Photos, hands the
/// bytes to the app's one `DocumentImporter`, collects the batch's outcomes in input order, then selects the
/// result (PQ1) and queues the notice (PQ4).
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
    /// The time a photo document's title names.
    private let now: () -> Date

    /// What the files picker, ⌘O and a drop accept: PDFs and images (part 3).
    static let importableTypes: [UTType] = [.pdf, .image]

    init(
        importer: any DocumentImporting, reader: any ImportFileReading = CoordinatedFileReader(),
        library: LibraryModel, now: @escaping () -> Date = { Date() }
    ) {
        self.importer = importer
        self.reader = reader
        self.library = library
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

    /// Imports photos picked together as one document, a page per photo in selection order (PQ5), titled
    /// "Photo <date, time>" (PQ2). A photo Photos cannot hand over (not downloaded, an error) is left out and
    /// counted in the notice; when none arrives, the batch is one failure.
    @discardableResult
    func importPhotos(_ items: [any ImportPhotoItem]) async -> ImportReport {
        var report = ImportReport()
        guard !items.isEmpty else { return report }
        let title = Self.photoTitle(at: now())
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
        if loaded.isEmpty {
            report.add(fileName: title, outcome: .failed(.couldNotRead))
        } else {
            let result = await importer.importImages(loaded, fileName: "", title: title, source: .image)
            let leftOut = if case .imported = result.outcome { result.leftOut + notHandedOver } else { 0 }
            report.add(fileName: title, outcome: result.outcome, leftOut: leftOut)
        }
        finish(report)
        return report
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
    private func finish(_ report: ImportReport) {
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
        notices.add(report.notice(.app))
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
