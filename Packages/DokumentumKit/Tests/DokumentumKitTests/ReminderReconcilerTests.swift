import DokumentumKit
import DokumentumTestSupport
import Foundation
import Testing

/// `ReminderReconciler` on `InMemoryNotificationCenter` (#12, part 3; plan §4 and its tests): the diff, the prefix, the
/// scheduled set, the delivered cleanup, failing adds and reads, the system delivering at the worst moment, the texts,
/// two devices, the cap, coalescing, and 30 days at most once. Fixed instants only; nothing waits for time.
struct ReminderReconcilerTests {
    private let idA = deadline().identifier

    // MARK: The diff

    @Test func aSecondReconcileAddsNothing() async {
        let device = ReminderDevice()
        let first = await device.reconcile(at: at(2026, 11, 20, 10))
        let second = await device.reconcile(at: at(2026, 11, 20, 11))
        #expect(first.added == 1)
        #expect(second.added == 0 && second.replaced == 0 && second.withdrawn == 0)
        #expect(await device.center.adds[idA] == 1)
        #expect(device.scheduled.identifiers == [idA])
    }

    /// A new day withdraws the old identifier and adds the new one; a new title or label replaces the request.
    @Test func aNewDayMovesTheRequestAndNewTextsReplaceIt() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        let moved = deadline(day: ymd(2026, 12, 4), setAt: at(2026, 11, 20, 11))
        device.set(deadlines: [moved])
        let move = await device.reconcile(at: at(2026, 11, 20, 12))
        #expect(move.withdrawn == 1 && move.added == 1)
        #expect(await device.pendingMoment() == nil)
        #expect(await device.pendingMoment(moved.identifier) == moment(2026, 12, 1, 9, 0))
        #expect(device.scheduled.identifiers == [moved.identifier], "a withdrawal before delivery leaves S")

