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

    @Test func testStoresAreInMemoryAndNeverSynced() {
        let memory = ArchiveStore.configuration(for: .inMemory(seed: true))
        #expect(memory.isStoredInMemoryOnly)
        #expect(memory.cloudKitContainerIdentifier == nil)
    }
}
