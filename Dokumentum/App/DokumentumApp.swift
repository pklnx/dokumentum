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
    /// Runs the repair passes; `nil` for an in-memory store.
    let repair: RepairScheduler?
    /// The one debounced "store changed" signal of a store on disk (#30): the repair and every window's library
    /// follow it, so the library sees remote changes and CloudKit imports (plan of #3, part 5). `nil` for an
    /// in-memory store, which nothing else writes.
    let storeChanges: StoreChangeObserver?
    /// The one importer of the app (plan of #4, N2): every window's `ImportController` uses it, so all
    /// imports go through one actor.
    let importer: DocumentImporter

    init() {
        var choice = ArchiveStore.currentChoice()
        #if DEBUG
            var url = ArchiveStore.storeURL
            var fallbackURL = ArchiveStore.fallbackStoreURL
            if let folder = UITestLocalStore.folder(arguments: ProcessInfo.processInfo.arguments) {
                // A fresh local store on disk in a temporary folder, never the archive's; removed again when
                // the app terminates.
                UITestLocalStore.removeFolder(arguments: ProcessInfo.processInfo.arguments)
                UITestLocalStore.removeFolderWhenTerminating(arguments: ProcessInfo.processInfo.arguments)
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
        // The repair (#2, part 3) for the stores on disk only: in-memory stores of tests and UI tests never start
        // it. A launch run now, then after store changes and CloudKit imports.
        let storeChanges = choice.isOnDisk ? StoreChangeObserver(container: container) : nil
        self.storeChanges = storeChanges
        if let storeChanges {
            repair = RepairScheduler.start(for: container, observer: storeChanges)
        } else {
            repair = nil
        }
        importer = DocumentImporter(container: container, deviceID: DeviceIdentity.processingDeviceID())
    }

    var body: some Scene {
        // An explicit id and one stable root type (`LibraryRootView`): the Mac's saved window state
        // names the scene, and a root type it does not know opened no window in the development VM
        // (plan of #3, T5). Whether the explicit id prevents that is checked on the maintainer's Mac.
        WindowGroup(id: "library") {
            // One source per window: each window's model reads its own change events. Creating them reads
            // nothing: the library is read when the window appears, then after each save.
            LibraryRootView(
                source: StoreLibrarySource(container: container, storeChanges: storeChanges?.changes()),
                launchStore: launchStore, importer: importer)
        }
        // On the scene, not the view, so the root view keeps its type.
        .modelContainer(container)
        #if os(macOS)
            // The system default (900 × 450) cuts "All Documents" in the sidebar.
            .defaultSize(width: 1100, height: 720)
            .commands {
                LibraryCommands()
                TrashCommands()
                ImportCommands()
                #if DEBUG
                    DebugCommands()
                #endif
            }
        #endif
    }
}
