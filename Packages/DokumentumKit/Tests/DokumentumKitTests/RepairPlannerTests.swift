import DokumentumKit
import Foundation
import Testing

/// Every case goes through `planned`: all input orders give the same plan, and the invariants hold.
struct RepairPlannerTests {
    // MARK: Order

    @Test func keeperOrderIsOldestThenSmallestInstanceID() {
        let records = [
            correspondent(3, "x", created: 5), correspondent(2, "x", created: 5), correspondent(1, "x", created: 9),
        ]
        for order in [records, records.reversed()] {
            #expect(RepairPlanner.keeperOrder(order).map(\.instanceID) == [uuid(2), uuid(3), uuid(1)])
        }
    }

    @Test func nothingToRepairPlansNothing() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10, tags: [20])],
            metadata: [correspondent(10, "Telekom"), tag(20, "Auto"), tag(21, "Golf", parent: 20)],
            blobs: [blob(.file, 30, documentID: 1, linkedTo: 1)]
        )
        #expect(planned(state).plan.isEmpty)
    }

    @Test func anEmptyStatePlansNothing() {
        #expect(planned(RepairSnapshot()).plan.isEmpty)
    }

    @Test func aRepeatedInstanceIDDoesNotCrash() {
        let state = RepairSnapshot(
            documents: [document(1), document(1)],
            metadata: [tag(2, "Auto"), tag(2, "Auto")],
            blobs: [blob(.file, 3, documentID: 1), blob(.file, 3, documentID: 1)]
        )
        #expect(!RepairPlanner.plan(state, context: settledContext).isEmpty)
    }

    @Test func theRepairOperationsAreTheFiveOfThePlan() {
        let operations: [RepairOperation] = [
            .repoint(reference: .parent(tag: uuid(1)), from: uuid(2), to: uuid(3)),
            .mergeMetadata(kind: .tag, loser: uuid(1), into: uuid(2)),
            .makeRoot(tag: uuid(1), expectedParent: uuid(2)),
            .relink(blob: uuid(1), to: uuid(2)),
            .revive(tombstone: uuid(1)),
        ]
        #expect(operations.map(namesARepairOperation) == ["repoint", "mergeMetadata", "makeRoot", "relink", "revive"])
    }

    // MARK: Pass 1, re-point

    /// A merges Y into X while B merges X into W: A's moved documents end on W.
    @Test func theABWCase() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 11), document(2, correspondent: 10)],
            metadata: [
                correspondent(10, "X", mergedInto: 12),
                correspondent(11, "Y", mergedInto: 10),
                correspondent(12, "W"),
            ]
        )
        let (plan, after) = planned(state)
        #expect(after.document(1).correspondent == uuid(12))
        #expect(after.document(2).correspondent == uuid(12))
        #expect(plan.operations.count == 2)
        #expect(!after.record(10).isLive)
        #expect(!after.record(11).isLive)
    }

    @Test func aChainIsFollowedToItsLiveEnd() {
        let state = RepairSnapshot(
            documents: [document(1, type: 10)],
            metadata: [
                metadata(.documentType, 10, "X", mergedInto: 11),
                metadata(.documentType, 11, "Y", mergedInto: 12),
                metadata(.documentType, 12, "W"),
            ]
        )
        let (plan, after) = planned(state)
        #expect(
            plan.operations == [.repoint(reference: .documentType(document: uuid(1)), from: uuid(10), to: uuid(12))]
        )
        #expect(after.document(1).documentType == uuid(12))
    }

    @Test func aTagReferenceIsSwappedAndTheDocumentIsTouched() {
        let state = RepairSnapshot(
            documents: [document(1, tags: [10, 13])],
            metadata: [tag(10, "X", mergedInto: 11), tag(11, "W"), tag(13, "Other")]
        )
        let (plan, after) = planned(state)
        #expect(plan.operations == [.repoint(reference: .tag(document: uuid(1)), from: uuid(10), to: uuid(11))])
        #expect(after.document(1).tags == [uuid(11), uuid(13)])
        #expect(after.document(1).modifiedAt == planningTime)
    }

    @Test func aTagReferenceToATombstoneGoesWhenTheDocumentHasTheTargetAlready() {
        let state = RepairSnapshot(
            documents: [document(1, tags: [10, 11])],
            metadata: [tag(10, "X", mergedInto: 11), tag(11, "W")]
        )
        #expect(planned(state).after.document(1).tags == [uuid(11)])
    }

    @Test func aParentPointingAtATombstoneIsRepointed() {
        let state = RepairSnapshot(metadata: [tag(10, "X", mergedInto: 11), tag(11, "W"), tag(12, "Child", parent: 10)])
        let (plan, after) = planned(state)
        #expect(plan.operations == [.repoint(reference: .parent(tag: uuid(12)), from: uuid(10), to: uuid(11))])
        #expect(after.record(12).parentInstanceID == uuid(11))
    }

    @Test func aParentReachingItselfThroughATombstoneBecomesARoot() {
        let state = RepairSnapshot(metadata: [tag(10, "X", parent: 11), tag(11, "Y", mergedInto: 10)])
        let (plan, after) = planned(state)
        #expect(after.record(10).parentInstanceID == nil)
        #expect(plan.operations.count == 2)
    }

    @Test func aMissingChainEndChangesNothing() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [correspondent(10, "X", mergedInto: 99, mergedAt: planningTime)]
        )
        #expect(planned(state).plan.isEmpty)
    }

    @Test func aSharedTargetIDFollowsTheOldestLiveRecord() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [
                correspondent(10, "X", mergedInto: 50),
                correspondent(13, "A", id: 1050, mergedInto: 60),
                correspondent(12, "B", id: 1050),
                correspondent(11, "C", id: 1050),
                correspondent(60, "End"),
            ]
        )
        #expect(planned(state).after.document(1).correspondent == uuid(11))
    }

    @Test func aTombstoneTargetSharingItsIDWithALiveRecordIsLeftBehind() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [
                correspondent(10, "X", mergedInto: 50),
                correspondent(11, "Old copy", created: 1, id: 1050, mergedInto: 60),
                correspondent(12, "Live copy", created: 2, id: 1050),
                correspondent(60, "End", created: 3),
            ]
        )
        #expect(planned(state).after.document(1).correspondent == uuid(12))
    }

    @Test func aChainOfSharedIDsWithoutALiveRecordFollowsTheOldestTombstone() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [
                correspondent(10, "X", mergedInto: 50),
                correspondent(11, "Old", created: 1, id: 1050, mergedInto: 60),
                correspondent(12, "New", created: 2, id: 1050, mergedInto: 61),
                correspondent(60, "End one", created: 3),
                correspondent(61, "End two", created: 4),
            ]
        )
        #expect(planned(state).after.document(1).correspondent == uuid(60))
    }

    @Test func chainsStayWithinTheirKind() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [
                correspondent(10, "X", mergedInto: 50, mergedAt: planningTime),
                metadata(.documentType, 11, "Same id as the target", id: 1050),
            ]
        )
        #expect(planned(state).plan.isEmpty)
    }

    // MARK: Pass 2, name merge

    @Test(arguments: [MetadataKind.correspondent, .documentType, .tag])
    func sameNamesMergeIntoTheOldest(kind: MetadataKind) {
        let tagged = kind == .tag
        func reference(_ instance: Int) -> DocumentSnapshot {
            document(
                instance + 100,
                correspondent: kind == .correspondent ? instance : nil,
                type: kind == .documentType ? instance : nil,
                tags: tagged ? [instance] : []
            )
        }
        let state = RepairSnapshot(
            documents: [reference(10), reference(11), reference(12)],
            metadata: [
                metadata(kind, 10, "Stadtwerke", created: 3),
                metadata(kind, 11, " STADTWERKE", created: 1),
                metadata(kind, 12, "stadtwerke", created: 2),
            ]
        )
        let (plan, after) = planned(state)
        #expect(
            plan.operations == [
                .mergeMetadata(kind: kind, loser: uuid(12), into: uuid(11)),
                .mergeMetadata(kind: kind, loser: uuid(10), into: uuid(11)),
            ]
        )
        #expect(after.metadata.count == 3)
        #expect(after.record(11).isLive)
        #expect(after.record(10).mergedIntoID == after.record(11).id)
        #expect(after.record(10).mergedAt == planningTime)
        #expect(after.record(12).mergedIntoID == after.record(11).id)
        for instance in [110, 111, 112] {
            let moved = after.document(instance)
            #expect(moved.correspondent == (kind == .correspondent ? uuid(11) : nil))
            #expect(moved.documentType == (kind == .documentType ? uuid(11) : nil))
            #expect(moved.tags == (tagged ? [uuid(11)] : []))
        }
        #expect(after.document(110).modifiedAt == planningTime)
        #expect(after.document(111).modifiedAt == at(0), "its reference did not change")
    }

    /// Pass 2 alone: every loser goes into the group's oldest, not into its predecessor (which a later
    /// round would only fix through the repeat loop, after a refused operation).
    @Test func aGroupOfThreeMergesIntoItsMinimumInOnePass() {
        let state = RepairSnapshot(metadata: [
            correspondent(12, "Stadtwerke", created: 3), correspondent(10, "stadtwerke", created: 1),
            correspondent(11, "STADTWERKE", created: 2),
        ])
        let pass = RepairPlanner.mergeSameNames(in: state)
        #expect(
            pass.operations == [
                .mergeMetadata(kind: .correspondent, loser: uuid(11), into: uuid(10)),
                .mergeMetadata(kind: .correspondent, loser: uuid(12), into: uuid(10)),
            ]
        )
        #expect(pass.apply(to: state, now: planningTime).skipped.isEmpty)
    }

    @Test func equalDatesMergeIntoTheSmallestInstanceID() {
        let state = RepairSnapshot(metadata: [correspondent(11, "A", created: 5), correspondent(10, "a", created: 5)])
        #expect(
            planned(state).plan.operations == [.mergeMetadata(kind: .correspondent, loser: uuid(11), into: uuid(10))]
        )
    }

    @Test func differentKindsDoNotMerge() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, "Auto"), metadata(.documentType, 11, "Auto"), tag(12, "Auto"),
        ])
        #expect(planned(state).plan.isEmpty)
    }

    @Test func emptyNamesAreNeverGrouped() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, ""), correspondent(11, "  "), tag(12, ""), tag(13, " "),
        ])
        #expect(planned(state).plan.isEmpty)
    }

    @Test func aTombstoneWithTheSameNameAsALiveRecordStaysATombstone() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, "Same", mergedInto: 99, mergedAt: planningTime),
            correspondent(11, "Same"),
            correspondent(12, "Same", mergedInto: 11),
        ])
        let (plan, after) = planned(state)
        #expect(plan.isEmpty)
        #expect(!after.record(10).isLive)
    }

    @Test func recordsSharingAnIDAndANameMergeByInstanceID() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 11)],
            metadata: [correspondent(10, "A", id: 7), correspondent(11, "A", id: 7)]
        )
        let (plan, after) = planned(state)
        #expect(plan.operations == [.mergeMetadata(kind: .correspondent, loser: uuid(11), into: uuid(10))])
        #expect(after.document(1).correspondent == uuid(10))
        #expect(RepairPlanner.chainEnd(of: uuid(11), in: after) == .live(uuid(10)))
    }

    /// Ported: two identical trees created on two devices become one tree in one run.
    @Test func identicalTreesMergeInOneCall() {
        let state = RepairSnapshot(
            documents: [10, 11, 12, 20, 21, 22].map { document($0 + 100, tags: [$0]) },
            metadata: [
                tag(10, "Auto", created: 1), tag(11, "Golf", created: 1, parent: 10),
                tag(12, "Werkstatt", created: 1, parent: 11),
                tag(20, "Auto", created: 2), tag(21, "Golf", created: 2, parent: 20),
                tag(22, "Werkstatt", created: 2, parent: 21),
            ]
        )
        let (plan, after) = planned(state)
        #expect(plan.operations.count == 3)
        #expect(Set(after.metadata.filter(\.isLive).map(\.instanceID)) == [uuid(10), uuid(11), uuid(12)])
        #expect(after.record(11).parentInstanceID == uuid(10))
        #expect(after.record(12).parentInstanceID == uuid(11))
        #expect(after.documents.count == 6)
        for (original, keeper) in [(10, 10), (11, 11), (12, 12), (20, 10), (21, 11), (22, 12)] {
            #expect(after.document(original + 100).tags == [uuid(keeper)])
        }
    }

    /// Pass 2 alone, not through `plan`'s repeat loop, which would hide a pass that merges one level per
    /// call: the children of merged tags become siblings and merge in the same pass (top down).
    @Test func onePassMergesNestedDuplicatesTopDown() {
        let state = RepairSnapshot(metadata: [
            tag(10, "Auto", created: 1), tag(11, "Golf", created: 1, parent: 10),
            tag(20, "Auto", created: 2), tag(21, "Golf", created: 2, parent: 20),
        ])
        #expect(
            RepairPlanner.mergeSameNames(in: state).operations == [
                .mergeMetadata(kind: .tag, loser: uuid(20), into: uuid(10)),
                .mergeMetadata(kind: .tag, loser: uuid(21), into: uuid(11)),
            ]
        )
    }

    /// The parent is part of the tag key: an older same-name tag under another parent does not head the
    /// group of two siblings and so block their merge.
    @Test func anOlderSameNameTagUnderAnotherParentDoesNotBlockSiblings() {
        let state = RepairSnapshot(metadata: [
            tag(1, "Golf", created: 10), tag(2, "Polo", created: 11), tag(3, "Werkstatt", created: 1, parent: 2),
            tag(4, "werkstatt", created: 20, parent: 1), tag(5, "WERKSTATT", created: 21, parent: 1),
        ])
        #expect(planned(state).plan.operations == [.mergeMetadata(kind: .tag, loser: uuid(5), into: uuid(4))])
    }

    /// Ported.
    @Test func sameNameUnderDifferentParentsIsNotMerged() {
        let state = RepairSnapshot(metadata: [
            tag(1, "Golf"), tag(2, "Polo"), tag(3, "Werkstatt", parent: 1), tag(4, "werkstatt", parent: 2),
        ])
        #expect(planned(state).plan.isEmpty)
    }

    /// Ported: device 1 put A under B, device 2 put B under A′, a duplicate of A. A and A′ have different
    /// parents, so they are no group here (the predecessor's test merged them by hand).
    @Test func mergeThenRepairHasNoCycle() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 3), tag(2, "A"), tag(3, "B", parent: 2)])
        #expect(planned(state).plan.isEmpty)
    }

    /// The same two devices once A and A′ share a parent: the merge closes the cycle and pass 3 breaks it.
    @Test func aMergeThatClosesACycleIsBrokenInTheSameRun() {
        let state = RepairSnapshot(metadata: [
            tag(1, "A", parent: 4), tag(2, "A", parent: 4), tag(3, "B", parent: 2), tag(4, "P", parent: 3),
        ])
        let (plan, after) = planned(state)
        #expect(
            plan.operations == [
                .mergeMetadata(kind: .tag, loser: uuid(2), into: uuid(1)),
                .makeRoot(tag: uuid(1), expectedParent: uuid(4)),
            ]
        )
        #expect(after.record(1).parentInstanceID == nil)
        #expect(after.record(3).parentInstanceID == uuid(1))
        #expect(after.record(4).parentInstanceID == uuid(3))
    }

    /// Ported: a cycle that arrived by sync is repaired in the same run.
    @Test func mergeDuplicatesRepairsCycles() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1)])
        let after = planned(state).after
        #expect(after.record(1).parentInstanceID == nil)
        #expect(after.record(2).parentInstanceID == uuid(1))
    }

    /// The plan reviewer's case: C→P, D2→P, D1→P, D1 and D2 with the same name, D1 keeper, C a child of
    /// D2, P a child of C.
    @Test func theReviewersCase() {
        let (p, c, d1, d2) = (1, 2, 3, 4)
        let state = RepairSnapshot(metadata: [
            tag(p, "P", created: 10, parent: c), tag(c, "C", created: 11, parent: d2),
            tag(d1, "D", created: 1, parent: p), tag(d2, "D", created: 2, parent: p),
        ])
        let (plan, after) = planned(state)
        #expect(
            plan.operations == [
                .mergeMetadata(kind: .tag, loser: uuid(d2), into: uuid(d1)),
                .makeRoot(tag: uuid(d1), expectedParent: uuid(p)),
            ]
        )
        #expect(after.record(d1).parentInstanceID == nil)
        #expect(after.record(c).parentInstanceID == uuid(d1))
        #expect(after.record(p).parentInstanceID == uuid(c))
        #expect(!after.record(d2).isLive)
    }

    /// A keeper nested in its own duplicate: it moves under itself, and pass 3 makes it a root. Only
    /// pass 3 clears a parent.
    @Test func aKeeperNestedInItsDuplicateBecomesARoot() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "A", parent: 2)])
        let (plan, after) = planned(state)
        #expect(
            plan.operations == [
                .mergeMetadata(kind: .tag, loser: uuid(2), into: uuid(1)),
                .makeRoot(tag: uuid(1), expectedParent: uuid(1)),
            ]
        )
        #expect(after.record(1).parentInstanceID == nil)
        #expect(after.record(2).parentInstanceID == uuid(1), "no reference stays on the new tombstone")
    }

    @Test func aTombstoneBelowALoserMovesToTheKeeperToo() {
        let state = RepairSnapshot(metadata: [
            tag(1, "A"), tag(2, "A"), tag(3, "Old", parent: 2, mergedInto: 1),
        ])
        let after = planned(state).after
        #expect(after.record(3).parentInstanceID == uuid(1))
        #expect(RepairPlanner.plan(after, context: settledContext).isEmpty)
    }

    /// Breaking a cycle can make two tags roots of the same name; that does not wait for the next run.
    @Test func aTagFreedFromACycleMergesInTheSameRun() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1), tag(3, "a")])
        let (plan, after) = planned(state)
        #expect(
            plan.operations == [
                .makeRoot(tag: uuid(1), expectedParent: uuid(2)),
                .mergeMetadata(kind: .tag, loser: uuid(3), into: uuid(1)),
            ]
        )
        #expect(!after.record(3).isLive)
        #expect(RepairPlanner.plan(after, context: settledContext).isEmpty)
    }

    @Test func aRunReachesItsFixpoint() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10, tags: [20, 21])],
            metadata: [
                correspondent(10, "X", mergedInto: 11), correspondent(11, "Y"), correspondent(12, "y"),
                tag(20, "Auto"), tag(21, "auto"), tag(22, "Golf", parent: 21), tag(23, "golf", parent: 20),
            ],
            blobs: [blob(.file, 30, documentID: 1)]
        )
        let after = planned(state).after
        #expect(RepairPlanner.plan(after, context: settledContext).isEmpty, "I7")
    }

    // MARK: Pass 3, cycles

    /// Ported.
    @Test func repairsCycleDeterministically() {
        let state = RepairSnapshot(metadata: [
            tag(1, "A", created: 1000, parent: 2), tag(2, "B", created: 2000, parent: 1),
        ])
        let (plan, after) = planned(state)
        #expect(plan.operations == [.makeRoot(tag: uuid(1), expectedParent: uuid(2))])
        #expect(after.record(1).parentInstanceID == nil)
        #expect(after.record(2).parentInstanceID == uuid(1))
    }

    /// Ported.
    @Test func repairWithEqualDatesPicksTheLowerID() {
        let state = RepairSnapshot(metadata: [
            tag(1, "X", created: 1000, parent: 2), tag(2, "Y", created: 1000, parent: 1),
        ])
        #expect(planned(state).plan.operations == [.makeRoot(tag: uuid(1), expectedParent: uuid(2))])
    }

    /// Ported.
    @Test func repairWithoutCycleChangesNothing() {
        let state = RepairSnapshot(metadata: [tag(1, "A"), tag(2, "B", parent: 1), tag(3, "C", parent: 2)])
        #expect(planned(state).plan.isEmpty)
    }

    @Test func aLongerCycleAndATailBreakOnceAtTheOldest() {
        let state = RepairSnapshot(metadata: [
            tag(1, "Tail", created: 1, parent: 2), tag(2, "A", created: 5, parent: 3),
            tag(3, "B", created: 3, parent: 4), tag(4, "C", created: 4, parent: 2),
        ])
        #expect(planned(state).plan.operations == [.makeRoot(tag: uuid(3), expectedParent: uuid(4))])
    }

    @Test func everyCycleIsBroken() {
        let state = RepairSnapshot(metadata: [
            tag(1, "A", parent: 2), tag(2, "B", parent: 1), tag(3, "C", parent: 4), tag(4, "D", parent: 3),
            tag(5, "Self", parent: 5),
        ])
        #expect(
            planned(state).plan.operations == [
                .makeRoot(tag: uuid(1), expectedParent: uuid(2)),
                .makeRoot(tag: uuid(3), expectedParent: uuid(4)),
                .makeRoot(tag: uuid(5), expectedParent: uuid(5)),
            ]
        )
    }

    /// Pass 3 alone, not through `plan`'s repeat loop, which would hide a pass that breaks one cycle per call.
    @Test func onePassBreaksEveryCycle() {
        let state = RepairSnapshot(metadata: [
            tag(1, "A", parent: 2), tag(2, "B", parent: 1), tag(3, "C", parent: 4), tag(4, "D", parent: 3),
        ])
        #expect(
            RepairPlanner.breakCycles(in: state).operations == [
                .makeRoot(tag: uuid(1), expectedParent: uuid(2)),
                .makeRoot(tag: uuid(3), expectedParent: uuid(4)),
            ]
        )
    }

    @Test func aCycleThroughATombstoneIsNotACycle() {
        let state = RepairSnapshot(metadata: [
            tag(1, "A", parent: 2),
            tag(2, "B", parent: 1, mergedInto: 99, mergedAt: planningTime),
        ])
        let (plan, after) = planned(state)
        #expect(plan.isEmpty)
        #expect(after.record(1).parentInstanceID == uuid(2))
    }

    // MARK: Pass 4, blobs

    @Test(arguments: BlobKind.allCases)
    func aBlobThatArrivedEarlyIsRelinked(kind: BlobKind) {
        let state = RepairSnapshot(documents: [document(1)], blobs: [blob(kind, 2, documentID: 1)])
        let (plan, after) = planned(state)
        #expect(plan.operations == [.relink(blob: uuid(2), to: uuid(1))])
        #expect(after.blob(2).linkedDocumentInstanceID == uuid(1))
    }

    @Test func aFileAndAThumbnailDoNotCompete() {
        let state = RepairSnapshot(
            documents: [document(1)],
            blobs: [blob(.file, 2, documentID: 1), blob(.thumbnail, 3, documentID: 1)]
        )
        #expect(planned(state).plan.operations.count == 2)
    }

    @Test func twoCandidatesLinkTheOldest() {
        let state = RepairSnapshot(
            documents: [document(1)],
            blobs: [blob(.file, 2, created: 9, documentID: 1), blob(.file, 3, created: 5, documentID: 1)]
        )
        let (plan, after) = planned(state)
        #expect(plan.operations == [.relink(blob: uuid(3), to: uuid(1))])
        #expect(after.blob(2).linkedDocumentInstanceID == nil)
        #expect(RepairPlanner.counts(in: after).documentsWithTwoFiles == 1)
    }

    @Test func twoCandidatesWithEqualDatesLinkTheSmallestInstanceID() {
        let state = RepairSnapshot(
            documents: [document(1)],
            blobs: [blob(.file, 3, created: 5, documentID: 1), blob(.file, 2, created: 5, documentID: 1)]
        )
        #expect(planned(state).plan.operations == [.relink(blob: uuid(2), to: uuid(1))])
    }

    /// A kind the document row says is linked (`linkedBlobs`, the store's light snapshot) counts like a listed
    /// linked blob: no relink onto it, and the unlinked candidate is counted as a second one.
    @Test(arguments: BlobKind.allCases)
    func aDocumentWithAnUnlistedLinkedBlobGetsNoSecond(kind: BlobKind) {
        let state = RepairSnapshot(
            documents: [document(1, linkedBlobs: [kind])],
            blobs: [blob(kind, 3, documentID: 1)]
        )
        let (plan, after) = planned(state)
        #expect(plan.isEmpty)
        #expect(after.blob(3).linkedDocumentInstanceID == nil)
        let counts = RepairPlanner.counts(in: after)
        let doubles: [Int] = [
            counts.documentsWithTwoFiles, counts.documentsWithTwoThumbnails, counts.documentsWithTwoTexts,
        ]
        let expected: [Int] = BlobKind.allCases.map { $0 == kind ? 1 : 0 }
        #expect(doubles == expected)
    }

    /// Another kind in `linkedBlobs` does not block a relink.
    @Test func anUnlistedLinkedFileDoesNotBlockTheText() {
        let state = RepairSnapshot(
            documents: [document(1, linkedBlobs: [.file, .thumbnail])],
            blobs: [blob(.text, 3, documentID: 1)]
        )
        #expect(planned(state).plan.operations == [.relink(blob: uuid(3), to: uuid(1))])
    }

    @Test func aDocumentWithABlobGetsNoSecond() {
        let state = RepairSnapshot(
            documents: [document(1)],
            blobs: [blob(.file, 2, documentID: 1, linkedTo: 1), blob(.file, 3, documentID: 1)]
        )
        let (plan, after) = planned(state)
        #expect(plan.isEmpty)
        #expect(after.blob(3).linkedDocumentInstanceID == nil)
    }

    @Test func documentsSharingAnIDAreServedOldestFirst() {
        let state = RepairSnapshot(
            documents: [
                document(1, id: 1050, created: 8), document(2, id: 1050, created: 7), document(3, id: 1050, created: 9),
            ],
            blobs: [
                blob(.file, 10, created: 2, documentID: 50),
                blob(.file, 11, created: 1, documentID: 50),
                blob(.file, 12, created: 3, documentID: 50, linkedTo: 3),
            ]
        )
        #expect(
            planned(state).plan.operations == [
                .relink(blob: uuid(11), to: uuid(2)),
                .relink(blob: uuid(10), to: uuid(1)),
            ]
        )
    }

    @Test func orphansAndDoublesStayUntouched() {
        let state = RepairSnapshot(
            documents: [document(1)],
            blobs: [
                blob(.file, 2, documentID: 99),
                blob(.thumbnail, 3, documentID: nil),
                blob(.file, 4, documentID: 1, linkedTo: 1),
                blob(.file, 5, documentID: 1, linkedTo: 1),
            ]
        )
        let (plan, after) = planned(state)
        #expect(plan.isEmpty)
        #expect(after == state)
    }

    // MARK: Pass 5, revive

    private func missingEnd(mergedDaysAgo age: Int) -> RepairSnapshot {
        RepairSnapshot(metadata: [
            correspondent(10, "X", mergedInto: 99, mergedAt: planningTime.addingTimeInterval(TimeInterval(-age * days)))
        ])
    }

    @Test func noReviveBeforeThirtyDays() {
        #expect(planned(missingEnd(mergedDaysAgo: 29)).plan.isEmpty)
    }

    @Test func noReviveWithoutACompletedImport() {
        let context = RepairContext(now: planningTime, hasCompletedImport: false)
        #expect(planned(missingEnd(mergedDaysAgo: 400), context: context).plan.isEmpty)
    }

    @Test(arguments: [30, 400])
    func aMissingEndRevivesAfterThirtyDaysAndAnImport(age: Int) {
        let (plan, after) = planned(missingEnd(mergedDaysAgo: age))
        #expect(plan.operations == [.revive(tombstone: uuid(10))])
        #expect(after.record(10).isLive)
        #expect(after.record(10).mergedAt == nil)
    }

    /// The grace is read from the chain's last tombstone, the one that would be revived.
    @Test func theGraceIsReadFromTheLastTombstoneOfTheChain() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, "X", mergedInto: 11, mergedAt: planningTime - TimeInterval(400 * days)),
            correspondent(11, "Y", mergedInto: 99, mergedAt: planningTime - TimeInterval(1 * days)),
        ])
        #expect(planned(state).plan.isEmpty)
    }

    @Test func aTombstoneWithoutAMergeDateIsNotRevived() {
        var state = missingEnd(mergedDaysAgo: 400)
        state.metadata[0].mergedAt = nil
        #expect(planned(state).plan.isEmpty)
    }

    @Test func onlyTheLastTombstoneOfAMissingChainIsRevivedAndTheOthersFollow() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [correspondent(10, "X", mergedInto: 11), correspondent(11, "Y", mergedInto: 99)]
        )
        let (plan, after) = planned(state)
        #expect(plan.operations == [.revive(tombstone: uuid(11))])
        let next = planned(after).after
        #expect(next.document(1).correspondent == uuid(11), "the next run re-points")
        #expect(!next.record(10).isLive)
        #expect(RepairPlanner.plan(next, context: settledContext).isEmpty)
    }

    /// A merge always goes into another record, so a tombstone naming its own `id` waits for a record that
    /// shares that `id` and is not here: a missing end, not a loop.
    @Test func aTombstoneNamingItsOwnIDIsAMissingEnd() {
        let recent = RepairSnapshot(metadata: [
            correspondent(10, "X", id: 1099, mergedInto: 99, mergedAt: planningTime)
        ])
        #expect(RepairPlanner.chainEnd(of: uuid(10), in: recent) == .missing(lastTombstone: uuid(10)))
        #expect(planned(recent).plan.isEmpty)
        let old = RepairSnapshot(metadata: [correspondent(10, "X", id: 1099, mergedInto: 99)])
        #expect(planned(old).plan.operations == [.revive(tombstone: uuid(10))])
    }

    @Test func aLoopRevivesItsMinimumAtOnceAndTheNextRunRepoints() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 11)],
            metadata: [
                correspondent(10, "X", created: 5, mergedInto: 11, mergedAt: planningTime),
                correspondent(11, "Y", created: 6, mergedInto: 12, mergedAt: planningTime),
                correspondent(12, "Z", created: 7, mergedInto: 10, mergedAt: planningTime),
            ]
        )
        #expect(RepairPlanner.repointReferences(in: state).isEmpty, "pass 1 leaves a loop to pass 5")
        let context = RepairContext(now: planningTime, hasCompletedImport: false)
        let (plan, after) = planned(state, context: context)
        #expect(plan.operations == [.revive(tombstone: uuid(10))], "needs neither 30 days nor an import")
        let next = planned(after, context: context)
        #expect(next.after.document(1).correspondent == uuid(10))
        #expect(next.after.record(11).mergedIntoID == uuid(1012), "only the minimum changes state")
    }

    @Test func aChainRunningIntoALoopRevivesOnlyTheLoopsMinimum() {
        let state = RepairSnapshot(metadata: [
            correspondent(9, "Tail", created: 1, mergedInto: 10, mergedAt: planningTime),
            correspondent(10, "X", created: 5, mergedInto: 11, mergedAt: planningTime),
            correspondent(11, "Y", created: 6, mergedInto: 10, mergedAt: planningTime),
        ])
        #expect(planned(state).plan.operations == [.revive(tombstone: uuid(10))])
    }

    @Test func aRevivedRecordAndASameNameLiveRecordMergeOnTheNextRun() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, "Same", created: 5, mergedInto: 99), correspondent(11, "same", created: 1),
        ])
        let first = planned(state)
        #expect(first.plan.operations == [.revive(tombstone: uuid(10))])
        let second = planned(first.after)
        #expect(second.plan.operations == [.mergeMetadata(kind: .correspondent, loser: uuid(10), into: uuid(11))])
        #expect(RepairPlanner.plan(second.after, context: settledContext).isEmpty)
    }

    // MARK: Counts

    @Test func countsAreCounted() {
        let state = RepairSnapshot(
            documents: [
                document(1), document(2), document(3, id: 1001), document(4), document(5, linkedBlobs: [.text]),
                document(6, linkedBlobs: [.text]),
            ],
            metadata: [
                correspondent(10, "A", id: 7), correspondent(11, "B", id: 7),
                tag(12, "C", id: 8), tag(13, "D", id: 8, mergedInto: 99),
                tag(14, "Different kinds do not share a group", id: 7),
                tag(15, "E", mergedInto: 12),
            ],
            blobs: [
                blob(.file, 20, documentID: 99),
                blob(.file, 21, documentID: nil),
                blob(.thumbnail, 22, documentID: 98),
                blob(.file, 23, documentID: 2, linkedTo: 2),
                blob(.file, 24, documentID: 2, linkedTo: 2),
                blob(.thumbnail, 25, documentID: 4, linkedTo: 4),
                blob(.thumbnail, 26, documentID: 4),
                // Two thumbnails for document 2 too, so the two kinds count differently.
                blob(.thumbnail, 27, documentID: 2, linkedTo: 2),
                blob(.thumbnail, 28, documentID: 2, linkedTo: 2),
                // Texts: one orphan; document 5 holds an unlisted linked text and has an unlinked one.
                blob(.text, 30, documentID: 97),
                blob(.text, 31, documentID: 5),
                // Document 6's unlisted linked text alone is one text, not two.
                blob(.file, 32, documentID: 6),
                // A second orphan thumbnail, so orphan texts and thumbnails differ.
                blob(.thumbnail, 33, documentID: 96),
            ]
        )
        var expected = RepairCounts()
        expected.orphanFiles = 2
        expected.orphanThumbnails = 2
        expected.documentsWithTwoFiles = 1
        expected.documentsWithTwoThumbnails = 2
        expected.orphanTexts = 1
        expected.documentsWithTwoTexts = 1
        expected.idGroupsWithSeveralRecords = 3
        expected.tombstones = 2
        #expect(RepairPlanner.counts(in: state) == expected)
    }

    @Test func aLinkedBlobIsNoOrphanWhateverItsDocumentID() {
        let state = RepairSnapshot(documents: [document(1)], blobs: [blob(.file, 2, documentID: 99, linkedTo: 1)])
        #expect(RepairPlanner.counts(in: state) == RepairCounts())
    }

    // MARK: Applying (the preconditions of I6)

    private let chained = RepairSnapshot(
        documents: [document(1, correspondent: 10)],
        metadata: [correspondent(10, "X", mergedInto: 11), correspondent(11, "W"), correspondent(12, "Other")]
    )

    @Test func aUserEditBetweenPlanAndSaveSkipsARepoint() {
        let plan = RepairPlanner.plan(chained, context: settledContext)
        var edited = chained
        edited.documents[0].correspondent = uuid(12)
        let application = plan.apply(to: edited, now: planningTime)
        #expect(application.applied.isEmpty)
        #expect(application.skipped == plan.operations)
        #expect(application.snapshot == edited)
    }

    @Test func aRepointSkipsWhenItsTargetIsNoLongerLive() {
        let plan = RepairPlanner.plan(chained, context: settledContext)
        var changed = chained
        changed.metadata[1].mergedIntoID = uuid(1012)
        #expect(plan.apply(to: changed, now: planningTime).applied.isEmpty)
    }

    @Test func aRepointSkipsWhenItsSourceWasRevived() {
        let plan = RepairPlanner.plan(chained, context: settledContext)
        var changed = chained
        changed.metadata[0].mergedIntoID = nil
        #expect(plan.apply(to: changed, now: planningTime).applied.isEmpty)
    }

    @Test func aRepointNeverCrossesKinds() {
        let state = RepairSnapshot(
            documents: [document(1, correspondent: 10)],
            metadata: [correspondent(10, "X", mergedInto: 99), tag(11, "W")]
        )
        let plan = RepairPlan([.repoint(reference: .correspondent(document: uuid(1)), from: uuid(10), to: uuid(11))])
        #expect(plan.apply(to: state, now: planningTime).applied.isEmpty)
    }

    @Test func aMergeSkipsWhenARecordIsNoLongerLiveOrItsNameChanged() {
        let state = RepairSnapshot(metadata: [correspondent(10, "A"), correspondent(11, "a")])
        let plan = RepairPlanner.plan(state, context: settledContext)
        #expect(plan.operations.count == 1)

        var keeperGone = state
        keeperGone.metadata[0].mergedIntoID = uuid(99)
        #expect(plan.apply(to: keeperGone, now: planningTime).applied.isEmpty)

        var loserGone = state
        loserGone.metadata[1].mergedIntoID = uuid(99)
        #expect(plan.apply(to: loserGone, now: planningTime).applied.isEmpty)

        var renamed = state
        renamed.metadata[1].name = "Renamed"
        #expect(plan.apply(to: renamed, now: planningTime).applied.isEmpty)

        #expect(plan.apply(to: RepairSnapshot(metadata: [state.metadata[0]]), now: planningTime).applied.isEmpty)
    }

    @Test func aTagMergeSkipsWhenAParentChanged() {
        let state = RepairSnapshot(metadata: [tag(10, "A"), tag(11, "a"), tag(12, "P")])
        let plan = RepairPlanner.plan(state, context: settledContext)
        var moved = state
        moved.metadata[1].parentInstanceID = uuid(12)
        #expect(plan.apply(to: moved, now: planningTime).applied.isEmpty)
    }

    @Test func aMakeRootSkipsWhenTheUserMovedTheTag() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1), tag(3, "C")])
        let plan = RepairPlanner.plan(state, context: settledContext)
        var moved = state
        moved.metadata[0].parentInstanceID = uuid(3)
        let application = plan.apply(to: moved, now: planningTime)
        #expect(application.applied.isEmpty)
        #expect(application.snapshot.record(1).parentInstanceID == uuid(3))
    }

    @Test func aMakeRootSkipsWhenTheTagIsNoLongerLive() {
        let state = RepairSnapshot(metadata: [tag(1, "A", parent: 2), tag(2, "B", parent: 1)])
        let plan = RepairPlanner.plan(state, context: settledContext)
        #expect(plan.operations == [.makeRoot(tag: uuid(1), expectedParent: uuid(2))])
        var merged = state
        merged.metadata[0].mergedIntoID = uuid(99)
        merged.metadata[0].mergedAt = planningTime
        let application = plan.apply(to: merged, now: planningTime)
        #expect(application.applied.isEmpty)
        #expect(application.snapshot.record(1).parentInstanceID == uuid(2))
    }

    @Test func aRelinkSkipsWhenTheDocumentGotABlobOrTheBlobGotALink() {
        let state = RepairSnapshot(
            documents: [document(1), document(2)],
            blobs: [blob(.file, 3, documentID: 1)]
        )
        let plan = RepairPlanner.plan(state, context: settledContext)
        var taken = state
        taken.blobs.append(blob(.file, 4, documentID: 1, linkedTo: 1))
        #expect(plan.apply(to: taken, now: planningTime).applied.isEmpty)
        var linked = state
        linked.blobs[0].linkedDocumentInstanceID = uuid(2)
        #expect(plan.apply(to: linked, now: planningTime).applied.isEmpty)
        #expect(RepairPlan([.relink(blob: uuid(3), to: uuid(2))]).apply(to: state, now: planningTime).applied.isEmpty)
        var linkedInTheRow = state
        linkedInTheRow.documents[0].linkedBlobs = [.file]
        #expect(plan.apply(to: linkedInTheRow, now: planningTime).applied.isEmpty, "the row says it has a file")
    }

    @Test func aReviveSkipsARecordThatIsLiveAgain() {
        let state = RepairSnapshot(metadata: [correspondent(10, "X")])
        #expect(RepairPlan([.revive(tombstone: uuid(10))]).apply(to: state, now: planningTime).applied.isEmpty)
    }

    /// I6 for a revival: an import brings the missing chain end between plan and save.
    @Test func aReviveSkipsWhenTheChainEndArrivedBeforeTheSave() {
        let state = RepairSnapshot(metadata: [
            correspondent(2, "Stadtwerke", mergedInto: 1, mergedAt: planningTime - TimeInterval(400 * days))
        ])
        let plan = RepairPlanner.plan(state, context: settledContext)
        #expect(plan.operations == [.revive(tombstone: uuid(2))])
        var arrived = state
        arrived.metadata.append(correspondent(1, "Stadtwerke"))
        let application = plan.apply(to: arrived, now: planningTime)
        #expect(application.applied.isEmpty)
        #expect(!application.snapshot.record(2).isLive)
    }

    /// I6 for a revival: an import re-routes the loop through an older record, which is now its minimum.
    @Test func aReviveSkipsWhenTheLoopGotAnOlderMemberBeforeTheSave() {
        let state = RepairSnapshot(metadata: [
            correspondent(11, "X", created: 6, mergedInto: 12, mergedAt: planningTime),
            correspondent(12, "Y", created: 7, mergedInto: 11, mergedAt: planningTime),
        ])
        let plan = RepairPlanner.plan(state, context: settledContext)
        #expect(plan.operations == [.revive(tombstone: uuid(11))])
        var rerouted = state
        rerouted.metadata[1].mergedIntoID = uuid(1010)
        rerouted.metadata.append(correspondent(10, "Z", created: 5, mergedInto: 11, mergedAt: planningTime))
        #expect(RepairPlanner.chainEnd(of: uuid(11), in: rerouted) == .loop(minimum: uuid(10)))
        let application = plan.apply(to: rerouted, now: planningTime)
        #expect(application.applied.isEmpty)
        #expect(!application.snapshot.record(11).isLive)
    }

    /// I6 for a revival: the missing end arrives as a tombstone, so the planned record is no longer the last.
    @Test func aReviveSkipsWhenTheChainGrewBeforeTheSave() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, "X", mergedInto: 11, mergedAt: planningTime - TimeInterval(400 * days))
        ])
        let plan = RepairPlanner.plan(state, context: settledContext)
        #expect(plan.operations == [.revive(tombstone: uuid(10))])
        var grown = state
        grown.metadata.append(correspondent(11, "Y", mergedInto: 99, mergedAt: planningTime - TimeInterval(400 * days)))
        let application = plan.apply(to: grown, now: planningTime)
        #expect(application.applied.isEmpty)
        #expect(!application.snapshot.record(10).isLive)
    }

    /// A revival planned on a view where 10 was still the chain's last applies nothing where 11 is here too.
    @Test func aReviveOfATombstoneThatIsNotTheChainsLastAppliesNothing() {
        let state = RepairSnapshot(metadata: [
            correspondent(10, "X", mergedInto: 11, mergedAt: planningTime - TimeInterval(400 * days)),
            correspondent(11, "Y", mergedInto: 99, mergedAt: planningTime - TimeInterval(400 * days)),
        ])
        #expect(RepairPlan([.revive(tombstone: uuid(10))]).apply(to: state, now: planningTime).applied.isEmpty)
    }

    @Test func frozenValuesPassThroughAPlanUnchanged() {
        var state = chained
        state.documents[0].sourceRaw = "fax"
        state.documents[0].processingStateRaw = "queued"
        state.documents[0].textSourceRaw = "braille"
        let moved = planned(state).after.document(1)
        #expect(moved.correspondent == uuid(11))
        #expect(moved.sourceRaw == "fax")
        #expect(moved.processingStateRaw == "queued")
        #expect(moved.textSourceRaw == "braille")
    }
}
