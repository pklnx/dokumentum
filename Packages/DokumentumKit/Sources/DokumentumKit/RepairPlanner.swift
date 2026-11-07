import Foundation

/// Where a tombstone's `mergedIntoID` chain ends.
public enum RepairChainEnd: Hashable, Sendable {
    /// At a live record present on this device.
    case live(UUID)
    /// The last tombstone of the chain names a record that is not here (still downloading, or deleted).
    case missing(lastTombstone: UUID)
    /// The chain runs in a circle; `minimum` is the circle's `keeperOrder` minimum.
    case loop(minimum: UUID)
}

/// Counted for diagnostics; nothing acts on them in #2.
public struct RepairCounts: Hashable, Sendable {
    /// Unlinked, and no present document has their `documentID`.
    public var orphanFiles = 0
    public var orphanThumbnails = 0
    /// Documents that two or more files claim: linked to it, or unlinked with its `id` as `documentID`.
    public var documentsWithTwoFiles = 0
    public var documentsWithTwoThumbnails = 0
    /// `id`s held by more than one document, or by more than one metadata record of one kind.
    public var idGroupsWithSeveralRecords = 0
    public var tombstones = 0

    public init() {}
}

/// Decides what a repair changes. Pure functions over snapshots: the SwiftData layer collects the
/// snapshots, asks here, and applies the result (plan of #2, "Repair passes"; invariants in
/// `RepairInvariants`).
///
/// The result never depends on the order of the input and winners depend only on `createdAt` and
/// `instanceID`, so every device that sees the same records plans the same operations.
public enum RepairPlanner {
    /// A tombstone whose chain end is missing is revived only this long after the merge.
    public static let reviveGrace: TimeInterval = 30 * 24 * 60 * 60

    // MARK: A run

    /// One run: pass 1 re-point, pass 2 name merge, pass 3 cycles, pass 4 blobs, pass 5 revive, each
    /// planned on the result of the one before.
    ///
    /// Passes 2 and 3 repeat until neither plans anything, because breaking a cycle can make two tags
    /// siblings of the same name. So a run that revives nothing leaves nothing for the next run (I7). A
    /// revived record is handled by the next run, which the save of this one triggers.
    public static func plan(_ snapshot: RepairSnapshot, context: RepairContext) -> RepairPlan {
        var state = snapshot
        var operations: [RepairOperation] = []
        // Only what applies goes into the plan, and only that counts as a change, so the loop below ends
        // even if a pass ever planned something its own precondition refuses.
        func run(_ pass: RepairPlan) -> Bool {
            let application = pass.apply(to: state, now: context.now)
            state = application.snapshot
            operations += application.applied
            return !application.applied.isEmpty
        }

        _ = run(repointReferences(in: state))
        var changed = true
        while changed {
            let merged = run(mergeSameNames(in: state))
            let broken = run(breakCycles(in: state))
            changed = merged || broken
        }
        _ = run(relinkBlobs(in: state))
        _ = run(reviveTombstones(in: state, context: context))
        return RepairPlan(operations)
    }

    // MARK: Order

    /// Oldest `createdAt` first, then the smallest `instanceID.uuidString`: strict, and the same on
    /// every device.
    public static func keeperOrder<T: KeeperOrdered>(_ records: [T]) -> [T] {
        records.sorted { precedes($0, $1) }
    }

    static func precedes(_ lhs: some KeeperOrdered, _ rhs: some KeeperOrdered) -> Bool {
        lhs.createdAt != rhs.createdAt
            ? lhs.createdAt < rhs.createdAt
            : lhs.instanceID.uuidString < rhs.instanceID.uuidString
    }

    // MARK: Chains

    /// Follows a tombstone's `mergedIntoID` chain. `nil` if the record is not here or not a tombstone.
    public static func chainEnd(of tombstone: UUID, in snapshot: RepairSnapshot) -> RepairChainEnd? {
        MetadataChains(snapshot).end(of: tombstone)
    }

    // MARK: Pass 1

