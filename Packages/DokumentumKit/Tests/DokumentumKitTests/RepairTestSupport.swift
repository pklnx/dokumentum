import DokumentumKit
import Foundation
import Testing

/// A readable, fixed UUID: its `uuidString` sorts by `n`.
func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
}

/// Seconds, so that test dates read as an order.
func at(_ seconds: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds))
}

let days = 24 * 60 * 60

/// The time of every planned run: after the dates tests use.
let planningTime = at(1000 * days)
let settledContext = RepairContext(now: planningTime, hasCompletedImport: true)

/// Metadata whose `id` is `instance + 1000`, unless a test wants them to share one.
func metadata(
    _ kind: MetadataKind,
    _ instance: Int,
    _ name: String,
    created: Int? = nil,
    id: Int? = nil,
    parent: Int? = nil,
    mergedInto: Int? = nil,
    mergedAt: Date? = nil
) -> MetadataSnapshot {
    MetadataSnapshot(
        kind: kind,
        instanceID: uuid(instance),
        id: uuid(id ?? instance + 1000),
        createdAt: at(created ?? instance),
        mergedAt: mergedAt ?? (mergedInto == nil ? nil : at(0)),
        name: name,
        parentInstanceID: parent.map(uuid),
        mergedIntoID: mergedInto.map { uuid($0 + 1000) }
    )
}

func tag(
    _ instance: Int,
    _ name: String,
    created: Int? = nil,
    id: Int? = nil,
    parent: Int? = nil,
    mergedInto: Int? = nil,
    mergedAt: Date? = nil
) -> MetadataSnapshot {
    metadata(
        .tag,
        instance,
        name,
        created: created,
        id: id,
        parent: parent,
        mergedInto: mergedInto,
        mergedAt: mergedAt
    )
}

func correspondent(
    _ instance: Int,
    _ name: String,
    created: Int? = nil,
    id: Int? = nil,
    mergedInto: Int? = nil,
    mergedAt: Date? = nil
) -> MetadataSnapshot {
    metadata(.correspondent, instance, name, created: created, id: id, mergedInto: mergedInto, mergedAt: mergedAt)
}

func document(
    _ instance: Int,
    id: Int? = nil,
    created: Int? = nil,
    modified: Int = 0,
    correspondent: Int? = nil,
    type: Int? = nil,
    tags: [Int] = []
) -> DocumentSnapshot {
    DocumentSnapshot(
        instanceID: uuid(instance),
        id: uuid(id ?? instance + 1000),
        createdAt: at(created ?? instance),
        modifiedAt: at(modified),
        correspondent: correspondent.map(uuid),
        documentType: type.map(uuid),
        tags: Set(tags.map(uuid))
    )
}

func blob(
    _ kind: BlobKind,
    _ instance: Int,
    created: Int? = nil,
    documentID: Int?,
    linkedTo: Int? = nil
) -> BlobSnapshot {
    BlobSnapshot(
        kind: kind,
        instanceID: uuid(instance),
        createdAt: at(created ?? instance),
        documentID: documentID.map { uuid($0 + 1000) },
        linkedDocumentInstanceID: linkedTo.map(uuid)
    )
}

/// A small generator with the same sequence on every platform (`SystemRandomNumberGenerator` has none).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard let first = items.first else { return [[]] }
    return permutations(Array(items.dropFirst())).flatMap { rest in
        (0...rest.count).map { position in
            var result = rest
            result.insert(first, at: position)
            return result
        }
    }
}

/// The input in other orders: all permutations if there are at most 720, or else 50 seeded shuffles.
func reorderings(of snapshot: RepairSnapshot) -> [RepairSnapshot] {
    func factorial(_ n: Int) -> Int { n <= 1 ? 1 : (2...n).reduce(1, *) }
    let counts = [snapshot.documents.count, snapshot.metadata.count, snapshot.blobs.count]
    if counts.allSatisfy({ $0 <= 6 }), counts.map(factorial).reduce(1, *) <= 720 {
        return permutations(snapshot.documents).flatMap { documents in
            permutations(snapshot.metadata).flatMap { metadata in
                permutations(snapshot.blobs).map { blobs in
                    RepairSnapshot(documents: documents, metadata: metadata, blobs: blobs)
                }
            }
        }
    }
    return (0..<50).map { seed in
        var generator = SeededGenerator(seed: seed)
        return RepairSnapshot(
            documents: snapshot.documents.shuffled(using: &generator),
            metadata: snapshot.metadata.shuffled(using: &generator),
            blobs: snapshot.blobs.shuffled(using: &generator)
        )
    }
}

/// A planned run with every standard check: the plan is the same for every input order, nothing it
/// plans is skipped, and the invariants hold.
func planned(
    _ snapshot: RepairSnapshot,
    context: RepairContext = settledContext,
    sourceLocation: SourceLocation = #_sourceLocation
) -> (plan: RepairPlan, after: RepairSnapshot) {
    let plan = RepairPlanner.plan(snapshot, context: context)
    for reordered in reorderings(of: snapshot) {
        let other = RepairPlanner.plan(reordered, context: context)
        #expect(other == plan, "the input order changed the plan", sourceLocation: sourceLocation)
        if other != plan { break }
    }
    let application = plan.apply(to: snapshot, now: context.now)
    #expect(application.skipped.isEmpty, sourceLocation: sourceLocation)
    let violations = RepairInvariants.violations(before: snapshot, plan: plan, after: application.snapshot)
    #expect(violations.isEmpty, "\(violations)", sourceLocation: sourceLocation)
    return (plan, application.snapshot)
}

