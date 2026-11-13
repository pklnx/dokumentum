#if DEBUG
    import CloudKit
    import CoreData
    import Foundation
    import SwiftData

    /// Creates every record type and field of the current schema in the CloudKit **Development**
    /// environment, so the CloudKit Console shows the complete schema before step 8 deploys it to
    /// Production (a maintainer step). DEBUG builds only; the Sync lab (#2, part 4) calls `run()`, never the
    /// launch.
    ///
    /// It opens its own store in a new temporary folder, never the live store, and removes the folder
    /// afterwards. It needs a signed build with the CloudKit entitlement and an iCloud account; it is never
    /// run from tests or an unsigned build.
    public enum DebugSchemaInitializer {
        /// A new temporary folder's store file; never the live store or inside its folder.
        public static func makeStoreURL() -> URL {
            FileManager.default.temporaryDirectory
                .appending(path: "DokumentumSchemaInit-\(UUID().uuidString)", directoryHint: .isDirectory)
                .appending(path: "SchemaInit.store")
        }

        /// The Core Data container for the current schema (`DokumentumMigrationPlan.current`, the model of
        /// `ArchiveStore.schema`) with its store at `url`, mirrored to the private database of the app's CloudKit
        /// container. It loads nothing.
        public static func makeContainer(at url: URL) throws -> NSPersistentCloudKitContainer {
            guard
                let model = NSManagedObjectModel.makeManagedObjectModel(
                    for: DokumentumMigrationPlan.current.models)
            else {
                throw CocoaError(.coreData)
            }
            let container = NSPersistentCloudKitContainer(name: "SchemaInit", managedObjectModel: model)
            let description = NSPersistentStoreDescription(url: url)
            let options = NSPersistentCloudKitContainerOptions(
                containerIdentifier: ArchiveStore.cloudKitContainerIdentifier)
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
            container.persistentStoreDescriptions = [description]
            return container
        }

        /// Loads the temporary store, initializes the CloudKit schema in Development, and removes the folder.
        public static func run() throws {
            let url = makeStoreURL()
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let container = try makeContainer(at: url)
            var loadError: (any Error)?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }
            defer {
                for store in container.persistentStoreCoordinator.persistentStores {
                    try? container.persistentStoreCoordinator.remove(store)
                }
            }
            try container.initializeCloudKitSchema(options: [])
            Log.sync.notice("CloudKit schema initialized in Development")
        }
    }
#endif
