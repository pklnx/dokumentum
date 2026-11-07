import DokumentumKit
import SwiftUI

/// The documents of the sidebar's selection, newest document date first (PQ4). One document at a
/// time (PQ11).
struct DocumentListView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: $model.selectedDocumentID) {
            ForEach(model.documents) { document in
                NavigationLink(value: document.instanceID) {
                    DocumentRow(document: document, tagPaths: model.tagPaths(of: document))
                }
                .accessibilityIdentifier(AccessibilityID.documentRow(document.instanceID))
            }
        }
        // On the list itself, before the overlay: an identifier after it would also replace the empty
        // state's own (measured on macOS, #44).
        .accessibilityIdentifier(AccessibilityID.documentList)
        .overlay {
            if model.documents.isEmpty {
                emptyState
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.documentListEmpty)
            }
        }
        .navigationTitle(title)
        #if os(macOS)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.selection == .inbox {
            ContentUnavailableView("Inbox empty", systemImage: "tray")
        } else {
            ContentUnavailableView("No documents", systemImage: "doc")
        }
    }

    private var title: Text {
        switch model.selection {
        case .inbox, nil: Text("Inbox")
        case .all: Text("All Documents")
        case .trash: Text("Trash")
        case .tag(let id): Text(verbatim: model.tree.tags[id]?.name ?? "")
        case .correspondent(let id):
            Text(verbatim: model.snapshot.correspondents.first { $0.instanceID == id }?.name ?? "")
        case .documentType(let id):
            Text(verbatim: model.snapshot.documentTypes.first { $0.instanceID == id }?.name ?? "")
        }
    }
}
