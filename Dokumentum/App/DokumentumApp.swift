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
    /// Why sync is off for this launch; `nil` for a CloudKit store.
    let syncOff: StoreSyncOffReason?

    init() {
        let choice = ArchiveStore.currentChoice()
        #if DEBUG
            // A `-UITestSeed` launch gets the sample documents in its in-memory store.
            container = ArchiveStore.openAtLaunch(choice, seed: { FixtureSeeder.seedForUITests($0) })
        #else
            container = ArchiveStore.openAtLaunch(choice)
        #endif
        syncOff = ArchiveStore.opened.flatMap { StoreSyncOffReason.reason(choice: choice, opened: $0) }
    }

    var body: some Scene {
        // An explicit id and one stable root type (`LibraryRootView`): the Mac's saved window state
        // names the scene, and a root type it does not know opened no window in the development VM
        // (plan of #3, T5). Whether the explicit id prevents that is checked on the maintainer's Mac.
        WindowGroup(id: "library") {
            // One source per window: each window's model reads its own change events.
            LibraryRootView(
                source: StoreLibrarySource(container: container), syncOff: syncOff,
                storeSyncs: ArchiveStore.opened == .cloudKit)
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
