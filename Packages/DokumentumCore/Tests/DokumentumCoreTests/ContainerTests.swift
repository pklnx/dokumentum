import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

struct ContainerTests {
    /// A container a test drops lives on until the end of the run, so an autosave or a task that outlives its
    /// test never finds the container gone. Without `ContainerKeeper` every reference here is `nil` after the
    /// block.
    @Test @MainActor func containersLiveUntilTheEndOfTheRun() throws {
        weak var inMemory: ModelContainer?
        weak var onDisk: ModelContainer?
        weak var kept: ModelContainer?
        try autoreleasepool {
            let first = try TestSupport.makeContainer()
            inMemory = first
            let second = try TestSupport.makeContainerOnDisk()
            onDisk = second
            let third = TestSupport.keepAlive(ArchiveStore.makeContainer(for: .inMemory(seed: false)).container)
            kept = third
        }
        #expect(inMemory != nil)
        #expect(onDisk != nil)
        #expect(kept != nil)
    }

    @Test func theHelpersNeverSync() throws {
        for container in [try TestSupport.makeContainer(), try TestSupport.makeContainerOnDisk()] {
            #expect(container.configurations.first?.cloudKitContainerIdentifier == nil)
        }
        #expect(try TestSupport.makeContainer().configurations.first?.isStoredInMemoryOnly == true)
        let disk = try #require(try TestSupport.makeContainerOnDisk().configurations.first)
        #expect(
            disk.url.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path)
                || disk.url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
