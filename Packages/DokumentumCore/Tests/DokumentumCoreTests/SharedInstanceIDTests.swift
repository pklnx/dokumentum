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

    // MARK: The merge pass (review A of #96, D2-1; review B, B-D3)

    enum Insertion: String, CaseIterable { case newerFirst, olderFirst }
    enum LoserReference: String, CaseIterable { case both, onlyNewer, onlyOlder }

    /// Review B's six configurations: two live correspondents "Stadtwerke" (a same-name merge; the later one is the
    /// loser) and two copies of one document sharing an `instanceID`, inserted in either order, with the loser
    /// referenced by both copies or one. The merge lands on the first run and nothing is skipped; the kept (older)
    /// copy is moved when it referenced the loser; the other copy keeps its reference, as it takes no part.
    @Test(arguments: Insertion.allCases, LoserReference.allCases)
    func aMergeLandsWhicheverCopyReferencesTheLoser(insertion: Insertion, reference: LoserReference) throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        let newerCreated = processingStart.addingTimeInterval(60)
        let id: UUID
        switch insertion {
        case .newerFirst:
            let newer = try store.insert(title: "Newer copy", created: newerCreated)
            id = try store.insert(title: "Older", created: processingStart)
            try store.edit(newer) { document, _ in document.instanceID = id }
        case .olderFirst:
            id = try store.insert(title: "Older", created: processingStart)
            let newer = try store.insert(title: "Newer copy", created: newerCreated)
            try store.edit(newer) { document, _ in document.instanceID = id }
        }
        let context = ModelContext(store.container)
        let keeper = Correspondent(name: "Stadtwerke", createdAt: processingStart)
        let loser = Correspondent(name: "Stadtwerke", createdAt: processingStart.addingTimeInterval(10))
        context.insert(keeper)
        context.insert(loser)
        for document in try context.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == id })) {
            let isNewer = document.title == "Newer copy"
            switch reference {
            case .both: document.correspondent = loser
            case .onlyNewer: if isNewer { document.correspondent = loser }
            case .onlyOlder: if !isNewer { document.correspondent = loser }
            }
        }
        try context.save()
        let (keeperID, loserID) = (keeper.instanceID, loser.instanceID)

        let report = try RepairRun.perform(
            in: store.container, now: processingStart.addingTimeInterval(hour), hasCompletedImport: true)

        #expect(!report.passes.contains { $0.metAnotherSave }, "\(report.passes)")
        #expect(report.skipped.isEmpty, "\(report.passes)")
        let stored = try ModelContext(store.container).fetch(
            FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == loserID }))
        #expect(stored.first?.mergedIntoID != nil, "the loser was not merged")
        let olderPointsTo = try correspondentID(of: "Older", id, in: store)
        let newerPointsTo = try correspondentID(of: "Newer copy", id, in: store)
        switch reference {
        case .both, .onlyOlder: #expect(olderPointsTo == keeperID, "the kept copy was not moved")
        case .onlyNewer: #expect(olderPointsTo == nil)
        }
        switch reference {
        case .both, .onlyNewer: #expect(newerPointsTo == loserID, "the copy that is not kept was written")
        case .onlyOlder: #expect(newerPointsTo == nil)
        }
        let next = try RepairRun.perform(
            in: store.container, now: processingStart.addingTimeInterval(2 * hour), hasCompletedImport: true)
        #expect(!next.passes.contains { $0.metAnotherSave }, "\(next.passes)")
        #expect(next.saves == 0, "the next run had something left to write")
    }

    /// Review A's probe: only the copy that is not kept points at one of two same-name correspondents (the older
    /// one, or the loser). Two runs: the merge lands in the first, and the second meets no other save.
    @Test(arguments: [false, true])
    func aMergeLandsWhenOnlyTheOtherCopyPointsAtACorrespondent(atTheLoser: Bool) throws {
        let store = try ProcessingStore()
        defer { store.remove() }
        _ = try store.insert(title: "Newer copy", created: processingStart.addingTimeInterval(60))
        let id = try store.insert(title: "Older", created: processingStart)
        let context = ModelContext(store.container)
        let first = Correspondent(name: "Stadtwerke", createdAt: processingStart)
        let second = Correspondent(name: "Stadtwerke", createdAt: processingStart.addingTimeInterval(10))
        context.insert(first)
        context.insert(second)
        for document in try context.fetch(FetchDescriptor<Document>()) where document.title == "Newer copy" {
            document.instanceID = id
            document.correspondent = atTheLoser ? second : first
        }
        try context.save()

        let now = processingStart.addingTimeInterval(hour)
        let firstRun = try RepairRun.perform(in: store.container, now: now, hasCompletedImport: true)
        let secondRun = try RepairRun.perform(in: store.container, now: now, hasCompletedImport: true)

        #expect(!firstRun.passes.contains { $0.metAnotherSave }, "\(firstRun.passes)")
        #expect(firstRun.saves == 1)
        #expect(!secondRun.passes.contains { $0.metAnotherSave }, "\(secondRun.passes)")
        #expect(secondRun.saves == 0)
        let merged = try ModelContext(store.container).fetch(FetchDescriptor<Correspondent>())
            .filter { $0.mergedIntoID != nil }
        #expect(merged.count == 1, "the two same-name correspondents were not merged")
    }

    private func correspondentID(of title: String, _ id: UUID, in store: ProcessingStore) throws -> UUID? {
        try ModelContext(store.container).fetch(
            FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == id })
        )
        .first { $0.title == title }?.correspondent?.instanceID
    }
}
