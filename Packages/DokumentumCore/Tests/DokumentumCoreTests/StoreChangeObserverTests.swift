import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// The shared "store changed" signal (`StoreChangeObserver`), ported from the predecessor's tests.
@MainActor
struct StoreChangeObserverTests {
    /// Lets the main-actor tasks that the observer's notification handlers queued so far run. A change that is
    /// ignored is then proven by `receivedSignals == 0` at once, instead of by waiting a fixed time for a signal
    /// that might only come later on a busy runner.
    private func drainMainActor() async {
        for _ in 0..<3 { await Task { @MainActor in }.value }
    }

    /// A burst of saves (their `didSave` and remote change notifications) gives one signal. The notifications
    /// are posted to the observer's own center: with real saves, a remote change notification that arrives late
    /// on a busy runner would be a second burst. The test ends the quiet period itself (`ManualDebounce`).
    @Test func severalSavesGiveOneDebouncedSignal() async throws {
        let container = try TestSupport.makeContainer()
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: container, center: center, sleep: debounce.sleep)
        let (signals, task) = TestSignal.counting(observer.changes())
        defer {
            task.cancel()
            observer.stop()
        }
        let storeURL = try #require(container.configurations.first?.url)
        func save() {
            center.post(name: ModelContext.didSave, object: container.mainContext)
            center.post(
                name: .NSPersistentStoreRemoteChange, object: nil,
                userInfo: [StoreChangeObserver.storeURLKey: storeURL])
        }

        for _ in 0..<3 { save() }
        await debounce.waitForStarts(6)
        #expect(signals.count == 0, "still waiting for quiet")
        #expect(observer.receivedSignals == 6)
        debounce.fire()
        await signals.wait(for: 1)
        // Every save restarted the one timer: nothing is left that could signal again.
        #expect(!debounce.isWaiting)
        await drainMainActor()
        #expect(signals.count == 1)

        save()
        await debounce.waitForStarts(8)
        debounce.fire()
        await signals.wait(for: 2)
        #expect(!debounce.isWaiting)
        await drainMainActor()
        #expect(signals.count == 2)
    }

    /// A real save to the store reaches the observer (through `didSave` or the remote change), with the real
    /// timer.
    @Test func aSaveIsSignalled() async throws {
        // On disk: in-memory stores of tests running in parallel all report `/dev/null` as their URL, so their
        // saves would count as changes of this store.
        let store = try TemporaryStore()
        defer { store.remove() }
        let observer = StoreChangeObserver(container: store.container, debounce: .milliseconds(50))
        let (signals, task) = TestSignal.counting(observer.changes())
        defer {
            task.cancel()
            observer.stop()
        }

        store.container.mainContext.insert(DokumentumCore.Tag(name: "Tax"))
        try store.container.mainContext.save()
        await signals.wait(for: 1, timeout: .seconds(60))
        #expect(observer.receivedSignals >= 1)
    }

    /// SwiftData posts `NSPersistentStoreRemoteChange` for every save; the observer relies on it for changes
    /// that do not pass through a `ModelContext` of the app (CloudKit import).
    @Test func theStorePostsRemoteChangeNotifications() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let storeURL = try #require(store.container.configurations.first?.url)
        let center = NotificationCenter.default
        // Recorded on the posting thread, not through the main actor, which the tests running in parallel keep
        // busy.
        let notified = TestSignal()
        let token = center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) {
            notification in
            guard let url = notification.userInfo?[StoreChangeObserver.storeURLKey] as? URL,
                StoreChangeObserver.isSameStore(url, storeURL)
            else { return }
            notified.fire()
        }
        defer { center.removeObserver(token) }

        store.container.mainContext.insert(DokumentumCore.Tag(name: "Tax"))
        try store.container.mainContext.save()
        #expect(await notified.wait(for: 1, timeout: .seconds(60)))
    }

    @Test func savesOfAnotherArchiveAreIgnored() async throws {
        let store = try TemporaryStore()
        let other = try TemporaryStore()
        defer {
            store.remove()
            other.remove()
        }
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: store.container, sleep: debounce.sleep)
        defer { observer.stop() }

        other.container.mainContext.insert(DokumentumCore.Tag(name: "Elsewhere"))
        try other.container.mainContext.save()
        await drainMainActor()
        #expect(observer.receivedSignals == 0, "the save of another archive was not ignored")

        // The observer does follow its own archive, so the check above is not vacuous.
        store.container.mainContext.insert(DokumentumCore.Tag(name: "Here"))
        try store.container.mainContext.save()
        await debounce.waitForStarts(1)
        #expect(observer.receivedSignals >= 1)
    }

    /// Changes from other devices arrive as `NSPersistentStoreRemoteChange` (CloudKit store).
    @Test func remoteChangesAreSignalledToEverySubscriber() async throws {
        let container = try TestSupport.makeContainer()
        let center = NotificationCenter()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: container, center: center, sleep: debounce.sleep)
        let (first, firstTask) = TestSignal.counting(observer.changes())
        let (second, secondTask) = TestSignal.counting(observer.changes())
        defer {
            firstTask.cancel()
            secondTask.cancel()
            observer.stop()
        }

        center.post(
            name: .NSPersistentStoreRemoteChange, object: nil,
            userInfo: [StoreChangeObserver.storeURLKey: URL(filePath: "/elsewhere.store")])
        await drainMainActor()
        #expect(observer.receivedSignals == 0, "another store")

        let storeURL = try #require(container.configurations.first?.url)
        center.post(
            name: .NSPersistentStoreRemoteChange, object: nil, userInfo: [StoreChangeObserver.storeURLKey: storeURL])
        await debounce.waitForStarts(1)
        debounce.fire()
        await first.wait(for: 1)
        await second.wait(for: 1)
        // Not only at the moment the first signal arrives: no duplicate follows it.
        #expect(!debounce.isWaiting)
        await drainMainActor()
        #expect(first.count == 1)
        #expect(second.count == 1)
    }
}
