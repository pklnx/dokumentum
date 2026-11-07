import Foundation

/// Why a file was not imported.
public enum ImportFailure: Error, Hashable, Sendable, CaseIterable {
    /// The file is neither a PDF nor an image (parts 2 and 3 of #4).
    case unsupportedType
    /// The file has no bytes.
    case empty
    /// The bytes are not a PDF PDFKit can open, the PDF is damaged, or it has no page (PDFKit on 27 does not
    /// open a PDF with an empty page tree at all, measured on #59).
    case unreadablePDF
    /// The PDF needs a password to open (PQ9).
    case passwordProtected
    /// An image file, or photos picked together, that ImageIO cannot decode: no page could be built (part 3).
    case unreadableImage
    /// The file could not be read: no access, or a file in iCloud Drive that could not be downloaded.
    case couldNotRead
    /// The archive could not be read for the duplicate check, or refused the save.
    case storeFailed
}

/// What the importer did with one file.
public enum ImportOutcome: Hashable, Sendable {
    /// A new inbox document with this `instanceID`.
    case imported(instanceID: UUID)
    /// The archive already has a document with exactly these bytes (PQ3: trashed ones included); nothing was
    /// written. `title` is the existing document's title as stored (it can be empty).
    case duplicate(of: UUID, title: String, isTrashed: Bool)
    case failed(ImportFailure)
}

/// What the importer did with images that become one document (part 3 of #4): the outcome, and how many of
/// the images could not be decoded and were left out of the document.
public struct ImageImportResult: Hashable, Sendable {
    public var outcome: ImportOutcome
    public var leftOut: Int

    public init(outcome: ImportOutcome, leftOut: Int = 0) {
        self.outcome = outcome
        self.leftOut = leftOut
    }
}

/// The alert shown after an import (PQ4).
public struct ImportNotice: Hashable, Sendable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// The words of a notice. Kit emits no strings: the app passes them in from its catalog.
public struct ImportNoticeStrings: Sendable {
    /// Nothing imported, only duplicates: "Already in the archive".
    public var alreadyInArchive: @Sendable () -> String
    /// Some imported, some duplicates, no failure: "%lld imported, duplicates skipped".
    public var importedDuplicatesSkipped: @Sendable (_ importedCount: Int) -> String
    /// A failure and something else imported or skipped: "Import partly failed".
    public var partlyFailed: @Sendable () -> String
    /// Only failures: "Import failed".
    public var failed: @Sendable () -> String
    /// The heading of the duplicate lines, with their count ("This file is already in the archive …").
    public var duplicatesHeading: @Sendable (_ count: Int) -> String
    /// One duplicate: "• name → “title”", with "(in the Trash)" when it is trashed.
    public var duplicateLine: @Sendable (_ fileName: String, _ existingTitle: String, _ isTrashed: Bool) -> String
    /// One failure, naming the file.
    public var failureLine: @Sendable (_ fileName: String, _ failure: ImportFailure) -> String
    /// Photos of a document that could not be read and were left out: "%lld photos could not be read …".
    public var leftOutLine: @Sendable (_ count: Int) -> String

    public init(
        alreadyInArchive: @escaping @Sendable () -> String,
        importedDuplicatesSkipped: @escaping @Sendable (Int) -> String,
        partlyFailed: @escaping @Sendable () -> String,
        failed: @escaping @Sendable () -> String,
        duplicatesHeading: @escaping @Sendable (Int) -> String,
        duplicateLine: @escaping @Sendable (String, String, Bool) -> String,
        failureLine: @escaping @Sendable (String, ImportFailure) -> String,
        leftOutLine: @escaping @Sendable (Int) -> String
    ) {
        self.alreadyInArchive = alreadyInArchive
        self.importedDuplicatesSkipped = importedDuplicatesSkipped
        self.partlyFailed = partlyFailed
        self.failed = failed
        self.duplicatesHeading = duplicatesHeading
        self.duplicateLine = duplicateLine
        self.failureLine = failureLine
        self.leftOutLine = leftOutLine
    }
}

