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
                row(document)
                    .accessibilityIdentifier(AccessibilityID.documentRow(document.instanceID))
                    .modifier(TrashRowActions(document: document))
                    #if os(macOS)
                        // The whole row, also the gap between its lines, takes the click that gives the list the
                        // focus.
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { isListFocused = true })
                    #endif
            }
        }
        #if os(macOS)
            // The list's name for VoiceOver, its navigation title ("Inbox", "Tax"): the sidebar's list gets "Sidebar"
            // from the system, this one got none (the Mac audit's "Element has no description", #82). Before the
            // identifier, which stays on the list.
            .accessibilityLabel(title)
            .focused($isListFocused)
            .onChange(of: model.selectedDocumentID) { _, selected in
                if selected != nil { isListFocused = true }
            }
            // Rows inserted above existing ones need an animated update to be measured (#72). Without one, the Mac's
            // table-backed `List` gives them its estimated row height (24 pt) and never measures them, so a
            // two-line row is cut to its title. Zero duration: the list looks as before, only the update path changes.
            .animation(.linear(duration: 0), value: model.documents.map(\.instanceID))
        #endif
        // On the list itself, before the overlay: an identifier after it would also replace the empty
        // state's own (measured on macOS, #44).
        .accessibilityIdentifier(AccessibilityID.documentList)
        .overlay {
            if model.documents.isEmpty {
                #if os(macOS)
                    emptyState
                #else
                    emptyState
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.documentListEmpty)
                #endif
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

    // On the Mac not a `NavigationLink`, as the sidebar rows (`SidebarView.row`): a link becomes a button there whose
    // role the Mac audit does not know ("Unknown role" on every row, #82). The tagged row is selected by the list's
    // `List(selection:)` as before. It is a button to VoiceOver with the button's action, which selects the document
    // as a click does. On the iPhone the link stays, for the push and the row's disclosure indicator.
    @ViewBuilder
    private func row(_ document: LibraryDocument) -> some View {
        let content = DocumentRow(document: document, tagPaths: model.tagPaths(of: document))
        #if os(macOS)
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.selectedDocumentID = document.instanceID }
                .tag(document.instanceID)
        #else
            NavigationLink(value: document.instanceID) {
                content
            }
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        #if os(macOS)
            // The Mac's own placeholder, with the identifier on its title (#82).
            if model.selection == .inbox {
                PlaceholderView(
                    title: "Inbox empty", systemImage: "tray", identifier: AccessibilityID.documentListEmpty)
            } else if model.selection == .trash {
                PlaceholderView(
                    title: "Trash empty", systemImage: "trash", identifier: AccessibilityID.documentListEmpty)
            } else {
                PlaceholderView(
                    title: "No documents", systemImage: "doc", identifier: AccessibilityID.documentListEmpty)
            }
        #else
            if model.selection == .inbox {
                ContentUnavailableView("Inbox empty", systemImage: "tray")
            } else if model.selection == .trash {
                ContentUnavailableView("Trash empty", systemImage: "trash")
            } else {
                ContentUnavailableView("No documents", systemImage: "doc")
            }
        #endif
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
