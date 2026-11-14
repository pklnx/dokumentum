import CoreData
import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// `ReminderScheduler` on a store (#12, part 3; plan §9): the launch reconcile, an editor save, another device's
/// changes through the store observer, the end of an import, the day, zone and clock notifications, a settings change,
/// the authorization becoming allowed, an empty fallback store, and never a request for permission. The center is
/// `InMemoryNotificationCenter`, the clock fixed, the debounce `ManualDebounce`, the notifications posted on a center of
/// the test's own. Nothing waits for time.
@MainActor
struct ReminderSchedulerTests {
    /// The test's clock and settings, read by the reconciler.
    final class World: @unchecked Sendable {
        // Guarded by `lock`.
        private var nowValue: Date
        private var settingsValue = ReminderSettings()
        private let lock = NSLock()

        init(now: Date) { nowValue = now }

        var now: Date {
            get { lock.withLock { nowValue } }
            set { lock.withLock { nowValue = newValue } }
        }
        var settings: ReminderSettings {
            get { lock.withLock { settingsValue } }
            set { lock.withLock { settingsValue = newValue } }
        }
    }

    nonisolated static let berlin = TimeZone(identifier: "Europe/Berlin")!

    nonisolated static func instant(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    nonisolated static let text = ReminderText(title: { $0.title }, body: { "\($0.daysAhead)|\($0.label)" })

    /// A scheduler on `container`, its reconciler on `center` and `scheduled`, and a signal for each finished reconcile.
    struct Harness {
        let scheduler: ReminderScheduler
        let finished: TestSignal
        let center: InMemoryNotificationCenter
        let world: World
        let notifications: NotificationCenter
    }

    static func harness(
        on container: ModelContainer, storeChanges: AsyncStream<Void>? = nil,
        center: InMemoryNotificationCenter = InMemoryNotificationCenter(
            status: .authorized, calendar: InMemoryNotificationCenter.gregorian(berlin)),
        scheduled: any ScheduledSetStoring = InMemoryScheduledSet(), world: World = World(now: instant(11, 20, 10))
    ) -> Harness {
        let reader = ReminderStoreReader(container: container)
        let reconciler = ReminderReconciler(
            center: center, scheduledSet: scheduled, readDeadlines: { try await reader.read() },
            settings: { world.settings }, text: text, now: { world.now },
            calendar: { InMemoryNotificationCenter.gregorian(berlin) })
        let notifications = NotificationCenter()
        let scheduler = ReminderScheduler(
            reconciler: reconciler, container: container, storeChanges: storeChanges, center: notifications)
        let finished = TestSignal()
        scheduler.didFinishReconcile = { _ in finished.fire() }
        return Harness(
            scheduler: scheduler, finished: finished, center: center, world: world, notifications: notifications)
    }

    /// A document with a deadline on 2026-11-27, set 2026-11-01 10:00; returns its `instanceID`.
    @discardableResult
    static func insertDeadline(
        into context: ModelContext, day: String = "2026-11-27", title: String = "Water bill"
    ) throws -> UUID {
        let document = Document(title: title)
        document.deadlineDay = day
        document.deadlineLabel = "Pay"
        document.deadlineSetAt = instant(11, 1, 10)
        context.insert(document)
        try context.save()
        return document.instanceID
    }

    nonisolated static func identifier(_ instanceID: UUID, _ day: String = "2026-11-27") -> String {
        ReminderIdentifier.make(instanceID: instanceID, day: DeadlineDay(storedValue: day)!)
    }

    // MARK: Triggers

    @Test func theLaunchReconciles() async throws {
        let container = try TestSupport.makeContainer()
        let id = try Self.insertDeadline(into: container.mainContext)
        let harness = Self.harness(on: container)
        defer { harness.scheduler.stop() }
        harness.scheduler.start()
        await harness.finished.wait(for: 1)
        #expect(await harness.center.pendingRequest(Self.identifier(id))?.moment.description == "2026-11-24 09:00")
        #expect(await harness.center.pendingRequest(Self.identifier(id))?.body == "3|Pay")
        #expect(await harness.center.authorizationRequests == 0)
    }

    /// An edit through `DocumentEditor` saves the context; the save reconciles.
    @Test func anEditorSaveReconciles() async throws {
        let container = try TestSupport.makeContainer()
        let document = Document(title: "Water bill")
        container.mainContext.insert(document)
        try container.mainContext.save()
        let harness = Self.harness(on: container)
        defer { harness.scheduler.stop() }
        harness.scheduler.start()
        await harness.finished.wait(for: 1)
        #expect(await harness.center.pending().isEmpty)

        let requests = harness.scheduler.requests
        let editor = DocumentEditor(context: container.mainContext, now: { Self.instant(11, 20, 10) })
        try editor.apply(.deadline(DeadlineDay(year: 2026, month: 12, day: 4)!, label: "Pay"), to: document.instanceID)
        await harness.finished.wait(for: requests + 1)
        #expect(
            await harness.center.pendingRequest(Self.identifier(document.instanceID, "2026-12-04"))?.moment.description
                == "2026-12-01 09:00")
        #expect(await harness.center.authorizationRequests == 0)
    }

