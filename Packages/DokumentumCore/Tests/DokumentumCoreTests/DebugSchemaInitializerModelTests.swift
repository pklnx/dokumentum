#if DEBUG
    import CoreData
    import DokumentumCore
    import Foundation
    import SwiftData
    import Testing

    /// The CloudKit schema initializer (release.md, M3 step 1) creates the Development schema from the same model
    /// the store opens with (review B1 of #10): `DebugSchemaInitializer.makeContainer(at:)` and `ArchiveStore.schema`
    /// both take `DokumentumMigrationPlan.current`. Left on an older version, "Initialize CloudKit schema" would
    /// miss the newer fields and the comparison before the Production deploy would fail. Building the container
    /// loads nothing and contacts no CloudKit.
    struct DebugSchemaInitializerModelTests {
        /// Every entity, attribute and relationship (names, types, optionality, defaults, external storage,
        /// destinations, delete rules), compared as the snapshot dump (`SchemaDump`) of each model.
        @Test func theInitializersModelIsTheStoresSchema() throws {
            let url = DebugSchemaInitializer.makeStoreURL()
            let container = try DebugSchemaInitializer.makeContainer(at: url)
            let store = try #require(NSManagedObjectModel.makeManagedObjectModel(for: ArchiveStore.schema))
            let initializer = SchemaDump.text(of: container.managedObjectModel, header: "")
            #expect(initializer == SchemaDump.text(of: store, header: ""))
            // The fields of the newest version are there, so the comparison above is not between two old models.
            let tag = try #require(container.managedObjectModel.entitiesByName["Tag"])
            #expect(tag.attributesByName["matchModeRaw"]?.attributeType == .stringAttributeType)
            #expect(tag.attributesByName["matchPattern"]?.attributeType == .stringAttributeType)
            #expect(container.persistentStoreCoordinator.persistentStores.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
    }
#endif
