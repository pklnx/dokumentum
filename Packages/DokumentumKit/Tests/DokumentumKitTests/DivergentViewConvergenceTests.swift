import DokumentumKit
import Foundation
import Testing

/// Plans made on two different snapshots of the same data (mid-sync), both applied to the whole data.
struct DivergentViewConvergenceTests {
    private func plan(_ snapshot: RepairSnapshot) -> RepairPlan {
        RepairPlanner.plan(snapshot, context: settledContext)
    }

    /// What must come out the same whatever the order: who is live and where the references point.
    private struct Outcome: Equatable {
        let live: Set<UUID>
        let references: [UUID: [UUID?]]
        let parents: [UUID: UUID?]
        let links: [UUID: UUID?]

        init(_ state: RepairSnapshot) {
            live = Set(state.metadata.filter(\.isLive).map(\.instanceID))
            references = Dictionary(
                uniqueKeysWithValues: state.documents.map { document in
                    let tags = document.tags.sorted { $0.uuidString < $1.uuidString }
                    return (document.instanceID, [document.correspondent, document.documentType] + tags)
                }
            )
            parents = Dictionary(uniqueKeysWithValues: state.metadata.map { ($0.instanceID, $0.parentInstanceID) })
            links = Dictionary(uniqueKeysWithValues: state.blobs.map { ($0.instanceID, $0.linkedDocumentInstanceID) })
        }
    }

    private func expectConvergence(
        _ union: RepairSnapshot,
        _ first: RepairSnapshot,
        _ second: RepairSnapshot,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let (a, b) = (plan(first), plan(second))
        let oneWay = checkedUnion(of: union, plans: [a, b], sourceLocation: sourceLocation)
        let otherWay = checkedUnion(of: union, plans: [b, a], sourceLocation: sourceLocation)
        guard let oneEnd = oneWay.settled(), let otherEnd = otherWay.settled() else {
            Issue.record("no fixpoint", sourceLocation: sourceLocation)
            return
        }
        #expect(Outcome(oneEnd) == Outcome(otherEnd), sourceLocation: sourceLocation)
    }

    // MARK: Mutable values decide nothing

    @Test func aNewerModifiedAtChangesNoPlan() {
        let state = RepairSnapshot(
            documents: [
                document(1, id: 1050, created: 5, modified: 1, correspondent: 10),
                document(2, id: 1050, created: 6, modified: 2, correspondent: 11),
            ],
            metadata: [correspondent(10, "A"), correspondent(11, "a")],
            blobs: [blob(.file, 20, documentID: 50)]
        )
        var newer = state
        newer.documents[0].modifiedAt = at(9)
        newer.documents[1].modifiedAt = at(3)
        #expect(plan(state) == plan(newer))
        #expect(plan(state).operations.contains(.relink(blob: uuid(20), to: uuid(1))))
        expectConvergence(state, state, newer)
    }

