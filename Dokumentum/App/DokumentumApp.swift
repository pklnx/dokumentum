import DokumentumCore
import SwiftData
import SwiftUI

@main
struct DokumentumApp: App {
    /// Finds the root view in UI tests, independent of the language.
    nonisolated static let rootIdentifier = "dokumentum.root"

    /// The archive of this launch: CloudKit, local, or in memory for tests and UI tests (`StoreChoice`). The
    /// library still reads its `LibrarySource`; #3's part 2 puts it on this store.
    let container: ModelContainer

    init() {
        container = ArchiveStore.openAtLaunch(ArchiveStore.currentChoice())
    }

    var body: some Scene {
        // An explicit id and one stable root type (`LibraryRootView`): the Mac's saved window state
        // names the scene, and a root type it does not know opened no window in the development VM
        // (plan of #3, T5). Whether the explicit id prevents that is checked on the maintainer's Mac.
        WindowGroup(id: "library") {
            LibraryRootView(source: librarySourceForThisBuild())
        }
        // On the scene, not the view, so the root view keeps its type.
        .modelContainer(container)
        #if os(macOS)
            // The system default (900 × 450) cuts "All Documents" in the sidebar.
            .defaultSize(width: 1100, height: 720)
            .commands { LibraryCommands() }
        #endif
    }
}
