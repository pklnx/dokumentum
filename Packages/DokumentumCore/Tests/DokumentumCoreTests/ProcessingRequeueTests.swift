import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// The one-time re-queue of step 3's documents (#6, part 2, plan point 6, T6, N7, N3): `done` with `.none` goes
/// back to `pending` with this device's claim, once per device; the thumbnail backfill is recorded; an edit in the
/// window backs off.
struct ProcessingRequeueTests {
    private func requeue(_ store: ProcessingStore, _ device: String = deviceA) -> ProcessingRequeue {
        ProcessingRequeue(defaultsSuite: store.failures(device).defaultsSuite)
    }

    @Test func aDoneDocumentWithoutTextGoesBackToPendingWithThisDevicesClaimOnce() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let old = try store.insert(
            stateRaw: "done", device: deviceB, claimedAt: processingStart.addingTimeInterval(-hour))
        let pass = requeue(store)
        #expect(!pass.isDone)

        let first = pass.run(in: store.container, deviceID: deviceA, now: clock.now)

        #expect(first.requeued == 1)
        #expect(first.completed)
        #expect(pass.isDone)
        let row = try store.row(old)
        #expect(row.stateRaw == "pending")
        #expect(row.deviceID == deviceA, "this device's claim (N7)")
        #expect(row.claimedAt == clock.now)

        // Processed meanwhile without text again (a stage that gives none), the flag stops a second pass.
        try store.edit(old) { document, _ in document.processingState = .done }
        clock.advance(by: 60)
        let second = pass.run(in: store.container, deviceID: deviceA, now: clock.now)
        #expect(second == ProcessingRequeue.Report())
        #expect(try store.row(old).stateRaw == "done")
    }

    @Test func documentsWithTextOrNotDoneAreLeftAloneAndTrashedOnesAreIncluded() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let pdfText = try store.insert(stateRaw: "done", textSource: .pdfText)
        let vision = try store.insert(stateRaw: "done", textSource: .vision)
        let pending = try store.insert(stateRaw: "pending", device: deviceB, claimedAt: processingStart)
        let failed = try store.insert(stateRaw: "failed")
        let unknownSource = try store.insert(stateRaw: "done")
        try store.edit(unknownSource) { document, _ in document.textSourceRaw = "newerSource" }
        let trashed = try store.insert(stateRaw: "done", trashed: true)
        let before = try [pdfText, vision, pending, failed, unknownSource].map { try store.row($0) }

        let report = requeue(store).run(in: store.container, deviceID: deviceA, now: clock.now)

        #expect(report.requeued == 1)
        #expect(try [pdfText, vision, pending, failed, unknownSource].map { try store.row($0) } == before)
        #expect(try store.row(trashed).stateRaw == "pending", "a trashed document waits for its restore")
        #expect(try store.row(trashed).isTrashed)
    }

    /// N3: only the re-queued documents without a thumbnail are recorded for part 4's backfill.
    @Test func reQueuedDocumentsWithoutAThumbnailAreRecordedForTheBackfill() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let without = try store.insert(stateRaw: "done")
        let with = try store.insert(stateRaw: "done", thumbnail: true)
        let withText = try store.insert(stateRaw: "done", textSource: .pdfText)
        let pass = requeue(store)

        #expect(pass.run(in: store.container, deviceID: deviceA, now: processingStart).requeued == 2)

        #expect(pass.thumbnailBackfill == [without])
        #expect(!pass.thumbnailBackfill.contains(with))
        #expect(!pass.thumbnailBackfill.contains(withText))
    }

    /// An edit saved in the window backs off: the edit stays, nothing is written, the flag stays unset, and the next
    /// pass re-queues the document.
    @Test func anEditInTheWindowBacksOffAndTheNextPassReQueues() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insert(title: "Original", stateRaw: "done")
        let pass = requeue(store)
        let edited = Mutex(false)

        let first = pass.run(in: store.container, deviceID: deviceA, now: processingStart) {
            guard !edited.withLock({ $0 }) else { return }
            edited.withLock { $0 = true }
            try store.edit(id) { document, _ in document.title = "User title" }
        }

        #expect(first.backedOff == 1)
        #expect(!first.completed)
        #expect(!pass.isDone)
        #expect(try store.row(id).title == "User title")
        #expect(try store.row(id).stateRaw == "done")

        let second = pass.run(in: store.container, deviceID: deviceA, now: processingStart)
        #expect(second.requeued == 1)
        #expect(second.completed)
        #expect(try store.row(id).title == "User title")
        #expect(try store.row(id).stateRaw == "pending")
    }

    /// Both devices run the pass: the second device finds the document `pending` (re-queued by the first) and
    /// leaves the first device's claim in place, and the first device's queue processes it at once.
    @Test func theOtherDevicesPassSkipsAReQueuedDocumentAndTheQueueProcessesIt() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insert(stateRaw: "done")
        let failures = store.failures(deviceA)
        let queue = ProcessingQueue(
            container: store.container, deviceID: deviceA, failures: failures,
            stage: DocumentStage(recognizer: StubRecognizer()),
            requeue: ProcessingRequeue(defaultsSuite: failures.defaultsSuite), watchdogSleep: ManualDebounce().sleep,
            now: clock.function)

        let report = await queue.run()

        #expect(report.requeued == 1)
        #expect(report.done == 1)
        #expect(report.saves == 2, "the re-queue write and the result write; no claim write")
        #expect(try store.text(of: id).source == .vision)
        #expect(try store.row(id).deviceID == deviceA)

        // Device B's pass, before it synced the result: the document is `done` with `.vision` now.
        let other = requeue(store, deviceB).run(in: store.container, deviceID: deviceB, now: clock.now)
        #expect(other.requeued == 0)
        #expect(try store.row(id).deviceID == deviceA)
    }

    @Test func theOtherDevicesPassLeavesAPendingDocumentAlone() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try store.insert(stateRaw: "done")
        #expect(requeue(store).run(in: store.container, deviceID: deviceA, now: processingStart).requeued == 1)
        let claimed = try store.row(id)

        let other = requeue(store, deviceB).run(
            in: store.container, deviceID: deviceB, now: processingStart.addingTimeInterval(60))

        #expect(other.requeued == 0)
        #expect(other.completed)
        #expect(try store.row(id) == claimed)
    }
}
