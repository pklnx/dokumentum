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
    let importer: any DocumentImporting
    /// Runs the processing queue (plan of #4, part 5): at launch, after imports, on every activation, after store
    /// changes and at the next claim expiry or backoff end; paused in the background on iOS and when the Mac app
    /// quits (`ProcessingLifecycle`). `nil` for an in-memory store, as the repair.
    let processing: ProcessingScheduler?
    /// "Try again" for a failed document (#6, P2): through the scheduler, which runs the queue after the write; for an
    /// in-memory store, which has no scheduler, a queue of its own that only writes (the document then stays
    /// `pending`, as every document of such a store does).
    let retrier: any ProcessingRetrying
    /// The one search index of the app (plan of #7, part 2, T9), for every store, in-memory ones included; every
    /// window's library follows it. Built at launch off the main actor, then updated from saves and store changes.
    let search: SearchIndexer
    /// The sync status of a CloudKit store (#31): events and the account; `nil` for every other store, which shows
    /// its own "Sync off" line. The footer of every window reads it through `syncStatus`.
    let syncMonitor: CloudSyncMonitor?
    /// Where the sidebar footer's line comes from.
    let syncStatus: SyncStatusSource?
    #if DEBUG
        /// The Sync lab (#31, part 2): Debug builds only.
        let syncLab: SyncLab
    #endif
    /// The "Suggestions" settings (#8, part 3): this device's switch and the classifier's availability, for the Mac's
    /// Settings window and the iPhone's settings sheet.
    let suggestionSettings: SuggestionSettings
    /// The suite of the classification switch for an in-memory store (tests and UI tests): emptied at each such
    /// launch, so a UI test that turns the switch off never changes this device's real setting.
    nonisolated static let inMemorySettingsSuite = "Dokumentum.InMemoryLaunchSettings"

    /// The suite of the classification switch (#139, review N1 of #159): for a store on disk the processing queue's
    /// (`ProcessingFailures`' suite, which the queue's `ClassificationSettings` defaults to, `ProcessingQueue.init`),
    /// so the settings write the key the queue reads; for an in-memory store `inMemorySettingsSuite`.
    static func settingsSuite(isOnDisk: Bool) -> String? {
        isOnDisk ? ProcessingFailures().defaultsSuite : inMemorySettingsSuite
    }
    #if os(iOS)
        /// The processing queue's background tasks (plan of #6, part 5): continued processing after a user's import,
        /// the processing task when the app goes to the background. `nil` where `processing` is.
        let background: BackgroundProcessing?
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
        // Only a CloudKit store creates the CloudKit container (T3): without the entitlement it traps.
        let syncMonitor = CloudSyncMonitor.forStore(launchStore.opened, makeProvider: { CloudKitAccountStatus() })
        self.syncMonitor = syncMonitor
        #if DEBUG
            syncStatus = SyncStatusSource.forLaunch(
                launchStore, monitor: syncMonitor,
                injected: UITestSyncStatus.status(arguments: ProcessInfo.processInfo.arguments))
        #else
            syncStatus = SyncStatusSource.forLaunch(launchStore, monitor: syncMonitor)
        #endif
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
        // The classification step's model (#8): the on-device model; a Debug launch can fix its availability.
        #if DEBUG
            let classifier = UITestClassifierAvailability.classifier(
                FoundationModelsClassifier(), arguments: ProcessInfo.processInfo.arguments)
        #else
            let classifier: any DocumentClassifying = FoundationModelsClassifier()
        #endif
        let documentImporter = DocumentImporter(container: container, deviceID: deviceID)
        #if DEBUG
            let takeoverInterval = ProcessingTakeoverArgument.seconds(arguments: ProcessInfo.processInfo.arguments)
        #else
            let takeoverInterval: TimeInterval? = nil
        #endif
        // The processing queue (#4, part 5), for the stores on disk only, like the repair.
        if let storeChanges {
            // The classification step (#8) with the on-device model. Created here, before the share queue below
            // imports anything, so the first launch's cut-off (P9) comes before those documents.
            let processing = ProcessingScheduler.start(
                for: container, observer: storeChanges, deviceID: deviceID, takeoverInterval: takeoverInterval,
                classifier: classifier)
            #if os(macOS)
                // Quitting is a known interruption: the running attempt is given back (#97 point 4).
                ProcessingLifecycle.pauseWhenTerminating(processing)
            #endif
            self.processing = processing
            retrier = processing
        } else {
            processing = nil
            retrier = ProcessingQueue(container: container, deviceID: deviceID, failures: ProcessingFailures())
        }
        // The switch lives where the queue reads it (`ProcessingQueue`: the failure counter's suite); a store that runs
        // no queue gets a suite of its own that each launch empties. A change of the switch requests a run.
        let settingsSuite = Self.settingsSuite(isOnDisk: choice.isOnDisk)
        if !choice.isOnDisk {
            UserDefaults().removePersistentDomain(forName: Self.inMemorySettingsSuite)
        }
        let scheduler = processing
        suggestionSettings = SuggestionSettings(
            classifier: classifier, settings: ClassificationSettings(defaultsSuite: settingsSuite),
            requestRun: { scheduler?.requestRun() })
        #if os(iOS)
            // Registered before the app finishes launching, once per identifier (T13, N4). Every user import goes
            // through the importer below, which asks for a continued-processing task; a CloudKit import never does.
            if let processing {
                let container = container
                let background = BackgroundProcessing(
                    scheduler: processing, tasks: SystemBackgroundTasks(),
                    openDocuments: { instanceIDs in
                        do {
                            return try OpenDocuments.count(in: container, among: instanceIDs)
                        } catch {
                            Log.processing.error("Open documents not counted: \(Log.code(of: error), privacy: .public)")
                            return 0
                        }
                    },
                    applicationIsInForeground: { UIApplication.shared.applicationState != .background })
                background.register()
                if let storeChanges {
                    background.followStoreChanges(storeChanges.changes())
                }
                self.background = background
                importer = BackgroundImportNotifying(base: documentImporter) { background.userImported($0) }
            } else {
                background = nil
                importer = documentImporter
            }
            shareQueue = ShareQueueImporter.forApp(importer: importer)
            shareQueue?.requestRun()
        #else
            importer = documentImporter
        #endif
        #if DEBUG
            // Through the app's importer (on iOS the one that asks for continued processing) and the app's schedulers.
            syncLab = SyncLab(
                container: container, launchStore: launchStore, deviceID: deviceID, importer: importer,
                processing: processing, repair: repair, search: search, monitor: syncMonitor,
                takeoverInterval: takeoverInterval)
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
                launchStore: launchStore, importer: importer, searcher: search, retrier: retrier,
                syncStatus: syncStatus
            )
            #if os(iOS)
                .environment(shareQueue)
            #endif
            #if DEBUG
                .environment(syncLab)
            #endif
            // The iPhone's settings sheet reads it (`SettingsButton`).
            .environment(suggestionSettings)
        }
        // A launch is an activation too; the share queue and the processing queue each run one at a time and
        // queue one more run. The background pauses processing on iOS (`ProcessingLifecycle`).
        .onChange(of: scenePhase) { _, phase in
            // The account may have changed while the app was in the background (#31, T4).
            if phase == .active { syncMonitor?.sceneBecameActive() }
            #if os(iOS)
                if phase == .active { shareQueue?.requestRun() }
            #endif
            #if os(iOS)
                ProcessingLifecycle.scenePhaseChanged(to: phase, scheduler: processing, background: background)
            #else
                ProcessingLifecycle.scenePhaseChanged(to: phase, scheduler: processing)
            #endif
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
        #if os(macOS)
            // The Mac's Settings window (⌘,), with the "Suggestions" section (#8, part 3).
            Settings {
                SettingsView(model: suggestionSettings)
            }
        #endif
        #if DEBUG && os(macOS)
            // The Sync lab's own window (#31, part 2), from Debug › Sync Lab….
            Window(Text(verbatim: "Sync Lab"), id: SyncLabWindow.id) {
                SyncLabView(lab: syncLab)
            }
            .modelContainer(container)
        #endif
    }
}