extension RepairSnapshot {
    func record(_ instance: Int) -> MetadataSnapshot {
        metadata.first { $0.instanceID == uuid(instance) }!
    }

    func document(_ instance: Int) -> DocumentSnapshot {
        documents.first { $0.instanceID == uuid(instance) }!
    }

    func blob(_ instance: Int) -> BlobSnapshot {
        blobs.first { $0.instanceID == uuid(instance) }!
    }

    /// Runs the planner until it plans nothing; `nil` if that takes more than `limit` runs.
    func settled(context: RepairContext = settledContext, runs limit: Int = 20) -> RepairSnapshot? {
        var state = self
        for _ in 0..<limit {
            let plan = RepairPlanner.plan(state, context: context)
            if plan.isEmpty { return state }
            state = plan.apply(to: state, now: context.now).snapshot
        }
        return nil
    }
}

/// An exhaustive switch without `default`: a new operation, a delete for one, does not compile until a
/// person looked at this list.
func namesARepairOperation(_ operation: RepairOperation) -> String {
    switch operation {
    case .repoint: "repoint"
    case .mergeMetadata: "mergeMetadata"
    case .makeRoot: "makeRoot"
    case .relink: "relink"
    case .revive: "revive"
    }
}

/// What must hold after plans made on different views were applied to the whole data, in the given order.
func checkedUnion(
    of union: RepairSnapshot,
    plans: [RepairPlan],
    context: RepairContext = settledContext,
    sourceLocation: SourceLocation = #_sourceLocation
) -> RepairSnapshot {
    var state = union
    for plan in plans {
        let application = plan.apply(to: state, now: context.now)
        let violations = RepairInvariants.violations(
            before: state,
            plan: RepairPlan(application.applied),
            after: application.snapshot,
            plannedOnBefore: false
        )
        #expect(violations.isEmpty, "\(violations)", sourceLocation: sourceLocation)
        state = application.snapshot
    }

    // No record or blob vanishes.
    func records(_ snapshot: RepairSnapshot) -> [Set<UUID>] {
        [
            Set(snapshot.documents.map(\.instanceID)),
            Set(snapshot.metadata.map(\.instanceID)),
            Set(snapshot.blobs.map(\.instanceID)),
        ]
    }
    #expect(records(state) == records(union), sourceLocation: sourceLocation)

    // Every name group keeps a live member.
    for kind in MetadataKind.allCases {
        func liveNames(_ snapshot: RepairSnapshot) -> Set<String> {
            Set(
                snapshot.metadata.filter { $0.kind == kind && $0.isLive }
                    .map { MetadataName.normalized($0.name) }
                    .filter { !$0.isEmpty }
            )
        }
        let lost = liveNames(union).subtracting(liveNames(state))
        #expect(lost.isEmpty, "\(kind) names without a live member: \(lost)", sourceLocation: sourceLocation)
    }

    // After re-pointing, every reference resolves to a live record or a tombstone still waiting under pass 5.
    let repointed = RepairPlanner.repointReferences(in: state).apply(to: state, now: context.now).snapshot
    func expectResolved(_ reference: UUID, _ holder: String) {
        guard let record = repointed.metadata.first(where: { $0.instanceID == reference }) else {
            Issue.record("\(holder) refers to an absent record \(reference)", sourceLocation: sourceLocation)
            return
        }
        if record.isLive { return }
        switch RepairPlanner.chainEnd(of: reference, in: repointed) {
        case .missing, .loop: break
        case .live, nil:
            Issue.record("\(holder) still refers to tombstone \(reference)", sourceLocation: sourceLocation)
        }
    }
    for document in repointed.documents {
        for reference in [document.correspondent, document.documentType].compactMap(\.self) + Array(document.tags) {
            expectResolved(reference, "document \(document.instanceID)")
        }
    }
    for tag in repointed.metadata {
        if let parent = tag.parentInstanceID { expectResolved(parent, "tag \(tag.instanceID)") }
    }
    return state
}

/// What a device that has not received everything sees: references to what it lacks are simply not there.
func view(
    of state: RepairSnapshot,
    droppingMetadata droppedMetadata: Set<Int> = [],
    documents droppedDocuments: Set<Int> = [],
    blobs droppedBlobs: Set<Int> = []
) -> RepairSnapshot {
    let metadata = Set(droppedMetadata.map(uuid))
    let documents = Set(droppedDocuments.map(uuid))
    let blobs = Set(droppedBlobs.map(uuid))
    return view(of: state, droppingMetadata: metadata, documents: documents, blobs: blobs)
}

func view(
    of state: RepairSnapshot,
    droppingMetadata metadata: Set<UUID>,
    documents: Set<UUID>,
    blobs: Set<UUID>
) -> RepairSnapshot {
    func kept(_ reference: UUID?) -> UUID? {
        reference.flatMap { metadata.contains($0) ? nil : $0 }
    }
    var result = state
    result.metadata.removeAll { metadata.contains($0.instanceID) }
    result.documents.removeAll { documents.contains($0.instanceID) }
    result.blobs.removeAll { blobs.contains($0.instanceID) }
    for index in result.metadata.indices {
        result.metadata[index].parentInstanceID = kept(result.metadata[index].parentInstanceID)
    }
    for index in result.documents.indices {
        result.documents[index].correspondent = kept(result.documents[index].correspondent)
        result.documents[index].documentType = kept(result.documents[index].documentType)
        result.documents[index].tags.subtract(metadata)
    }
    for index in result.blobs.indices {
        if let link = result.blobs[index].linkedDocumentInstanceID, documents.contains(link) {
            result.blobs[index].linkedDocumentInstanceID = nil
        }
    }
    return result
}
