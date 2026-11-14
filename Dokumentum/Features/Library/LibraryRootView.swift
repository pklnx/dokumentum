import DokumentumCore
import DokumentumKit
import SwiftUI

/// The library window: sidebar, list and detail in one `NavigationSplitView`. The Mac shows three
/// columns; the iPhone collapses them into a navigation stack that opens on the Inbox list (PQ1).
/// No size-class branches.
///
/// This type is the window's stable root (`DokumentumApp`): later steps change what is inside it, not
/// the root's type, because the Mac's saved window state names the root's type (plan of #3, T5).
struct LibraryRootView: View {
    @State private var model: LibraryModel
    /// The window's trash actions (plan of #3, part 4).
    @State private var trash: LibraryTrash
    /// The window's imports (#4, part 2), on the app's one importer.
    @State private var importController: ImportController
    /// The debug command's confirmation comes from it.
    let launchStore: LaunchStore
    /// The sidebar footer's sync line (#31).
    let syncStatus: SyncStatusSource?
    /// "Today" is read again when the window's scene becomes active (#12, review N4 of #219).
    @Environment(\.scenePhase) private var scenePhase

    /// Reads nothing: SwiftUI creates the view again whenever the app's body is evaluated, and keeps only
    /// the first model. The library is read when the window appears (`loadIfNeeded`).
    /// - Parameters:
    ///   - searcher: the app's one search index (#7, part 2); every window's model follows its updates.
    ///   - retrier: "Try again" for a failed document (#6, P2).
    ///   - syncStatus: the footer's sync line (#31); without one, the store's own (`SyncStatusSource.forLaunch`).
    init(
        source: any LibrarySource, launchStore: LaunchStore, importer: any DocumentImporting,
        searcher: (any DocumentSearching)? = nil, retrier: (any ProcessingRetrying)? = nil,
        syncStatus: SyncStatusSource? = nil
    ) {
        let model = LibraryModel(source: source, searcher: searcher, retrier: retrier, loadNow: false)
        _model = State(initialValue: model)
        _trash = State(initialValue: LibraryTrash(model: model))
        _importController = State(initialValue: ImportController(importer: importer, library: model))
        self.launchStore = launchStore
        self.syncStatus = syncStatus ?? SyncStatusSource.forLaunch(launchStore, monitor: nil)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, syncStatus: syncStatus)
        } content: {
            DocumentListView(model: model)
        } detail: {
            DocumentDetailView(model: model)
                .safeAreaInset(edge: .top, spacing: 0) { TrashedDocumentBar(trash: trash) }
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
        .task { await model.observeSearchIndex() }
        // The deadlines' status and count follow the calendar day (#12, part 2a).
        .task { await model.observeDayChanges() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.dayMayHaveChanged() }
        }
        .focusedSceneValue(\.libraryModel, model)
        .environment(trash)
        .focusedSceneValue(\.libraryTrash, trash)
        .modifier(EmptyTrashConfirmation(trash: trash))
        .modifier(ImportSupport(controller: importController, launchStore: launchStore))
        #if DEBUG
            .modifier(sampleDocumentsCommand)
        #endif
        #if DEBUG || SEARCH_BENCHMARK
            .modifier(SearchBenchmarkPresenter())
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
