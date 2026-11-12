import DokumentumKit
import SwiftUI

/// The documents of the sidebar's selection, newest document date first (PQ4). One document at a
/// time (PQ11). The search field (#7, part 3) narrows them: words, filter chips and the scope switch (selected list
/// or All Documents), in the same order and rows.
struct DocumentListView: View {
    @Bindable var model: LibraryModel
    #if os(macOS)
        /// Whether the list has the keyboard focus. A click on a row does not move the focus there by itself: the
        /// info panel's title field kept it, and ⌘⌫ meant for Move to Trash then emptied the title, which was saved
        /// (review of #74, finding 1). So a click on a row, the selected one too, and every change of the
        /// selection give the list the focus.
        @FocusState private var isListFocused: Bool
        /// Whether the search field has the focus; Edit › Find… (⌘F) sets it (`LibraryModel.focusSearch`).
        @FocusState private var isSearchFocused: Bool
        /// The height each row needs at its current width, measured by its hidden copy (#81). Not observed: only a
        /// change in `generations` updates the list.
        @State private var rowHeights = RowHeights()
        /// How often each row's needed height changed while its content stayed the same (#81): part of its identity.
        @State private var generations: [UUID: Int] = [:]
    #endif

    var body: some View {
        List(selection: $model.selectedDocumentID) {
            ForEach(model.documents) { document in
                let tagPaths = model.tagPaths(of: document)
                row(document, tagPaths: tagPaths)
                    .accessibilityIdentifier(AccessibilityID.documentRow(document.instanceID))
                    .modifier(TrashRowActions(document: document))
                    #if os(macOS)
                        // The whole row, also the gap between its lines, takes the click that gives the list the
                        // focus.
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { isListFocused = true })
                        // A row whose content or needed height changes is replaced, so the table measures it again
                        // (#80, #81): see below.
                        .id(
                            RowKey(
                                inputs: RowInputs(document: document, tagPaths: tagPaths),
                                generation: generations[document.instanceID] ?? 0))
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
            // The Mac's table-backed `List` measures a row inserted above existing ones once, when it is inserted, and
            // keeps that height. Two fixes cover that:
            // - Inserts need an animated update to be measured at all (#72). Without one, the table gives the rows its
            //   estimated row height (24 pt), so a two-line row is cut to its title. Zero duration: the list looks as
            //   before, only the update path changes.
            // - A content change, such as a tag added or removed, updates the cell in place and the row keeps its
            //   height (#80): a new tag line is cut, a removed one leaves a gap. So each row's identity includes what
            //   it shows (`RowInputs`): a changed row is removed and inserted again, and the table measures it. The
            //   new height applies at once, without an animation (maintainer decision on #80).
            // - A width change of the list column re-measures rows loaded at once, but not the inserted ones (#81): a
            //   title that wraps or unwraps leaves a gap or is cut. So each row measures the height it needs at its
            //   width with a hidden copy (`row(_:tagPaths:)`), and a row whose needed height changes while its content
            //   stays the same gets a new generation in its identity (`RowKey`): it is replaced like a changed row.
            //   Only those rows are replaced, so the scroll position and the selection stay.
            .animation(.linear(duration: 0), value: model.documents.map(\.instanceID))
        #endif
        // On the list itself, before the overlay: an identifier after it would also replace the empty
        // state's own (measured on macOS, #44).
        .accessibilityIdentifier(AccessibilityID.documentList)
        .overlay {
            if model.documents.isEmpty {
                if model.isSearchActive {
                    searchEmptyState
                } else {
                    #if os(macOS)
                        emptyState
                    #else
                        emptyState
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(AccessibilityID.documentListEmpty)
                    #endif
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { indexingLine }
        .searchable(
            text: $model.search.text, tokens: $model.search.tokens, placement: searchPlacement, prompt: Text("Search")
        ) { token in
            SearchTokenLabel(token: token, name: model.name(of: token))
        }
        // The chips offered for the text typed; picking one adds it. Not `suggestedTokens`: the Mac shows none of them
        // (measured on macOS 27 for #123).
        .searchSuggestions {
            ForEach(model.searchSuggestions) { token in
                SearchTokenLabel(token: token, name: model.name(of: token))
                    .searchCompletion(token)
            }
        }
        #if os(macOS)
            .searchFocused($isSearchFocused)
            .onChange(of: model.searchFocusRequests) { isSearchFocused = true }
        #endif
        .searchScopes($model.search.scope, activation: .onSearchPresentation) {
            // No switch while All Documents is the list: both scopes would be the same.
            if model.selection != .all {
                title
                    .accessibilityIdentifier(AccessibilityID.searchScope(.selection))
                    .tag(SearchScope.selection)
                Text("All Documents")
                    .accessibilityIdentifier(AccessibilityID.searchScope(.all))
                    .tag(SearchScope.all)
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
    // `List(selection:)` as before. Its select action, which selects the document as a click does, is what makes the
    // row a button to VoiceOver, the role the audit checks; a button trait alone adds nothing (#88 review: without the
    // trait it stays a button, without the action it has "Unknown role"; #89). On the iPhone the link stays, for the
    // push and the row's disclosure indicator.
    @ViewBuilder
    private func row(_ document: LibraryDocument, tagPaths: [String]) -> some View {
        let content = DocumentRow(document: document, tagPaths: tagPaths)
        #if os(macOS)
            content
                .accessibilityAction { model.selectedDocumentID = document.instanceID }
                // After the action, so that it stays on the row's one element (#89): the copy is hidden from VoiceOver
                // and adds none.
                .background { heightProbe(document, tagPaths: tagPaths) }
                .tag(document.instanceID)
        #else
            NavigationLink(value: document.instanceID) {
                content
            }
        #endif
    }

    #if os(macOS)
        /// A hidden copy of the row that measures the height the row needs at its current width, whatever height the
        /// table gave the row (#81). Not the row itself: it is laid out in the height the table gave it, and in the
        /// plan's probes a row that was too short kept its title on one line, so its height did not change.
        private func heightProbe(_ document: LibraryDocument, tagPaths: [String]) -> some View {
            DocumentRow(document: document, tagPaths: tagPaths)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: { height in
                    let inputs = RowInputs(document: document, tagPaths: tagPaths)
                    if rowHeights.noteChanged(height, for: inputs) { replaceLater(document.instanceID) }
                }
        }

        /// Queues the row for a new generation. The rows are replaced a few per update, one update per turn of the main
        /// queue: when many rows are replaced in one update on a busy Mac, the table keeps the old height of some of
        /// them (measured on #81 with 30 rows inserted on top of 3000: with 15 or 30 rows per update some stayed at
        /// their old height, with 10 or fewer none did).
        private func replaceLater(_ id: UUID) {
            guard !rowHeights.pending.contains(id) else { return }
            rowHeights.pending.append(id)
            if rowHeights.pending.count == 1 { replacePendingRows() }
        }

        private func replacePendingRows() {
            DispatchQueue.main.async {
                let batch = rowHeights.pending.prefix(RowHeights.rowsPerUpdate)
                for id in batch { generations[id, default: 0] += 1 }
                // The next batch after the table took this one.
                DispatchQueue.main.async {
                    rowHeights.pending.removeFirst(batch.count)
                    if !rowHeights.pending.isEmpty { replacePendingRows() }
                }
            }
        }
    #endif

    /// The iPhone's field sits in the list's navigation bar, always shown (plan of #7, Approach 8); the Mac's in the
    /// window's toolbar.
    private var searchPlacement: SearchFieldPlacement {
        #if os(iOS)
            .navigationBarDrawer(displayMode: .always)
        #else
            .automatic
        #endif
    }

    /// "Indexing texts… 12 of 40" over the results while the index reads its texts (P5): results show what is in
    /// so far. In the primary colour on the list's own background, as the placeholders (#82).
    @ViewBuilder
    private var indexingLine: some View {
        if let progress = model.indexingProgress {
            Text("Indexing texts… \(progress.indexed.formatted()) of \(progress.total.formatted())")
                .font(indexingLineFont)
                .foregroundStyle(.primary)
                // On the text, before the frame: the line's element is the text alone, not the band behind it, which
                // reaches under the toolbar on the Mac (the audit measured the band's contrast).
                .accessibilityIdentifier(AccessibilityID.searchIndexing)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.background)
        }
    }

    /// Large and heavy enough for the audit's contrast check: on the Mac it failed the line at 10 pt medium in dark mode
    /// ("not high enough unless font size is larger"), and at 13 pt medium and 13 pt semibold in light mode although the
    /// line's pixels measure 14.94:1 (#123); 15 pt semibold passes, as for the placeholders (#89).
    private var indexingLineFont: Font {
        #if os(macOS)
            .title3.weight(.semibold)
        #else
            .subheadline.weight(.semibold)
        #endif
    }

    /// No document matches the search (P4): "No Results for “x”", or "No Results" for chips alone.
    @ViewBuilder
    private var searchEmptyState: some View {
        let text = model.search.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: LocalizedStringKey = text.isEmpty ? "No Results" : "No Results for “\(text)”"
        #if os(macOS)
            PlaceholderView(title: title, systemImage: "magnifyingglass", identifier: AccessibilityID.searchEmpty)
        #else
            ContentUnavailableView(title, systemImage: "magnifyingglass")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.searchEmpty)
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

#if os(macOS)
    /// Everything a `DocumentRow` shows: its two inputs, so the identity cannot miss a field the row adds later.
    private struct RowInputs: Hashable {
        let document: LibraryDocument
        let tagPaths: [String]
    }

    /// A row's identity in the list: what it shows, and how often its needed height changed for that (#81).
    private struct RowKey: Hashable {
        let inputs: RowInputs
        let generation: Int
    }

    /// The last height each row needed, with the inputs it was measured for (#81). Per document shown in the window;
    /// not pruned, it is dropped with the window.
    private final class RowHeights {
        /// How many rows get a new generation in one update (`DocumentListView.replaceLater`).
        static let rowsPerUpdate = 5
        /// The rows waiting for a new generation, oldest first.
        var pending: [UUID] = []
        private var entries: [UUID: (inputs: RowInputs, height: CGFloat)] = [:]

        /// Records `height` for the row and tells whether the row needs a new measurement by the table: only when the
        /// same inputs now need a different height. A row's first measurement changes nothing, and neither does a
        /// content change: a new `RowInputs` already replaces that row (#80).
        func noteChanged(_ height: CGFloat, for inputs: RowInputs) -> Bool {
            let id = inputs.document.instanceID
            // Written on every call: after a content change the entry must hold the new inputs, or the next width
            // change could not bump the row.
            defer { entries[id] = (inputs, height) }
            guard let previous = entries[id], previous.inputs == inputs else { return false }
            return abs(previous.height - height) > 0.5
        }
    }
#endif