    @Test func aRenameOnOneDeviceChangesNoWinner() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, "Zebra", created: 5), correspondent(11, "ZEBRA", created: 6),
        ])
        var renamed = state
        renamed.metadata[0].name = "ZEBRA"
        renamed.metadata[1].name = "Zebra"
        #expect(plan(state) == plan(renamed))
        #expect(plan(renamed).operations == [.mergeMetadata(kind: .correspondent, loser: uuid(11), into: uuid(10))])
    }

    @Test func anOlderMergeDateChangesNoWinner() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [
                correspondent(10, "X", mergedInto: 11, mergedAt: at(1)),
                correspondent(11, "Y", mergedInto: 10, mergedAt: at(2)),
            ]
        )
        var other = state
        other.metadata[0].mergedAt = at(2)
        other.metadata[1].mergedAt = at(1)
        #expect(plan(state) == plan(other))
    }

    // MARK: A record is missing

    @Test func aViewWithoutTheOldestRecordConverges() {
        let state = RepairSnapshot(
            documents: [
                document(1, correspondent: 10), document(2, correspondent: 11), document(3, correspondent: 12),
            ],
            metadata: [correspondent(10, "A"), correspondent(11, "a"), correspondent(12, "A ")]
        )
        let withoutOldest = view(of: state, droppingMetadata: [10])
        let withoutMiddle = view(of: state, droppingMetadata: [11])
        expectConvergence(state, withoutOldest, withoutMiddle)

        let end = checkedUnion(of: state, plans: [plan(withoutOldest), plan(withoutMiddle)]).settled()
        #expect(end?.metadata.filter(\.isLive).map(\.instanceID) == [uuid(10)])
        #expect(end?.documents.allSatisfy { $0.correspondent == uuid(10) } == true)
    }

    @Test func aViewWithoutTheMergeTargetChangesNothingThereAndTheOtherRepoints() {
        let state = RepairSnapshot(
            documents: [document(1, tags: [10])],
            metadata: [tag(10, "X", mergedInto: 11, mergedAt: planningTime), tag(11, "W")]
        )
        let withoutTarget = view(of: state, droppingMetadata: [11])
        #expect(plan(withoutTarget).isEmpty)
        let after = checkedUnion(of: state, plans: [plan(withoutTarget), plan(state)])
        #expect(after.document(1).tags == [uuid(11)])
    }

    @Test func aReviveFromAViewThatLacksTheTargetKeepsEveryRecord() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [correspondent(10, "Same", created: 5, mergedInto: 11), correspondent(11, "same", created: 1)]
        )
        let withoutTarget = view(of: state, droppingMetadata: [11])
        #expect(plan(withoutTarget).operations == [.revive(tombstone: uuid(10))])
        let after = checkedUnion(of: state, plans: [plan(withoutTarget)])
        #expect(!after.record(10).isLive, "the chain end is here, so the revival is skipped")
        let end = after.settled()
        #expect(end?.record(10).isLive == false)
        #expect(end?.document(1).correspondent == uuid(11))
    }

    @Test func viewsThatEachLackADocumentConverge() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 11), document(2, correspondent: 11)],
            metadata: [correspondent(10, "A"), correspondent(11, "a")]
        )
        expectConvergence(state, view(of: state, documents: [1]), view(of: state, documents: [2]))
    }

    // MARK: A relationship is missing

    @Test func aViewWithoutAReferenceLeavesItForTheOtherPlan() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 11, type: 20)],
            metadata: [
                correspondent(10, "A"), correspondent(11, "a"),
                metadata(.documentType, 20, "X", mergedInto: 21), metadata(.documentType, 21, "W"),
            ]
        )
        var withoutReferences = state
        withoutReferences.documents[0].correspondent = nil
        withoutReferences.documents[0].documentType = nil
        expectConvergence(state, withoutReferences, state)
        let after = checkedUnion(of: state, plans: [plan(withoutReferences)])
        #expect(after.document(1).correspondent == uuid(10), "the merge moves what the store holds, seen or not")
        #expect(after.document(1).documentType == uuid(20), "waits for the next run's re-point")
    }

    @Test func aViewWithoutAParentDoesNotMergeTagsUnderDifferentParents() {
        let state = RepairSnapshot(metadata: [tag(1, "P"), tag(2, "A"), tag(3, "a", parent: 1)])
        var withoutParent = state
        withoutParent.metadata[2].parentInstanceID = nil
        #expect(plan(withoutParent).operations == [.mergeMetadata(kind: .tag, loser: uuid(3), into: uuid(2))])
        let after = checkedUnion(of: state, plans: [plan(withoutParent)])
        #expect(after.record(3).isLive, "the precondition holds on the whole data, where the parents differ")
    }

    @Test func viewsThatDisagreeAboutACycleLeaveNone() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 3), tag(3, "C", parent: 1)])
        var oneEdgeMissing = state
        oneEdgeMissing.metadata[1].parentInstanceID = nil
        expectConvergence(state, oneEdgeMissing, state)
        let end = checkedUnion(of: state, plans: [plan(oneEdgeMissing), plan(state)]).settled()
        #expect(end?.record(1).parentInstanceID == nil)
    }

    // MARK: Blobs

    @Test func twoViewsRelinkingDifferentBlobsLinkOne() {
        let state = RepairSnapshot(
            documents: [document(1)],
            blobs: [blob(.file, 10, documentID: 1), blob(.file, 11, documentID: 1)]
        )
        let (first, second) = (view(of: state, blobs: [11]), view(of: state, blobs: [10]))
        #expect(plan(first).operations == [.relink(blob: uuid(10), to: uuid(1))])
        #expect(plan(second).operations == [.relink(blob: uuid(11), to: uuid(1))])
        let after = checkedUnion(of: state, plans: [plan(second), plan(first)])
        #expect(after.blobs.count { $0.linkedDocumentInstanceID == uuid(1) } == 1)
        #expect(RepairPlanner.counts(in: after).documentsWithTwoFiles == 1, "the other is counted, not lost")
    }

    @Test func aViewWithoutTheLinkedBlobDoesNotAddASecondLink() {
        let state = RepairSnapshot(
            documents: [document(1)],
            blobs: [blob(.file, 10, documentID: 1, linkedTo: 1), blob(.file, 11, documentID: 1)]
        )
        let withoutLinked = view(of: state, blobs: [10])
        #expect(plan(withoutLinked).operations == [.relink(blob: uuid(11), to: uuid(1))])
        let after = checkedUnion(of: state, plans: [plan(withoutLinked)])
        #expect(after.blob(11).linkedDocumentInstanceID == nil)
        #expect(after.blob(10).linkedDocumentInstanceID == uuid(1))
    }
}
