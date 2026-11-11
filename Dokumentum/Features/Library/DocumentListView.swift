import DokumentumKit
import SwiftUI

/// The documents of the sidebar's selection, newest document date first (PQ4). One document at a
/// time (PQ11).
struct DocumentListView: View {
    @Bindable var model: LibraryModel
    #if os(macOS)
        /// Whether the list has the keyboard focus. A click on a row does not move the focus there by itself: the
        /// info panel's title field kept it, and ⌘⌫ meant for Move to Trash then emptied the title, which was saved
        /// (review of #74, finding 1). So a click on a row, the selected one too, and every change of the
        /// selection give the list the focus.
        @FocusState private var isListFocused: Bool
    #endif

    var body: some View {
        List(selection: $model.selectedDocumentID) {
            ForEach(model.documents) { document in
                let tagPaths = model.tagPaths(of: document)
                NavigationLink(value: document.instanceID) {
                    DocumentRow(document: document, tagPaths: tagPaths)
                }
                .accessibilityIdentifier(AccessibilityID.documentRow(document.instanceID))
                .modifier(TrashRowActions(document: document))
                #if os(macOS)
                    // The whole row, also the gap between its lines, takes the click that gives the list the focus.
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { isListFocused = true })
                    // A row whose content changes is replaced, so the table measures it again (#80): see below.
                    .id(RowInputs(document: document, tagPaths: tagPaths))
                #endif
            }
        }
        #if os(macOS)
            .focused($isListFocused)
            .onChange(of: model.selectedDocumentID) { _, selected in
                if selected != nil { isListFocused = true }
            }
            // The Mac's table-backed `List` measures a row inserted above existing ones once, when it is inserted, and
            // keeps that height. Two fixes cover that:
            // - Inserts need an animated update to be measured at all (#72). Without one, the table gives the rows its
            //   estimated row height (24 pt), so a two-line row is cut to its title. Zero duration: the list looks as
            //   before, only the update path changes.
            // - A content change, such as a tag added or removed, updates the cell in place and the row keeps its
            //   height (#80): a new tag line is cut, a removed one leaves a gap. So each row's identity includes what
            //   it shows (`RowInputs`): a changed row is removed and inserted again, and the table measures it. The
            //   new height applies at once, without an animation (maintainer decision on #80).
            .animation(.linear(duration: 0), value: model.documents.map(\.instanceID))
        #endif
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
        // The trash's toolbar has only Empty Trash: an import lands in the Inbox, not in the trash (#70).
        .toolbar {
            if model.selection == .trash {
                ToolbarItem(placement: .primaryAction) {
                    EmptyTrashButton()
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    ImportToolbarMenu()
                }
            }
        }
        #if os(macOS)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.selection == .inbox {
            ContentUnavailableView("Inbox empty", systemImage: "tray")
        } else if model.selection == .trash {
            ContentUnavailableView("Trash empty", systemImage: "trash")
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

#if os(macOS)
    /// Everything a `DocumentRow` shows: its two inputs, so the identity cannot miss a field the row adds later.
    private struct RowInputs: Hashable {
        let document: LibraryDocument
        let tagPaths: [String]
    }
#endif
