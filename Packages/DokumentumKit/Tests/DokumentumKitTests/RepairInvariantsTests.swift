import DokumentumKit
import Foundation
import Testing

/// `RepairInvariants` itself: a checker that finds nothing proves nothing.
struct RepairInvariantsTests {
    private let before = RepairSnapshot(
        documents: [document(1, correspondent: 10, type: 20, tags: [30, 31])],
        metadata: [
            correspondent(10, "X", mergedInto: 11),
            correspondent(11, "W"),
            metadata(.documentType, 20, "Invoice"),
            tag(30, "A"),
            tag(31, "B", parent: 30),
            tag(32, "Old", mergedInto: 30),
        ],
        blobs: [blob(.file, 40, documentID: 1, linkedTo: 1), blob(.thumbnail, 41, documentID: 1)]
    )

    private func found(
        plan: RepairPlan = RepairPlan(),
        plannedOnBefore: Bool = true,
        change: (inout RepairSnapshot) -> Void = { _ in }
    ) -> Set<RepairInvariantViolation.Invariant> {
        var after = before
        change(&after)
        let violations = RepairInvariants.violations(
            before: before,
            plan: plan,
            after: after,
            plannedOnBefore: plannedOnBefore
        )
        return Set(violations.map(\.invariant))
    }

    private func index(_ instance: Int, in snapshot: RepairSnapshot) -> Int {
        snapshot.metadata.firstIndex { $0.instanceID == uuid(instance) }!
    }

    @Test func noChangeIsNoViolation() {
        #expect(found().isEmpty)
    }

    @Test func violationsNameWhatBroke() {
        var after = before
        after.documents[0].sourceRaw = "file2"
        let violation = RepairInvariants.violations(before: before, plan: RepairPlan(), after: after)[0]
        #expect(violation.description == "I8: document \(uuid(1)) changed a frozen raw value")
    }

    // MARK: I1

    @Test func i1FindsAVanishedRecordOfEveryEntity() {
        #expect(found { $0.documents.removeAll() } == [.i1])
        #expect(found { $0.blobs.removeAll { $0.kind == .file } } == [.i1])
        #expect(found { $0.blobs.removeAll { $0.kind == .thumbnail } } == [.i1])
        #expect(found { $0.metadata.removeAll { $0.kind == .documentType } }.contains(.i1))
        #expect(found { $0.metadata.removeAll { $0.instanceID == uuid(11) } }.contains(.i1))
        #expect(found { $0.metadata.removeAll { $0.instanceID == uuid(32) } }.contains(.i1))
    }

    @Test func i1FindsARecordThatAppeared() {
        #expect(found { $0.blobs.append(blob(.file, 42, documentID: 1)) } == [.i1])
    }

    // MARK: I2

    @Test func i2FindsAnOperationTargetingATombstoneOrAbsentRecordOrWrongKind() {
        let reference = RepairReference.correspondent(document: uuid(1))
        let toTombstone = RepairOperation.repoint(reference: reference, from: uuid(10), to: uuid(10))
        #expect(found(plan: RepairPlan([toTombstone])).contains(.i2))
        let toAbsent = RepairOperation.repoint(reference: reference, from: uuid(10), to: uuid(99))
        #expect(found(plan: RepairPlan([toAbsent])).contains(.i2))
        let toWrongKind = RepairOperation.repoint(reference: reference, from: uuid(10), to: uuid(30))
        #expect(found(plan: RepairPlan([toWrongKind])).contains(.i2))
        let mergeIntoTombstone = RepairOperation.mergeMetadata(kind: .correspondent, loser: uuid(11), into: uuid(10))
        #expect(found(plan: RepairPlan([mergeIntoTombstone])).contains(.i2))
        #expect(found(plan: RepairPlan([.relink(blob: uuid(41), to: uuid(99))])).contains(.i2))
    }

    @Test func i2FindsAChangedReferenceToATombstone() {
        #expect(found { $0.documents[0].documentType = uuid(10) } == [.i2])
        #expect(found { $0.documents[0].correspondent = uuid(32) } == [.i2])
        #expect(found { $0.documents[0].tags.insert(uuid(32)) } == [.i2])
        #expect(found { $0.documents[0].tags.insert(uuid(99)) } == [.i2])
        #expect(found { $0.metadata[index(30, in: $0)].parentInstanceID = uuid(32) } == [.i2])
    }