    /// Every document reference and tag parent that points at a tombstone whose chain ends at a live
    /// record goes to that record. A loop or a missing end changes nothing here.
    public static func repointReferences(in snapshot: RepairSnapshot) -> RepairPlan {
        let chains = MetadataChains(snapshot)
        func target(of reference: UUID?) -> (from: UUID, to: UUID)? {
            guard let reference, case .live(let live)? = chains.end(of: reference) else { return nil }
            return (reference, live)
        }

        var operations: [RepairOperation] = []
        for document in keeperOrder(snapshot.documents) {
            let instanceID = document.instanceID
            if let (from, to) = target(of: document.correspondent) {
                operations.append(.repoint(reference: .correspondent(document: instanceID), from: from, to: to))
            }
            if let (from, to) = target(of: document.documentType) {
                operations.append(.repoint(reference: .documentType(document: instanceID), from: from, to: to))
            }
            for tag in document.tags.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let (from, to) = target(of: tag) {
                    operations.append(.repoint(reference: .tag(document: document.instanceID), from: from, to: to))
                }
            }
        }
        for tag in keeperOrder(snapshot.metadata.filter { $0.kind == .tag }) {
            if let (from, to) = target(of: tag.parentInstanceID) {
                operations.append(.repoint(reference: .parent(tag: tag.instanceID), from: from, to: to))
            }
        }
        return RepairPlan(operations)
    }

    // MARK: Pass 2

    /// Live records of one kind with the same normalized name merge into the `keeperOrder` minimum;
    /// tags only under the same parent, top down, until a round merges nothing. Empty names and
    /// tombstones are never grouped.
    public static func mergeSameNames(in snapshot: RepairSnapshot) -> RepairPlan {
        var operations: [RepairOperation] = []
        for kind in [MetadataKind.correspondent, .documentType] {
            let records = keeperOrder(snapshot.metadata.filter { $0.kind == kind && $0.isLive })
            operations += mergeOperations(kind: kind, groups: duplicates(records) { MetadataName.normalized($0.name) })
        }

        // Merging two tags makes their children siblings, so the rounds simulate each merge. The date is
        // only a placeholder: planning a merge does not read `mergedAt`.
        var state = snapshot
        while true {
            let tags = keeperOrder(state.metadata.filter { $0.kind == .tag && $0.isLive })
            let groups = duplicates(tags) { tag in
                let name = MetadataName.normalized(tag.name)
                return name.isEmpty ? "" : "\(tag.parentInstanceID?.uuidString ?? "root")/\(name)"
            }
            let application = RepairPlan(mergeOperations(kind: .tag, groups: groups))
                .apply(to: state, now: Date(timeIntervalSince1970: 0))
            guard !application.applied.isEmpty else { break }
            operations += application.applied
            state = application.snapshot
        }
        return RepairPlan(operations)
    }

    private static func mergeOperations(kind: MetadataKind, groups: [[MetadataSnapshot]]) -> [RepairOperation] {
        groups.flatMap { group in
            group.dropFirst().map {
                .mergeMetadata(kind: kind, loser: $0.instanceID, into: group[0].instanceID)
            }
        }
    }

    /// Groups with more than one record, each in input order. An empty key is not a group.
    private static func duplicates(
        _ records: [MetadataSnapshot],
        key: (MetadataSnapshot) -> String
    ) -> [[MetadataSnapshot]] {
        var groups: [String: [MetadataSnapshot]] = [:]
        var order: [String] = []
        for record in records {
            let name = key(record)
            guard !name.isEmpty else { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(record)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    // MARK: Pass 3

    /// Every cycle among live tags gets its `keeperOrder` minimum made a root. A parent chain that
    /// reaches a tombstone or a missing record ends there and is not a cycle.
    public static func breakCycles(in snapshot: RepairSnapshot) -> RepairPlan {
        let tags = keeperOrder(snapshot.metadata.filter { $0.kind == .tag && $0.isLive })
        let byInstance = Dictionary(tags.map { ($0.instanceID, $0) }, uniquingKeysWith: { first, _ in first })
        var finished: Set<UUID> = []
        var operations: [RepairOperation] = []
        for tag in tags {
            // Walk up until a tag repeats; the cycle is the part from its first visit on.
            var chain: [MetadataSnapshot] = []
            var position: [UUID: Int] = [:]
            var current: MetadataSnapshot? = tag
            while let next = current, !finished.contains(next.instanceID), position[next.instanceID] == nil {
                position[next.instanceID] = chain.count
                chain.append(next)
                current = next.parentInstanceID.flatMap { byInstance[$0] }
            }
            if let repeated = current, let start = position[repeated.instanceID],
                let oldest = keeperOrder(Array(chain[start...])).first, let parent = oldest.parentInstanceID
            {
                operations.append(.makeRoot(tag: oldest.instanceID, expectedParent: parent))
            }
            finished.formUnion(chain.map(\.instanceID))
        }
        return RepairPlan(operations)
    }

    // MARK: Pass 4

    /// An unlinked blob whose `documentID` names a present document without a blob of that kind is
    /// linked to it. Of several unlinked blobs for one document only the `keeperOrder` minimum is; the
    /// others stay unlinked and are counted. If documents share the `id`, they are served in
    /// `keeperOrder`, one blob each.
    public static func relinkBlobs(in snapshot: RepairSnapshot) -> RepairPlan {
        var operations: [RepairOperation] = []
        let documents = keeperOrder(snapshot.documents)
        for kind in BlobKind.allCases {
            let blobs = snapshot.blobs.filter { $0.kind == kind }
            let taken = Set(blobs.compactMap(\.linkedDocumentInstanceID))
            var free = Dictionary(grouping: documents.filter { !taken.contains($0.instanceID) }, by: \.id)
            for blob in keeperOrder(blobs) where blob.linkedDocumentInstanceID == nil {
                guard let documentID = blob.documentID, let document = free[documentID]?.first else { continue }
                free[documentID]?.removeFirst()
                operations.append(.relink(blob: blob.instanceID, to: document.instanceID))
            }
        }
        return RepairPlan(operations)
    }

    // MARK: Pass 5

    /// A loop's `keeperOrder` minimum is revived at once. The last tombstone of a chain with a missing
    /// end is revived only when `mergedAt` is at least `reviveGrace` ago and this device has completed
    /// a successful import in this session. A tombstone without a `mergedAt` is not old enough.
    public static func reviveTombstones(in snapshot: RepairSnapshot, context: RepairContext) -> RepairPlan {
        let chains = MetadataChains(snapshot)
        var revived: Set<UUID> = []
        for tombstone in snapshot.metadata where !tombstone.isLive {
            switch chains.end(of: tombstone.instanceID) {
            case .loop(let minimum):
                revived.insert(minimum)
            case .missing(let last):
                guard context.hasCompletedImport, let mergedAt = chains.record(last)?.mergedAt,
                    context.now.timeIntervalSince(mergedAt) >= reviveGrace
                else { continue }
                revived.insert(last)
            case .live, nil:
                continue
            }
        }
        let records = keeperOrder(snapshot.metadata.filter { revived.contains($0.instanceID) })
        return RepairPlan(records.map { .revive(tombstone: $0.instanceID) })
    }

    // MARK: Counts

    /// The diagnostics for this state; see `RepairCounts`.
    public static func counts(in snapshot: RepairSnapshot) -> RepairCounts {
        var counts = RepairCounts()
        let documentIDs = Set(snapshot.documents.map(\.id))
        func isOrphan(_ blob: BlobSnapshot) -> Bool {
            guard blob.linkedDocumentInstanceID == nil else { return false }
            return blob.documentID.map { !documentIDs.contains($0) } ?? true
        }
        func documentsWithTwo(_ kind: BlobKind) -> Int {
            let blobs = snapshot.blobs.filter { $0.kind == kind }
            return snapshot.documents.count { document in
                blobs.count {
                    $0.linkedDocumentInstanceID == document.instanceID
                        || ($0.linkedDocumentInstanceID == nil && $0.documentID == document.id)
                } >= 2
            }
        }
        counts.orphanFiles = snapshot.blobs.count { $0.kind == .file && isOrphan($0) }
        counts.orphanThumbnails = snapshot.blobs.count { $0.kind == .thumbnail && isOrphan($0) }
        counts.documentsWithTwoFiles = documentsWithTwo(.file)
        counts.documentsWithTwoThumbnails = documentsWithTwo(.thumbnail)
        counts.idGroupsWithSeveralRecords = Dictionary(grouping: snapshot.documents, by: \.id).values
            .count { $0.count > 1 }
        for kind in MetadataKind.allCases {
            let records = snapshot.metadata.filter { $0.kind == kind }
            counts.idGroupsWithSeveralRecords += Dictionary(grouping: records, by: \.id).values.count { $0.count > 1 }
        }
        counts.tombstones = snapshot.metadata.count { !$0.isLive }
        return counts
    }
}

/// The metadata of one snapshot, indexed for following `mergedIntoID`.
struct MetadataChains {
    private struct TargetKey: Hashable {
        let kind: MetadataKind
        let id: UUID
    }

    private let byInstance: [UUID: MetadataSnapshot]
    private let byTarget: [TargetKey: [MetadataSnapshot]]

    init(_ snapshot: RepairSnapshot) {
        byInstance = Dictionary(snapshot.metadata.map { ($0.instanceID, $0) }, uniquingKeysWith: { first, _ in first })
        byTarget = Dictionary(grouping: RepairPlanner.keeperOrder(snapshot.metadata)) {
            TargetKey(kind: $0.kind, id: $0.id)
        }
    }

    func record(_ instanceID: UUID) -> MetadataSnapshot? {
        byInstance[instanceID]
    }

    /// `nil` if the record is not here or is live.
    func end(of instanceID: UUID) -> RepairChainEnd? {
        guard let start = byInstance[instanceID], !start.isLive else { return nil }
        var path: [MetadataSnapshot] = []
        var position: [UUID: Int] = [:]
        var current = start
        while true {
            if current.isLive { return .live(current.instanceID) }
            if let first = position[current.instanceID] {
                let minimum = RepairPlanner.keeperOrder(Array(path[first...]))[0]
                return .loop(minimum: minimum.instanceID)
            }
            position[current.instanceID] = path.count
            path.append(current)
            guard let next = next(after: current) else { return .missing(lastTombstone: current.instanceID) }
            current = next
        }
    }

    /// Records can share an `id`: the chain follows the first live one in `keeperOrder`, or else the
    /// first tombstone. A tombstone is never its own next: a merge always goes into another record, so
    /// one that names its own `id` was merged into a record sharing that `id` that is not here.
    private func next(after tombstone: MetadataSnapshot) -> MetadataSnapshot? {
        guard let target = tombstone.mergedIntoID else { return nil }
        let candidates = (byTarget[TargetKey(kind: tombstone.kind, id: target)] ?? [])
            .filter { $0.instanceID != tombstone.instanceID }
        return candidates.first(where: \.isLive) ?? candidates.first
    }
}
