import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// Tombstones on real stores: re-pointing through chains, the revive rule (pass 5), and that tombstones are
/// never grouped, never part of a cycle, never listed, and never mixed up with a record sharing their `id`.
struct TombstoneTests {
    @Test func aChainIsFollowedToItsLiveEnd() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, type: 10)],
                metadata: [
                    metadata(.documentType, 10, "X", mergedInto: 11), metadata(.documentType, 11, "Y", mergedInto: 12),
                    metadata(.documentType, 12, "W"),
                ]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.after.document(1)?.documentType == uuid(12))
        #expect(repair.plan.operations.count == 1, "one re-point straight to the end")
    }

    /// A loop X → Y → Z → X: its `keeperOrder` minimum is revived at once, without 30 days or an import, and
    /// the next run re-points to it.
    @Test func aLoopRevivesItsMinimumAndTheNextRunRepoints() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11)],
                metadata: [
                    correspondent(10, "X", created: 5, mergedInto: 11, mergedAt: repairTime),
                    correspondent(11, "Y", created: 6, mergedInto: 12, mergedAt: repairTime),
                    correspondent(12, "Z", created: 7, mergedInto: 10, mergedAt: repairTime),
                ]))

        let first = try await CheckedRepair.run(store, hasCompletedImport: false)
        #expect(first.plan.operations == [.revive(tombstone: uuid(10))])
        #expect(first.after.record(10)?.isLive == true)
        #expect(first.after.record(10)?.mergedAt == nil)
        let second = try await CheckedRepair.run(store, hasCompletedImport: false)
        #expect(second.after.document(1)?.correspondent == uuid(10))
        #expect(second.after.record(11)?.mergedIntoID == uuid(1012), "only the minimum changes state")
    }

    /// A chain whose end is missing (still downloading, or deleted) changes nothing.
    @Test(arguments: [(29, true), (400, false)])
    func aMissingEndChangesNothing(daysAgo: Int, hasCompletedImport: Bool) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10)],
                metadata: [correspondent(10, "X", mergedInto: 99, mergedAt: at((1000 - daysAgo) * days))]))

        let repair = try await CheckedRepair.run(store, hasCompletedImport: hasCompletedImport)
        #expect(repair.plan.isEmpty)
        #expect(repair.report.saves == 0)
        #expect(repair.after.document(1)?.correspondent == uuid(10))
    }

    /// … and is revived once it was merged 30 days ago and an import completed in this session.
    @Test(arguments: [30, 400])
    func aMissingEndIsRevivedAfterThirtyDaysAndAnImport(daysAgo: Int) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10)],
                metadata: [correspondent(10, "X", mergedInto: 99, mergedAt: at((1000 - daysAgo) * days))]))

        let repair = try await CheckedRepair.run(store, hasCompletedImport: true)
        #expect(repair.plan.operations == [.revive(tombstone: uuid(10))])
        #expect(repair.after.record(10)?.isLive == true)
        #expect(repair.after.document(1)?.correspondent == uuid(10), "the reference never moved")
    }

    /// A revived record and a live record of the same name merge on the next run.
    @Test func aRevivedRecordAndASameNameLiveRecordMergeOnTheNextRun() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [
                correspondent(10, "Same", created: 5, mergedInto: 99), correspondent(11, "same", created: 1),
            ]))

        let first = try await CheckedRepair.run(store)
        #expect(first.plan.operations == [.revive(tombstone: uuid(10))], "a tombstone is never grouped by name")
        let second = try await CheckedRepair.run(store)
        #expect(second.plan.operations == [.mergeMetadata(kind: .correspondent, loser: uuid(10), into: uuid(11))])
        let third = try await CheckedRepair.run(store)
        #expect(third.plan.isEmpty)
    }

    /// A tombstone with the name of a live record stays a tombstone, and is not part of a cycle.
    @Test func tombstonesAreNeverGroupedOrPartOfACycle() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [
                tag(1, "Tax"), tag(2, "Tax", mergedInto: 1, mergedAt: repairTime),
                tag(3, "Loop", parent: 4, mergedInto: 99, mergedAt: repairTime),
                tag(4, "Loop", parent: 3, mergedInto: 99, mergedAt: repairTime),
            ]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.isEmpty)
        #expect(repair.after.record(3)?.parentInstanceID == uuid(4), "a cycle among tombstones is left alone")
    }

    /// Lists never show tombstones: after a merge the library's sidebar lists only the keeper, and the moved
    /// document shows the keeper.
    @Test func listsNeverShowTombstones() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11, tags: [21])],
                metadata: [
                    correspondent(10, "Stadtwerke"), correspondent(11, "stadtwerke"), tag(20, "Tax"), tag(21, "Tax"),
                ]))

        _ = try await CheckedRepair.run(store)
        let library = try StoreLibrarySource.read(in: ModelContext(store.container))
        #expect(library.correspondents.map(\.instanceID) == [uuid(10)])
        #expect(library.tags.map(\.instanceID) == [uuid(20)])
        #expect(library.documents.first?.correspondent?.instanceID == uuid(10))
        #expect(library.documents.first?.tagIDs == [uuid(20)])
    }

    /// A live record sharing its `id` with a tombstone is left alone (no dedupe in #2); operations name the
    /// tombstone and the live record by `instanceID`, never by `id`.
    @Test func aRecordSharingItsIDWithATombstoneIsUntouched() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10), document(2, correspondent: 11)],
                metadata: [
                    correspondent(10, "Old", id: 50, mergedInto: 12), correspondent(11, "Other", id: 50),
                    correspondent(12, "New"),
                ]))

        let repair = try await CheckedRepair.run(store)
        #expect(
            repair.plan.operations == [
                .repoint(reference: .correspondent(document: uuid(1)), from: uuid(10), to: uuid(12))
            ])
        #expect(repair.after.document(2)?.correspondent == uuid(11))
        #expect(repair.after.record(11)?.isLive == true)
        #expect(repair.after.record(10)?.isLive == false)
        #expect(repair.report.counts.idGroupsWithSeveralRecords == 1, "counted, not repaired")
    }
}