    @Test func i2FindsABlobLinkedToAnAbsentDocument() {
        #expect(found { $0.blobs[1].linkedDocumentInstanceID = uuid(99) } == [.i2])
    }

    @Test func i2LeavesAnUnchangedReferenceToATombstoneAlone() {
        #expect(before.document(1).correspondent == uuid(10))
        #expect(found().isEmpty)
    }

    // MARK: I3

    @Test func i3FindsADroppedReference() {
        #expect(found { $0.documents[0].correspondent = nil } == [.i3])
        #expect(found { $0.documents[0].documentType = nil } == [.i3])
    }

    @Test func i3FindsARemovedTagWithoutReplacement() {
        #expect(found { $0.documents[0].tags.remove(uuid(30)) } == [.i3])
    }

    @Test func i3AcceptsARemovedTombstoneTagWithItsReplacement() {
        var state = before
        state.documents[0].tags = [uuid(32)]
        var after = state
        after.documents[0].tags = [uuid(30)]
        #expect(RepairInvariants.violations(before: state, plan: RepairPlan(), after: after).isEmpty)
    }

    @Test func i3FindsARemovedTombstoneTagWithoutReplacement() {
        var state = before
        state.documents[0].tags = [uuid(32)]
        var after = state
        after.documents[0].tags = []
        let violations = RepairInvariants.violations(before: state, plan: RepairPlan(), after: after)
        #expect(violations.map(\.invariant) == [.i3])
    }

    /// Plans from two views on the union: one re-points the tag, the other revives it. The removed tag was
    /// replaced by what its chain named before the revival, so nothing was dropped.
    @Test func i3AcceptsAReplacementOfATagRevivedLaterInTheSameChange() {
        let state = RepairSnapshot(
            documents: [document(1, tags: [10])],
            metadata: [tag(10, "T", mergedInto: 11), tag(11, "U")]
        )
        let plan = RepairPlan([
            .repoint(reference: .tag(document: uuid(1)), from: uuid(10), to: uuid(11)),
            .revive(tombstone: uuid(10)),
        ])
        let application = plan.apply(to: state, now: planningTime)
        #expect(application.skipped.isEmpty)
        #expect(application.snapshot.document(1).tags == [uuid(11)])
        #expect(application.snapshot.record(10).isLive)
        let violations = RepairInvariants.violations(
            before: state,
            plan: plan,
            after: application.snapshot,
            plannedOnBefore: false
        )
        #expect(violations.isEmpty, "\(violations)")
    }

    /// A revival in the same plan can take over the `id` the chain follows: the tag was replaced before it.
    @Test func i3AcceptsAReplacementOfBeforeARevivalTookOverTheChain() {
        let state = RepairSnapshot(
            documents: [document(1, tags: [10, 11])],
            metadata: [
                tag(10, "T", mergedInto: 50),
                tag(11, "Live copy", created: 20, id: 1050),
                tag(12, "Old copy", created: 1, id: 1050, mergedInto: 99),
            ]
        )
        let plan = RepairPlanner.plan(state, context: settledContext)
        #expect(plan.operations.contains(.revive(tombstone: uuid(12))))
        let after = plan.apply(to: state, now: planningTime).snapshot
        #expect(after.document(1).tags == [uuid(11)])
        #expect(RepairInvariants.violations(before: state, plan: plan, after: after).isEmpty)
    }

    /// `mergedIntoID` names an `id`, and an older record sharing it comes first in the chain.
    @Test func i3AcceptsAMergeWhoseKeeperSharesItsID() {
        let state = RepairSnapshot(
            documents: [document(1, tags: [10, 11])],
            metadata: [
                tag(9, "Other name", created: 1, id: 1050),
                tag(10, "Same", created: 5, id: 1050),
                tag(11, "same", created: 6),
            ]
        )
        let plan = RepairPlanner.plan(state, context: settledContext)
        #expect(plan.operations == [.mergeMetadata(kind: .tag, loser: uuid(11), into: uuid(10))])
        let after = plan.apply(to: state, now: planningTime).snapshot
        #expect(after.document(1).tags == [uuid(10)])
        #expect(RepairPlanner.chainEnd(of: uuid(11), in: after) == .live(uuid(9)))
        #expect(RepairInvariants.violations(before: state, plan: plan, after: after).isEmpty)
    }