        device.set(deadlines: [deadline(day: ymd(2026, 12, 4), setAt: at(2026, 11, 20, 11), title: "Strom")])
        let retitled = await device.reconcile(at: at(2026, 11, 20, 13))
        #expect(retitled.replaced == 1)
        #expect(await device.center.pendingRequest(moved.identifier)?.title == "Strom")
        device.set(deadlines: [
            deadline(day: ymd(2026, 12, 4), setAt: at(2026, 11, 20, 11), label: "Zahlen", title: "Strom")
        ])
        let relabelled = await device.reconcile(at: at(2026, 11, 20, 14))
        #expect(relabelled.replaced == 1)
        #expect(await device.center.pendingRequest(moved.identifier)?.body == "3|2026-12-04|Zahlen")
        #expect(await device.center.adds[moved.identifier] == 3)
    }

    /// Done, trashed or deleted: a pending reminder is withdrawn (its `S` entry goes) and a delivered one is removed from
    /// Notification Center (its `S` entry stays: it has fired).
    @Test(arguments: ["done", "trashed", "deleted"])
    func doneTrashedOrDeletedRemovesPendingAndDelivered(change: String) async {
        let early = deadline(documentB, day: ymd(2026, 11, 23))
        let device = ReminderDevice([deadline(), early])
        await device.reconcile(at: at(2026, 11, 19, 10))
        await device.deliver(upTo: at(2026, 11, 20, 9))
        #expect(await device.center.delivered().map(\.identifier) == [early.identifier])
        switch change {
        case "done":
            device.set(deadlines: [deadline(done: true), deadline(documentB, day: ymd(2026, 11, 23), done: true)])
        case "trashed":
            device.set(deadlines: [deadline(trashed: true), deadline(documentB, day: ymd(2026, 11, 23), trashed: true)])
        default: device.set(deadlines: [])
        }
        let report = await device.reconcile(at: at(2026, 11, 20, 10))
        #expect(report.withdrawn == 1 && report.removedDelivered == 1)
        #expect(await device.center.pending().isEmpty)
        #expect(await device.center.delivered().isEmpty)
        #expect(device.scheduled.identifiers == [early.identifier])
    }

    /// Off: every `deadline.` request is withdrawn, another notification of the app is untouched, and delivered reminders
    /// are left alone (re-review 2, N3), also one whose deadline was done meanwhile. The same without authorization. On
    /// again, the next reconcile removes the done one's banner.
    @Test(arguments: [false, true])
    func offOrNotAuthorizedWithdrawsOnlyPrefixedPendingRequests(revoked: Bool) async throws {
        let early = deadline(documentB, day: ymd(2026, 11, 23))
        let device = ReminderDevice([deadline(), early])
        let foreign = ReminderRequest(
            identifier: "import.finished", moment: moment(2026, 11, 30, 9, 0), title: "x", body: "y", instanceID: nil)
        try await device.center.add(foreign)
        await device.reconcile(at: at(2026, 11, 19, 10))
        await device.deliver(upTo: at(2026, 11, 20, 9))
        if revoked {
            await device.center.setStatus(.denied)
        } else {
            device.set(settings: ReminderSettings(isOn: false))
        }
        device.set(deadlines: [deadline(), deadline(documentB, day: ymd(2026, 11, 23), done: true)])
        let report = await device.reconcile(at: at(2026, 11, 20, 10))
        #expect(report.withdrawn == 1 && report.added == 0 && report.removedDelivered == 0)
        #expect(await device.center.pending().map(\.identifier) == ["import.finished"])
        #expect(await device.center.delivered().map(\.identifier) == [early.identifier])
        #expect(await device.center.authorizationRequests == 0, "the reconciler never asks")

        if revoked {
            await device.center.setStatus(.authorized)
        } else {
            device.set(settings: ReminderSettings())
        }
        let again = await device.reconcile(at: at(2026, 11, 20, 11))
        #expect(again.removedDelivered == 1)
        #expect(await device.center.delivered().isEmpty)
    }

    /// Not authorized: nothing is planned; once authorized, the next reconcile catches up what is inside the lead time.
    @Test func afterAuthorizationTheNextReconcileCatchesUp() async {
        let device = ReminderDevice(status: .notDetermined)
        let report = await device.reconcile(at: at(2026, 11, 25, 9))
        #expect(report.planned == 0)
        #expect(await device.center.pending().isEmpty)
        await device.center.setStatus(.provisional)
        await device.reconcile(at: at(2026, 11, 25, 9, 30))
        #expect(await device.pendingMoment() == moment(2026, 11, 25, 9, 31))
        #expect(await device.center.authorizationRequests == 0)
    }

    // MARK: Failures (R1, R2)

    /// R1: an `add` that fails leaves `S` unchanged, so the next reconcile adds it.
    @Test func aFailingAddLeavesTheSetUnchangedAndTheNextReconcileAddsIt() async {
        struct AddFailed: Error {}
        let device = ReminderDevice(hooks: .init(beforeAdd: { _ in throw AddFailed() }))
        let failed = await device.reconcile(at: at(2026, 11, 20, 10))
        #expect(failed.failedAdds == 1 && failed.added == 0)
        #expect(device.scheduled.identifiers.isEmpty)
        await device.center.setHooks(.init())
        let next = await device.reconcile(at: at(2026, 11, 20, 11))
        #expect(next.added == 1)
        #expect(device.scheduled.identifiers == [idA])
        await device.deliver(upTo: at(2026, 11, 30))
        #expect(await device.shown() == 1)
    }

    /// A scheduled set that cannot be read ends the reconcile with no change, as a failed deadline read does.
    @Test func anUnreadableScheduledSetChangesNothing() async {
        final class Unreadable: ScheduledSetStoring, @unchecked Sendable {
            struct Failure: Error {}
            var saves = 0
            func load() throws -> Set<String> { throw Failure() }
            func save(_ scheduled: Set<String>) throws { saves += 1 }
        }
        let unreadable = Unreadable()
        let center = InMemoryNotificationCenter(status: .authorized)
        let reconciler = ReminderReconciler(
            center: center, scheduledSet: unreadable, readDeadlines: { [deadline()] },
            settings: { ReminderSettings() }, text: identifyingText, now: { at(2026, 11, 20, 10) },
            calendar: { InMemoryNotificationCenter.gregorian(Zones.berlin) })
        let report = await reconciler.reconcile()
        #expect(report.outcome == .scheduledSetUnreadable)
        #expect(await center.pending().isEmpty)
        #expect(unreadable.saves == 0)
    }

    /// R2: pruning keeps an entry of today − 1 and drops today − 2, by its day alone, whatever the deadlines say.
    @Test func theReconcilePrunesTheSetByDayOnly() async {
        let yesterday = ReminderIdentifier.make(instanceID: documentB, day: ymd(2026, 11, 26))
        let twoDaysAgo = ReminderIdentifier.make(instanceID: documentB, day: ymd(2026, 11, 25))
        let device = ReminderDevice([], scheduled: InMemoryScheduledSet([yesterday, twoDaysAgo, idA]))
        await device.reconcile(at: at(2026, 11, 27, 8))
        #expect(device.scheduled.identifiers == [yesterday, idA])
    }

    // MARK: The system delivering at the worst moment

    /// N5: a request the system delivers between the reconciler's reads of pending and delivered is not added again.
    @Test func aRequestDeliveredBetweenTheReadsIsNotAddedAgain() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        // The lead moves so the request would be replaced, and the system delivers it right after the pending read.
        await device.center.setHooks(.init(deliverAfterNextPendingRead: at(2026, 11, 24, 9)))
        device.set(settings: ReminderSettings(leadDays: 2))
        await device.reconcile(at: at(2026, 11, 24, 9, 0, 1))
        #expect(await device.pendingMoment() == nil)
        #expect(await device.center.adds[idA] == 1)
        await device.deliver(upTo: at(2026, 11, 30))
        #expect(await device.shown() == 1)
    }

    /// Re-review 2, N1: the system delivers a request right before the reconciler withdraws it (the deadline was done):
    /// the delivered read after the withdrawal keeps its `S` entry, so undoing "done" later does not remind again.
    @Test func aRequestDeliveredDuringItsWithdrawalStaysFired() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        await device.center.setHooks(.init(deliverBeforeNextRemovePending: at(2026, 11, 24, 9)))
        device.set(deadlines: [deadline(done: true)])
        await device.reconcile(at: at(2026, 11, 24, 9, 0, 1))
        #expect(device.scheduled.identifiers == [idA])
        await device.reconcile(at: at(2026, 11, 24, 10))
        device.set(deadlines: [deadline()])
        await device.reconcile(at: at(2026, 11, 25, 10))
        #expect(await device.pendingMoment() == nil)
        await device.deliver(upTo: at(2026, 11, 30))
        #expect(await device.shown() == 1)
    }

    // MARK: Texts (N6, Q5)

    /// The body is relative to the moment's day: 3 days ahead "on <date>", the day before "tomorrow", the due day
    /// "today", whatever day the reconcile runs on. The title is the document's title, never its text.
    @Test(arguments: [(3, 3), (1, 1), (0, 0)])
    func theBodyIsRelativeToTheMomentsDay(leadDays: Int, daysAhead: Int) async throws {
        let device = ReminderDevice(settings: ReminderSettings(leadDays: leadDays))
        await device.reconcile(at: at(2026, 11, 2, 10))
        let request = try #require(await device.center.pendingRequest(idA))
        #expect(request.body == "\(daysAhead)|2026-11-27|Pay")
        #expect(request.title == "Water bill")
        #expect(request.instanceID == documentA)
        #expect(request.threadIdentifier == "deadlines")
        // A reconcile on a later day changes nothing.
        let later = await device.reconcile(at: at(2026, 11, 12, 10))
        #expect(later.replaced == 0)
    }

    @Test func aCatchUpOnTheDueDaySaysToday() async throws {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 27, 8))
        #expect(try #require(await device.center.pendingRequest(idA)).body == "0|2026-11-27|Pay")
    }

    // MARK: Relaunch

    /// A new reconciler on the same center and `S` (a relaunch) plans nothing again for what has fired.
    @Test func aRelaunchKeepsWhatHasFired() async {
        let device = ReminderDevice()
        await device.reconcile(at: at(2026, 11, 20, 10))
        await device.deliver(upTo: at(2026, 11, 24, 9))
        await device.center.clearDelivered()
        device.relaunch()
        await device.reconcile(at: at(2026, 11, 25, 10))
        #expect(await device.pendingMoment() == nil)
        #expect(await device.shown() == 1)
    }

    // MARK: Two devices

    /// Two centers, two `S`, settings of 3 days / 09:00 and on the day / 18:00: each shows a deadline once, at its own
    /// moment; a day moved on one moves both; done on one clears the other's pending and delivered reminders; a
    /// deadline set on one inside the window reminds on its due day on both, with no catch-up.
    @Test func twoDevicesEachRemindOnceByTheirOwnSettings() async {
        let iPhone = ReminderDevice()
        let mac = ReminderDevice(settings: ReminderSettings(leadDays: 0, minuteOfDay: 18 * 60))
        func sync(_ deadlines: [ReminderDeadline]) {
            iPhone.set(deadlines: deadlines)
            mac.set(deadlines: deadlines)
        }
        func step(_ instant: Date) async {
            await iPhone.deliver(upTo: instant)
            await mac.deliver(upTo: instant)
            await iPhone.reconcile(at: instant)
            await mac.reconcile(at: instant)
        }
        await step(at(2026, 11, 20, 10))
        #expect(await iPhone.pendingMoment() == moment(2026, 11, 24, 9, 0))
        #expect(await mac.pendingMoment() == moment(2026, 11, 27, 18, 0))
        await step(at(2026, 11, 28))
        #expect(await iPhone.center.delivered().map(\.moment) == [moment(2026, 11, 24, 9, 0)])
        #expect(await mac.center.delivered().map(\.moment) == [moment(2026, 11, 27, 18, 0)])

        // The day moved on the iPhone (to 12-10, set 11-28): both move, and the old day's banners go.
        let moved = deadline(day: ymd(2026, 12, 10), setAt: at(2026, 11, 28))
        sync([moved])
        await step(at(2026, 11, 28, 1))
        #expect(await iPhone.pendingMoment(moved.identifier) == moment(2026, 12, 7, 9, 0))
        #expect(await mac.pendingMoment(moved.identifier) == moment(2026, 12, 10, 18, 0))
        #expect(await mac.center.delivered().isEmpty)
        // The iPhone's reminder is delivered; done on the iPhone withdraws the Mac's pending one.
        await step(at(2026, 12, 8))
        sync([deadline(day: ymd(2026, 12, 10), setAt: at(2026, 11, 28), done: true)])
        await step(at(2026, 12, 8, 1))
        #expect(await mac.center.pending().isEmpty)
        #expect(await iPhone.center.delivered().isEmpty)
        // Both delivered, then done on the iPhone: the Mac's banner goes too.
        let both = deadline(documentB, day: ymd(2026, 12, 14), setAt: at(2026, 12, 1))
        sync([both])
        await step(at(2026, 12, 8, 2))
        await step(at(2026, 12, 14, 19))
        #expect(await mac.center.delivered().map(\.identifier) == [both.identifier])
        sync([deadline(documentB, day: ymd(2026, 12, 14), setAt: at(2026, 12, 1), done: true)])
        await step(at(2026, 12, 14, 20))
        #expect(await mac.center.delivered().isEmpty)
        #expect(await iPhone.center.delivered().isEmpty)

        // Set on the iPhone inside the window: the due day on both, never at entry.
        let entered = deadline(day: ymd(2026, 12, 20), setAt: at(2026, 12, 18, 12))
        sync([entered])
        await step(at(2026, 12, 18, 12, 0, 1))
        #expect(await iPhone.pendingMoment(entered.identifier) == moment(2026, 12, 20, 9, 0))
        #expect(await mac.pendingMoment(entered.identifier) == moment(2026, 12, 20, 18, 0))
        await step(at(2026, 12, 31))
        #expect(await iPhone.shown(entered.identifier) == 1)
        #expect(await mac.shown(entered.identifier) == 1)
        #expect(await iPhone.center.shownTotal == 4)
        #expect(await mac.center.shownTotal == 3)
        #expect(await iPhone.center.shown.values.allSatisfy { $0 == 1 })
        #expect(await mac.center.shown.values.allSatisfy { $0 == 1 })
    }

    // MARK: The cap

    /// 100 deadlines: never more than 60 pending; later ones fill in as earlier ones are delivered, and one left out
    /// whose moment passed meanwhile is caught up. Each is shown once.
    @Test func theCapFillsInAndCatchesUpWhatWasLeftOut() async {
        let many = (0..<100).map { index in
            deadline(
                UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                day: ymd(2026, 12, 1).adding(days: index)!, setAt: at(2026, 11, 1))
        }
        let device = ReminderDevice(many)
        await device.reconcile(at: at(2026, 11, 14, 10))
        #expect(await device.center.pending().count == 60)
        // The app does not run for 70 days: the 60 pending ones are delivered; the 40 left out have passed lead moments.
        await device.deliver(upTo: at(2027, 2, 6, 8))
        #expect(await device.center.shownTotal == 60)
        let report = await device.reconcile(at: at(2027, 2, 6, 10))
        let pending = await device.center.pending()
        #expect(pending.count <= 60)
        #expect(report.added == pending.count)
        // Left out, their lead moment passed, their day still ahead (02-06 … 02-09): caught up at 10:01.
        #expect(pending.filter { $0.moment == moment(2027, 2, 6, 10, 1) }.count == 4)
        var instant = at(2027, 2, 6, 10)
        while instant < at(2027, 3, 15) {
            instant = instant.addingTimeInterval(6 * 3600)
            await device.deliver(upTo: instant)
            await device.reconcile(at: instant)
            #expect(await device.center.pending().count <= 60)
        }
        let shown = await device.center.shown
        #expect(shown.values.allSatisfy { $0 == 1 })
        // The 60 first, the 4 caught up and the 29 with a lead moment ahead; the 7 left out whose day passed while the app
        // did not run (01-30 … 02-05) are not caught up (rule 5).
        #expect(shown.count == 60 + 4 + 29)
    }

    // MARK: Concurrency

    /// Reconciles requested while an `add` is held are served by one more run, with no duplicate add.
    @Test func reconcilesDuringAHeldAddAreCoalesced() async throws {
        let held = Checkpoint()
        defer { held.release() }
        let device = ReminderDevice(hooks: .init(beforeAdd: { _ in await held.pass() }))
        device.world.withLock { $0.now = at(2026, 11, 20, 10) }
        let reconciler = device.reconciler
        let first = Task { await reconciler.reconcile() }
        await held.reached()
        let more = (0..<3).map { _ in Task { await reconciler.reconcile() } }
        // Let the three requests reach the reconciler before the add goes on: they wait for its one more run.
        try await TestSupport.waitUntil(asynchronously: { await reconciler.queuedRequests == 3 })
        held.release()
        #expect(await first.value.added == 1)
        for task in more { #expect(await task.value.added == 0) }
        #expect(await reconciler.runs == 2)
        #expect(await device.center.adds[idA] == 1)
    }

    // MARK: 30 days

    /// Hourly steps for 30 days, each with a delivery and a reconcile. Along the way: a lead change and a time change,
    /// a westward zone change while pending with reconciles between the two moments and an eastward one back, done and
    /// undone, a relaunch, a re-sync, a cleared delivered list and one empty read. Every deadline is shown exactly once.
    @Test func atMostOnceOverThirtyDays() async {
        let deadlines = [
            deadline(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, day: ymd(2026, 11, 10)),
            deadline(UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, day: ymd(2026, 11, 15)),
            deadline(UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, day: ymd(2026, 11, 20)),
            deadline(UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, day: ymd(2026, 11, 25)),
            deadline(
                UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, day: ymd(2026, 11, 29),
                setAt: at(2026, 11, 27, 20)),
        ]
        let device = ReminderDevice([])
        let start = at(2026, 11, 1)
        for hour in 0...(30 * 24) {
            let instant = start.addingTimeInterval(Double(hour) * 3600)
            switch hour {
            case 1: device.set(deadlines: Array(deadlines.prefix(4)))
            case 2 * 24 + 12: device.set(settings: ReminderSettings(leadDays: 1, minuteOfDay: 18 * 60))
            case 4 * 24: device.set(settings: ReminderSettings())
            case 5 * 24 + 20: await device.move(to: Zones.newYork)
            case 7 * 24 + 18: await device.move(to: Zones.berlin)
            case 10 * 24:
                device.set(deadlines: [deadlines[0], doneCopy(deadlines[1]), deadlines[2], deadlines[3]])
            case 12 * 24 + 12: device.set(deadlines: Array(deadlines.prefix(4)))
            case 15 * 24: device.relaunch()
            case 17 * 24: device.set(deadlines: Array(deadlines.prefix(4)).reversed())
            case 20 * 24 + 12: await device.center.clearDelivered()
            case 22 * 24: device.world.withLock { $0.nextReadEmpty = true }
            case 26 * 24 + 21: device.set(deadlines: deadlines)
            default: break
            }
            await device.deliver(upTo: instant)
            await device.reconcile(at: instant)
        }
        let shown = await device.center.shown
        #expect(shown.count == 5)
        #expect(shown.values.allSatisfy { $0 == 1 }, "\(shown)")
    }

    private func doneCopy(_ reminder: ReminderDeadline) -> ReminderDeadline {
        var copy = reminder
        copy.deadline.doneAt = at(2026, 11, 11)
        return copy
    }
}
