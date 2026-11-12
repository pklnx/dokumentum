import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import DokumentumCore

/// The queue's writes against a save that lands while they hold the row (plan of #4, part 5, T6 and B1): after
/// the write fetched and changed its document, before it reads the row again (`ProcessingQueue.Hooks.beforeCheck`).
/// A context writes back the whole row when it saves over a newer one (#56), so the write reads the row again and
/// backs off. The edit stays, the queue saved nothing in that run, and the next run completes the document.
///
/// A save at the queue's own `willSave` is not used: it falls into the residual window between the re-read and the
/// commit, which a test can only document (docs/development/index.md, "The processing queue").
struct ProcessingConcurrentEditTests {
    enum Edit: String, CaseIterable, CustomTestStringConvertible {
        case title, correspondent, trash

        var testDescription: String { rawValue }

        func apply(to document: Document, in context: ModelContext) {
            switch self {
            case .title:
                document.title = "User title"
            case .correspondent:
                let correspondent = Correspondent(name: "Stadtwerke")
                context.insert(correspondent)
                document.correspondent = correspondent
            case .trash:
                document.deletedAt = processingStart
            }
            document.touch(processingStart)
        }

        func expectKept(_ row: ProcessingRow, sourceLocation: SourceLocation = #_sourceLocation) {
            switch self {
            case .title: #expect(row.title == "User title", sourceLocation: sourceLocation)
            case .correspondent: #expect(row.correspondent == "Stadtwerke", sourceLocation: sourceLocation)
            case .trash: #expect(row.isTrashed, sourceLocation: sourceLocation)
            }
        }
    }

    /// A document that needs the given write first: no claim for the claim write; this device's fresh claim for the
    /// result write, which is then the run's only write.
    private func insert(for write: ProcessingQueue.Write, in store: ProcessingStore) throws -> UUID {
        switch write {
        case .claim: try store.insert(title: "Original")
        case .result: try store.insert(title: "Original", device: deviceA, claimedAt: processingStart)
        case .classification:
            try store.insert(title: "Original", stateRaw: "classify", device: deviceA, claimedAt: processingStart)
        case .retry: try store.insert(title: "Original", stateRaw: "failed")
        }
    }

    /// A hook that runs `edit` once, at the first check of `write`.
    private func once(
        _ write: ProcessingQueue.Write, _ edit: @escaping @Sendable () throws -> Void
    ) -> ProcessingQueue.Hooks {
        let done = Mutex(false)
        return ProcessingQueue.Hooks(beforeCheck: { kind in
            guard kind == write else { return }
            let first = done.withLock { done in
                defer { done = true }
                return !done
            }
            if first { try edit() }
        })
    }

    @Test(arguments: [ProcessingQueue.Write.claim, .result], Edit.allCases)
    func anEditSavedInTheWindowStaysAndTheNextRunCompletes(write: ProcessingQueue.Write, edit: Edit) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insert(for: write, in: store)
        let before = try store.row(id)
        let hooks = once(write) { try store.edit(id) { document, context in edit.apply(to: document, in: context) } }
        let queue = store.queue(deviceA, clock: clock, hooks: hooks)

        let first = await queue.run()

        #expect(first.backedOff == 1)
        #expect(first.saves == 0, "the queue saved nothing in that run")
        let afterEdit = try store.row(id)
        edit.expectKept(afterEdit)
        #expect(afterEdit.stateRaw == before.stateRaw)
        #expect(afterEdit.deviceID == before.deviceID)
        #expect(afterEdit.claimedAt == before.claimedAt)

