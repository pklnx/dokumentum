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

    /// The open document's `instanceID`. The detail column loads it with `loadDetail(for:)`.
    var selectedDocumentID: UUID?

    /// The tags whose nested tags are shown.
    var expandedTags: Set<UUID> = []

    init(source: any LibrarySource) {
        self.source = source
        reload()
    }

    /// Reads the source again and refilters. A selected document that left the list is deselected.
    func reload() {
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
        for await _ in source.changes {
            reload()
            if let selectedDocumentID { await loadDetail(for: selectedDocumentID) }
        }
    }

    /// Loads the detail of `instanceID` (`nil`: nothing selected). The PDF is read and checked off
    /// the main actor. A result that arrives after the selection moved on is dropped.
    func loadDetail(for instanceID: UUID?) async {
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
        guard !Task.isCancelled, selectedDocumentID == instanceID else { return }
        detail = next
    }

    /// Whether PDFKit can open `data`; off the main actor, since a large PDF takes a while.
    @concurrent
    nonisolated static func isReadablePDF(_ data: Data) async -> Bool {
        guard let document = PDFDocument(data: data) else { return false }
        return document.pageCount > 0
    }

    // MARK: Sidebar

    /// The display path of each of the document's tags, sorted, for rows and VoiceOver.
    func tagPaths(of document: LibraryDocument) -> [String] {
        document.tagIDs.map(tree.displayPath(of:)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func toggleExpanded(_ tag: UUID) {
        if expandedTags.contains(tag) { expandedTags.remove(tag) } else { expandedTags.insert(tag) }
    }
}
