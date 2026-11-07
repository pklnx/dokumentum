import SwiftUI

@main
struct DokumentumApp: App {
    /// Finds the root view in UI tests, independent of the language.
    nonisolated static let rootIdentifier = "dokumentum.root"

    var body: some Scene {
        // An explicit id and one stable root type (`LibraryRootView`): the Mac's saved window state
        // names the scene, and a root type it does not know opened no window in the development VM
        // (plan of #3, T5). Whether the explicit id prevents that is checked on the maintainer's Mac.
        WindowGroup(id: "library") {
            LibraryRootView(source: librarySourceForThisBuild())
        }
        #if os(macOS)
        // The system default (900 × 450) cuts "All Documents" in the sidebar.
        .defaultSize(width: 1100, height: 720)
        .commands { LibraryCommands() }
        #endif
    }
}
