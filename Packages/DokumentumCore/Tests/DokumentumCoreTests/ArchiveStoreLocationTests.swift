import DokumentumCore
import Foundation
import SwiftData
import Testing

/// The store lives in the app's own container, never in the app group (plan of #2, "Store setup and
/// location"). These tests only build configurations; nothing opens the real store.
struct ArchiveStoreLocationTests {
    private let expected = URL.applicationSupportDirectory.appending(path: "Dokumentum/Dokumentum.store")

    @Test func theStoreIsInApplicationSupport() {
        #expect(ArchiveStore.storeURL == expected)
        #expect(ArchiveStore.fallbackStoreURL.deletingLastPathComponent() == expected.deletingLastPathComponent())
        #expect(ArchiveStore.fallbackStoreURL != expected)
    }

    @Test func cloudKitAndLocalUseTheSameFile() {
        let cloudKit = ArchiveStore.configuration(for: .cloudKit)
        let local = ArchiveStore.configuration(for: .local)
        #expect(cloudKit.url == expected)
        #expect(local.url == expected)
        #expect(cloudKit.cloudKitContainerIdentifier == "iCloud.space.pklnx.Dokumentum")
        #expect(local.cloudKitContainerIdentifier == nil)
        #expect(!cloudKit.isStoredInMemoryOnly && !local.isStoredInMemoryOnly)
    }

    @Test func theStoreIsNotInTheAppGroup() {
        let group = "group.space.pklnx.dokumentum"
        for url in [ArchiveStore.storeURL, ArchiveStore.fallbackStoreURL] {
            #expect(!url.path.localizedCaseInsensitiveContains(group))
            #expect(!url.path.contains("Group Containers"))
            #expect(!url.path.contains("/Shared/AppGroup/"))
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                #expect(!url.standardizedFileURL.path.hasPrefix(container.standardizedFileURL.path))
            }
        }
    }

    /// In a test run every live path is refused: the store, its fallback, their side files, and the app
    /// group container. Only the paths are checked; nothing opens them.
    @Test func aTestRunRefusesTheLiveStorePaths() throws {
        let live = ArchiveStore.storeURL.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let refused = [
            ArchiveStore.storeURL, ArchiveStore.fallbackStoreURL, live,
            live.appending(path: "Dokumentum.store-wal"),
            live.appending(path: ".Dokumentum_SUPPORT/_EXTERNAL_DATA/Blob"),
            live.appending(path: "Sub/../Dokumentum.store"),
            home.appending(path: "Library/Group Containers/group.space.pklnx.dokumentum/Archive.store"),
            URL(filePath: "/private/var/mobile/Containers/Shared/AppGroup/0A1B2C3D/Archive.store"),
        ]
        for url in refused {
            #expect(ArchiveStore.isLiveStorePath(url), "\(url.path)")
            #expect(throws: ArchiveStore.LiveStorePathRefused(url: url)) {
                try ArchiveStore.refuseLiveStorePath(url, isRunningTests: true)
            }
            // Outside tests the app opens them as always.
            try ArchiveStore.refuseLiveStorePath(url, isRunningTests: false)
        }
        let allowed = [
            FileManager.default.temporaryDirectory.appending(path: "DokumentumTests-X/Test.store"),
            live.deletingLastPathComponent().appending(path: "Dokumentum2/Dokumentum.store"),
            live.deletingLastPathComponent().appending(path: "Dokumentum.store"),
            URL(filePath: "/dev/null"),
        ]
        for url in allowed {
            #expect(!ArchiveStore.isLiveStorePath(url), "\(url.path)")
            try ArchiveStore.refuseLiveStorePath(url, isRunningTests: true)
        }
    }

    /// `open` itself refuses a live path in a test run, before it creates a folder. The probe is an app group
    /// path under `/Shared`, which the read-only system volume cannot hold: without the guard the open fails
    /// with a file error instead, and still writes nothing.
    @Test func openRefusesALivePathInATestRun() {
        #expect(TestEnvironment.isRunningTests)
        let probe = URL(filePath: "/Shared/AppGroup/DokumentumGuardProbe/Probe.store")
        #expect(throws: ArchiveStore.LiveStorePathRefused(url: probe)) {
            try ArchiveStore.open(ArchiveStore.configuration(for: .local, at: probe))
        }
        #expect(!FileManager.default.fileExists(atPath: "/Shared"))
    }

    @Test func testStoresAreInMemoryAndNeverSynced() {
        let memory = ArchiveStore.configuration(for: .inMemory(seed: true))
        #expect(memory.isStoredInMemoryOnly)
        #expect(memory.cloudKitContainerIdentifier == nil)
    }
}
