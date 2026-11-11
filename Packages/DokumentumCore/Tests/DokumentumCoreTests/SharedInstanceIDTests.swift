import DokumentumCoreTestSupport
import DokumentumKit
import Foundation
import SwiftData
import Testing

@testable import DokumentumCore

/// Two `Document` rows sharing an `instanceID` (a copied record): every reader keeps the same copy
/// (`RowRecords.oldestFirst`), so the repair plans, applies and checks on one row, and the processing queue picks
/// that row too (review A of #96, N2; review B, B-D1, from its probe). The newer copy is inserted first in every
/// case, so the store returns it first.
struct SharedInstanceIDTests {
    /// The copy each reader keeps, by title.
    private func kept(_ id: UUID, in store: ProcessingStore) throws -> (plan: String?, check: String?, queue: String?) {
        let plan = try RepairStore.read(in: ModelContext(store.container)).records.documents[id]?.title
        let check = try RowRecords.read([RowKey(entity: .document, instanceID: id)], in: ModelContext(store.container))
            .documents[id]?.title
        let queue = try ProcessingQueue.fetch(id, in: ModelContext(store.container))?.title
        return (plan, check, queue)
    }

    /// Two copies, the newer inserted first; `point` gives each its correspondent: a live "Stadtwerke" and a
    /// tombstone "Stadtwerke alt" merged into it.
    private func seed(
        _ store: ProcessingStore, newerCreated: Date, point: (_ newer: Bool) -> Bool
    ) throws -> UUID {
        _ = try store.insert(title: "Newer copy", created: newerCreated)
        let older = try store.insert(title: "Older", created: processingStart)
        let context = ModelContext(store.container)
        let winner = Correspondent(name: "Stadtwerke")
        let loser = Correspondent(name: "Stadtwerke alt")
        context.insert(winner)
        context.insert(loser)
        (loser.mergedIntoID, loser.mergedAt) = (winner.id, processingStart)
        for document in try context.fetch(FetchDescriptor<Document>()) {
            let isNewer = document.title == "Newer copy"
            if isNewer { document.instanceID = older }
            if point(isNewer) { document.correspondent = loser }
        }
        try context.save()
        return older
    }

    private func correspondent(of title: String, _ id: UUID, in store: ProcessingStore) throws -> String? {
        try ModelContext(store.container).fetch(
            FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == id })
        )
        .first { $0.title == title }?.correspondent?.name
    }

    /// The kept copy (the older one) points to the tombstone: the repair plans the repoint on it and applies it to
    /// it. With the plan on another copy than the apply, the repoint is never planned or always skipped.
    @Test func theRepairRepointsTheCopyItPlannedOn() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store, newerCreated: processingStart.addingTimeInterval(60)) { isNewer in !isNewer }

        let before = try kept(id, in: store)
        #expect(before.plan == "Older" && before.check == "Older" && before.queue == "Older", "\(before)")
        let report = try RepairRun.perform(
            in: store.container, now: processingStart.addingTimeInterval(hour), hasCompletedImport: true)

        #expect(report.skipped.isEmpty, "\(report.passes)")
        #expect(report.plan.operations.count == 1, "\(report.plan)")
        #expect(try correspondent(of: "Older", id, in: store) == "Stadtwerke")
        #expect(try correspondent(of: "Newer copy", id, in: store) == nil)
    }

    /// Review B's probe: only the copy that is not kept points to the tombstone. The repair plans nothing for it
    /// (#56: only the first copy of an `instanceID` takes part) and, above all, skips nothing on every run.
    @Test func aReferenceOnTheCopyThatIsNotKeptIsNeitherPlannedNorSkipped() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store, newerCreated: processingStart.addingTimeInterval(60)) { isNewer in isNewer }

        let before = try kept(id, in: store)
        #expect(before.plan == before.check, "the plan reads \(before.plan ?? "-"), the check \(before.check ?? "-")")
        let report = try RepairRun.perform(
            in: store.container, now: processingStart.addingTimeInterval(hour), hasCompletedImport: true)

        #expect(report.skipped.isEmpty, "\(report.passes)")
        #expect(report.saves == 0)
    }

    /// Equal `createdAt` (a literal copy): every reader keeps the first row the store returns.
    @Test func equalDatesKeepTheStoresFirstRowEverywhere() throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let id = try seed(store, newerCreated: processingStart) { isNewer in !isNewer }

        let kept = try kept(id, in: store)
        #expect(kept.plan == "Newer copy" && kept.check == "Newer copy" && kept.queue == "Newer copy", "\(kept)")
        let report = try RepairRun.perform(
            in: store.container, now: processingStart.addingTimeInterval(hour), hasCompletedImport: true)
        #expect(report.skipped.isEmpty, "\(report.passes)")
    }

    /// The queue decides on the copy it writes: the newer copy (returned first) holds another device's fresh claim,
    /// the kept older copy this device's own. The scan must decide on the older one, which is then processed.
    @Test func theQueueDecidesOnTheCopyItWrites() async throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let newer = try store.insert(
            title: "Newer copy", created: processingStart.addingTimeInterval(60), stateRaw: "processing",
            device: deviceB, claimedAt: processingStart)
        let older = try store.insert(
            title: "Older", created: processingStart, device: deviceA, claimedAt: processingStart)
        try store.edit(newer) { document, _ in document.instanceID = older }

        let report = await store.queue(deviceA, clock: clock).run()

        #expect(report.done == 1, "\(report)")
        #expect(report.waiting == 0, "the scan decided on the newer copy")
        let rows = try ModelContext(store.container).fetch(
            FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == older }))
        #expect(rows.first { $0.title == "Older" }?.processingStateRaw == "done")
        #expect(rows.first { $0.title == "Newer copy" }?.processingDeviceID == deviceB)
    }
}
