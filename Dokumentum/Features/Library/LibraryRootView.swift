import SwiftUI

/// The library window: sidebar, list and detail in one `NavigationSplitView`. The Mac shows three
/// columns; the iPhone collapses them into a navigation stack that opens on the Inbox list (PQ1).
/// No size-class branches.
///
/// This type is the window's stable root (`DokumentumApp`): later steps change what is inside it, not
/// the root's type, because the Mac's saved window state names the root's type (plan of #3, T5).
struct LibraryRootView: View {
    @State private var model: LibraryModel

    init(source: any LibrarySource) {
        _model = State(initialValue: LibraryModel(source: source))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            DocumentListView(model: model)
        } detail: {
            DocumentDetailView(model: model)
        }
        .task { await model.observeChanges() }
        .focusedSceneValue(\.libraryModel, model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DokumentumApp.rootIdentifier)
    }
}

extension FocusedValues {
    /// The library of the focused window, for the menu commands.
    @Entry var libraryModel: LibraryModel?
}
