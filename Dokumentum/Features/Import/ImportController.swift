import DokumentumCore
import DokumentumKit
import Foundation
import Observation

/// The imports of one window (plan of #4, part 2), like `LibraryModel` one per window: it reads each picked
/// or dropped file off the main actor, hands the bytes to the app's one `DocumentImporter`, collects the
/// batch's outcomes in input order, then selects the result (PQ1) and queues the notice (PQ4).
@MainActor @Observable
final class ImportController {
    let importer: any DocumentImporting
    let reader: any ImportFileReading
    let library: LibraryModel

    /// The window's notices: one shown, the others waiting.
    private(set) var notices = ImportNoticeQueue()
    /// Whether the files picker is open (the "+" menu and ⌘O open it).
    var isPickingFiles = false

    init(
        importer: any DocumentImporting, reader: any ImportFileReading = CoordinatedFileReader(), library: LibraryModel
    ) {
        self.importer = importer
        self.reader = reader
        self.library = library
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
            case .unsupportedType: String(localized: "“\(fileName)” is not a PDF and was not imported.")
            case .empty: String(localized: "“\(fileName)” is empty and was not imported.")
            case .unreadablePDF: String(localized: "“\(fileName)” is damaged or not a PDF and was not imported.")
            case .passwordProtected: String(localized: "“\(fileName)” is password-protected and was not imported.")
            case .couldNotRead: String(localized: "“\(fileName)” could not be read and was not imported.")
            case .storeFailed: String(localized: "“\(fileName)” could not be saved in the archive.")
            }
        })
}
