import DokumentumCore
import DokumentumKit
import Foundation
import Observation
import PDFKit

/// What the detail column shows.
enum DetailState: Equatable {
    /// No document is selected, or the selected one is gone.
    case noSelection
    /// The PDF of the selected document is being read.
    case loading
    /// "Still downloading": the document has no file yet, or its file has no data yet.
    case stillDownloading
    /// "This PDF cannot be shown": the data is not a readable PDF.
    case unreadable
    case pdf(instanceID: UUID, data: Data)
}

/// The library's state for the views: the sidebar's rows and counts, the selected list, and the open
/// document. The views see only values from a `LibrarySource`, never model objects (plan of #3,
/// T1). Sidebar filters and counts run in memory (`LibrarySelection`, `LibraryCounts`).
@MainActor @Observable
final class LibraryModel {
    let source: any LibrarySource

    private(set) var snapshot = LibrarySnapshot.empty
    private(set) var tree = TagTree([])
    private(set) var counts = LibraryCounts()
    /// The documents of `selection`, in list order.
    private(set) var documents: [LibraryDocument] = []
    private(set) var detail = DetailState.noSelection

    /// The sidebar's selection; Inbox at the start (PQ1). `nil` on the iPhone when the stack is back
    /// at the sidebar.
    var selection: LibrarySelection? = .inbox {
        didSet {
            guard selection != oldValue else { return }
            applySelection()
        }
    }

    /// The open document's `instanceID`. The detail column loads it with `loadDetail(for:)`. When it clears (the
    /// document left the list, or the iPhone went back), the info panel closes: it has nothing to show.
    var selectedDocumentID: UUID? {
        didSet {
            if selectedDocumentID == nil { isInfoPresented = false }
        }
    }

    /// The tags whose nested tags are shown.
    var expandedTags: Set<UUID> = []

    /// Whether the open document's info panel is shown (Document › Show Info, ⌘I).
    var isInfoPresented = false

    /// Whether the source has been read at least once.
    private(set) var isLoaded = false
    /// Counts `loadDetail` calls: only the newest one's result is shown.
    private var detailGeneration = 0

    /// - Parameter loadNow: reads the source at once; a view passes `false` and calls `loadIfNeeded()` when
    ///   it appears, because SwiftUI may create it again on any re-evaluation and discards that model.
    init(source: any LibrarySource, loadNow: Bool = true) {
        self.source = source
        if loadNow { reload() }
    }

    /// Reads the source unless it was read before.
    func loadIfNeeded() {
        if !isLoaded { reload() }
    }

    /// Reads the source again and refilters. A selected document that left the list is deselected.
    func reload() {
        isLoaded = true
        snapshot = source.snapshot()
        tree = TagTree(snapshot.tags)
        counts = LibraryCounts(snapshot.documents, tree: tree)
        applySelection()
    }

    private func applySelection() {
        documents = selection.map { $0.filter(snapshot.documents, in: tree) } ?? []
        if let selectedDocumentID, !documents.contains(where: { $0.instanceID == selectedDocumentID }) {
            self.selectedDocumentID = nil
        }
    }

    /// Re-reads the source on every `changes` event, and the open document with it, until the
    /// calling task is cancelled. The root view runs it in `.task`.
    func observeChanges() async {
        loadIfNeeded()
        for await _ in source.changes {
            reload()
            if let selectedDocumentID { await loadDetail(for: selectedDocumentID) }
        }
    }

    /// Loads the detail of `instanceID` (`nil`: nothing selected). The PDF is read and checked off
    /// the main actor. A result that arrives after the selection moved on, or after a newer load of the
    /// same document started, is dropped: an older read must not replace a newer one.
    func loadDetail(for instanceID: UUID?) async {
        detailGeneration += 1
        let generation = detailGeneration
        guard let instanceID else {
            detail = .noSelection
            return
        }
        if case .pdf(let shown, _) = detail, shown == instanceID {
            // Keep showing the PDF while it is read again after a change.
        } else {
            detail = .loading
        }
        let state = await source.loadPDF(instanceID: instanceID)
        let next: DetailState
        switch state {
        case .noDocument: next = .noSelection
        case .noFile, .noData: next = .stillDownloading
        case .data(let data):
            next = await Self.isReadablePDF(data) ? .pdf(instanceID: instanceID, data: data) : .unreadable
        }
        guard !Task.isCancelled, generation == detailGeneration, selectedDocumentID == instanceID else { return }
        detail = next
    }