    /// Another device's changes arrive in the store without a context of the app (a second container on the same file,
    /// as the mirroring); the observer's debounced change reconciles: scheduled, removed when trashed, moved with the
    /// day, and one whose lead moment passed is caught up. No request for permission on the way.
    @Test func anotherDevicesChangesAreFollowed() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let debounce = ManualDebounce()
        let posting = NotificationCenter()
        let observer = StoreChangeObserver(container: store.container, center: posting, sleep: debounce.sleep)
        defer { observer.stop() }
        let harness = Self.harness(on: store.container, storeChanges: observer.changes())
        defer { harness.scheduler.stop() }
        harness.scheduler.start()
        await harness.finished.wait(for: 1)

        let storeURL = try #require(store.container.configurations.first?.url)
        let mirror = try TestSupport.makeContainerOnDisk(at: storeURL)
        var reconciles = 1
        func synced() async {
            posting.post(
                name: .NSPersistentStoreRemoteChange, object: nil,
                userInfo: [StoreChangeObserver.storeURLKey: storeURL])
            await debounce.waitForStarts(debounce.started + 1)
            debounce.fire()
            reconciles += 1
            await harness.finished.wait(for: reconciles)
        }

        let id = try Self.insertDeadline(into: mirror.mainContext)
        await synced()
        #expect(await harness.center.pendingRequest(Self.identifier(id))?.moment.description == "2026-11-24 09:00")

