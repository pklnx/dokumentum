import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The library follows what arrives without a context of the app (plan of #3, part 5): the remote changes the
/// CloudKit mirroring saves into the store, and the end of each CloudKit import, through the app's shared
/// `StoreChangeObserver` (#30). The observer listens on a center of the test's own and its debounce is ended by
/// the test (`ManualDebounce`), so nothing waits for time.
@MainActor
struct StoreLibraryRemoteChangeTests {
    /// A runner that does nothing: the scheduler's runs are not under test here.
    private struct IdleRunner: RepairRunning {
        func run(hasCompletedImport: Bool) async -> RepairReport? { RepairReport() }
    }

    /// Another writer of the same store file (as the mirroring is) saves a document; the library's own save
    /// observation does not see it. The store's remote change notification, debounced, makes the library read
    /// again, and the snapshot then lists the document.
    @Test func aRemoteChangeOfTheStoreFiresChangesAndTheSnapshotShowsIt() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: store.container, center: center, sleep: debounce.sleep)
        defer { observer.stop() }
        let source = StoreLibrarySource(container: store.container, storeChanges: observer.changes())
        let (changes, subscriber) = TestSignal.counting(source.changes)
        defer { subscriber.cancel() }

        let storeURL = try #require(store.container.configurations.first?.url)
        let mirror = try TestSupport.makeContainerOnDisk(at: storeURL)
        mirror.mainContext.insert(Document(title: "Vom anderen Gerät"))
        try mirror.mainContext.save()
        // The library's save observation runs inside `save()`: a save of another container is no event of its own.
        #expect(changes.count == 0)

        center.post(
            name: .NSPersistentStoreRemoteChange, object: nil, userInfo: [StoreChangeObserver.storeURLKey: storeURL])
        await debounce.waitForStarts(1)
        debounce.fire()
        await changes.wait(for: 1)
        #expect(source.snapshot().documents.map(\.title) == ["Vom anderen Gerät"])
    }

    /// The end of a CloudKit import restarts the shared observer's debounce (`RepairScheduler`), and the library
    /// reads again after it, also when the import itself posted no remote change.
    @Test func theEndOfACloudKitImportFiresChanges() async throws {
        let container = try TestSupport.makeContainer()
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: container, center: center, sleep: debounce.sleep)
        let (events, imports) = AsyncStream<CloudImportEvent>.makeStream()
        let scheduler = RepairScheduler(runner: IdleRunner(), observer: observer, importEvents: events)
        let source = StoreLibrarySource(container: container, storeChanges: observer.changes())
        let (changes, subscriber) = TestSignal.counting(source.changes)
        defer {
            subscriber.cancel()
            scheduler.stop()
        }
        scheduler.start()

        imports.yield(CloudImportEvent(succeeded: true))
        await debounce.waitForStarts(1)
        #expect(changes.count == 0, "still waiting for quiet")
        debounce.fire()
        await changes.wait(for: 1)
    }
}
