import DokumentumCore
import SwiftData
import SwiftUI

@main
struct DokumentumApp: App {
    /// Finds the root view in UI tests, independent of the language.
    nonisolated static let rootIdentifier = "dokumentum.root"

    /// The archive of this launch: CloudKit, local, or in memory for tests and UI tests (`StoreChoice`).
    /// The library reads it through `StoreLibrarySource`.
    let container: ModelContainer
    /// The launch's choice and the store that opened: the footer and the debug command read it.
    let launchStore: LaunchStore

    init() {
        var choice = ArchiveStore.currentChoice()
        #if DEBUG
            var url = ArchiveStore.storeURL
            var fallbackURL = ArchiveStore.fallbackStoreURL
            if let folder = UITestLocalStore.folder(arguments: ProcessInfo.processInfo.arguments) {
                // A fresh local store on disk in a temporary folder, never the archive's.
                try? FileManager.default.removeItem(at: folder)
                choice = .local
                url = folder.appending(path: "Dokumentum.store")
                fallbackURL = folder.appending(path: "Dokumentum-local.store")
            }
            // A `-UITestSeed` launch gets the sample documents in its in-memory store.
            container = ArchiveStore.openAtLaunch(
                choice, at: url, fallbackURL: fallbackURL, seed: { FixtureSeeder.seedForUITests($0) })
        #else
            container = ArchiveStore.openAtLaunch(choice)
        #endif
        launchStore = LaunchStore(choice: choice, opened: ArchiveStore.opened ?? .inMemory)
    }

    var body: some Scene {
        // An explicit id and one stable root type (`LibraryRootView`): the Mac's saved window state
        // names the scene, and a root type it does not know opened no window in the development VM
        // (plan of #3, T5). Whether the explicit id prevents that is checked on the maintainer's Mac.
        WindowGroup(id: "library") {
            // One source per window: each window's model reads its own change events. Creating them reads
            // nothing: the library is read when the window appears, then after each save.
            LibraryRootView(source: StoreLibrarySource(container: container), launchStore: launchStore)
        }
        // On the scene, not the view, so the root view keeps its type.
        .modelContainer(container)
        #if os(macOS)
            // The system default (900 × 450) cuts "All Documents" in the sidebar.
            .defaultSize(width: 1100, height: 720)
            .commands {
                LibraryCommands()
                #if DEBUG
                    DebugCommands()
                #endif
            }
        #endif
    }
}
