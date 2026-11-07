#if DEBUG
    import CoreData
    import DokumentumCore
    import Foundation
    import Testing

    /// The schema initializer works on a throwaway store, never the live one. It never runs in tests: that
    /// needs a signed build and an iCloud account (#2, part 4's Sync lab).
    struct DebugSchemaInitializerTests {
        @Test func itsStoreIsNeverTheLiveStoreOrInItsFolder() {
            let url = DebugSchemaInitializer.makeStoreURL()
            let live = ArchiveStore.storeURL.standardizedFileURL
            #expect(url.standardizedFileURL != live)
            #expect(!url.standardizedFileURL.path.hasPrefix(live.deletingLastPathComponent().path))
            #expect(
                url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
            #expect(
                DebugSchemaInitializer.makeStoreURL().deletingLastPathComponent() != url.deletingLastPathComponent())
        }

        /// The container it would load mirrors the app's model to the app's CloudKit container. Building it loads
        /// nothing and contacts nothing.
        @Test func itMirrorsTheCurrentModelToTheAppsContainer() throws {
            let url = DebugSchemaInitializer.makeStoreURL()
            let container = try DebugSchemaInitializer.makeContainer(at: url)
            let description = try #require(container.persistentStoreDescriptions.first)
            #expect(container.persistentStoreDescriptions.count == 1)
            #expect(description.url == url)
            #expect(description.cloudKitContainerOptions?.containerIdentifier == "iCloud.space.pklnx.Dokumentum")
            #expect(
                Set(container.managedObjectModel.entities.compactMap { $0.name }) == [
                    "Document", "DocumentFile", "DocumentThumbnail", "DocumentText", "Tag", "Correspondent",
                    "DocumentType",
                ])
            #expect(container.persistentStoreCoordinator.persistentStores.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
    }
#endif