        let document = try #require(
            try mirror.mainContext.fetch(FetchDescriptor<Document>()).first { $0.instanceID == id })
        document.deadlineDay = "2026-12-04"
        try mirror.mainContext.save()
        await synced()
        #expect(await harness.center.pendingRequest(Self.identifier(id)) == nil)
        #expect(
            await harness.center.pendingRequest(Self.identifier(id, "2026-12-04"))?.moment.description
                == "2026-12-01 09:00")

        document.deletedAt = Self.instant(11, 20, 11)
        try mirror.mainContext.save()
        await synced()
        #expect(await harness.center.pending().isEmpty)

        // Restored on the other device on 12-02: the lead moment passed, the day is ahead: caught up.
        harness.world.now = Self.instant(12, 2, 10)
        document.deletedAt = nil
        try mirror.mainContext.save()
        await synced()
        #expect(
            await harness.center.pendingRequest(Self.identifier(id, "2026-12-04"))?.moment.description
                == "2026-12-02 10:01")
        #expect(await harness.center.authorizationRequests == 0)
    }

    /// The end of a CloudKit import restarts the observer's debounce (`RepairScheduler` signals it); its change
    /// reconciles.
    @Test func theEndOfAnImportReconciles() async throws {
        let container = try TestSupport.makeContainer()
        let debounce = ManualDebounce()
        let observer = StoreChangeObserver(container: container, center: NotificationCenter(), sleep: debounce.sleep)
        defer { observer.stop() }
        let harness = Self.harness(on: container, storeChanges: observer.changes())
        defer { harness.scheduler.stop() }
        harness.scheduler.start()
        await harness.finished.wait(for: 1)
        observer.signal()
        await debounce.waitForStarts(1)
        debounce.fire()
        await harness.finished.wait(for: 2)
        #expect(harness.scheduler.requests == 2)
    }

    /// The calendar day, the system time zone and the system clock: each reconciles.
    @Test(arguments: ReminderScheduler.timeNotifications)
    func aDayZoneOrClockChangeReconciles(name: Notification.Name) async throws {
        let container = try TestSupport.makeContainer()
        let harness = Self.harness(on: container)
        defer { harness.scheduler.stop() }
        harness.scheduler.start()
        await harness.finished.wait(for: 1)
        harness.notifications.post(name: name, object: nil)
        await harness.finished.wait(for: 2)
        #expect(harness.scheduler.requests == 2)
    }

    /// The app requests a reconcile after a settings change: turned off, the reminder is withdrawn; on again inside the
    /// window, caught up.
    @Test func aSettingsChangeReconciles() async throws {
        let container = try TestSupport.makeContainer()
        let id = try Self.insertDeadline(into: container.mainContext)
        let harness = Self.harness(on: container)
        defer { harness.scheduler.stop() }
        harness.scheduler.start()
        await harness.finished.wait(for: 1)
        harness.world.settings = ReminderSettings(isOn: false)
        harness.scheduler.requestReconcile()
        await harness.finished.wait(for: 2)
        #expect(await harness.center.pending().isEmpty)
        harness.world.settings = ReminderSettings(leadDays: 7)
        harness.scheduler.requestReconcile()
        await harness.finished.wait(for: 3)
        #expect(await harness.center.pendingRequest(Self.identifier(id))?.moment.description == "2026-11-20 10:01")
    }

    /// Not determined: nothing is scheduled and nothing is asked. Allowed later (the app requests a reconcile when the
    /// answer comes or the scene becomes active): caught up.
    @Test func theAuthorizationBecomingAllowedCatchesUp() async throws {
        let container = try TestSupport.makeContainer()
        let id = try Self.insertDeadline(into: container.mainContext)
        let center = InMemoryNotificationCenter(
            status: .notDetermined, calendar: InMemoryNotificationCenter.gregorian(Self.berlin))
        let harness = Self.harness(on: container, center: center, world: World(now: Self.instant(11, 25, 10)))
        defer { harness.scheduler.stop() }
        harness.scheduler.start()
        await harness.finished.wait(for: 1)
        #expect(await center.pending().isEmpty)
        await center.setStatus(.authorized)
        harness.scheduler.requestReconcile()
        await harness.finished.wait(for: 2)
        #expect(await center.pendingRequest(Self.identifier(id))?.moment.description == "2026-11-25 10:01")
        #expect(await center.authorizationRequests == 0, "the scheduler never asks")
    }

    // MARK: R2

    /// The app opens an empty local fallback store once (the store failed to open), then the store with the data again:
    /// the same center and `S` on both. The reminder that fired is not shown again.
    @Test func anEmptyFallbackStoreBetweenTwoLaunchesRemindsNoTwice() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try TestSupport.makeContainerOnDisk(at: folder.appending(path: "Dokumentum.store"))
        let fallback = try TestSupport.makeContainerOnDisk(at: folder.appending(path: "Dokumentum-local.store"))
        let id = try Self.insertDeadline(into: data.mainContext)
        let center = InMemoryNotificationCenter(
            status: .authorized, calendar: InMemoryNotificationCenter.gregorian(Self.berlin))
        let scheduled = ScheduledSetFile(url: folder.appending(path: "Reminders/Scheduled.json"))
        let world = World(now: Self.instant(11, 20, 10))

        func launch(_ container: ModelContainer, at now: Date) async {
            world.now = now
            let harness = Self.harness(on: container, center: center, scheduled: scheduled, world: world)
            harness.scheduler.start()
            await harness.finished.wait(for: 1)
            harness.scheduler.stop()
        }
        await launch(data, at: Self.instant(11, 20, 10))
        await center.deliver(upTo: Self.instant(11, 24, 9))
        await launch(fallback, at: Self.instant(11, 25, 8))
        #expect(await center.delivered().isEmpty, "the empty read clears the banners")
        await launch(data, at: Self.instant(11, 25, 10))
        await center.deliver(upTo: Self.instant(11, 30, 0))
        #expect(await center.shown[Self.identifier(id)] == 1)
        #expect(await center.authorizationRequests == 0)
    }
}
