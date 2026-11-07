import DokumentumCore
import SwiftUI

/// The library window: sidebar, list and detail in one `NavigationSplitView`. The Mac shows three
/// columns; the iPhone collapses them into a navigation stack that opens on the Inbox list (PQ1).
/// No size-class branches.
///
/// This type is the window's stable root (`DokumentumApp`): later steps change what is inside it, not
/// the root's type, because the Mac's saved window state names the root's type (plan of #3, T5).
struct LibraryRootView: View {
    @State private var model: LibraryModel
    /// The window's imports (#4, part 2), on the app's one importer.
    @State private var importController: ImportController
    /// The footer's reason and the debug command's confirmation come from it.
    let launchStore: LaunchStore

    /// Reads nothing: SwiftUI creates the view again whenever the app's body is evaluated, and keeps only
    /// the first model. The library is read when the window appears (`loadIfNeeded`).
    init(source: any LibrarySource, launchStore: LaunchStore, importer: any DocumentImporting) {
        let model = LibraryModel(source: source, loadNow: false)
        _model = State(initialValue: model)
        _importController = State(initialValue: ImportController(importer: importer, library: model))
        self.launchStore = launchStore
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, syncOff: launchStore.syncOffReason)
        } content: {
            DocumentListView(model: model)
        } detail: {
            DocumentDetailView(model: model)
        }
        #if os(macOS)
            // The info panel, a trailing column of the whole window (plan of #3, part 3). Not on the detail
            // column: there the inspector's split view sometimes did not lay out the detail's next state, and
            // "Still downloading" stayed at a zero frame (measured in the German `UISmoke` runs of #57).
            .inspector(isPresented: $model.isInfoPresented) {
                DocumentInfoView(model: model)
            }
        #endif
        .onAppear { model.loadIfNeeded() }
        .task { await model.observeChanges() }
        .focusedSceneValue(\.libraryModel, model)
        .modifier(ImportSupport(controller: importController, launchStore: launchStore))
        #if DEBUG
            .modifier(sampleDocumentsCommand)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DokumentumApp.rootIdentifier)
    }
}

#if DEBUG
    extension LibraryRootView {
        /// The debug command of this window; it asks first for every store on disk (`LaunchStore`).
        var sampleDocumentsCommand: SampleDocumentsCommand {
            SampleDocumentsCommand(asksFirst: launchStore.asksBeforeAddingSampleDocuments)
        }
    }
#endif

extension FocusedValues {
    /// The library of the focused window, for the menu commands.
    @Entry var libraryModel: LibraryModel?
}
