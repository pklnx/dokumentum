import DokumentumCore
import DokumentumKit
import Foundation
import SwiftData
import Testing

/// The repair passes on real stores (plan of #2, part 3, DW3): each case is seeded into a SwiftData store on
/// disk, repaired through `RepairRunner`, and read back. `CheckedRepair` checks `RepairInvariants` on the
/// store's snapshots and that the store ends exactly where `RepairPlanner`'s simulation ends. Ported cases
/// from the predecessor's `MetadataMaintenanceTests` and `TagHierarchyTests` keep the loser as a tombstone.
struct RepairPassesTests {
    // MARK: Pass 1, re-point

    @Test func everyReferenceToATombstoneGoesToTheLiveEnd() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 10, type: 20, tags: [30]), document(2, correspondent: 11)],
                metadata: [
                    correspondent(10, "Old", mergedInto: 11), correspondent(11, "New"),
                    metadata(.documentType, 20, "Old", mergedInto: 21), metadata(.documentType, 21, "New"),
                    tag(30, "Old", mergedInto: 31), tag(31, "New"), tag(32, "Child", parent: 30),
                ]))

        let repair = try await CheckedRepair.run(store)
        let after = repair.after
        #expect(after.document(1)?.correspondent == uuid(11))
        #expect(after.document(1)?.documentType == uuid(21))
        #expect(after.document(1)?.tags == [uuid(31)])
        #expect(after.document(1)?.modifiedAt == repairTime, "touched")
        #expect(after.document(2)?.modifiedAt == at(0), "a document already on the live record is not touched")
        #expect(after.record(32)?.parentInstanceID == uuid(31))
        #expect(after.record(10)?.isLive == false, "re-pointing leaves the tombstone a tombstone")
    }

    /// A merges Y into X while B merges X into W: A's moved documents end on W.
    @Test func theABWCase() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11), document(2, correspondent: 10)],
                metadata: [
                    correspondent(10, "X", mergedInto: 12), correspondent(11, "Y", mergedInto: 10),
                    correspondent(12, "W"),
                ]))

        let after = try await CheckedRepair.run(store).after
        #expect(after.document(1)?.correspondent == uuid(12))
        #expect(after.document(2)?.correspondent == uuid(12))
    }

    // MARK: Pass 2, merge (ported from MetadataMaintenanceTests)

    @Test(arguments: [MetadataKind.correspondent, .documentType, .tag])
    func sameNamesMergeIntoTheOldestAndTheLoserStaysATombstone(kind: MetadataKind) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        func referencing(_ instance: Int, _ record: Int) -> DocumentSnapshot {
            switch kind {
            case .correspondent: document(instance, correspondent: record)
            case .documentType: document(instance, type: record)
            case .tag: document(instance, tags: [record])
            }
        }
        try store.seed(
            RepairSnapshot(
                documents: [referencing(1, 10), referencing(2, 11)],
                metadata: [metadata(kind, 10, "Telekom", created: 5), metadata(kind, 11, " telekom", created: 1)]))

        let after = try await CheckedRepair.run(store).after
        #expect(after.record(11)?.isLive == true, "the older record is the keeper")
        #expect(after.record(10)?.mergedIntoID == uuid(1011))
        #expect(after.record(10)?.mergedAt == repairTime)
        #expect(after.metadata.count == 2, "the loser is not deleted")
        for instance in [1, 2] {
            let moved = try #require(after.document(instance))
            #expect([moved.correspondent, moved.documentType].contains(uuid(11)) || moved.tags == [uuid(11)])
        }
        #expect(after.document(1)?.modifiedAt == repairTime, "moved documents are touched")
        #expect(after.document(2)?.modifiedAt == at(0), "a document already on the keeper is not")
    }

    /// Two devices both created Auto › Golf › Werkstatt before syncing: one run merges all levels.
    @Test func identicalTreesMergeInOneCall() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: (1...6).map { document($0, tags: [9 + $0]) },
                metadata: [
                    tag(10, "Auto", created: 1000), tag(11, "Golf", created: 1000, parent: 10),
                    tag(12, "Werkstatt", created: 1000, parent: 11),
                    tag(13, "Auto", created: 2000), tag(14, "Golf", created: 2000, parent: 13),
                    tag(15, "Werkstatt", created: 2000, parent: 14),
                ]))

        let repair = try await CheckedRepair.run(store)
        let after = repair.after
        #expect(
            after.metadata.filter(\.isLive).map(\.instanceID).sorted { $0.uuidString < $1.uuidString }
                == [10, 11, 12].map(uuid))
        #expect(after.record(11)?.parentInstanceID == uuid(10))
        #expect(after.record(12)?.parentInstanceID == uuid(11))
        #expect(after.documents.count == 6, "all documents kept")
        for instance in 1...6 {
            #expect(after.document(instance)?.tags == [uuid(10 + (instance - 1) % 3)])
        }
        #expect(repair.report.saves >= 1)
    }

    @Test func sameNameUnderDifferentParentsIsNotMerged() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [
                tag(1, "Golf"), tag(2, "Polo"), tag(3, "Werkstatt", parent: 1), tag(4, "werkstatt", parent: 2),
            ]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.isEmpty)
        #expect(repair.report.saves == 0)
    }

    /// Device 1 put A under B, device 2 put B under A′ (a duplicate of A). A and A′ have different parents, so
    /// they are not merged, and no cycle arises.
    @Test func mergeThenRepairHasNoCycle() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(RepairSnapshot(metadata: [tag(1, "A", parent: 3), tag(2, "A"), tag(3, "B", parent: 2)]))

        #expect(try await CheckedRepair.run(store).plan.isEmpty)
    }

    /// The same once A and A′ share a parent: the merge (pass 2) moves B under A and closes a cycle, which
    /// pass 3 breaks in the same run, each pass in its own save.
    @Test func aMergeThatClosesACycleIsBrokenInTheSameRun() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [
                tag(1, "A", parent: 4), tag(2, "A", parent: 4), tag(3, "B", parent: 2), tag(4, "P", parent: 3),
            ]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.report.passes.map(\.pass) == [.merge, .cycles])
        #expect(repair.report.saves == 2, "one transaction per pass")
        #expect(repair.after.record(1)?.parentInstanceID == nil)
        #expect(repair.after.record(3)?.parentInstanceID == uuid(1))
        #expect(repair.after.record(4)?.parentInstanceID == uuid(3))
    }

    /// Ported: a cycle that arrived by sync is repaired in the same run.
    @Test func mergeDuplicatesRepairsCycles() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [tag(1, "A", created: 1000, parent: 2), tag(2, "B", created: 2000, parent: 1)]))

        let after = try await CheckedRepair.run(store).after
        #expect(after.record(1)?.parentInstanceID == nil)
        #expect(after.record(2)?.parentInstanceID == uuid(1))
    }

    /// The plan reviewer's case: P under C, C under D2, D1 and D2 under P with the same name, D1 the keeper.
    @Test func theReviewersCase() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let (p, c, d1, d2) = (1, 2, 3, 4)
        try store.seed(
            RepairSnapshot(metadata: [
                tag(p, "P", created: 10, parent: c), tag(c, "C", created: 11, parent: d2),
                tag(d1, "D", created: 1, parent: p), tag(d2, "D", created: 2, parent: p),
            ]))

        let after = try await CheckedRepair.run(store).after
        #expect(after.record(d1)?.parentInstanceID == nil)
        #expect(after.record(c)?.parentInstanceID == uuid(d1))
        #expect(after.record(p)?.parentInstanceID == uuid(c))
        #expect(after.record(d2)?.isLive == false)
    }

    /// A keeper nested in its own duplicate moves under itself (a tag that is its own parent, saved), and
    /// pass 3 makes it a root.
    @Test func aKeeperNestedInItsDuplicateBecomesARoot() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "A", parent: 2)]))

        let after = try await CheckedRepair.run(store).after
        #expect(after.record(1)?.parentInstanceID == nil)
        #expect(after.record(2)?.parentInstanceID == uuid(1))
    }

    @Test func mergingCorrespondentsTouchesTheMovedDocuments() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(
                documents: [document(1, correspondent: 11), document(2, correspondent: 10)],
                metadata: [correspondent(10, "Telekom"), correspondent(11, "Telekom")]))

        let after = try await CheckedRepair.run(store).after
        #expect(after.document(1)?.correspondent == uuid(10))
        #expect(after.document(1)?.modifiedAt == repairTime)
        #expect(after.document(2)?.modifiedAt == at(0), "a document already on the keeper is not touched")
    }

    @Test func mergingTagsTouchesTheirDocumentsAlsoWhenTheKeeperWasThere() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(documents: [document(1, tags: [10, 11])], metadata: [tag(10, "Tax"), tag(11, "Tax")]))

        let after = try await CheckedRepair.run(store).after
        #expect(after.document(1)?.tags == [uuid(10)])
        #expect(after.document(1)?.modifiedAt == repairTime, "it lost the duplicate tag")
    }

    // MARK: Pass 3, cycles (ported from TagHierarchyTests)

    @Test func repairsCycleDeterministically() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [tag(1, "A", created: 1000, parent: 2), tag(2, "B", created: 2000, parent: 1)]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.operations == [.makeRoot(tag: uuid(1), expectedParent: uuid(2))])
        #expect(repair.after.record(1)?.parentInstanceID == nil, "the older tag becomes the root")
        #expect(repair.after.record(2)?.parentInstanceID == uuid(1))
    }

    @Test(arguments: [false, true])
    func repairWithEqualDatesPicksTheLowerID(insertLowerFirst: Bool) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let tags = [tag(1, "X", created: 1000, parent: 2), tag(2, "Y", created: 1000, parent: 1)]
        try store.seed(RepairSnapshot(metadata: insertLowerFirst ? tags : tags.reversed()))

        let after = try await CheckedRepair.run(store).after
        #expect(after.record(1)?.parentInstanceID == nil, "same result whatever the insert and fetch order")
        #expect(after.record(2)?.parentInstanceID == uuid(1))
    }

    /// Runs after every store change: without a cycle it must not change or save anything, or its own save
    /// would trigger it again.
    @Test func repairWithoutCycleChangesNothing() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(
            RepairSnapshot(metadata: [tag(1, "Auto"), tag(2, "Golf", parent: 1), tag(3, "Werkstatt", parent: 2)]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.plan.isEmpty)
        #expect(repair.report.saves == 0)
    }

    /// Breaking a cycle can make two tags roots of the same name: passes 2 and 3 repeat in the same run, so
    /// the merge does not wait for the next one.
    @Test func aTagFreedFromACycleMergesInTheSameRun() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.seed(RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1), tag(3, "a")]))

        let repair = try await CheckedRepair.run(store)
        #expect(repair.report.passes.map(\.pass) == [.cycles, .merge])
        #expect(repair.after.record(3)?.isLive == false)
        #expect(try await CheckedRepair.run(store).plan.isEmpty, "nothing left for the next run")
    }

    @Test func aCycleThroughATombstoneIsNotBroken() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        // 1 → 2 (a tombstone whose chain end is missing) → 1: the parent chain ends at the tombstone.
        try store.seed(
            RepairSnapshot(metadata: [
                tag(1, "A", parent: 2), tag(2, "B", parent: 1, mergedInto: 99, mergedAt: repairTime),
            ]))

        #expect(try await CheckedRepair.run(store).plan.isEmpty)
    }
}
