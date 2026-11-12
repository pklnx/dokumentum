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
    /// Runs the processing queue (plan of #4, part 5): at launch, after imports, on every activation, after store
    /// changes and at the next claim expiry or backoff end; paused in the background on iOS and when the Mac app
    /// quits (`ProcessingLifecycle`). `nil` for an in-memory store, as the repair.
    let processing: ProcessingScheduler?
    /// The one search index of the app (plan of #7, part 2, T9), for every store, in-memory ones included; every
    /// window's library follows it. Built at launch off the main actor, then updated from saves and store changes.
    let search: SearchIndexer
    #if os(iOS)
        /// Imports what the share extension queued (plan of #4, part 4): at launch and on every activation, on
        /// the one importer. `nil` without the app group, and in runs that stay away from real data.
        let shareQueue: ShareQueueImporter?
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        var choice = ArchiveStore.currentChoice()
        #if DEBUG || SEARCH_BENCHMARK
            // A `-SearchBenchmark` launch runs on an empty in-memory store (#7, part 2).
            choice = SearchBenchmarkArgument.storeChoice(choice, arguments: ProcessInfo.processInfo.arguments)
        #endif
        #if DEBUG
            #if os(macOS)
                UITestAppearance.apply(arguments: ProcessInfo.processInfo.arguments)
            #endif
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
        #if DEBUG
            search = SearchIndexer(
                container: container,
                hooks: UITestHoldSearchIndex.hooks(for: container, arguments: ProcessInfo.processInfo.arguments))
        #else
            search = SearchIndexer(container: container)
        #endif
        search.start(storeChanges: storeChanges?.changes())
        let deviceID = DeviceIdentity.processingDeviceID()
        importer = DocumentImporter(container: container, deviceID: deviceID)
        // The processing queue (#4, part 5), for the stores on disk only, like the repair.
        if let storeChanges {
            #if DEBUG
                let takeoverInterval = ProcessingTakeoverArgument.seconds(arguments: ProcessInfo.processInfo.arguments)
            #else
                let takeoverInterval: TimeInterval? = nil
            #endif
            let processing = ProcessingScheduler.start(
                for: container, observer: storeChanges, deviceID: deviceID, takeoverInterval: takeoverInterval)
            #if os(macOS)
                // Quitting is a known interruption: the running attempt is given back (#97 point 4).
                ProcessingLifecycle.pauseWhenTerminating(processing)
            #endif
            self.processing = processing
        } else {
            processing = nil
        }
        #if os(iOS)
            shareQueue = ShareQueueImporter.forApp(importer: importer)
            shareQueue?.requestRun()
        #endif
    }

    var body: some Scene {
        // An explicit id and one stable root type (`LibraryRootView`): the Mac's saved window state
        // names the scene, and a root type it does not know opened no window in an unsigned local build
        // (plan of #3, T5). Whether the explicit id prevents that is checked on the maintainer's Mac.
        WindowGroup(id: "library") {
            // One source per window: each window's model reads its own change events. Creating them reads
            // nothing: the library is read when the window appears, then after each save.
            LibraryRootView(
                source: StoreLibrarySource(container: container, storeChanges: storeChanges?.changes()),
                launchStore: launchStore, importer: importer, searcher: search
            )
            #if os(iOS)
                .environment(shareQueue)
            #endif
        }
        // A launch is an activation too; the share queue and the processing queue each run one at a time and
        // queue one more run. The background pauses processing on iOS (`ProcessingLifecycle`).
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
                if phase == .active { shareQueue?.requestRun() }
            #endif
            ProcessingLifecycle.scenePhaseChanged(to: phase, scheduler: processing)
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