    @Test func i3FindsAClearedParentWithoutMakeRoot() {
        #expect(found { $0.metadata[index(31, in: $0)].parentInstanceID = nil } == [.i3])
    }

    @Test func i3FindsAChangedOrRemovedBlobLink() {
        #expect(found { $0.blobs[0].linkedDocumentInstanceID = nil } == [.i3])
    }

    // MARK: I4

    @Test func i4FindsATombstoneWithoutAMerge() {
        #expect(found { $0.metadata[index(11, in: $0)].mergedIntoID = uuid(1030) } == [.i4])
    }

    @Test func i4FindsAClearedTombstoneWithoutARevive() {
        #expect(
            found {
                $0.metadata[index(10, in: $0)].mergedIntoID = nil
                $0.metadata[index(10, in: $0)].mergedAt = nil
            } == [.i4]
        )
    }

    @Test func i4FindsAChangedTargetOrDate() {
        #expect(found { $0.metadata[index(10, in: $0)].mergedIntoID = uuid(1030) } == [.i4])
        #expect(found { $0.metadata[index(10, in: $0)].mergedAt = at(5) } == [.i4])
    }

    @Test func i4FindsARevivalThatKeepsItsDate() {
        let plan = RepairPlan([.revive(tombstone: uuid(10))])
        let result = found(plan: plan, plannedOnBefore: false) { $0.metadata[index(10, in: $0)].mergedIntoID = nil }
        #expect(result == [.i4])
    }

    @Test func i4FindsAMergeIntoTheWrongID() {
        var state = before
        state.metadata.append(correspondent(12, "w"))
        let plan = RepairPlan([.mergeMetadata(kind: .correspondent, loser: uuid(12), into: uuid(11))])
        var after = state
        after.metadata[index(12, in: after)].mergedIntoID = uuid(1030)
        after.metadata[index(12, in: after)].mergedAt = at(5)
        let violations = RepairInvariants.violations(before: state, plan: plan, after: after)
        #expect(violations.map(\.invariant) == [.i4])
    }

    // MARK: I5

    @Test func i5FindsAChangedImmutableValue() {
        #expect(found { $0.documents[0].id = uuid(99) } == [.i5])
        #expect(found { $0.documents[0].createdAt = at(99) } == [.i5])
        #expect(found { $0.metadata[index(11, in: $0)].id = uuid(99) } == [.i5])
        #expect(found { $0.metadata[index(11, in: $0)].createdAt = at(99) } == [.i5])
        #expect(found { $0.metadata[index(11, in: $0)].name = "Renamed" } == [.i5])
        #expect(found { $0.blobs[0].documentID = uuid(99) } == [.i5])
        #expect(found { $0.blobs[0].createdAt = at(99) } == [.i5])
    }

    @Test func i5FindsAYoungerKeeper() {
        let state = RepairSnapshot(metadata: [correspondent(10, "A", created: 1), correspondent(11, "a", created: 2)])
        let plan = RepairPlan([.mergeMetadata(kind: .correspondent, loser: uuid(10), into: uuid(11))])
        let after = plan.apply(to: state, now: planningTime).snapshot
        let violations = RepairInvariants.violations(before: state, plan: plan, after: after)
        #expect(violations.map(\.invariant) == [.i5])
    }

    private func decisions(
        _ state: RepairSnapshot,
        _ operation: RepairOperation
    ) -> [RepairInvariantViolation.Invariant] {
        let plan = RepairPlan([operation])
        let after = plan.apply(to: state, now: planningTime).snapshot
        return RepairInvariants.violations(before: state, plan: plan, after: after).map(\.invariant)
    }

    @Test func i5FindsARepointThatLeavesTheChain() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [correspondent(10, "X", mergedInto: 11), correspondent(11, "W"), correspondent(12, "Other")]
        )
        let wrong = RepairOperation.repoint(reference: .correspondent(document: uuid(1)), from: uuid(10), to: uuid(12))
        #expect(decisions(state, wrong) == [.i5])
        let right = RepairOperation.repoint(reference: .correspondent(document: uuid(1)), from: uuid(10), to: uuid(11))
        #expect(decisions(state, right).isEmpty)
    }

    @Test func i5FindsARootThatIsNotTheCyclesOldest() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1), tag(3, "C", parent: 1)])
        #expect(decisions(state, .makeRoot(tag: uuid(2), expectedParent: uuid(1))) == [.i5])
        #expect(decisions(state, .makeRoot(tag: uuid(3), expectedParent: uuid(1))) == [.i5], "below the cycle")
        #expect(decisions(state, .makeRoot(tag: uuid(1), expectedParent: uuid(2))).isEmpty)
        // Older than the cycle, so only the membership check can tell it is outside.
        var withOlderTail = state
        withOlderTail.metadata.append(tag(4, "Tail", created: 0, parent: 1))
        #expect(decisions(withOlderTail, .makeRoot(tag: uuid(4), expectedParent: uuid(1))) == [.i5], "older tail")
    }

    @Test func i5FindsARootThatIsNoLiveTag() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 1, mergedInto: 99)])
        #expect(decisions(state, .makeRoot(tag: uuid(1), expectedParent: uuid(1))).contains(.i5))
    }

    @Test func i5FindsARelinkOfTheWrongBlobOrDocument() {
        let state = RepairSnapshot(
            documents: [document(1, id: 1050, created: 1), document(2, id: 1050, created: 2)],
            blobs: [blob(.file, 10, created: 1, documentID: 50), blob(.file, 11, created: 2, documentID: 50)]
        )
        #expect(decisions(state, .relink(blob: uuid(11), to: uuid(1))) == [.i5], "not the oldest blob")
        #expect(decisions(state, .relink(blob: uuid(10), to: uuid(2))) == [.i5], "not the oldest document")
        #expect(decisions(state, .relink(blob: uuid(10), to: uuid(1))).isEmpty)
        #expect(decisions(state, .relink(blob: uuid(99), to: uuid(1))) == [.i5], "not present")
    }

    @Test func i5FindsARevivalWithoutACause() {
        let state = RepairSnapshot(metadata: [
            correspondent(1, "Loop one", mergedInto: 2),
            correspondent(2, "Loop two", mergedInto: 1),
            correspondent(3, "Chain", mergedInto: 4),
            correspondent(4, "Last", mergedInto: 99),
            correspondent(5, "To a live record", mergedInto: 6),
            correspondent(6, "Live"),
        ])
        #expect(decisions(state, .revive(tombstone: uuid(1))).isEmpty)
        #expect(decisions(state, .revive(tombstone: uuid(2))) == [.i5])
        #expect(decisions(state, .revive(tombstone: uuid(4))).isEmpty)
        #expect(decisions(state, .revive(tombstone: uuid(3))) == [.i5])
        #expect(decisions(state, .revive(tombstone: uuid(5))) == [.i5])
    }

    @Test func aPlanFromAnotherViewIsNotJudgedByItsDecisions() {
        let state = RepairSnapshot(metadata: [correspondent(5, "X", mergedInto: 6), correspondent(6, "Live")])
        let plan = RepairPlan([.revive(tombstone: uuid(5))])
        let after = plan.apply(to: state, now: planningTime).snapshot
        #expect(RepairInvariants.violations(before: state, plan: plan, after: after, plannedOnBefore: false).isEmpty)
        #expect(!RepairInvariants.violations(before: state, plan: plan, after: after).isEmpty)
    }

    // MARK: I8

    @Test func i8FindsARewrittenFrozenValue() {
        #expect(found { $0.documents[0].sourceRaw = "scan" } == [.i8])
        #expect(found { $0.documents[0].textSourceRaw = "vision" } == [.i8])
        #expect(found { $0.documents[0].processingStateRaw = "done" } == [.i8])
    }
}