/// The outcomes of one batch (one pick, one drop), in the order of its files. Ported from the predecessor's
/// `ImportResult` (pklnx/document-archive `ec5c71d`), without model objects: it holds `instanceID`s only.
public struct ImportReport: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var fileName: String
        public var outcome: ImportOutcome
        /// Photos of this entry's document that could not be read and were left out (part 3 of #4).
        public var leftOut: Int

        public init(fileName: String, outcome: ImportOutcome, leftOut: Int = 0) {
            self.fileName = fileName
            self.outcome = outcome
            self.leftOut = leftOut
        }
    }

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public mutating func add(fileName: String, outcome: ImportOutcome, leftOut: Int = 0) {
        entries.append(Entry(fileName: fileName, outcome: outcome, leftOut: leftOut))
    }

    /// The new documents, in batch order.
    public var imported: [UUID] {
        entries.compactMap { if case .imported(let id) = $0.outcome { id } else { nil } }
    }

    /// The skipped files with the existing document, in batch order.
    public var duplicates: [(fileName: String, existing: UUID, title: String, isTrashed: Bool)] {
        entries.compactMap { entry in
            if case .duplicate(let id, let title, let isTrashed) = entry.outcome {
                (entry.fileName, id, title, isTrashed)
            } else {
                nil
            }
        }
    }

    public var failures: [(fileName: String, failure: ImportFailure)] {
        entries.compactMap { if case .failed(let failure) = $0.outcome { ($0.fileName, failure) } else { nil } }
    }

    /// The photos left out of the batch's documents, all entries together.
    public var leftOut: Int {
        entries.reduce(0) { $0 + $1.leftOut }
    }

    /// The document to open afterwards (PQ1): the one new document, or the existing one when the batch's only
    /// outcome was one duplicate. `nil` for several documents and for a batch without either.
    public var documentToOpen: DocumentToOpen? {
        let imported = imported
        if imported.count == 1, let id = imported.first { return .new(id) }
        let duplicates = duplicates
        if imported.isEmpty, duplicates.count == 1, let duplicate = duplicates.first {
            return .existing(duplicate.existing)
        }
        return nil
    }

    public enum DocumentToOpen: Hashable, Sendable {
        case new(UUID)
        case existing(UUID)
    }

    /// The notice for this batch; `nil` when every file was imported whole (PQ4) or the batch was empty.
    /// Wording of the predecessor's `ImportResult.notice`, with "Import failed" when nothing but failures came
    /// out. Photos left out count like a failure: "Import partly failed", with their line last.
    public func notice(_ strings: ImportNoticeStrings) -> ImportNotice? {
        let duplicates = duplicates
        let failures = failures
        let leftOut = leftOut
        guard !duplicates.isEmpty || !failures.isEmpty || leftOut > 0 else { return nil }
        var lines: [String] = []
        if !duplicates.isEmpty {
            lines.append(strings.duplicatesHeading(duplicates.count))
            lines += duplicates.map { strings.duplicateLine($0.fileName, $0.title, $0.isTrashed) }
        }
        lines += failures.map { strings.failureLine($0.fileName, $0.failure) }
        if leftOut > 0 { lines.append(strings.leftOutLine(leftOut)) }
        let importedCount = imported.count
        let title: String
        if failures.isEmpty, leftOut == 0 {
            title = importedCount == 0 ? strings.alreadyInArchive() : strings.importedDuplicatesSkipped(importedCount)
        } else {
            title = importedCount == 0 && duplicates.isEmpty ? strings.failed() : strings.partlyFailed()
        }
        return ImportNotice(title: title, message: lines.joined(separator: "\n"))
    }
}

/// The notices of one window: one is shown, the ones that arrive meanwhile wait, oldest first (the
/// predecessor's `ImportNoticeQueue`). A notice equal to the shown or the last waiting one is not repeated.
public struct ImportNoticeQueue: Hashable, Sendable {
    /// The notice on screen.
    public private(set) var shown: ImportNotice?
    /// The notices waiting, oldest first.
    public private(set) var waiting: [ImportNotice] = []

    public init() {}

    /// Shows `notice` at once when nothing is shown and nothing waits, otherwise queues it. `nil` changes
    /// nothing.
    public mutating func add(_ notice: ImportNotice?) {
        guard let notice, notice != (waiting.last ?? shown) else { return }
        if shown == nil, waiting.isEmpty { shown = notice } else { waiting.append(notice) }
    }

    /// The shown notice was dismissed. The next one comes with `showNext()`, after the alert has closed
    /// (presenting it in the same update would be lost).
    public mutating func dismissShown() {
        shown = nil
    }

    /// Shows the next waiting notice; `false` when one is shown already or none waits.
    @discardableResult
    public mutating func showNext() -> Bool {
        guard shown == nil, !waiting.isEmpty else { return false }
        shown = waiting.removeFirst()
        return true
    }
}