        let next = await queue.run()
        let row = try store.row(id)
        edit.expectKept(row)
        if edit == .trash {
            #expect(next.skipped == 1, "a trashed document waits for its restore")
            #expect(row.stateRaw == before.stateRaw)
        } else {
            #expect(next.done == 1)
            #expect(row.stateRaw == "done")
            #expect(row.pageCount == 2)
        }
    }

    /// A save to another document in the window leaves the queue's write in place.
    @Test(arguments: [ProcessingQueue.Write.claim, .result])
    func aSaveToAnotherRowLeavesTheWriteInPlace(write: ProcessingQueue.Write) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insert(for: write, in: store)
        let other = try store.insert(title: "Other", stateRaw: "done")
        let hooks = once(write) { try store.edit(other) { document, _ in document.title = "Other, edited" } }

        let report = await store.queue(deviceA, clock: clock, hooks: hooks).run()

        #expect(report.backedOff == 0)
        #expect(report.done == 1)
        #expect(try store.row(id).stateRaw == "done")
        #expect(try store.row(other).title == "Other, edited")
    }

    /// What the re-check (step 2) catches on its own: a change saved before the write's fetch, so the write
    /// context already reads it and the `RowState` re-read finds nothing new (review A of #96, B1; review B, N1).
    enum EarlyChange: String, CaseIterable, CustomTestStringConvertible {
        case trash, textUnlinked

        var testDescription: String { rawValue }

        func apply(to document: Document) {
            switch self {
            case .trash: document.deletedAt = processingStart
            case .textUnlinked: document.text = nil
            }
        }
    }

    /// For the claim write the change is saved after the scan (`Hooks.afterScan`), before the claim write's fetch;
    /// for the result write it is saved while the stage runs, before the result write's fetch. Either way the queue
    /// writes nothing: a document trashed or without its text record is never claimed or written `done`.
    @Test(arguments: [ProcessingQueue.Write.claim, .result], EarlyChange.allCases)
    func aChangeBeforeTheWritesFetchIsCaughtByTheReCheck(write: ProcessingQueue.Write, change: EarlyChange)
        async throws
    {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try insert(for: write, in: store)
        let before = try store.row(id)
        let edit: @Sendable () throws -> Void = { try store.edit(id) { document, _ in change.apply(to: document) } }
        let stage = TestStage { _ in if write == .result { try edit() } }
        let hooks = ProcessingQueue.Hooks(afterScan: { if write == .claim { try? edit() } })
        let queue = store.queue(deviceA, stage: stage, clock: clock, hooks: hooks)

        let report = await queue.run()

        #expect(report.saves == 0, "the queue wrote over the change")
        #expect(report.dropped == 1)
        #expect(report.backedOff == 0, "the re-check, not the re-read, caught it")
        #expect(stage.count == (write == .claim ? 0 : 1))
        let row = try store.row(id)
        #expect(row.stateRaw == before.stateRaw)
        #expect(row.deviceID == before.deviceID)
        #expect(row.claimedAt == before.claimedAt)
        #expect(row.pageCount == before.pageCount)
        #expect(row.isTrashed == (change == .trash))
    }

    // MARK: Two background writers

    /// A live correspondent (10) and a tombstone merged into it (11), and a document pointing at the tombstone:
    /// #56's repair re-points the document to 10 (pass 1).
    private func seedRepoint(_ store: ProcessingStore, write: ProcessingQueue.Write) throws -> UUID {
        let id = try insert(for: write, in: store)
        try store.edit(id) { document, context in
            let keeper = Correspondent(name: "Telekom", createdAt: at(10))
            (keeper.instanceID, keeper.id) = (uuid(10), uuid(1010))
            let tombstone = Correspondent(name: "Telekom", createdAt: at(11))
            (tombstone.instanceID, tombstone.id, tombstone.mergedIntoID, tombstone.mergedAt) =
                (uuid(11), uuid(1011), uuid(1010), at(20))
            context.insert(keeper)
            context.insert(tombstone)
            document.correspondent = tombstone
        }
        return id
    }

    /// #56's repair saves the same document inside the queue's window: the queue backs off, the repair's write
    /// stays, and the next queue run completes.
    @Test(arguments: [ProcessingQueue.Write.claim, .result])
    func theRepairInTheQueuesWindowStays(write: ProcessingQueue.Write) async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try seedRepoint(store, write: write)
        let repairs = Mutex<[RepairReport]>([])
        let hooks = once(write) {
            let report = try RepairRun.perform(in: store.container, now: repairTime, hasCompletedImport: true)
            repairs.withLock { $0.append(report) }
        }
        let queue = store.queue(deviceA, clock: clock, hooks: hooks)

        let first = await queue.run()

        let repair = try #require(repairs.withLock { $0.first })
        #expect(repair.saves == 1, "the repair re-pointed the document")
        #expect(first.backedOff == 1)
        #expect(first.saves == 0)
        #expect(try store.row(id).correspondent == "Telekom")
        #expect(try correspondent(of: id, in: store) == uuid(10))

        let next = await queue.run()
        #expect(next.done == 1)
        #expect(try store.row(id).stateRaw == "done")
        #expect(try correspondent(of: id, in: store) == uuid(10), "the repair's write stayed")
    }

    /// The reverse order: the queue's result write lands inside the repair pass's window. The repair backs off
    /// (`metAnotherSave`), the queue's write stays, and the next repair run re-points: both changes end in the store.
    @Test func theQueueInTheRepairsWindowStays() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seedRepoint(store, write: .result)
        let file = try #require(try store.fileIdentifier(of: id))
        let held = ProcessingQueue.Held(stateRaw: "pending", deviceID: deviceA, claimedAt: processingStart, file: file)
        let outcomes = Mutex<[ProcessingQueue.WriteOutcome]>([])

        let repair = try RepairRun.perform(
            in: store.container, now: repairTime, hasCompletedImport: true,
            beforeCheck: { _ in
                guard outcomes.withLock({ $0.isEmpty }) else { return }
                let outcome = ProcessingQueue.write(
                    .result, id, expecting: held, in: store.container, beforeCheck: nil,
                    change: { $0.processingState = .done })
                outcomes.withLock { $0.append(outcome) }
            })

        #expect(outcomes.withLock { $0 } == [.saved])
        #expect(repair.passes.contains { $0.metAnotherSave })
        #expect(repair.saves == 0)
        #expect(try store.row(id).stateRaw == "done")
        #expect(try correspondent(of: id, in: store) == uuid(11), "the repair wrote nothing yet")

        let next = try RepairRun.perform(in: store.container, now: repairTime, hasCompletedImport: true)
        #expect(next.saves == 1)
        #expect(try correspondent(of: id, in: store) == uuid(10))
        #expect(try store.row(id).stateRaw == "done", "the queue's write stayed")
    }

    private func correspondent(of id: UUID, in store: ProcessingStore) throws -> UUID? {
        try ProcessingStore.fetch(id, in: ModelContext(store.container))?.correspondent?.instanceID
    }
}