    /// Whether PDFKit can open `data`; off the main actor, since a large PDF takes a while.
    @concurrent
    nonisolated static func isReadablePDF(_ data: Data) async -> Bool {
        guard let document = PDFDocument(data: data) else { return false }
        return document.pageCount > 0
    }

    // MARK: Editing

    /// The open document's row, while it is in the list.
    var selectedDocument: LibraryDocument? {
        selectedDocumentID.flatMap { id in documents.first { $0.instanceID == id } }
    }

    /// Whether the source takes edits (the store does; the fixtures of unit tests do not).
    var canEdit: Bool { source.editor != nil }

    /// Applies one edit to the document with `instanceID` (plan of #3, part 3) and reads the library again at
    /// once, so the info panel shows the new value without waiting for the change event. An edit that was not
    /// saved (the document was trashed or deleted meanwhile, or the save failed and was rolled back) reads it
    /// again too, so the panel shows what the store holds now. `nil`: the source takes no edits, or the save
    /// failed (logged).
    @discardableResult
    func edit(_ change: DocumentEditor.Change, of instanceID: UUID) -> DocumentEditor.Outcome? {
        guard let editor = source.editor else { return nil }
        do {
            let outcome = try editor.apply(change, to: instanceID)
            if outcome != .unchanged { reload() }
            return outcome
        } catch {
            Log.store.error("Could not save an edit: \(Log.code(of: error), privacy: .public)")
            reload()
            return nil
        }
    }

    /// Saves the info panel's title draft to its own document if the user changed it (`TitleDraft`). When the
    /// edit is not saved (the document was trashed or deleted meanwhile, or the save failed and was rolled back),
    /// the draft starts again from the stored title: the field never keeps a title that is not stored and that
    /// would not be saved again (reviews of #57).
    func commitTitle(_ draft: inout TitleDraft) {
        guard let commit = draft.commit() else { return }
        switch edit(.title(commit.title), of: commit.document) {
        case .saved, .unchanged:
            return
        case .noDocument, .trashed, .noMetadata, nil:
            // A document that is gone has no title to show: it left the list, and the panel closed with it.
            guard let stored = snapshot.documents.first(where: { $0.instanceID == commit.document }) else { return }
            draft.show(commit.document, title: stored.title)
        }
    }

    /// The correspondent, type or tag named `name` (an existing one with the same merge key, or a new one),
    /// set on the document with `instanceID`; a tag is added. An empty name does nothing.
    @discardableResult
    func assignMetadata(_ kind: MetadataKind, named name: String, to instanceID: UUID) -> DocumentEditor.Outcome? {
        guard let editor = source.editor else { return nil }
        let record: UUID
        do {
            record = try editor.createMetadata(kind: kind, name: name)
        } catch DocumentEditor.MetadataError.emptyName {
            return nil
        } catch {
            Log.store.error("Could not save new metadata: \(Log.code(of: error), privacy: .public)")
            return nil
        }
        let change: DocumentEditor.Change =
            switch kind {
            case .correspondent: .correspondent(record)
            case .documentType: .documentType(record)
            case .tag: .tag(record, true)
            }
        let outcome = edit(change, of: instanceID)
        // A reused record the document already had saves nothing, and `edit` reads nothing then; the new record
        // itself was saved.
        if outcome == .unchanged { reload() }
        return outcome
    }

    /// Every live tag with its display path, sorted by it: the info panel's tag list.
    var tagChoices: [(instanceID: UUID, path: String)] {
        tree.tags.keys.map { ($0, tree.displayPath(of: $0)) }
            .sorted { lhs, rhs in
                switch lhs.1.localizedStandardCompare(rhs.1) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.0.uuidString < rhs.0.uuidString
                }
            }
    }

    // MARK: Sidebar

    /// The display path of each of the document's tags, sorted, for rows and VoiceOver. A tag the
    /// sidebar does not list (a tombstone whose chain ends nowhere) shows by its name.
    func tagPaths(of document: LibraryDocument) -> [String] {
        document.tagIDs.map { tree.tags[$0] == nil ? snapshot.unlistedTagNames[$0] ?? "" : tree.displayPath(of: $0) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func toggleExpanded(_ tag: UUID) {
        if expandedTags.contains(tag) { expandedTags.remove(tag) } else { expandedTags.insert(tag) }
    }
}
