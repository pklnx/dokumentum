import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// Changes from the other device (#13, part 1; plan §3, P-a of #7): a second container on the same file writes, as the
/// CloudKit mirroring does, and the store's remote change reaches the indexer through the shared `StoreChangeObserver`,
/// whose debounce the test ends (`ManualDebounce`). An insert, a text written later, a thumbnail linked later and a
/// trash move each reach the index.
@MainActor
struct SpotlightIndexerRemoteTests {
    @Test func anotherContainersWritesReachTheIndexAfterTheRemoteChange() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let harness = try SpotlightHarness(container: store.container)
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: store.container, center: center, sleep: debounce.sleep)
        defer { observer.stop() }
        let passes = PassSignal()
        let indexer = harness.indexer(hooks: passes.hooks)
        defer { indexer.stop() }
        indexer.start(storeChanges: observer.changes())
        await passes.ended.wait()

        let storeURL = try #require(store.container.configurations.first?.url)
        let mirror = try TestSupport.makeContainerOnDisk(at: storeURL)
        var remoteChanges = 0
        func remoteChange() async {
            remoteChanges += 1
            center.post(
                name: .NSPersistentStoreRemoteChange, object: nil, userInfo: [StoreChangeObserver.storeURLKey: storeURL]
            )
            await debounce.waitForStarts(remoteChanges)
            debounce.fire()
            await passes.ended.wait(for: remoteChanges + 1)
        }

        // An import on the other device.
        let id = try SpotlightStore.insert(.init(title: "Vom Mac"), in: mirror)
        await remoteChange()
        #expect(try #require(await harness.items()[id]).title == "Vom Mac")

        // Its text, recognised there later.
        try SpotlightStore.setText("Heizkostenabrechnung", of: id, in: mirror)
        await remoteChange()
        #expect(try #require(await harness.items()[id]).textContent == "Heizkostenabrechnung")

        // Its thumbnail, linked later.
        try SpotlightStore.edit(id, in: mirror) { document, context in
            let thumbnail = DocumentThumbnail(documentID: document.id, imageData: SpotlightIndexerTests.thumbnail)
            context.insert(thumbnail)
            document.thumbnail = thumbnail
        }
        await remoteChange()
        #expect(try #require(await harness.items()[id]).thumbnailData == SpotlightIndexerTests.thumbnail)

        // Moved to the trash there.
        try SpotlightStore.trash(id, in: mirror)
        await remoteChange()
        #expect(await harness.items()[id] == nil)
        #expect(harness.fingerprinted().isEmpty)
    }
}
