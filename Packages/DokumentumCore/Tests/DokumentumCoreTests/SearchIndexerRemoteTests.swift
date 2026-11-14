import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// What reaches the indexer without a context of its container (plan of #7, T2): a second container on the same
/// file writes, as the CloudKit mirroring does, and the store's remote change arrives through the shared
/// `StoreChangeObserver`, whose debounce the test ends (`ManualDebounce`). And the history's expiry, which
/// rebuilds the index aside while the old one keeps answering.
@MainActor
struct SearchIndexerRemoteTests {
    @Test func aTextWrittenByAnotherContainerIsFoundAfterTheRemoteChange() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let document = try SearchStore.insert(title: "Import", in: store.container)
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: store.container, center: center, sleep: debounce.sleep)
        defer { observer.stop() }
        let indexer = SearchIndexer(container: store.container)
        let recorder = StateRecorder(indexer.updates())
        defer {
            recorder.cancel()
            indexer.stop()
        }
        indexer.start(storeChanges: observer.changes())
        await recorder.ready.wait()

        let storeURL = try #require(store.container.configurations.first?.url)
        let mirror = try TestSupport.makeContainerOnDisk(at: storeURL)
        try SearchStore.setText("Wasserzähler abgelesen", of: document, in: mirror)
        center.post(
            name: .NSPersistentStoreRemoteChange, object: nil, userInfo: [StoreChangeObserver.storeURLKey: storeURL])
        await debounce.waitForStarts(1)
        debounce.fire()

        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("wasserzahler").matches == [document])
    }

    /// The history after the indexer's token is deleted: the next event rebuilds (`.building`, then `.ready`). While
    /// the rebuild is held after its first batch, queries answer from the old index; after the swap from the new
    /// one, which has the change the expired history no longer holds.
    @Test func anExpiredHistoryRebuildsAsideAndSwaps() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let document = try SearchStore.insert(title: "Zähler", text: "Altstand", in: store.container)
        let armed = Armed()
        let beforeHistory = Checkpoint()
        let rebuildBatch = Checkpoint()
        let indexer = SearchIndexer(
            container: store.container,
            hooks: .init(
                afterBatch: { _ in if armed.isOn { await rebuildBatch.pass() } },
                beforeHistory: { if armed.isOn { await beforeHistory.pass() } }))
        let recorder = StateRecorder(indexer.updates())
        defer {
            beforeHistory.release()
            rebuildBatch.release()
            recorder.cancel()
            indexer.stop()
        }
        indexer.start()
        await recorder.ready.wait()
        #expect(await indexer.lastHistoryErrorCode == nil)
        armed.turnOn()

        try SearchStore.setText("Neustand", of: document, in: store.container)
        await beforeHistory.reached()
        let context = ModelContext(store.container)
        let newest = try #require(try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>()).last?.token)
        try context.deleteHistory(
            HistoryDescriptor<DefaultHistoryTransaction>(predicate: #Predicate { $0.token <= newest }))
        let elementsBefore = recorder.states.count
        beforeHistory.release()

        await rebuildBatch.reached()
        let during = await indexer.search("altstand")
        #expect(during.matches == [document], "the old index answers during the rebuild")
        #expect(during.state == .building(indexed: 1, total: 1))
        #expect(await indexer.search("neustand").matches == [])
        rebuildBatch.release()

        await recorder.ready.wait(for: 2)
        #expect(await indexer.search("neustand").matches == [document])
        #expect(await indexer.search("altstand").matches == [])
        #expect(await indexer.builds == 2)
        // The Sync lab shows why a search missed (T11 of #31): an expiry is recorded too (review B, N2 of PR #155).
        #expect(await indexer.lastHistoryErrorCode != nil, "the expiry left no history error code")
        // A subscriber keeps the newest element only, so it may not see each `.building` step, but one at least.
        let rebuild = Array(recorder.states.dropFirst(elementsBefore))
        #expect(rebuild.last == .ready)
        #expect(rebuild.contains { if case .building = $0 { true } else { false } }, "\(rebuild)")
    }
}
