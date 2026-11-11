import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

/// The processing queue on a store on disk (plan of #4, part 5): claims, takeovers, two devices, failures,
/// resume, waiting, the trash, unknown states and dropped results. Each test has its own clock and per-device
/// failure counters.
struct ProcessingQueueTests {
    @Test func anImportedDocumentGoesFromPendingToDoneWithItsPageCount() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let importer = DocumentImporter(container: store.container, deviceID: deviceA, now: clock.function)
        let outcome = await importer.importFile(
            data: TestPDF.make(pages: ["1", "2", "3"]), fileName: "Three.pdf", contentType: nil, source: .file)
        guard case .imported(let imported) = outcome else {
            Issue.record("not imported: \(outcome)")
            return
        }
        // A document whose stored page count is wrong gets the stage's.
        let other = try store.insert(device: deviceA, claimedAt: clock.now, pages: 4, pageCount: 1)
        clock.advance(by: 60)

        let report = await store.queue(deviceA, clock: clock).run()

        #expect(report.done == 2)
        #expect(report.saves == 2, "own fresh claims: no claim write, one result write each")
        let row = try store.row(imported)
        #expect(row.stateRaw == "done")
        #expect(row.pageCount == 3)
        #expect(row.deviceID == deviceA)
        #expect(row.claimedAt == processingStart, "the import's claim is kept")
        #expect(try store.row(other).pageCount == 4)
        #expect(try store.row(other).stateRaw == "done")
    }

    @Test func anotherDevicesFreshClaimWaitsAndIsTakenOverAtSixHours() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceB, claimedAt: processingStart.addingTimeInterval(-hour))
        let queue = store.queue(deviceA, clock: clock)

        let waiting = await queue.run()
        #expect(waiting.waiting == 1)
        #expect(waiting.saves == 0)
        #expect(waiting.nextExpiry == processingStart.addingTimeInterval(5 * hour), "B's claim plus 6 h")
        #expect(try store.row(id).deviceID == deviceB)
        #expect(try store.row(id).stateRaw == "pending")

        clock.advance(by: 5 * hour - 1)
        #expect(await queue.run().waiting == 1, "one second before 6 h it still waits")
        clock.advance(by: 1)
        let takeover = await queue.run()
        #expect(takeover.done == 1)
        #expect(takeover.saves == 2, "the claim write, then the result write")
        let row = try store.row(id)
        #expect(row.stateRaw == "done")
        #expect(row.deviceID == deviceA)
        #expect(row.claimedAt == clock.now)
    }

    /// T8 (#97 point 1): a claim written by a clock 7 h ahead is not taken over at once; it waits until this device
    /// has seen it for 6 h by its own clock, also across a relaunch (the sighting is in the per-device defaults), and
    /// the sighting goes once the document is `done`.
    @Test func aClaimFromAFastClockIsTakenOverOnceThisDeviceSawItForSixHours() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceB, claimedAt: processingStart.addingTimeInterval(7 * hour))
        let failures = store.failures(deviceA)
        let sightings = ClaimSightings(defaultsSuite: failures.defaultsSuite)

        let first = await store.queue(deviceA, failures: failures, clock: clock).run()
        #expect(first.waiting == 1)
        #expect(first.saves == 0)
        #expect(first.nextExpiry == processingStart.addingTimeInterval(6 * hour), "first seen now, plus 6 h")
        #expect(sightings.sighting(of: id)?.seenAt == processingStart)

        clock.advance(by: 6 * hour - 1)
        // A relaunch: a new queue on the same defaults.
        #expect(await store.queue(deviceA, failures: failures, clock: clock).run().waiting == 1)
        clock.advance(by: 1)
        let takeover = await store.queue(deviceA, failures: failures, clock: clock).run()
        #expect(takeover.done == 1)
        #expect(try store.row(id).deviceID == deviceA)
        _ = await store.queue(deviceA, failures: failures, clock: clock).run()
        #expect(sightings.documents.isEmpty, "the sighting stayed after done")
    }

    /// A new claim on the document starts a new sighting.
    @Test func aNewClaimStartsANewSighting() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceB, claimedAt: processingStart.addingTimeInterval(7 * hour))
        let queue = store.queue(deviceA, clock: clock)
        #expect(await queue.run().waiting == 1)
        clock.advance(by: 5 * hour)
        let renewed = processingStart.addingTimeInterval(12 * hour)
        try store.edit(id) { document, _ in document.processingClaimedAt = renewed }
        let report = await queue.run()
        #expect(report.waiting == 1)
        #expect(report.nextExpiry == clock.now.addingTimeInterval(6 * hour))
    }

    /// Two devices on one store, run at the same time: every document ends `done`, and a fresh claim of one device
    /// is never processed by the other.
    @Test func twoQueuesWithDifferentDevicesOnOneStoreEndEveryDocumentDone() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        var ids: [UUID] = []
        var claimedByA: [UUID] = []
        var claimedByB: [UUID] = []
        for index in 0..<4 {
            let created = processingStart.addingTimeInterval(TimeInterval(-index * 60))
            claimedByA.append(
                try store.insert(title: "A\(index)", created: created, device: deviceA, claimedAt: created))
            claimedByB.append(
                try store.insert(title: "B\(index)", created: created, device: deviceB, claimedAt: created))
            ids.append(try store.insert(title: "Free\(index)", created: created))
            ids.append(
                try store.insert(
                    title: "Expired\(index)", created: created, stateRaw: "processing", device: "DEVICE-GONE",
                    claimedAt: created.addingTimeInterval(-7 * hour)))
        }
        ids += claimedByA + claimedByB
        let queueA = store.queue(deviceA, clock: clock)
        let queueB = store.queue(deviceB, clock: clock)

        async let reportA = queueA.run()
        async let reportB = queueB.run()
        let (a, b) = await (reportA, reportB)

        for id in ids {
            let row = try store.row(id)
            #expect(row.stateRaw == "done", "\(row.title)")
        }
        for id in claimedByA { #expect(try store.row(id).deviceID == deviceA, "B processed A's fresh claim") }
        for id in claimedByB { #expect(try store.row(id).deviceID == deviceB, "A processed B's fresh claim") }
        // A document both decided on is written `done` once or, in the residual window, twice; never less.
        #expect(a.done + b.done >= ids.count)
    }

    /// The claim write re-checks what its decision was based on. A scans while the document is free and decides to
    /// claim it; B claims it before A writes. A's claim write must find B's claim and write nothing, and only B
    /// processes the document.
    @Test func aClaimMadeAfterTheScanIsNotOverwritten() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert()
        let scanned = Checkpoint()
        let bProcessing = Checkpoint()
        defer {
            scanned.release()
            bProcessing.release()
        }
        let stageA = TestStage()
        let queueA = store.queue(
            deviceA, stage: stageA, clock: clock, hooks: .init(afterScan: { await scanned.pass() }))
        let queueB = store.queue(deviceB, stage: TestStage { _ in await bProcessing.pass() }, clock: clock)

        let runA = Task { await queueA.run() }
        await scanned.reached()  // A saw the document free
        let runB = Task { await queueB.run() }
        await bProcessing.reached()  // B claimed it and works on it
        #expect(try store.row(id).deviceID == deviceB)
        scanned.release()
        let reportA = await runA.value
        bProcessing.release()
        let reportB = await runB.value

        #expect(stageA.count == 0, "A processed a document B had claimed")
        #expect(reportA.saves == 0)
        #expect(reportA.dropped == 1)
        #expect(reportB.done == 1)
        let row = try store.row(id)
        #expect(row.stateRaw == "done")
        #expect(row.deviceID == deviceB)
    }

    /// Three failures on one device give `failed`; the counter is per device, so another device still processes it,
    /// and the counter keys go once the document is `done`.
    @Test func threeFailuresGiveFailedAndAnotherDeviceStillProcessesIt() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let failuresA = store.failures(deviceA)
        let queueA = store.queue(deviceA, failures: failuresA, stage: TestStage(failing: 100), clock: clock)

        for attempt in 1...2 {
            // Past the backoff of the attempt before (1 min, then 10 min).
            clock.advance(by: 10 * 60)
            let report = await queueA.run()
            #expect(report.failures == 1)
            #expect(report.saves == 0, "a failure below the limit writes nothing")
            #expect(failuresA.count(for: id) == attempt)
            #expect(try store.row(id).stateRaw == "pending")
        }
        clock.advance(by: 10 * 60)
        let third = await queueA.run()
        #expect(third.failed == 1)
        #expect(third.saves == 1)
        #expect(try store.row(id).stateRaw == "failed")
        #expect(failuresA.count(for: id) == 3)
        let fourth = await queueA.run()
        #expect(fourth.skipped == 1, "A does not try it a fourth time")
        #expect(fourth.saves == 0)

        // B fails once, then succeeds: its own counter goes at `done`.
        let failuresB = store.failures(deviceB)
        let queueB = store.queue(deviceB, failures: failuresB, stage: TestStage(failing: 1), clock: clock)
        let firstB = await queueB.run()
        #expect(firstB.failures == 1)
        #expect(firstB.saves == 1, "B claimed the failed document")
        #expect(try store.row(id).stateRaw == "processing")
        #expect(failuresB.count(for: id) == 1)
        clock.advance(by: 60)
        let secondB = await queueB.run()
        #expect(secondB.done == 1)
        #expect(try store.row(id).stateRaw == "done")
        #expect(try store.row(id).deviceID == deviceB)
        #expect(failuresB.documents.isEmpty, "B's key went with its own write of done")
        #expect(failuresA.documents == [id])
        _ = await queueA.run()
        #expect(failuresA.documents.isEmpty, "A's key went when A saw the document done")
    }

    /// The attempt is counted before the stage, so an attempt that never returns (a crash or a memory kill in the
    /// stage) counts too (review B of #96, N3). Three runs whose stage never returns, each by a new queue as after a
    /// relaunch, leave the counter at 3; the fourth writes `failed` without running the stage again.
    @Test func attemptsThatNeverReturnedAreCountedAndTheFourthGivesUp() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let failures = store.failures(deviceA)
        let stuck = (0..<3).map { _ in Checkpoint() }
        var abandoned: [Task<ProcessingReport, Never>] = []
        defer { for checkpoint in stuck { checkpoint.release() } }

        for (attempt, checkpoint) in stuck.enumerated() {
            // Past the backoff of the attempt before: each launch is later.
            clock.advance(by: 10 * 60)
            let queue = store.queue(
                deviceA, failures: failures, stage: TestStage { _ in await checkpoint.pass() }, clock: clock)
            abandoned.append(Task { await queue.run() })
            await checkpoint.reached()  // the stage runs and never returns, as in a crash
            #expect(failures.count(for: id) == attempt + 1, "the attempt was not counted before the stage")
        }
        let stage = TestStage()
        let report = await store.queue(deviceA, failures: failures, stage: stage, clock: clock).run()

        #expect(stage.count == 0, "the fourth attempt ran the stage again")
        #expect(report.failed == 1)
        #expect(report.saves == 1)
        #expect(try store.row(id).stateRaw == "failed")
        // The abandoned runs, let go: their results are dropped, as the row is no longer what they ran under.
        for checkpoint in stuck { checkpoint.release() }
        for task in abandoned { #expect(await task.value.dropped == 1) }
        #expect(try store.row(id).stateRaw == "failed")
    }

    /// A stage that returns clears the attempt it counted.
    @Test func aStageThatReturnsClearsItsAttempt() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart)
        let failures = store.failures(deviceA)
        let counted = Mutex<[Int]>([])
        let stage = TestStage { _ in counted.withLock { $0.append(failures.count(for: id)) } }

        let report = await store.queue(deviceA, failures: failures, stage: stage, clock: clock).run()

        #expect(counted.withLock { $0 } == [1], "counted before the stage")
        #expect(report.done == 1)
        #expect(failures.documents.isEmpty)
    }

    /// Two rows sharing an `instanceID` (a copied record): the scan decides on the oldest, and every fetch of the
    /// queue and the check before its save pick that same row, so it is processed (review A of #96, N2). The newer
    /// row is inserted first, so a fetch without a sort finds it first.
    @Test func aCopySharingTheInstanceIDDoesNotMixIntoTheWrites() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let newer = try store.insert(
            title: "Newer copy", created: processingStart.addingTimeInterval(60), device: deviceA,
            claimedAt: processingStart, pages: 3)
        let older = try store.insert(
            title: "Older", created: processingStart, device: deviceA, claimedAt: processingStart)
        try store.edit(newer) { document, _ in document.instanceID = older }

        let report = await store.queue(deviceA, clock: clock).run()

        #expect(report.done == 1, "\(report)")
        #expect(report.dropped == 0 && report.backedOff == 0)
        let rows = try ModelContext(store.container).fetch(
            FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == older }))
        #expect(rows.first { $0.title == "Older" }?.processingStateRaw == "done")
        #expect(rows.first { $0.title == "Older" }?.pageCount == 2)
        #expect(rows.first { $0.title == "Newer copy" }?.processingStateRaw == "pending")
    }

    /// A document left in `.processing` with this device's claim (the app quit during the work) is processed by the
    /// next queue, as the launch run does.
    @Test func aNewQueueResumesItsDevicesDocument() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(stateRaw: "processing", device: deviceA, claimedAt: processingStart)
        clock.advance(by: hour)

        let report = await store.queue(deviceA, clock: clock).run()

        #expect(report.done == 1)
        #expect(report.saves == 1, "its own fresh claim needs no claim write")
        #expect(try store.row(id).stateRaw == "done")
    }

    @Test func withoutTextRecordOrFileDataItWaitsAndWritesNothing() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let noText = try store.insert(title: "no text", text: false)
        let noFile = try store.insert(title: "no file", file: false)
        let noData = try store.insert(title: "no data", fileData: false)
        let before = try [noText, noFile, noData].map(store.row)
        let stage = TestStage()

        let report = await store.queue(deviceA, stage: stage, clock: clock).run()

        #expect(report.waiting == 3)
        #expect(report.saves == 0)
        #expect(stage.count == 0)
        #expect(try [noText, noFile, noData].map(store.row) == before, "not even a claim was written")
    }

    @Test func aTrashedDocumentIsProcessedOnlyAfterItsRestore() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(trashed: true)
        let queue = store.queue(deviceA, clock: clock)

        let trashed = await queue.run()
        #expect(trashed.skipped == 1)
        #expect(trashed.saves == 0)
        #expect(try store.row(id).stateRaw == "pending")

        try store.edit(id) { document, _ in document.deletedAt = nil }
        let restored = await queue.run()
        #expect(restored.done == 1)
        #expect(try store.row(id).stateRaw == "done")
    }

    /// A state from a newer build is never written, also in fields the queue would otherwise set (#29's
    /// `FrozenEnumModelTests`).
    @Test func anUnknownStateIsNeverWritten() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let mine = try store.insert(stateRaw: "queued", device: deviceA, claimedAt: processingStart)
        let unclaimed = try store.insert(stateRaw: "analyzing")
        let stage = TestStage()

        let report = await store.queue(deviceA, stage: stage, clock: clock).run()

        #expect(report.skipped == 2)
        #expect(report.saves == 0)
        #expect(stage.count == 0)
        #expect(try store.row(mine).stateRaw == "queued")
        #expect(try store.row(unclaimed).stateRaw == "analyzing")
        #expect(try store.row(unclaimed).deviceID == "")
    }

    /// The file was replaced during the work (another `DocumentFile` linked): the result is dropped, and the next
    /// run processes the new file.
    @Test func aResultWhoseFileWasReplacedIsDropped() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(device: deviceA, claimedAt: processingStart, pages: 2)
        let oldFile = try store.row(id).fileInstanceID
        let stage = TestStage { call in
            guard call == 1 else { return }
            try store.edit(id) { document, context in
                let pdf = TestPDF.make(pages: ["1", "2", "3", "4", "5"])
                let file = DocumentFile(documentID: document.id, pdfData: pdf)
                context.insert(file)
                document.file = file
            }
        }
        let queue = store.queue(deviceA, stage: stage, clock: clock)

        let first = await queue.run()
        #expect(first.dropped == 1)
        #expect(first.saves == 0)
        let afterFirst = try store.row(id)
        #expect(afterFirst.stateRaw == "pending")
        #expect(afterFirst.fileInstanceID != oldFile)
        #expect(afterFirst.pageCount == 0, "the old file's page count was not written")

        let second = await queue.run()
        #expect(second.done == 1)
        #expect(try store.row(id).pageCount == 5)
    }

    /// Another device took the document over during the work: this device's result is dropped and the other
    /// device's claim stays. With a newer claim time, and with the same time (clocks apart by exactly the gap), so
    /// the device alone decides too.
    @Test(arguments: [7 * hour, 0])
    func aResultAfterATakeoverIsDropped(laterBy offset: TimeInterval) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        // In `processing` already, so that with the same time only the device differs.
        let id = try store.insert(stateRaw: "processing", device: deviceA, claimedAt: processingStart)
        let takenOver = processingStart.addingTimeInterval(offset)
        let stage = TestStage { _ in
            try store.edit(id) { document, _ in
                (document.processingDeviceID, document.processingClaimedAt, document.processingStateRaw) =
                    (deviceB, takenOver, "processing")
            }
        }

        let report = await store.queue(deviceA, stage: stage, clock: clock).run()

        #expect(report.dropped == 1)
        #expect(report.saves == 0)
        let row = try store.row(id)
        #expect(row.stateRaw == "processing")
        #expect(row.deviceID == deviceB)
        #expect(row.claimedAt == takenOver)
    }

    @Test func theFailureCounterIsPerDefaultsSuite() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let a = store.failures(deviceA)
        let b = store.failures(deviceB)
        let id = UUID()
        #expect(a.increment(for: id) == 1)
        #expect(a.increment(for: id) == 2)
        #expect(b.count(for: id) == 0)
        a.remove(id)
        #expect(a.count(for: id) == 0)
        #expect(a.documents.isEmpty)
    }
}
